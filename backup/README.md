# ERPNext backups & disaster recovery

**Status (2026-11-15):** automated backups run **every 6 hours**, are copied to
**two independent off-cluster providers**, are monitored by an alert that
emails `info@glia.org` when they stop, and a restore has been **proven** by
loading a dumped copy into a scratch database.

Before this existed there was no automated backup at all and `sites/` lived only
on a single ReadWriteOnce DigitalOcean volume — losing the node or the PVC lost
the whole store.

---

## 1. What runs

CronJob `erpnext-backup` in namespace `erpnext`, schedule `30 */6 * * *
America/Toronto` (00:30, 06:30, 12:30, 18:30). One pod, pinned to
`nodeSelector: glia.workload=erpnext` because the sites PVC is ReadWriteOnce.

`backup/backup.sh` (mounted from ConfigMap `erpnext-backup-scripts`):

1. `bench --site asset.glia.org backup --with-files` → `sites/<site>/private/backups/`:
   - `<stamp>-asset_glia_org-database.sql.gz` (~13.5 MB)
   - `<stamp>-asset_glia_org-files.tar` (~106 MB public files)
   - `<stamp>-asset_glia_org-private-files.tar` (~240 KB)
   - `<stamp>-asset_glia_org-site_config_backup.json`
2. **Integrity:** `gzip -t` on the dump, `tar -tf` on both archives.
3. **Copy #1 — Nextcloud** (WebDAV, off-cluster droplet):
   `https://cloud.glia.org/remote.php/dav/files/tloubani/erpnext-backups/asset.glia.org/`
   Each file is uploaded then re-read off-cluster and its `Content-Length`
   compared with the local size.
4. **Copy #2 — DigitalOcean Spaces** (`backup/spaces.py`, boto3, S3 API) into a
   **dedicated bucket**, `glia-erpnext-backups` (nyc3, private), under
   `<site>/<stamp>/`. Each object is verified by `HEAD` size. A different
   provider from copy #1, and separate from the Mattermost bucket — the script
   **refuses to write into `glia-group`** so a stale secret cannot put donor
   data back there.
5. **Retention:** 14 days on the PVC, 120 days on both remote copies.
6. **Both copies are mandatory:** if either credential set is missing the run
   fails (rather than silently degrading to a single copy) and the health check
   alerts.
7. **Status marker:** `sites/<site>/private/backups/last_run.json` —
   `{status: ok|failed, stage, stamp, finished}`. A `trap` writes `failed` with
   the stage where it died.

Any failure exits non-zero → the Job is marked failed, and the marker tells the
health check *where* it broke.

## 2. Alerting

