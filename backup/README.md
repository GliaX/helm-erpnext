# ERPNext backups & disaster recovery

**Status (2026-11-15):** automated daily backup with an off-cluster copy is
**live**, and a restore has been **proven** by loading a dumped copy into a
scratch database on the cluster.

Before this existed the newest dump was a hand-run one and `sites/` lived only
on a single ReadWriteOnce DigitalOcean block volume — losing the node or the
PVC lost the whole store.

---

## 1. What runs

`erpnext-backup-cronjob.yaml` — CronJob `erpnext-backup` in namespace
`erpnext`, **03:30 America/Toronto daily**.

1. `bench --site asset.glia.org backup --with-files` inside a pod that mounts
   the same sites PVC (pinned by `nodeSelector: glia.workload=erpnext`, because
   the volume is ReadWriteOnce and only pods on that node may attach it).
   Produces, under `sites/asset.glia.org/private/backups/`:
   - `<stamp>-asset_glia_org-database.sql.gz` (~13 MB)
   - `<stamp>-asset_glia_org-files.tar` (~106 MB, public files)
   - `<stamp>-asset_glia_org-private-files.tar` (~240 KB)
   - `<stamp>-asset_glia_org-site_config_backup.json`
2. **Verifies** locally: `gzip -t` on the dump and `tar -tf` on both archives.
3. **Uploads** the set to Nextcloud over WebDAV, then re-reads each file's
   `Content-Length` off-cluster and compares it with the local size. A mismatch
   fails the job.
4. **Prunes**: local sets older than 14 days, remote sets older than 120 days
   (both by the timestamp in the filename).

Off-cluster destination:
`https://cloud.glia.org/remote.php/dav/files/tloubani/erpnext-backups/asset.glia.org/`

Credentials live in the k8s Secret `erpnext-backup-nextcloud`
(`NC_URL`, `NC_USER`, `NC_PASS` = a Nextcloud **app password**, ACCESS.md §2).
Re-create it, never commit it:

```sh
kubectl -n erpnext create secret generic erpnext-backup-nextcloud \
  --from-literal=NC_URL=https://cloud.glia.org \
  --from-literal=NC_USER=tloubani \
  --from-literal=NC_PASS=<app password>
```

---

## 2. Daily operations

```sh
kubectl -n erpnext get cronjob erpnext-backup            # schedule/state
kubectl -n erpnext get jobs | grep erpnext-backup        # history
kubectl -n erpnext logs job/<job-name>                   # what happened
```

Run one now:

```sh
kubectl -n erpnext create job --from=cronjob/erpnext-backup "erpnext-backup-manual-$(date +%H%M)"
kubectl -n erpnext logs -f job/<job-name>
```

A healthy run ends with `[backup] done: <stamp> backed up locally and
off-cluster`, and every file prints `verified … (N bytes off-cluster)`.

Note: finished Jobs are kept 14 days (`ttlSecondsAfterFinished`), so a failure
is easy to inspect after the fact.

---

## 3. Restore drill (already performed 2026-11-15)

The point of a backup is a restore that works. This drill was run end-to-end:

```sh
# 1. pull the newest dump back from Nextcloud (proves the off-cluster copy is real)
curl -u "$NEXTCLOUD_USERNAME:$NEXTCLOUD_APP_PASSWORD" \
  "$NEXTCLOUD_URL/remote.php/dav/files/$NEXTCLOUD_USERNAME/erpnext-backups/asset.glia.org/<stamp>-asset_glia_org-database.sql.gz" \
  -o /tmp/drill.sql.gz
gzip -t /tmp/drill.sql.gz

# 2. load it into a scratch database (never the live one)
ROOTPW=$(kubectl -n erpnext get secret erpnext -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
kubectl -n erpnext exec erpnext-mariadb-sts-0 -- \
  mysql -uroot -p"$ROOTPW" -e 'CREATE DATABASE restore_drill CHARACTER SET utf8mb4'
gzip -dc /tmp/drill.sql.gz | kubectl -n erpnext exec -i erpnext-mariadb-sts-0 -- \
  mysql -uroot -p"$ROOTPW" restore_drill

# 3. sanity-check counts, then drop it
kubectl -n erpnext exec -i erpnext-mariadb-sts-0 -- mysql -uroot -p"$ROOTPW" -N <<'SQL'
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='restore_drill';
USE restore_drill; SELECT COUNT(*) FROM `tabSales Order`;
SQL
kubectl -n erpnext exec erpnext-mariadb-sts-0 -- mysql -uroot -p"$ROOTPW" -e 'DROP DATABASE restore_drill'
```

Result for `20261115_011040` (live counts in brackets):
816 tables · 14,926 contacts (14,926) · 4,275 customers (4,275) ·
580 sales orders (580) · 29 website items (29) · 247 items (247) ·
38 blog posts (38) · 0 guest carts (0). **Match.**

---

## 4. Full-site restore (disaster)

Assumes the image is deployable and the PVC is empty/lost.

```sh
# 1. get the newest set down from Nextcloud into the bench
kubectl -n erpnext exec -it deploy/erpnext-gunicorn -- bash
cd /home/frappe/frappe-bench
# (inside the pod, with curl available)
#   curl -u ... -T/-o into sites/<site>/private/backups/

# 2. recreate the site skeleton if the PVC is gone
bench new-site asset.glia.org --mariadb-root-password <pw> \
  --admin-password <pw> --install-app erpnext

# 3. restore database + files
bench --site asset.glia.org restore \
  sites/asset.glia.org/private/backups/<stamp>-asset_glia_org-database.sql.gz \
  --with-public-files sites/asset.glia.org/private/backups/<stamp>-asset_glia_org-files.tar \
  --with-private-files sites/asset.glia.org/private/backups/<stamp>-asset_glia_org-private-files.tar \
  --force

# 4. align the installed apps with the image, then migrate
bench --site asset.glia.org install-app payments webshop crm glia_email_builder glia_guest_checkout
bench --site asset.glia.org migrate
bench --site asset.glia.org clear-cache
```

Then verify `/all-products`, a product page, `/guest_cart` and the desk login.
The site config backup (`*-site_config_backup.json`) carries `encryption_key`
and `site_config` — restoring the same encryption key matters, or stored
secrets (gateway keys) become unreadable.

---

## 5. Known gaps

- **Alerting**: a failed job is only visible via `kubectl`. Add a failure
  notification (email/webhook) — not yet wired.
- **Restore drill is manual**: repeat it after any schema-changing upgrade, at
  least quarterly; consider automating it as a monthly job against a scratch DB.
- **Off-cluster copy is single-destination** (Nextcloud on the auth droplet).
  A second destination (DO Spaces or another host) would harden this.
- **No point-in-time recovery**: MariaDB binary logs are not being archived;
  worst-case loss is up to 24 h of orders. Raise the schedule (e.g. every 6 h)
  if that window is unacceptable for a storefront.
