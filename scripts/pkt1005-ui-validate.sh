#!/usr/bin/env bash
# pkt1005-ui-validate.sh — PKT-1005 (Pillar D) headless UI-validation harness
#
# Repeatable, scriptable routine an executor runs UNATTENDED to prove The
# Bridge's redesigned Settings UI is open-able, navigable, and AX-readable by
# stable identifier — the gate this packet exists to open. It drives the loop:
#
#     bridge_open_settings(section)   # cold-open the Settings window host
#     bridge_settings_navigate(sec)   # deep-link to the section
#     ax_tree(<bridge pid>)           # read the live AX tree
#     assert expected BridgeAXID ids present  # per the harness manifest
#
# The pure-logic core + the per-section expected-id MANIFEST live in
# TheBridge/Modules/SettingsUIValidationHarness.swift (unit-tested in
# TheBridgeTests/SettingsAXIdentifierTests.swift). This script is the
# on-device wiring; it expects the Bridge MCP tools to be invoked by the agent
# harness and the resulting ax_tree JSON saved to a file it can grep.
#
# USAGE (two modes):
#   1. AGENT-DRIVEN (normal): the executing agent calls the Bridge MCP tools
#      directly (bridge_open_settings → bridge_settings_navigate → ax_tree),
#      pipes each section's ax_tree JSON to this script, and reads the verdict.
#         ./scripts/pkt1005-ui-validate.sh --section skills --ax-json /tmp/ax-skills.json
#   2. MANIFEST DUMP: print the expected ids per section (no live app needed),
#      so the agent knows exactly what to assert.
#         ./scripts/pkt1005-ui-validate.sh --manifest
#
# The 7 sections (stable case names): orders skills jobs tools security connection advanced
#
# Exit 0 = all asserted ids found; non-zero = at least one missing (names printed).

set -euo pipefail

# ── Expected-id manifest (MUST mirror SettingsUIValidationHarness.swift) ──────
# Shared chrome present for every section + the section root container id.
shared_ids() {  # $1 = section case name
  local s="$1"
  printf 'bridge.settings.nav.%s\n' "$s"
  printf 'bridge.settings.title\n'
  printf 'bridge.settings.%s.root\n' "$s"
}

# Skills (Pillar C priority surface) — full control instrumentation.
skills_extra_ids() {
  cat <<'EOF'
bridge.settings.skills.root
bridge.settings.skills.list
bridge.settings.skills.toggle.routing
bridge.settings.skills.toggle.enabled
bridge.settings.skills.cache.indicator
bridge.settings.skills.status.indicator
bridge.settings.skills.trash
bridge.settings.skills.metadata.grid
EOF
}

expected_ids() {  # $1 = section
  shared_ids "$1"
  if [ "$1" = "skills" ]; then
    skills_extra_ids
  fi
}

ALL_SECTIONS="orders skills jobs tools security connection advanced"

print_manifest() {
  for s in $ALL_SECTIONS; do
    echo "== $s =="
    expected_ids "$s" | sort -u
    echo
  done
}

validate_section() {  # $1 = section, $2 = path to ax_tree JSON
  local section="$1" axjson="$2" missing=0
  if [ ! -f "$axjson" ]; then
    echo "::error:: ax_tree JSON not found at $axjson" >&2
    return 2
  fi
  echo "── validating section '$section' against $axjson ──"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if grep -qF "$id" "$axjson"; then
      echo "  ✅ $id"
    else
      echo "  ❌ MISSING: $id"
      missing=$((missing + 1))
    fi
  done < <(expected_ids "$section" | sort -u)
  if [ "$missing" -ne 0 ]; then
    echo "::error:: section '$section' FAILED — $missing expected id(s) missing"
    return 1
  fi
  echo "✅ section '$section' PASSED (all expected ids present)"
  return 0
}

# ── arg parse ─────────────────────────────────────────────────────────────
MODE=""
SECTION=""
AXJSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MODE="manifest"; shift ;;
    --section)  SECTION="$2"; shift 2 ;;
    --ax-json)  AXJSON="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "manifest" ]; then
  print_manifest
  exit 0
fi

if [ -n "$SECTION" ] && [ -n "$AXJSON" ]; then
  validate_section "$SECTION" "$AXJSON"
  exit $?
fi

cat >&2 <<'USAGE'
PKT-1005 UI-validation harness. Provide one of:
  --manifest                          dump expected ids per section
  --section <name> --ax-json <path>   assert a section's ax_tree read
USAGE
exit 2
