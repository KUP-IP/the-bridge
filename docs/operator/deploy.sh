#!/usr/bin/env bash
#
# deploy.sh — KUP Worker (Bridge Cloud Access control plane) deploy automation.
#
# Automates the wrangler steps from cloud-deploy-runbook.md:
#   1. Create the Cloudflare KV namespace (prod + preview) for the tenant Store.
#   2. Put the control-plane secrets (CAPABILITY_SIGNING_SECRET).
#   3. Deploy the Worker.
#
# It does NOT create your WorkOS tenant, set Bridge (Mac) host env vars, or bind
# the bridge.kup.solutions route — those are operator dashboard / launchd steps
# documented in the runbook. It also does NOT edit wrangler.toml for you: after
# step 1 it PRINTS the [[kv_namespaces]] block to paste in, then waits for you.
#
# Usage:
#   ./deploy.sh                 # full run (create KV, prompt to edit toml, secrets, deploy)
#   DRY_RUN=1 ./deploy.sh       # validate only: wrangler deploy --dry-run, no writes
#   SKIP_KV=1 ./deploy.sh       # KV already created+bound; jump to secrets + deploy
#
# Requirements: wrangler >= 3.x, authenticated (`wrangler login` / API token).
# Run from the kup-worker repo root (where wrangler.toml lives).

set -euo pipefail

# --- config -----------------------------------------------------------------
KV_BINDING="${KV_BINDING:-TENANTS}"          # must match src/index.ts Store binding
WORKER_DIR="${WORKER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
WRANGLER="${WRANGLER:-npx wrangler}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_KV="${SKIP_KV:-0}"

# EXACT secret names read by src/index.ts (Env interface).
SECRETS=("CAPABILITY_SIGNING_SECRET")

cd "$WORKER_DIR"

echo "==> kup-worker deploy  (dir: $WORKER_DIR)"
echo "==> wrangler: $($WRANGLER --version 2>/dev/null | tail -1)"

# --- 0. auth sanity ---------------------------------------------------------
if ! $WRANGLER whoami >/dev/null 2>&1; then
  echo "ERROR: wrangler is not authenticated. Run: wrangler login" >&2
  exit 1
fi

# --- DRY RUN: validate the build + bindings, write nothing ------------------
if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> DRY_RUN=1 — validating build only (no KV create, no secrets, no deploy)"
  $WRANGLER deploy --dry-run
  echo "==> dry-run OK"
  exit 0
fi

# --- 1. create KV namespace (prod + preview) --------------------------------
if [[ "$SKIP_KV" != "1" ]]; then
  echo "==> Creating KV namespace '$KV_BINDING' (production)..."
  $WRANGLER kv namespace create "$KV_BINDING"
  echo "==> Creating KV namespace '$KV_BINDING' (preview)..."
  $WRANGLER kv namespace create "$KV_BINDING" --preview

  cat <<EOF

------------------------------------------------------------------
ACTION REQUIRED: paste the binding wrangler printed above into
wrangler.toml, e.g.:

  [[kv_namespaces]]
  binding = "$KV_BINDING"
  id = "<production id from the first command>"
  preview_id = "<preview id from the second command>"

Then re-run with SKIP_KV=1 to continue:  SKIP_KV=1 ./deploy.sh
------------------------------------------------------------------
EOF
  read -r -p "Press ENTER once wrangler.toml is updated to continue, or Ctrl-C to stop... " _
fi

# --- 2. put secrets ---------------------------------------------------------
for s in "${SECRETS[@]}"; do
  echo "==> Setting secret: $s  (paste the value when prompted)"
  $WRANGLER secret put "$s"
done

# --- 3. deploy --------------------------------------------------------------
echo "==> Deploying..."
$WRANGLER deploy
echo "==> Deploy complete."

cat <<'EOF'

Next (operator, NOT automated here — see cloud-deploy-runbook.md):
  - Bind route/custom domain bridge.kup.solutions to this Worker.
  - Set non-secret vars in wrangler.toml: WORKOS_JWKS_URL, WORKOS_AUDIENCE
    (then re-deploy), or set them as secrets if you prefer.
  - Provision the WorkOS tenant: client_id + redirect_uri=bridge-auth://callback.
  - Set the Bridge (Mac) host env vars: BRIDGE_ENABLE_HTTP=1, BRIDGE_OAUTH_ISSUER,
    BRIDGE_OAUTH_JWKS, NOTION_BRIDGE_PORT, BRIDGE_CLOUD_BASE_URL, WORKOS_CLIENT_ID.
EOF
