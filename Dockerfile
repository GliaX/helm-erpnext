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

# Fetch the Webshop (E Commerce) app. Same get-app flow.
RUN bench get-app "${WEBSHOP_REPO}" --branch "${WEBSHOP_BRANCH}"

# In a siteless image build, `bench get-app` does not always register the app in
# sites/apps.txt — and `bench build` only compiles+symlinks apps listed there.
# Register all bundled apps explicitly, then build (compiles JS/CSS bundles,
# writes the shared assets.json manifest, and creates the assets/<app> symlinks
# Frappe serves). Without this, webshop's bundles 404 and the storefront is blank.
RUN cd /home/frappe/frappe-bench \
 && for app in payments webshop crm; do \
        grep -qxF "$app" sites/apps.txt || echo "$app" >> sites/apps.txt; \
    done
RUN bench build
# Belt-and-suspenders: ensure the assets/<app> symlinks exist (bench build makes
# these, but recreate for any app that was missed).
RUN cd /home/frappe/frappe-bench \
 && for app in payments webshop crm; do \
        src="apps/$app/$app/public"; \
        [ -d "$src" ] && ln -sfn "$(pwd)/$src" "assets/$app" || true; \
    done
# bench build compiles webshop's bundles but (in this version) does NOT register
# them in the shared assets/assets.json manifest. Without the mapping, Frappe's
# include_script('web.bundle.js') can't resolve the hashed path and the storefront
# renders blank. Register them explicitly, pointing at the COMPILED dist bundles
# (not the source web.bundle.js, which is raw ES-module imports). Hashes are read
# from the freshly-built dist files.
RUN cd /home/frappe/frappe-bench \
 && js="$(basename $(ls apps/webshop/webshop/public/dist/js/web.bundle.*.js | head -1))" \
 && css="$(basename $(ls apps/webshop/webshop/public/dist/css/webshop-web.bundle.*.css | head -1))" \
 && python3 -c "import json,sys; p='assets/assets.json'; d=json.load(open(p)); j,c=sys.argv[1],sys.argv[2]; d['web.bundle.js']='/assets/webshop/dist/js/'+j; d['webshop-web.bundle.css']='/assets/webshop/dist/css/'+c; json.dump(d, open(p,'w'), indent=2); print('registered webshop bundles js='+j+' css='+c)" "$js" "$css"

# Sanity: all apps present and webshop assets collected.
RUN test -d /home/frappe/frappe-bench/apps/crm \
 && test -d /home/frappe/frappe-bench/apps/payments \
 && test -d /home/frappe/frappe-bench/apps/webshop \
 && test -d /home/frappe/frappe-bench/assets/webshop \
 && grep -q "crm" /home/frappe/frappe-bench/sites/apps.txt \
 && grep -q "payments" /home/frappe/frappe-bench/sites/apps.txt \
 && grep -q "webshop" /home/frappe/frappe-bench/sites/apps.txt \
 && echo "crm + payments + webshop apps present, assets built"
