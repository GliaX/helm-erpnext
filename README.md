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

## Frappe CRM — INSTALLED (2026-07-29)

Apps must be baked into the image (only `sites/` is persistent in this chart).
This repo's `Dockerfile` + `.github/workflows/build-image.yml` build
`ghcr.io/gliax/erpnext:v16.30.0-crm-v1.80.0-fix`, deployed on `asset.glia.org`.

**Status: ERPNext upgraded to v16.30.0 (Frappe 16.29.0) and Frappe CRM v1.80.0
installed and working.** `bench migrate` is clean, 39 FCRM doctypes present,
CRM Lead/Deal creation verified end-to-end.

### History / why the v16.30 upgrade was required

CRM v1.x uses Frappe framework APIs that older patch releases lack. On the
previous base (`frappe/erpnext:v16.4.1` → **Frappe 16.5.0**) CRM install/migrate
failed in two places:

- `cannot import name '_add' from 'frappe.desk.form.assign_to'` — `_add` is the
  internal worker, absent in some 16.x patches (including 16.5.0). Fixed in our
  fork by using the public `add()` (see `tareko/crm:fix-assign-to-v1.x`; upstream
  PR [frappe/crm#2581](https://github.com/frappe/crm/pull/2581)).
- `cannot import name 'get_dynamic_linked_docs' from 'frappe.model.delete_doc` —
  that symbol was [added to Frappe on 2026-04-13](https://github.com/frappe/frappe/commit/f0ef9295),
  after 16.5.0. Only fixable by upgrading Frappe.

Upgrading the base to `frappe/erpnext:v16.30.0` (Frappe 16.29.0) provides both
symbols, so CRM runs natively. The image still carries the fork's `_add` fix
(harmless on 16.29 where `_add` also exists) until upstream merges #2581, after
which it can switch to vanilla `frappe/crm`.

The Shopify→ERPNext donation sync can target either CRM (`CRM Contact`) or
ERPNext core (`Customer`/`Contact`/`Address`). See `GliaX/glia-shopify-erpnext`.

### Operational notes

- The chart is pinned to **8.0.21** (app v16.30 via the image override). Chart
  8.0.69 restructures the MariaDB templates — upgrading the chart is deferred to
  avoid touching the running MariaDB; do it separately with care.
- `values.pin.yaml` (node-pin) is **required** for every rollout (RWO sites PVC).
- After any future image rebuild, run `bench --site asset.glia.org migrate` then
  `kubectl rollout restart` the erpnext deployments.

## Secret hygiene

- `values.yaml` is **secret-free** (verified). The 3 deployment secrets live in
  the gitignored `values.secret.yaml` overlay.
- Future improvement: migrate to a Kubernetes `Secret` referenced via the
  chart's `*ExistingSecret` fields (`dbExistingSecret`, `adminExistingSecret`) so
  no plaintext password is ever needed at `helm upgrade` time.
