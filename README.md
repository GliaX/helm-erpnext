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

## CRITICAL: node-pinning (`values.pin.yaml`) is REQUIRED

The sites PVC is **ReadWriteOnce** (DigitalOcean block storage) attached to one
node (`pool-f971mwbjk-372vst`). The chart's default topology-spread
(`maxSkew:1 / DoNotSchedule`) scatters pods across nodes during rollouts, which
triggers **Multi-Attach errors** (the cluster even autoscales new nodes trying to
place them). So every deploy/upgrade MUST include the pin overlay:

```bash
helm -n erpnext upgrade erpnext frappe/erpnext --version 8.0.21 \
  -f values.yaml -f values.secret.yaml -f values.pin.yaml
```

`values.pin.yaml` sets `nodeSelector: kubernetes.io/hostname=pool-f971mwbjk-372vst`
on every erpnext deployment and relaxes topology-spread to `ScheduleAnyway`.
**Always pass `-f values.pin.yaml`** or the rollout will deadlock. (Durable fix:
migrate the sites PVC to RWX, or switch its storageClass to
`WaitForFirstConsumer` — tracked as a follow-up.)

## Deploy / upgrade

```bash
helm repo add frappe https://helm.erpnext.com
helm repo update
helm -n erpnext upgrade erpnext frappe/erpnext --version 8.0.21 \
  -f values.yaml -f values.secret.yaml -f values.pin.yaml
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

## Adding Frappe apps (e.g. Frappe CRM) — status: blocked on app bug

Apps must be baked into the image (only `sites/` is persistent in this chart).
The IaC-native way is the `Dockerfile` + `.github/workflows/build-image.yml` in
this repo (builds `ghcr.io/gliax/erpnext:v16.4.1-crm-v1.80.0`).

**Attempted 2026-07-28 — FAILED.** Frappe CRM **v1.80.0** (released that day)
fails to install onto the site against Frappe 16.5.0 / ERPNext 16.4.1 with a
module-resolution error (`No module named 'frappe.core.doctype.crm_lead_status'`
while syncing the `CRM Lead Status` doctype, whose JSON correctly declares
`module: FCRM`). The image rolled out fine, but `bench install-app crm` aborted
mid-sync; we `uninstall-app`'d it and reverted the image. Asset.glia.org was
restored to its pre-change state (verified). The image + pipeline remain here
for a retry with an older CRM release (e.g. **v1.79.1**) once validated.

To retry (after a clean install in a staging site first):
1. Pin a known-good CRM version in `Dockerfile` (`--build-arg CRM_VERSION=v1.79.1`)
   and in `.github/workflows/build-image.yml`.
2. Build & push (the workflow does this on push).
3. `values.yaml`: set `image.repository`/`tag` to the new image and add `"crm"`
   to `jobs.createSite.installApps`.
4. `helm upgrade ... -f values.yaml -f values.secret.yaml -f values.pin.yaml`
   (backup first), then `bench --site asset.glia.org install-app crm && bench migrate`.

The current Shopify→ERPNext donation sync does **not** require Frappe CRM — it
uses ERPNext core doctypes (`Customer`/`Contact`/`Address`) + one custom doctype
created via the API. See `GliaX/glia-shopify-erpnext`.

## Secret hygiene

- `values.yaml` is **secret-free** (verified). The 3 deployment secrets live in
  the gitignored `values.secret.yaml` overlay.
- Future improvement: migrate to a Kubernetes `Secret` referenced via the
  chart's `*ExistingSecret` fields (`dbExistingSecret`, `adminExistingSecret`) so
  no plaintext password is ever needed at `helm upgrade` time.
