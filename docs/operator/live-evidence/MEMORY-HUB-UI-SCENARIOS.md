# Memory Hub UI Scenarios — Live Evidence (PKT-MEM-121 / 122)

**Branch:** `feat/mem-120-routing-quality-ux`  
**Harness:** `scripts/memory-hub-ui-scenarios.sh` · PKT-1005 memory section in `scripts/pkt1005-ui-validate.sh`  
**Navigation contract:** `bridge_settings_navigate(section:Memory, anchor:…)` with compound anchors (`process/<memoId>`, `inbox/<filter>`, `activity` → process).

| ID | Scenario | Navigation | Assert | Grade | Build | Notes |
|----|----------|------------|--------|-------|-------|-------|
| UI-1 | First Understand | `anchor:process` | `bridge.settings.memory.process.intentTable` populated after Understand; no spinner after settle | PASS | v3.9.2 build 68 | AX-id path; no scroll-area button index |
| UI-2 | Process ↔ Inbox ↔ Process | `anchor:inbox` → `anchor:process` | Same memo selected; restore **<1s**; no `Loading preview…` | PASS | v3.9.2 build 68 | Session cache SC-1 |
| UI-3 | Section leave/return | Skills → Memory/process | Transcript + intents restored from RAM cache | PASS | v3.9.2 build 68 | SC-2 |
| UI-4 | Re-run Understand | `refreshPreview` AX id | Intents reload; triage invalidated if active | PASS | v3.9.2 build 68 | Hermetic triage invalidation green |
| UI-5 | Quit/relaunch | Kill app, reopen | No instant cache; shows load path | PASS | v3.9.2 build 68 | SC-4 RAM-only cache |
| UI-6 | Commit eviction | Operator commits one intent on test memo | Memo leaves list; cache entry gone | **OPERATOR** | — | Destructive — operator must run on disposable memo; hermetic `remove` green |
| UI-7 | Picker round-trip | Registry row select → tab away → return | `selectedRowId` restored | PASS | v3.9.2 build 68 | Hermetic SC-8 + live spot-check |
| UI-8 | PKT-1005 Memory AX | Navigate memory + ax_tree grep | All harness ids present (incl. triage banner ids) | PASS | v3.9.2 build 68 | `pkt1005-ui-validate.sh --section memory` |
| UI-9 | W5-Triage (122) | `triage_open` → UI commit → `triage_await` | `committed` event; agent does not re-commit | **PARTIAL** | v3.9.2 build 68 | Hermetic lifecycle green; live W5 row pending operator commit step |

## Hermetic coverage (no live UI required)

| SC | Criterion | Test file |
|----|-----------|-----------|
| SC-5 cache eviction on commit | `remove(forMemoId:)` after commit path | `MemoryProcessPreviewSessionTests` |
| SC-7 triage invalidation on refresh | Re-run Understand calls bridge | `MemoryProcessPreviewSessionTests` + `TriageSessionTests` |
| SC-8 picker round-trip | PreviewBundle fields | `MemoryProcessPreviewSessionTests` |
| Compound anchors | `process/<memoId>`, inbox filters | `MemorySettingsTests`, `TriageSessionTests` |

## Operator actions still required

1. **UI-6 (SC-5):** Commit one intent on a **test memo** in Process; confirm memo disappears from list and re-select does not show stale preview.
2. **UI-9 (W5-Triage):** Full agent↔operator handoff — see `PKT-MEM-113` §W5-Triage.

## Automation principles (friction log)

- Prefer `bridge_settings_navigate` + `ax_tree` grep over coordinate clicks.
- Target `accessibilityIdentifier` paths (`BridgeAXID.Memory.Process.*`), never `AXScrollArea:/AXButton:N`.
- Memo selection: `anchor:process/<memoId>` when memo id known.
