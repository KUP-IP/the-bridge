#!/usr/bin/env bash
# inject-remote-access.sh — Packet E (PRJCT-2754): bake the operator WorkOS/OAuth
# IdP identity into TheBridge/Modules/Auth/RemoteAccessIdentity.swift at build
# time, so the cloud connector's OAuth identity is present at EVERY launch with
# no dependency on launchctl-setenv (the root cause of the placeholder-PRM
# revert). Mirrors Packet B's inject-license-key.
#
# Per value: environment variable wins; absent → left empty (fail-closed).
# When NO identity vars are set (normal local `make build`), this is a NO-OP —
# it leaves the committed fail-closed default untouched (zero git churn).
# release.yml exports the values from repo secrets; an operator can also bake a
# local build with `make build BRIDGE_OAUTH_ISSUER=… WORKOS_CLIENT_ID=… …`.
#
# All baked values are NON-SECRET (public issuer/clientID/redirect/resource).
set -euo pipefail

OUT="TheBridge/Modules/Auth/RemoteAccessIdentity.swift"

ISS="${BRIDGE_OAUTH_ISSUER:-}"
RES="${BRIDGE_PUBLIC_RESOURCE:-}"
CID="${WORKOS_CLIENT_ID:-}"
WBU="${WORKOS_BASE_URL:-}"
WRU="${WORKOS_REDIRECT_URI:-}"

if [ -z "${ISS}${RES}${CID}${WBU}${WRU}" ]; then
  echo "🔐 inject-remote-access: no identity in env → leaving committed fail-closed default (no-op)"
  exit 0
fi

# Reject characters that can't appear in these (non-secret) values and would
# break the generated Swift string literal — fail loud rather than emit broken code.
for v in "$ISS" "$RES" "$CID" "$WBU" "$WRU"; do
  case "$v" in
    *'"'*|*'\'*|$'*'\n'*) echo "❌ inject-remote-access: illegal character in an identity value" >&2; exit 1;;
  esac
done

cat > "$OUT" <<EOF
// RemoteAccessIdentity.swift — Packet E (PRJCT-2754 · durable Remote-Access config)
// TheBridge · Modules · Auth
//
// ⚠️ GENERATED / BUILD-INJECTED — do not hand-edit. (scripts/inject-remote-access.sh)
// Baked operator IdP identity (non-secret). See the committed default for docs.

enum RemoteAccessIdentity {
    static let issuer = "${ISS}"
    static let publicResource = "${RES}"
    static let workosClientID = "${CID}"
    static let workosBaseURL = "${WBU}"
    static let workosRedirectURI = "${WRU}"
}
EOF
echo "🔐 inject-remote-access: baked operator IdP identity (issuer=$([ -n "$ISS" ] && echo set || echo empty), resource=$([ -n "$RES" ] && echo set || echo empty))"
