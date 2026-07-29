# Custom ERPNext image bundling Frappe CRM.
#
# Extends the pinned upstream image (v16.4.1) with the Frappe CRM app so it's
# present on every pod (apps/ is not on a PVC in this chart, so apps must live
# in the image). `bench install-app crm` + `bench migrate` are run separately,
# after the rollout, against the live site.
#
# CRM source: the Glia fork's v1.x branch carrying the assign_to fix
# (use public add() instead of removed private _add()), pending upstream merge
# of frappe/crm#2581. v1.x (not develop/v2) for Frappe 16 compatibility.
#
# Build (the CI workflow does this on push):
#   docker build -t ghcr.io/gliax/erpnext:v16.4.1-crm-v1.80.0-fix \
#     --build-arg CRM_REPO=https://github.com/tareko/crm.git \
#     --build-arg CRM_BRANCH=fix-assign-to-v1.x .
FROM frappe/erpnext:v16.4.1

ARG CRM_REPO=https://github.com/tareko/crm.git
ARG CRM_BRANCH=fix-assign-to-v1.x

WORKDIR /home/frappe/frappe-bench

# Fetch the CRM app into apps/crm and install its Python deps. Clones, installs
# requirements, and builds assets so the app is importable. Does NOT touch site
# data (no install-app here).
RUN bench get-app "${CRM_REPO}" --branch "${CRM_BRANCH}"

# Sanity: CRM is present in apps/. (bench registers it in sites/apps.txt.)
RUN test -d /home/frappe/frappe-bench/apps/crm \
 && grep -q "crm" /home/frappe/frappe-bench/sites/apps.txt \
 && echo "crm app present"
