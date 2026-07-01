# Memory Hub UI Scenarios — Live Evidence (PKT-MEM-121 / 122 / 123)

**Branch:** `feat/mem-120-routing-quality-ux`  
**Harness:** `scripts/memory-hub-ui-scenarios.sh` · PKT-1005 memory section in `scripts/pkt1005-ui-validate.sh`  
**Navigation contract:** `bridge_settings_navigate(section:Memory, anchor:…)` with compound anchors (`process/<memoId>`, `inbox/<filter>`, `activity` → process).

## W0 HITL baseline (2026-06-30 — agent-driven, no voice)

| Tier | ID | Result | Notes |
|------|-----|--------|-------|
| T0 | T0a | **PASS** | `make test` → 2863/2863 green; floor raised to 2863 |
| T0 | T0b | **PASS** | `make install-copy` target available (operator relaunch for live UI) |
| T0 | T0c | **PASS** | Bridge MCP handshake COMPLETE this session |
| T0 | T0d | **PASS** | PKT-1005 harness includes processLocal/processCloud/processPrompt AX ids |
| T1 | T1a | **PASS** | Three-pane layout unchanged (PKT-MEM-123 L1) |
| T1 | T1b | **PASS** | Inspect-only select — no Understand on memo click (W1) |
| T1 | T1c | **PASS** | Session cache tests green (`MemoryProcessPreviewSessionTests`) |

**Next:** Tier 2 requires operator voice scripts in [MEMORY-HUB-VOICE-SCRIPTS.md](MEMORY-HUB-VOICE-SCRIPTS.md).

## T-Real — Operator Greg memo (2026-07-01 closeout)

**Build:** v3.9.3 build 69 · **Memo:** `20260630 163652-575021F5.m4a-4856794-1782856025`  
**Evidence:** [mem-closeout-2026-07-01.png](mem-closeout-2026-07-01.png) · [mem-closeout-plan.json](mem-closeout-plan.json) · [mem-closeout-registry-audit.json](mem-closeout-registry-audit.json)

| Check | Result | Notes |
|-------|--------|-------|
| Bridge online | **PASS** | bridge_status online |
| Memo + transcript | **PASS** | inspect-only + understand |
| Understand plan | **PASS** | 2 intents, degraded local, <120s |
| Intent tags in UI | **PASS** | AX: intentTags + 1 checkbox "Update record 86% ★" |
| dryRun | **PASS** | No writes; agent-deferred skip documented (FR-012) |
| Oracle O1–O2 registry | **FAIL** | → FR-008, PKT-MEM-128 |
| Oracle O3 memory | **PARTIAL** | → FR-008 |
| Oracle O4–O5 preview | **FAIL** | → FR-009, FR-011 |
| **Pipeline verdict** | **WORKING** | Operator approved execute 2026-07-01; polish → packets 127–130 |

## V1 Process layout — live acceptance (REVIEW-FIRST)

**Live run:** 2026-06-30 · `make install-copy` → v3.9.2 build 68 · memo `20251007 133129-0E0F965C.m4a-654734-1759861973` (short Apple transcript)  
**Evidence:** `docs/operator/live-evidence/memory-process-v1-2026-06-30.png` · merged AX `ax-memory-full-2026-06-30.json`

| ID | Scenario | Result | Build | Notes |
|----|----------|--------|-------|-------|
| L1 | Three-pane chrome | **PASS** | 3.9.2/68 | Memo sidebar + center controls + activity drawer toggle visible; screenshot captured |
| L2 | J3 center order | **PASS** | 3.9.2/68 | AX: `intentTags`, `transcriptExpand`, `confirmSummary`, `confirmButton`, `dryRun`, `refreshPreview` |
| L3 | Batch happy path | **OPERATOR** | — | Needs disposable memo with ≥2 checkable intents + operator OK on notify-tier commits |
| L4 | Batch partial fail | **OPERATOR** | — | Force guardrail-blocked 2nd intent (D6); not run — destructive |
| L5 | Registry sheet | **OPERATOR** | — | Needs registry intent without row pick; sheet AX id conditional |
| L6 | Preview cache | **PASS** | 3.9.2/68 | Skills → `process/<memoId>` remount restores preview + checked tag (Skills sandwich required when tab already mounted) |
| L7 | Triage UI-9 | **PARTIAL** | 3.9.2/68 | `voice_memo_triage_open` → sessionHandle OK; UI Confirm click did not emit `committed` within 5s await (retry with operator Confirm + 1800s await) |
| L8 | PKT-1005 | **PARTIAL** | 3.9.2/68 | Merged 5-tab AX: **23/36** memory ids (`ax-memory-full-2026-06-30.json`). Process V1 controls present; container ids (`centerPane`, `memoList`) not exposed in AX flat dump; `activityDrawer` grep false-positive via `activityDrawerToggle` substring |

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
| UI-1 | First Understand | `anchor:process` | `intentTags` populated after Understand | **PASS** | v3.9.2 build 68 | `centerPane` id not in AX dump; tags + confirm strip verified |
| UI-2 | Process ↔ Inbox ↔ Process | `anchor:inbox` → Skills → `process/<memoId>` | Same memo; restore <1s; tags preserved | **PASS** | v3.9.2 build 68 | L6; Skills sandwich triggers `onAppear` restore |
| UI-3 | Section leave/return | Skills → Memory/process | Transcript + checked tags restored from RAM cache | **PASS** | v3.9.2 build 68 | SC-2 + L6 |
| UI-4 | Re-run Understand | `refreshPreview` AX id | Intents reload; triage invalidated if active | PASS | v3.9.2 build 68 | Hermetic triage invalidation green |
| UI-5 | Quit/relaunch | Kill app, reopen | No instant cache; shows load path | PASS | v3.9.2 build 68 | SC-4 RAM-only cache |
| UI-6 | Batch Confirm eviction | Check tags → Confirm on test memo | Memo leaves list when processed gate clears; cache entry gone | **OPERATOR** | — | V1 batch Confirm (replaces single-intent commit) |
| UI-7 | Picker round-trip | Registry configure sheet → tab away → return | `selectedRowIdByIntentId` restored | **OPERATOR** | — | V1 per-intent picker maps |
| UI-8 | PKT-1005 Memory AX | 5-tab ax_tree merge | Process V1 ids + cross-tab memory ids | **PARTIAL** | v3.9.2 build 68 | 23/36; see L8 notes |
| UI-9 | W5-Triage (122) | `triage_open` → batch Confirm → `triage_await` | `committed` with N/M detail | **PARTIAL** | v3.9.2 build 68 | open OK; await timeout until operator Confirm completes |

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

1. **L3–L5:** Batch Confirm on **disposable** multi-intent memo (notify-tier writes); approve macOS notification if prompted.
2. **L7 retry:** `voice_memo_triage_open` → operator Confirm in UI → `voice_memo_triage_await` (1800s) for `committed N/M` detail.
3. **GO gate (D10):** After PR CI green + operator sign-off on L3–L5, reply **GO** to merge and tag v3.9.3.

## Automation friction log (2026-06-30)

- **`process/<memoId>` anchor alone does not select memo** when Process tab is already mounted — only sets `lastSelectedMemoId`. Use **Skills → Memory/process/<memoId>** sandwich (or memo-row click) to trigger `restorePreviewSessionIfNeeded` / `loadPreview`.
- Long-memo first load can block `ToolRouter` queue; prefer short memo for smoke or restart app before smoke.
- PKT-1005 `grep -F` treats `activityDrawerToggle` as match for `activityDrawer` — use exact-id audit for ship gate.
