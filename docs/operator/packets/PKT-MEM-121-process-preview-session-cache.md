# PKT-MEM-121 — Process Preview Session Cache

**Status:** REVIEW (2026-06-30 · hermetic + live SC-1–SC-4, SC-8 PASS; SC-5 operator; floor **2824**)  
**Class:** Standard · **Execution Class:** REVIEW-FIRST  
**Project:** Ship The Bridge v4 · Memory Hub Sprint  
**Parent sprint:** hub packet [PKT-MEM-120](./PKT-MEM-120-memory-hub-routing-quality-ux.md)  
**Plan SSOT:** [`.cursor/plans/process_tab_preview_cache_7dd44de1.plan.md`](../../../.cursor/plans/process_tab_preview_cache_7dd44de1.plan.md)  
**Sprint plan SSOT:** [`.cursor/plans/memory_hub_sprint_e107afc7.plan.md`](../../../.cursor/plans/memory_hub_sprint_e107afc7.plan.md) §Wave 4  
**Branch:** `feat/mem-120-routing-quality-ux`  
**Baseline:** test floor **2796**

> **GOAL_CONDITION:** Achieve Process-tab preview session cache (LRU 12, full UI bundle, Re-run Understand invalidates triage) on `feat/mem-120-routing-quality-ux` within this packet scope, prove with `MemoryProcessPreviewSessionTests` + manual checklist SC-1–SC-8 + `make test-floor` green, respect PKT-MEM-105 invariants and `ToolAnnotationCatalog` for new UI, Execution Class REVIEW-FIRST — stop after install-copy smoke artifact; do not merge to main.

---

## Goal Contract

### Outcome

After Understand runs for a voice memo in **Settings → Memory → Process**, leaving the Process tab or Memory section and returning **within the same app session** restores transcript + intents + full UI selection **without** re-running Ollama/`voice_memo_get`. App quit clears cache. **Re-run Understand** explicitly re-parses and **invalidates any active triage session** for that memo (R10.3).

### Scope — IN

- `MemoryProcessPreviewSession` actor: LRU **12**, transcript SHA-256 fingerprint, `lastSelectedMemoId`.
- **PreviewBundle:** transcript, plan, `selectedIntentId`, `overrideIntentId`, `intentDiffBadges`, picker state (entity + rowId + loaded rows).
- `MemorySection.tabBody`: ZStack keep `MemoryProcessTab` mounted (Process only).
- `loadPreview(for:forceRefresh:)` cache hit/miss; restore on appear; remove on commit.
- **Re-run Understand** button + `BridgeAXID.Memory.Process.refreshPreview`.
- Hermetic tests + test-floor raise.

### Scope — OUT

- Disk persistence across app restart.
- `MemoryHubPlanSnapshotStore.append` on parse.
- MCP `forceRefresh` on `voice_memo_get`.
- PKT-MEM-122 triage tools (sequential follow-on).
- Version bump (sprint closeout).

### Constraints

- PKT-MEM-105 processed gate unchanged — commit path still authoritative.
- Swift 6 strict concurrency; hermetic via `BridgePaths.overrideHomeForTesting`.
- New UI controls require `ToolAnnotationCatalog` entries if exposed as MCP-adjacent surfaces (refresh is UI-only — AX id required).

### Success Criteria

| ID | Criterion | Evidence |
|----|-----------|----------|
| SC-1 | Process ↔ Inbox ↔ Process preserves preview + selection | Manual |
| SC-2 | Settings section leave/return restores from cache | Manual |
| SC-3 | Re-run Understand re-parses; cache updated | Manual |
| SC-4 | App quit → relaunch → no cache | Manual |
| SC-5 | Commit removes memo + cache entry | Hermetic + manual |
| SC-6 | `make test-floor` green; floor raised | Gate output |
| SC-7 | Re-run Understand invalidates triage session for memo (stub OK if 122 not landed) | Hermetic hook or integration test with `TriageSession` |
| SC-8 | Picker state round-trips in PreviewBundle | Hermetic |

### Verification Plan

1. `MemoryProcessPreviewSessionTests` — put/get, LRU, fingerprint mismatch, remove.
2. Manual checklist (6 steps in sub-plan) + SC-7/SC-8.
3. `make test-floor` after floor bump.

### Failure / Stop Conditions

- Cache hit serves stale plan when transcript fingerprint changed → **BLOCKER**.
- Tab keep-alive breaks notification gate (`MemoryHubUIState`) → fix before REVIEW.
- Memory growth > ~2 MB for 12 memos with long transcripts → review LRU.

### Dependencies

- **Shipped:** PKT-MEM-120 Process cockpit, `voice_memo_get` / `buildPlan`.
- **Parallel OK** with W1-B operator smoke; **must land before** PKT-MEM-122.

### Required Capabilities

- Swift build/test on worktree `9lxf`; branch `feat/mem-120-routing-quality-ux`.

### Prohibited Actions

- No disk session file without operator approval.
- No merge to `main`.

---

## Brief Contract

Operator triages a memo, hops to Inbox or Processing, returns to the **same intents and selection** without paying the Ollama tax again.

---

## Packet Runner Output

### Current Canonical Result

_Validated QUEUE 2026-06-30 — not yet executed._

### Artifact Manifest

- Packet: this file
- Sub-plan: `.cursor/plans/process_tab_preview_cache_7dd44de1.plan.md`
- Sprint plan: `.cursor/plans/memory_hub_sprint_e107afc7.plan.md` §Wave 4

### Exceptional History

- 2026-06-30 Validate #2: SC-7/SC-8 added; triage invalidation on refresh locked (R10.3).
