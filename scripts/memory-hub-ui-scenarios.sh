#!/usr/bin/env bash
# memory-hub-ui-scenarios.sh — Memory Hub live UI scenario helper (PKT-MEM sprint)
#
# Agent-driven: prints scenario steps + expected AX ids. Does NOT drive the UI itself.
# Pair with Bridge MCP: bridge_settings_navigate → ax_tree → this script for id checklist.
#
# Usage:
#   ./scripts/memory-hub-ui-scenarios.sh              # list scenarios
#   ./scripts/memory-hub-ui-scenarios.sh UI-2         # steps for one scenario
#   ./scripts/memory-hub-ui-scenarios.sh --ax-ids     # grep targets for pkt1005 memory section

set -euo pipefail

scenario() {
  local id="$1"
  shift
  if [ "${1:-}" = "--ax-ids" ]; then return 0; fi
  if [ -n "${SCENARIO_FILTER:-}" ] && [ "$SCENARIO_FILTER" != "$id" ]; then return 0; fi
  echo "=== $id ==="
  while [ $# -gt 0 ]; do echo "  - $1"; shift; done
  echo
}

SCENARIO_FILTER="${1:-}"
if [ "${1:-}" = "--ax-ids" ]; then
  exec ./scripts/pkt1005-ui-validate.sh --manifest | sed -n '/^== memory ==$/,/^== /p' | grep -v '^=='
fi

scenario UI-1 \
  "bridge_settings_navigate(section:Memory, anchor:process, focus:true)" \
  "Select memo via process/<memoId> anchor or memoRow AX id" \
  "Assert bridge.settings.memory.process.centerPane and intentTags populated after Understand" \
  "No scroll-area button index clicks"

scenario UI-2 \
  "Run Understand on test memo" \
  "bridge_settings_navigate(anchor:inbox) then anchor:process" \
  "Same memo selected; restore <1s; no Loading preview spinner"

scenario UI-3 \
  "bridge_settings_navigate(section:Skills)" \
  "bridge_settings_navigate(section:Memory, anchor:process)" \
  "Session cache restores transcript + intents"

scenario UI-4 \
  "Activate refreshPreview AX id (bridge.settings.memory.process.refreshPreview)" \
  "Intents reload; triage session invalidated if active"

scenario UI-5 \
  "Quit The Bridge; relaunch; open Memory/process" \
  "Shows load path — no instant cache from prior session"

scenario UI-6 \
  "Operator commits one intent on test memo (destructive — use test memo)" \
  "Memo leaves process list; preview cache entry evicted"

scenario UI-7 \
  "Select registry picker row; switch to Inbox; return Process" \
  "Hermetic SC-8 + live selectedRowId restore"

scenario UI-8 \
  "./scripts/pkt1005-ui-validate.sh --section memory --ax-json <ax.json>" \
  "All memory harness ids present"

scenario UI-9 \
  "voice_memo_triage_open(memoId) → operator UI commit → triage_await" \
  "Event kind=committed; agent does NOT voice_memo_commit again"

echo "Evidence template: docs/operator/live-evidence/MEMORY-HUB-UI-SCENARIOS.md"
