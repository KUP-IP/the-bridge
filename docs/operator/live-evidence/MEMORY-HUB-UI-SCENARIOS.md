# Memory Hub UI Scenarios — Live Evidence (PKT-MEM-121 / 122 / 123)

**Branch:** `feat/mem-120-routing-quality-ux`  
**Harness:** `scripts/memory-hub-ui-scenarios.sh` · PKT-1005 memory section in `scripts/pkt1005-ui-validate.sh`  
**Navigation contract:** `bridge_settings_navigate(section:Memory, anchor:…)` with compound anchors (`process/<memoId>`, `inbox/<filter>`, `activity` → process).

## V1 Process layout — live acceptance (REVIEW-FIRST)

| ID | Scenario | Pass criteria |
|----|----------|---------------|
| L1 | Three-pane chrome | Left memos always visible (220px); activity drawer collapse/expand; center never zero-width |
| L2 | J3 center order | Single title; transcript under title with fade; tags; summary strip; Confirm |
| L3 | Batch happy path | Check 2 tags → Confirm → 2 activity receipts in drawer; memo evicts when processed |
| L4 | Batch partial fail | Force fail on intent 2 → intent 1+3 still commit; summary shows ✓/✗ |
| L5 | Registry sheet | Check registry tag without row → sheet blocks → pick row → Confirm succeeds |
| L6 | Preview cache | Inbox round-trip preserves checked tags + transcript expanded state |
| L7 | Triage UI-9 | `triage_open` → Confirm → `triage_await` returns committed with N/M detail |
| L8 | PKT-1005 | `./scripts/pkt1005-ui-validate.sh --section memory` all V1 ids present |

## UI scenario matrix

| ID | Scenario | Navigation | Assert | Grade | Build | Notes |
|----|----------|------------|--------|-------|-------|-------|
| UI-1 | First Understand | `anchor:process` | `bridge.settings.memory.process.centerPane` + `intentTags` populated after Understand | **OPERATOR** | — | V1 AX ids (replaces intentTable) |
| UI-2 | Process ↔ Inbox ↔ Process | `anchor:inbox` → `anchor:process` | Same memo selected; restore **<1s**; checked tags preserved | **OPERATOR** | — | Session cache SC-1 + L6 |
| UI-3 | Section leave/return | Skills → Memory/process | Transcript + checked tags restored from RAM cache | **OPERATOR** | — | SC-2 |
| UI-4 | Re-run Understand | `refreshPreview` AX id | Intents reload; triage invalidated if active | PASS | v3.9.2 build 68 | Hermetic triage invalidation green |
| UI-5 | Quit/relaunch | Kill app, reopen | No instant cache; shows load path | PASS | v3.9.2 build 68 | SC-4 RAM-only cache |
| UI-6 | Batch Confirm eviction | Check tags → Confirm on test memo | Memo leaves list when processed gate clears; cache entry gone | **OPERATOR** | — | V1 batch Confirm (replaces single-intent commit) |
| UI-7 | Picker round-trip | Registry configure sheet → tab away → return | `selectedRowIdByIntentId` restored | **OPERATOR** | — | V1 per-intent picker maps |
| UI-8 | PKT-1005 Memory AX | Navigate memory + ax_tree grep | V1 harness ids (centerPane, intentTags, confirmButton, activityDrawer, …) | **OPERATOR** | — | L8 gate |
| UI-9 | W5-Triage (122) | `triage_open` → batch Confirm → `triage_await` | `committed` event with `committed N/M` detail | **OPERATOR** | — | L7; hermetic batch detail green |

## Hermetic coverage (no live UI required)

| SC | Criterion | Test file |
|----|-----------|-----------|
| SC-5 cache eviction on commit | `remove(forMemoId:)` when processed gate clears | `MemoryProcessPreviewSessionTests` |
| SC-7 triage invalidation on refresh | Re-run Understand calls bridge | `MemoryProcessPreviewSessionTests` + `TriageSessionTests` |
| SC-8 picker round-trip | PreviewBundle V1 fields (`checkedIntentIds`, `selectedRowIdByIntentId`) | `MemoryProcessPreviewSessionTests` |
| Batch ordering / partial fail | Lane priority, continue-on-failure, triage detail | `MemoryProcessBatchConfirmTests` |
| V1 AX manifest | centerPane, intentTags, confirmButton, activityDrawer | `MemoryProcessLayoutAXTests` |
| Compound anchors | `process/<memoId>`, inbox filters | `MemorySettingsTests`, `TriageSessionTests` |

## Operator actions still required (REVIEW-FIRST)

1. **L1–L8:** Visual review + screenshot evidence after `make install-copy`.
2. **UI-6:** Batch Confirm on disposable test memo; confirm partial/processed eviction.
3. **UI-9:** Full agent↔operator handoff with batch Confirm detail string.

## Automation principles (friction log)

- Prefer `bridge_settings_navigate` + `ax_tree` grep over coordinate clicks.
- Target `accessibilityIdentifier` paths (`BridgeAXID.Memory.Process.*`), never `AXScrollArea:/AXButton:N`.
- Memo selection: `anchor:process/<memoId>` when memo id known.