The backup job cannot alert about its own failure, so the check is out-of-band:
the **`glia_ops`** app (<https://github.com/GliaX/glia-ops>) runs a Frappe
scheduler job (`glia_ops.backups.daily_check`) that reads the marker and emails
`info@glia.org` when it is:

- missing (nothing has ever completed, or the volume was replaced),
- `failed` (the mail names the failing stage), or
- older than 26 h (three missed 6-hourly runs).

Alerts are de-duplicated for 12 h and the dedupe clears as soon as a healthy
backup lands, so the next incident alerts immediately.

Run it by hand:

```sh
kubectl -n erpnext exec deploy/erpnext-gunicorn -- bash -lc \
  'cd /home/frappe/frappe-bench && bench --site asset.glia.org execute glia_ops.backups.run_check'
```

It reports `{"healthy": true|false, ...}` and sends mail only when unhealthy.

---

## 3. Credentials & manifests

All secrets are created out of band; none are in git.

```sh
# copy #1 — Nextcloud app password (ACCESS.md §2)
kubectl -n erpnext create secret generic erpnext-backup-nextcloud \
  --from-literal=NC_URL=https://cloud.glia.org \
  --from-literal=NC_USER=tloubani \
  --from-literal=NC_PASS=<app password>

# copy #2 — dedicated bucket + its own bucket-scoped key.
# Bucket glia-erpnext-backups (nyc3, private) was created with doctl on
# 2026-11-15; the key below can only touch that bucket:
#   doctl spaces keys create glia-erpnext-backup \
#     --grants 'bucket=glia-erpnext-backups;permission=readwrite'
kubectl -n erpnext create secret generic erpnext-backup-spaces \
  --from-literal=SPACES_ENDPOINT=https://nyc3.digitaloceanspaces.com \
  --from-literal=SPACES_REGION=nyc3 \
  --from-literal=SPACES_BUCKET=glia-erpnext-backups \
  --from-literal=SPACES_PREFIX= \
  --from-literal=SPACES_KEY=<access key> \
  --from-literal=SPACES_SECRET=<secret key>
```

Scripts live in this repo and are mounted from a ConfigMap — **re-apply after
editing `backup.sh` or `spaces.py`**:

```sh
kubectl -n erpnext create configmap erpnext-backup-scripts \
  --from-file=backup/backup.sh --from-file=backup/spaces.py \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f backup/erpnext-backup-cronjob.yaml
```

Rotation = update the secret; no image or manifest change needed.

---

## 4. Daily operations

```sh
kubectl -n erpnext get cronjob,jobs | grep erpnext-backup   # schedule + history
kubectl -n erpnext logs job/<job-name>                      # what happened
kubectl -n erpnext exec deploy/erpnext-gunicorn -- \
  cat /home/frappe/frappe-bench/sites/asset.glia.org/private/backups/last_run.json
```

Run one now:

```sh
kubectl -n erpnext create job --from=cronjob/erpnext-backup "erpnext-backup-manual-$(date +%H%M)"
kubectl -n erpnext logs -f job/<job-name>
```

A healthy run ends with `[backup] done: <stamp> backed up locally, on Nextcloud
and mirrored to Spaces`, and the marker shows `"status": "ok"`.

---

## 5. Restore drill (performed 2026-11-15)

The point of a backup is a restore that works.

```sh
# 1. pull the newest dump back from Nextcloud (proves the remote copy is real)
curl -u "$NEXTCLOUD_USERNAME:$NEXTCLOUD_APP_PASSWORD" \
  "$NEXTCLOUD_URL/remote.php/dav/files/$NEXTCLOUD_USERNAME/erpnext-backups/asset.glia.org/<stamp>-asset_glia_org-database.sql.gz" \
  -o /tmp/drill.sql.gz && gzip -t /tmp/drill.sql.gz

# 2. load into a scratch database (never the live one)
ROOTPW=$(kubectl -n erpnext get secret erpnext -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
kubectl -n erpnext exec erpnext-mariadb-sts-0 -- \
  mysql -uroot -p"$ROOTPW" -e 'CREATE DATABASE restore_drill CHARACTER SET utf8mb4'
gzip -dc /tmp/drill.sql.gz | kubectl -n erpnext exec -i erpnext-mariadb-sts-0 -- \
  mysql -uroot -p"$ROOTPW" restore_drill

# 3. sanity counts, then drop
kubectl -n erpnext exec erpnext-mariadb-sts-0 -- mysql -uroot -p"$ROOTPW" -N \
  -e 'SELECT COUNT(*) FROM restore_drill.`tabSales Order`'
kubectl -n erpnext exec erpnext-mariadb-sts-0 -- \
  mysql -uroot -p"$ROOTPW" -e 'DROP DATABASE restore_drill'
```

Result for `20261115_011040` (live counts in brackets): 816 tables ·
14,926 contacts (14,926) · 4,275 customers (4,275) · 580 sales orders (580) ·
29 website items (29) · 247 items (247) · 38 blog posts (38). **Match.**

---

## 6. Full-site restore (disaster)

```sh
kubectl -n erpnext exec -it deploy/erpnext-gunicorn -- bash
cd /home/frappe/frappe-bench

# 1. bring the newest set down (Nextcloud or Spaces) into
#    sites/asset.glia.org/private/backups/

# 2. recreate the site skeleton if the PVC is gone
bench new-site asset.glia.org --mariadb-root-password <pw> \
  --admin-password <pw> --install-app erpnext

# 3. restore database + files
bench --site asset.glia.org restore \
  sites/asset.glia.org/private/backups/<stamp>-asset_glia_org-database.sql.gz \
  --with-public-files sites/asset.glia.org/private/backups/<stamp>-asset_glia_org-files.tar \
  --with-private-files sites/asset.glia.org/private/backups/<stamp>-asset_glia_org-private-files.tar \
  --force

# 4. align apps with the image, then migrate
bench --site asset.glia.org install-app payments webshop crm glia_email_builder \
  glia_guest_checkout glia_donations glia_ops
bench --site asset.glia.org migrate
bench --site asset.glia.org clear-cache
```

Then verify `/all-products`, a product page, `/guest_cart`, `/recurring_donation`
and the desk login. The `*-site_config_backup.json` carries `encryption_key` —
restore the same key or stored secrets (gateway keys) become unreadable.

---

## 7. Known gaps

- **Files are not encrypted at rest**: the Spaces bucket and Nextcloud folder
  hold the dump as-is. Both are private, but client-side encryption (age/gpg
  with an offline key) would harden this.
- **Two providers, two failure domains**: copy #1 is Nextcloud on the auth
  droplet, copy #2 a dedicated DO Spaces bucket with a bucket-scoped key. They
  share no credentials and no bucket with any other service.
- **No point-in-time recovery**: MariaDB binary logs are not archived, so
  worst-case loss is one backup interval (currently ≤ 6 h). Tighten the schedule
  if that is still too much.
- **Restore drill is manual**: repeat it after schema-changing upgrades, at
  least quarterly; a monthly automated drill against a scratch DB would be
  better.
- **Alerting is email only**: if the mail relay is down, the alert is lost.
  A Mattermost webhook as a second channel would help.
