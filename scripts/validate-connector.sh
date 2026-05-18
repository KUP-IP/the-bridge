#!/usr/bin/env bash
# validate-connector.sh — PKT-800 (v3.0) one-shot remote-connector validator.
#
# Run this ONCE after the operator has provisioned the WorkOS tenant +
# public domain + Cloudflare Tunnel (see
# docs/operator/connector-provisioning-runbook.md). It exercises the
# live remote OAuth MCP surface end-to-end and exits non-zero on the
# first failure so it is safe to gate a submission on.
#
# Usage:
#   BASE_URL=https://bridge.kup.solutions \
#   EXPECT_ISSUER=https://<your-workos-issuer> \
#   [BEARER=<a test access token>] \
#   [STEPUP_TOOL=<a destructiveHint tool name>] \
#   scripts/validate-connector.sh
#
# BEARER is optional: without it, only the unauthenticated discovery +
# 401 challenge checks run (still meaningful). With it, scope/step-up
# enforcement is exercised too.
set -uo pipefail

BASE_URL="${BASE_URL:?set BASE_URL, e.g. https://bridge.kup.solutions}"
EXPECT_ISSUER="${EXPECT_ISSUER:?set EXPECT_ISSUER to the WorkOS AuthKit issuer URL}"
BEARER="${BEARER:-}"
STEPUP_TOOL="${STEPUP_TOOL:-}"
PRM_PATH="/.well-known/oauth-protected-resource"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }

echo "== validate-connector :: ${BASE_URL} =="

# 1. PRM discovery (RFC 9728)
PRM="$(curl -fsS "${BASE_URL}${PRM_PATH}" 2>/dev/null)"
if [ -z "$PRM" ]; then
  fail "PRM ${PRM_PATH} did not return a body"
else
  echo "$PRM" | python3 - "$EXPECT_ISSUER" <<'PY'
import json, sys
expect_iss = sys.argv[1]
d = json.load(sys.stdin)
req = ["resource", "authorization_servers", "scopes_supported", "bearer_methods_supported"]
miss = [k for k in req if k not in d]
ok = True
if miss:
    print("  FAIL  PRM missing RFC 9728 members:", miss); ok = False
if not d.get("authorization_servers"):
    print("  FAIL  authorization_servers empty"); ok = False
elif expect_iss not in d["authorization_servers"]:
    print(f"  FAIL  authorization_servers {d['authorization_servers']} != expected {expect_iss}"); ok = False
need = {"snippets.read","snippets.write","voice.resolve","runners.exec","contacts.read"}
if not need.issubset(set(d.get("scopes_supported", []))):
    print("  FAIL  scopes_supported missing", need - set(d.get('scopes_supported', []))); ok = False
if any(k in d for k in ("authorizationServers","scopesSupported","bearerMethodsSupported")):
    print("  FAIL  camelCase key leak in PRM"); ok = False
print("  PASS  PRM RFC 9728 shape + issuer + 5 scopes + snake_case" if ok else "  (PRM checks failed)")
sys.exit(0 if ok else 1)
PY
  [ $? -ne 0 ] && FAIL=1
fi

# 2. Unauthenticated /mcp must 401 + WWW-Authenticate: Bearer
HDRS="$(curl -fsS -D - -o /dev/null -X POST "${BASE_URL}/mcp" \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null || true)"
CODE="$(printf '%s' "$HDRS" | awk 'NR==1{print $2}')"
if [ "$CODE" = "401" ] && printf '%s' "$HDRS" | grep -qi '^WWW-Authenticate: *Bearer'; then
  pass "unauthenticated /mcp -> 401 + WWW-Authenticate: Bearer"
else
  fail "unauthenticated /mcp expected 401+WWW-Authenticate, got ${CODE:-<none>}"
fi

# 3. /health unaffected (non-regression)
[ "$(curl -fsS -o /dev/null -w '%{http_code}' "${BASE_URL}/health" 2>/dev/null)" = "200" ] \
  && pass "/health 200 (non-regression)" || fail "/health not 200"

# 4. With a bearer: a destructiveHint tools/call WITHOUT connector.step_up -> 403
if [ -n "$BEARER" ] && [ -n "$STEPUP_TOOL" ]; then
  C="$(curl -fsS -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/mcp" \
    -H "Authorization: Bearer ${BEARER}" -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${STEPUP_TOOL}\",\"arguments\":{\"_stepUp\":\"x\"}}}" 2>/dev/null || true)"
  [ "$C" = "403" ] \
    && pass "destructive tool + forged _stepUp (no connector.step_up scope) -> 403" \
    || fail "expected 403 for forged step-up, got ${C}"
else
  echo "  SKIP  step-up enforcement (set BEARER + STEPUP_TOOL to exercise)"
fi

echo "== $( [ $FAIL -eq 0 ] && echo 'ALL CHECKS PASSED' || echo 'FAILURES PRESENT' ) =="
exit $FAIL
