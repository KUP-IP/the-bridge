# PKT-MEM-123 — Memory Process V1 Layout + Batch Confirm

| Field | Value |
|-------|-------|
| **Class** | Standard |
| **Execution Class** | REVIEW-FIRST |
| **Project** | Ship The Bridge v4 · Memory Hub |
| **Branch** | `feat/mem-120-routing-quality-ux` (or follow-on off `main`) |
| **Depends on** | PKT-MEM-121 (preview session cache), PKT-MEM-122 (triage session) |
| **Plan SSOT** | `.cursor/plans/v1_process_layout_b95b7971.plan.md` |
| **Spec** | `docs/operator/MEMORY-PROCESS-LAYOUT-J3-OPERATOR-SPEC.md` — **V1 APPROVED** |

## GOAL_CONDITION

Achieve V1 Memory Process layout (fixed memo sidebar, J3 center with collapsed transcript + multi-select intent tags + Confirm summary strip + blocking registry sheet, collapsible Memory Hub activity push drawer) and UI-free batch commit orchestrator on the feature branch, prove with ~30+ new hermetic tests + L1–L8 live acceptance + PKT-1005 memory AX gate, preserve PKT-MEM-105 trust invariants (no blind commit, review lanes not executable, processed gate unchanged). Execution Class **REVIEW-FIRST** — stop after operator live GO; do not merge without screenshot evidence.

## Objective

Replace the three-column Process cockpit (memo list · intent table · detail inspector + bottom activity strip) with the accepted **V1 three-pane** layout:

- **Left (220px fixed):** memo sidebar — unchanged selection semantics.
- **Center (J3):** single title block → transcript with gradient fade → checkable intent tags → Confirm summary strip → Confirm.
- **Right (0 or 300px push drawer):** Memory Hub global `activity.jsonl` feed (limit 50), collapsible via `@AppStorage`.

Batch confirm runs sequential `voice_memo_commit` calls (no new MCP tool) in lane-priority order with **continue-on-failure** partial summary.

## Scope

### IN

- `MemoryProcessBatchConfirm.swift` — UI-free orchestrator (ordering, registry validation, summary aggregation).
- Extended `MemoryProcessPreviewBundle` — `checkedIntentIds`, `transcriptExpanded`, per-intent picker maps.
- `MemoryProcessCockpit.needsPicker(for:allRows:)` + `tagLabel(for:)`.
- Full `MemoryProcessTab` refactor to V1 layout + `MemoryProcessRegistryConfigureSheet`.
- AX contract update (`centerPane`, `intentTags`, `confirmButton`, `confirmSummary`, `activityDrawer`, …).
- Hermetic tests + floor bump; PKT-1005 memory section; UI scenario doc updates.

### OUT

- V5 processing checklist UI (post-confirm progress card).
- New MCP tool `voice_memo_commit_batch`.
- Primary override UI (Make primary) — suppressed lanes manually checkable.
- Per-memo Dry-run button — follow-up PKT-MEM-124 if operator misses it.
- Notify-tier batch deduplication.
- Layout changes to Inbox / Notion / Agent / Processing tabs.
- Version bump — separate release commit after operator GO.

## Set-in-stone decisions

| Item | Decision |
|------|----------|
| Layout | V1 push drawer + J3 center order locked |
| Batch failure | **Continue**; partial summary at end |
| Registry | **Blocking pre-Confirm sheet** |
| Trust | Confirm summary strip (`commitWriteLabel` + truncated preview per checked tag) |
| Tag eligibility | Executable lanes only; `review` kind not checkable |
| `needsManual` | Not success; batch continues |
| Triage emit | One event after batch if any success; detail `committed N/M: kinds; lastReceipt=hash` |
| Activity | Memory Hub global feed, limit **50**; drawer default **closed** |

## Definition of Done

### Hermetic (machine)

- [ ] `make test-floor` green; floor raised to measured count
- [ ] `MemoryProcessBatchConfirmTests` + preview bundle + batch integration + guardrail extension pass
- [ ] AX manifest hermetic (`MemoryProcessLayoutAXTests` + `SettingsUIValidationHarness`)

### Live (operator REVIEW-FIRST)

- [ ] L1–L8 live acceptance rows in `MEMORY-HUB-UI-SCENARIOS.md`
- [ ] `make install-copy` + PKT-1005 memory section green
- [ ] Operator GO on visual review (screenshot evidence)

## Live acceptance (L1–L8)

| ID | Scenario | Pass criteria |
|----|----------|---------------|
| L1 | Three-pane chrome | Left memos always visible; activity drawer collapse/expand; center never zero-width |
| L2 | J3 center order | Single title; transcript under title with fade; tags; summary strip; Confirm |
| L3 | Batch happy path | Check 2 tags → Confirm → 2 activity receipts; memo evicts when processed |
| L4 | Batch partial fail | Force fail on intent 2 → intent 1+3 still commit; summary shows ✓/✗ |
| L5 | Registry sheet | Check registry tag without row → sheet blocks → pick row → Confirm succeeds |
| L6 | Preview cache | Inbox round-trip preserves checked tags + transcript expanded state |
| L7 | Triage UI-9 | `triage_open` → Confirm → `triage_await` returns committed with N/M detail |
| L8 | PKT-1005 | `./scripts/pkt1005-ui-validate.sh --section memory` all V1 ids present |

## Routing

| Role | Keeper / skill |
|------|----------------|
| Executor | `executor` — single packet, phases P1→P6 |
| Domain | `focus-keepr` — Memory Hub Process UI ship |
| App/UI | `app-dev` — SwiftUI three-pane Settings refactor if needed |

## Fresh-agent checklist

1. Which layout? → **V1** push drawer, J3 center order locked.
2. Batch failure? → **Continue**; partial summary.
3. Registry picker? → **Blocking sheet** before Confirm.
4. New MCP tool? → **No**.
5. What proves done? → L1–L8 + test-floor + pkt1005.
