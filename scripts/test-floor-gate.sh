#!/usr/bin/env bash
# test-floor-gate.sh — WS-C (v2.3, PKT-798)
#
# Locks the green test baseline as a CI gate. The custom harness
# (.build/debug/NotionBridgeTests) already exits non-zero on any failing
# test, but that does NOT catch tests being silently deleted or disabled —
# a suite that shrinks from 710 → 600 with 0 failures would otherwise pass
# CI unnoticed. This gate fails the build if the passing count drops below
# the floor OR any test fails.
#
# FLOOR provenance: the packet text specified 504 (the PKT-740 / v2.2-era
# baseline). That number is stale. v2.2 closeout floor was 733/733; WS-A
# then retired the Cursor SDK integration (deprecated/disabled, never
# deleted, its tests) and WS-D/WS-B added the snippets + transport-router
# suites, landing a verified-green baseline of 710. WS-C added 5
# fail-closed BridgeFeatureFlags tests → 715. v3.0 prep 0.4 added 4
# BridgeModuleRegistry single-source enforcement tests → 719. v3.0·0.5
# added the MCP tool-metadata contract + P0/P1 guards (+13) → 732. The
# Dev-suite every-angle-of-attack audit then added 44 tests across three
# new files: DevModuleTests (first-ever dev_module_info coverage — the
# tool had shipped with zero tests and no runner), DevSuiteAuditTests
# (48-tool cross-tool invariants: explicit annotation coverage,
# camelCase schema keys, non-thin rendered descriptions, inputSchema
# sanity, requiresConfirmation/tier coherence, BridgeToolAliases
# did-you-mean recovery), and DevSuiteEdgeTests (wrong-type / empty /
# idempotency / capability-missing envelope hardening) → 776. The
# Messages-suite every-angle-of-attack audit then added 27 tests in
# MessagesSuiteAuditTests (attributedBody decoder defect: stray leading
# C0 control byte + U+FFFC object-replacement glyph in previews —
# reproduced with deterministic typedstream fixtures and fixed at the
# decodeAttributedBody boundary via sanitizeDecodedText; plus per-tool
# wrong-type/empty/wrong-key hardening, camelCase schema-key + alias
# convention, explicit-annotation + requiresConfirmation/tier coherence,
# messages_send confirm-gate + raw-chatNNN ghost-thread guard — all
# network/Messages.app-free, no live send — and ToolMetadata authored
# steers rendered into the MCP description) → the gate is now locked at
# the actual verified green count of 803, not the stale stub value (504).
# PKT-800 S1 (remote OAuth/HTTP, slice 1, 2026-05-17): added the RFC 9728
# Protected Resource Metadata factory + the env-configurable
# BRIDGE_OAUTH_ISSUER seam (default https://auth.example.invalid — no
# live WorkOS tenant in S1), wired the gated streamableHTTP seam on
# ServerManager (symmetric to the stdio guard; default config stays
# stdio-only so existing clients are byte-for-byte unchanged), served
# GET /.well-known/oauth-protected-resource on the existing NIO listener
# (new distinct path — does NOT shadow /health,/sse,/messages,/mcp;
# routing unified through the new single-source MCPHTTPRoute classifier),
# and added RemoteOAuthHTTPTests (PRM required-members /
# issuer override+default / snake_case wire form / Codable round-trip,
# TransportRouter default-vs-env with the stdio non-regression invariant,
# exhaustive non-shadowing route classification, and two NIOEmbedded
# real-request-decode drives). Reconciled delta: the prior green base
# is 803 (independently re-verified on f65fee1 this session); this file
# contributes exactly 24 harness `test()` blocks (55 internal checks),
# so 803 + 24 = 827. The literal harness summary was
# `Results: 827 passed, 0 failed, 827 total`. (An earlier working note
# in this block described it as "+22 on a 805 base" — that prose
# mis-described an arithmetically-correct result; corrected here per the
# honest-ledger rule. No other suite changed.) No token/bearer
# validation, ScopeGate conformer, DCR or consent in this slice (deferred).
# Per the
# order-inversion rule we never lower a green baseline to satisfy a stale
# DoD number. Raising the floor when the suite legitimately grows is
# expected; lowering it requires a conscious decision recorded alongside
# the change.
set -euo pipefail

FLOOR="${BRIDGE_TEST_FLOOR:-827}"
BIN=".build/debug/NotionBridgeTests"

echo "🧪 test-floor-gate: building debug + running suite (floor=${FLOOR})..."
swift build -c debug

LOG="$(mktemp -t bridge-test-floor.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

set +e
"$BIN" | tee "$LOG"
set -e

LINE="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' "$LOG" | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "::error::test-floor-gate: could not find the 'Results:' summary line in test output"
  exit 2
fi

PASSED="$(printf '%s\n' "$LINE" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
FAILED="$(printf '%s\n' "$LINE" | sed -E 's/^Results: [0-9]+ passed, ([0-9]+) failed.*/\1/')"

if [ "$FAILED" -ne 0 ]; then
  echo "::error::test-floor-gate: ${FAILED} failing test(s) — green bar broken"
  exit 1
fi

if [ "$PASSED" -lt "$FLOOR" ]; then
  echo "::error::test-floor-gate: passed=${PASSED} is BELOW floor=${FLOOR} — tests were removed or disabled. If this drop is intentional, lower the floor in scripts/test-floor-gate.sh in the same change and record why."
  exit 1
fi

echo "✅ test-floor-gate OK: passed=${PASSED} >= floor=${FLOOR}, failed=0"
