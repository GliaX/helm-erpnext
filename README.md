# helm-erpnext

Infrastructure-as-code for Glia's ERPNext deployment at **`asset.glia.org`**.

This repo wraps the upstream [`frappe/erpnext`](https://github.com/frappe/erpnext)
Helm chart, pins it to the deployed version, and holds Glia's configuration —
**without secrets**. It is the single source of truth for how the cluster is
configured; `kubectl apply`/manual edits should be avoided going forward.

| | |
|---|---|
| **Release / namespace** | `erpnext` / `erpnext` |
| **Upstream chart** | `frappe/erpnext` **8.0.21** |
| **App version (image)** | `frappe/erpnext:v16.4.1` |
| **Site** | `asset.glia.org` |
| **Database** | in-cluster MariaDB statefulset (`mariadb:10.6`) on a DigitalOcean block-storage PVC (`do-block-storage`, 8 Gi). A DigitalOcean managed DB is configured in `values.yaml` but currently **disabled** (commented). |
| **Backups** | `data-erpnext-mariadb-sts-0` PVC + `erpnext` (sites) PVC. See [Backups](#backups). |

## Layout

```
helm-erpnext/
├── Chart.yaml                   # wrapper chart; depends on frappe/erpnext 8.0.21
├── values.yaml                  # Glia config, SANITIZED (no secrets)
├── values.secret.example.yaml   # template — copy to values.secret.yaml (gitignored)
└── .gitignore                   # keeps values.secret.yaml + charts/ out of git
```

## One-time bootstrap (local workstation)

```bash
helm repo add frappe https://helm.erpnext.com
git clone git@github.com:GliaX/helm-erpnext.git
cd helm-erpnext
helm dep update .                 # fetches the upstream chart into charts/

cp values.secret.example.yaml values.secret.yaml
# edit values.secret.yaml — fill in the real passwords (see recover step below)
```

### Recovering the current secrets (if not recorded)

Before the first IaC-driven upgrade, capture the live passwords so the new
manifests match the existing DB:

```bash
# MariaDB root password (from the running statefulset env / existing secret)
kubectl -n erpnext exec erpnext-mariadb-sts-0 -- printenv | grep -i mysql
kubectl -n erpnext get secret -o yaml | grep -iE 'root|password'

# ERPNext Administrator password is NOT recoverable from the cluster — if lost,
# reset it via bench: kubectl -n erpnext exec deploy/erpnext-gunicorn -- \
#   bench --site asset.glia.org set-admin-password <new>
```

## Day-to-day operations

```bash
# Preview a change (dry run)
helm -n erpnext diff upgrade erpnext . -f values.yaml -f values.secret.yaml   # needs helm-diff

# Apply
helm -n erpnext upgrade --install erpnext . -f values.yaml -f values.secret.yaml

# Run bench migrate after an app/chart upgrade (uses the chart's migrate Job)
# — in values.yaml set jobs.migrate.enabled: true, siteName: asset.glia.org,
#   then helm upgrade (the Job runs once), then set it back to false.

# Create a site (idempotent; skips if it exists) — jobs.createSite in values.yaml.
```

## Backups

Before any write/upgrade, take a backup. Two equivalent options:

**Option A — bench backup (logical):**
```bash
kubectl -n erpnext exec deploy/erpnext-gunicorn -- \
  bench --site asset.glia.org backup --with-files
# Copy the dump off the PVC afterwards.
```

**Option B — DigitalOcean volume snapshot:** snapshot the `data-erpnext-mariadb-sts-0`
PVC (and the `erpnext` sites PVC) from the DigitalOcean console / `doctl`.

## Upgrading ERPNext

1. Take a backup (above).
2. Pick a target chart version: `helm search repo frappe/erpnext --versions`.
3. Update `Chart.yaml` `dependencies[0].version` and `appVersion`.
4. `helm dep update .`
5. `helm -n erpnext upgrade erpnext . -f values.yaml -f values.secret.yaml`
6. Enable `jobs.migrate` for one run (see above).

## Adding Frappe apps (e.g. Frappe CRM) — future

Apps must be baked into the image (only `sites/` is persistent in this chart).
The durable, IaC-native way is to maintain a custom image in **this repo**:

1. Add a `Dockerfile` extending `frappe/erpnext:<tag>` that runs
   `bench get-app https://github.com/frappe/<app>`.
2. Build & push to a registry.
3. Set `image.repository`/`image.tag` in `values.yaml` and append the app to
   `jobs.createSite.installApps`.
4. `helm upgrade` (backup first), then `bench --site asset.glia.org install-app <app> && bench migrate`.

The current Shopify→ERPNext donation sync does **not** require any new app (it
uses core doctypes + one custom doctype created via the API). See
`GliaX/glia-shopify-erpnext`.

## Secret hygiene

- `values.yaml` is **secret-free** (verified). The 3 deployment secrets live in
  the gitignored `values.secret.yaml` overlay.
- Future improvement: migrate to a Kubernetes `Secret` referenced via the
  chart's `*ExistingSecret` fields (`dbExistingSecret`, `adminExistingSecret`) so
  no plaintext password is ever needed at `helm upgrade` time.
