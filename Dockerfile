# Custom ERPNext image bundling Frappe CRM.
#
# Extends the pinned upstream image (v16.4.1) with the Frappe CRM app so it's
# present on every pod (apps/ is not on a PVC in this chart, so apps must live
# in the image). `bench install-app crm` + `bench migrate` are run separately,
# after the rollout, against the live site.
#
# Build:
#   docker build -t ghcr.io/gliax/erpnext:v16.4.1-crm-v1.80.0 \
#     --build-arg CRM_VERSION=v1.80.0 .
# Push:
#   docker push ghcr.io/gliax/erpnext:v16.4.1-crm-v1.80.0
FROM frappe/erpnext:v16.4.1

ARG CRM_VERSION=v1.79.1

WORKDIR /home/frappe/frappe-bench

# Fetch the CRM app into apps/crm and install its Python deps. Uses --skip-checkout
# semantics via get-app: clones, installs requirements, and runs the app's build
# step so it's importable. Does NOT touch site data (no install-app here).
RUN bench get-app "https://github.com/frappe/crm.git" --branch "${CRM_VERSION}"

# Sanity: CRM is present in apps/. (bench registers it in sites/apps.txt.)
RUN test -d /home/frappe/frappe-bench/apps/crm \
 && grep -q "crm" /home/frappe/frappe-bench/sites/apps.txt \
 && echo "crm app present"
