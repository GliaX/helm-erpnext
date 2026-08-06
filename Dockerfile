# Custom ERPNext image bundling Frappe CRM + Frappe Webshop (E Commerce).
#
# Extends the pinned upstream image (v16.30.0) with extra apps so they're
# present on every pod (apps/ is not on a PVC in this chart, so apps must live
# in the image). `bench install-app <app>` + `bench migrate` are run separately,
# after the rollout, against the live site.
#
# Apps bundled:
#   * CRM (Frappe CRM) — the Glia fork's v1.x branch carrying the assign_to fix
#     (use public add() instead of removed private _add()), pending upstream
#     merge of frappe/crm#2581. v1.x (not develop/v2) for Frappe 16 compat.
#   * Webshop (frappe/webshop, version-16) — the E Commerce app extracted out
#     of core erpnext in v15+. Provides Website Item, Webshop/E Commerce
#     Settings, and Shopping Cart (needed for the Shopify -> ERPNext shop
#     migration). Without it, the catalog sync imports Items/Prices only and
#     skips storefront publishing. Depends on the Payments app.
#   * Payments (frappe/payments, version-16) — payment gateway plumbing,
#     extracted from core frappe in v15+. Required by Webshop.
#
# Build (the CI workflow does this on push):
#   docker build -t ghcr.io/gliax/erpnext:v16.30.0-crm-v1.80.0-webshop \
#     --build-arg CRM_REPO=https://github.com/tareko/crm.git \
#     --build-arg CRM_BRANCH=fix-assign-to-v1.x .
FROM frappe/erpnext:v16.30.0

ARG CRM_REPO=https://github.com/tareko/crm.git
ARG CRM_BRANCH=fix-assign-to-v1.x
ARG PAYMENTS_REPO=https://github.com/frappe/payments.git
ARG PAYMENTS_BRANCH=version-16
ARG WEBSHOP_REPO=https://github.com/frappe/webshop.git
ARG WEBSHOP_BRANCH=version-16

WORKDIR /home/frappe/frappe-bench

# Fetch the CRM app into apps/crm and install its Python deps. Clones, installs
# requirements, and builds assets so the app is importable. Does NOT touch site
# data (no install-app here).
RUN bench get-app "${CRM_REPO}" --branch "${CRM_BRANCH}"

# Fetch the Payments app (extracted from core frappe in v15+). Webshop imports
# `payments`, so it must be present before webshop.
RUN bench get-app "${PAYMENTS_REPO}" --branch "${PAYMENTS_BRANCH}"

# Fetch the Webshop (E Commerce) app. Same get-app flow; assets are built below.
RUN bench get-app "${WEBSHOP_REPO}" --branch "${WEBSHOP_BRANCH}"

# Build + collect assets for every app. This compiles each app's JS/CSS bundles,
# generates the shared assets manifest (assets.json), and creates the
# assets/<app> symlinks Frappe serves. WITHOUT this, webshop's bundles 404 and
# the storefront renders blank. The base image has node.js; the running pod does not.
RUN bench build

# Sanity: all apps are present in apps/. (bench registers them in apps.txt.)
RUN test -d /home/frappe/frappe-bench/apps/crm \
 && test -d /home/frappe/frappe-bench/apps/payments \
 && test -d /home/frappe/frappe-bench/apps/webshop \
 && test -d /home/frappe/frappe-bench/assets/webshop \
 && grep -q "crm" /home/frappe/frappe-bench/sites/apps.txt \
 && grep -q "payments" /home/frappe/frappe-bench/sites/apps.txt \
 && grep -q "webshop" /home/frappe/frappe-bench/sites/apps.txt \
 && echo "crm + payments + webshop apps present, assets built"
