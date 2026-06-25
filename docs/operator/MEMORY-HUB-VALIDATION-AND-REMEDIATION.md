# Memory Hub — Phase 0 Validation Tests + Remediation Plan

**Packet:** [PKT-MEM-106 — Phase 0 (Trust + Process Cockpit Integration)](./packets/PKT-MEM-106-phase0-trust-cockpit.md)
**Branch:** `feat/memory-hub-voice-curator` (one Phase 0 integration packet, sliced 0a → 0b → 0c)
**Spec SSOT:** `MEMORY-HUB-EXECUTION-SPEC.md` §0.1 (decision ledger) · §2 (LOCKED contracts) · §7 (18-item Wave-3 reflow) · §9 (gates)
**Phase-0 floor baseline:** locked reflow baseline **2303**; if the live `scripts/test-floor-gate.sh` `FLOOR=` is already higher, keep that higher floor and raise only by measured net-new green with a dated provenance comment.
**Re-test order (operator-locked Decision 5):** **M1 → M5 → M8**

This document has two parts:

- **PART A — Validation test plan** (`§A0`–`§A2`): the per-slice net-new automated tests that gate each slice's floor bump, plus the live M1/M5/M8 re-test plan.
- **PART B — Remediation plan** (`§B0`–`§B10` + STOP-conditions): how the executor diagnoses and recovers from each failure mode, with STOP / CONTINUE / BLOCKED severity.

> **Doc-reconciliation note (applied throughout):** (a) SPEC §0.1 is the decision SSOT; SPEC §8 and MANIFEST ~line 55 REFERENCE it. (b) SPEC §0 "Test floor baseline 2270" is **stale → 2303** as the locked Phase-0 baseline; never lower a live script floor that already exceeds it. (c) PKT-MEM-112/113 predate the 06-25 reflow — **Phase 0 (PKT-MEM-106) precedes A–E and supersedes the B/D/E UI items** (registry picker, activity strip, cloud-key UI, Agent forget/pin). (d) Version drift: targets the **v3.8.2-built / v3.8.3-shipping** binary line (live-suite wording), not "v3.9.x".

---

# PART A — VALIDATION TEST PLAN

## §A0. Scope, conventions, and what counts as net-new

### A0.1 Coverage map (DoD item → slice)

| DoD item (SPEC §7) | Slice | Surface |
|---|---|---|
| Lane-priority-first election | 0a | `VoiceMemoIntentElection` |
| Deterministic `intentId` (`intent_v1_`+20hex, canonical JSON) | 0a | new identity generator |
| Same-kind distinctness (no `memoId+intentKind` collapse) | 0a | review model + enqueue |
| Legacy derive-on-read + `legacyDerived` + rewrite-on-touch | 0a | review store shim |
| Processed-gate alignment (all `markProcessed` callsites) | 0a | shared predicate + resolver + processor |
| `rowId` commit — param threads to writer | 0a | `voice_memo_commit` → registry writer |
| `rowId` commit — picker selection flows into commit | 0b | picker → `voice_memo_commit` |
| Append-only protected fields | 0a | registry write mode |
| Non-protected per-field diff (model + gate) | 0c | diff model + commit guardrail |
| Split cockpit + primary override + per-intent commit | 0b | `MemoryProcessTab` |
| Registry entity/row picker (live + cached + 24h stale) | 0b | picker + per-entity JSON cache |
| Process↔Inbox unresolved-lane mirror | 0b | review projection |
| Activity JSONL receipt envelope (full SHA-256 / first-12) | 0b | activity log |
| AX IDs (zones/rows/commands suffixed memoId/intentId) | 0b | cockpit + harness |
| Progressive preview (heuristic→local-auto→cloud-manual) + timeouts (8s/20s) | 0c | preview pipeline |
| Versioned snapshots + diff badges + no-silent-removal (demote/supersede) | 0c | snapshot store |
| Snapshot retention (heuristic/latest-enhanced/committed) | 0c | snapshot pruning |
| Lane threshold gates (0.80/0.90/0.86/0.86/0.90) + ambiguity + stale | 0c | commit guardrails |
| Duplicate block-by-default + force-reason enum + note | 0c | duplicate guard |
| Processing Keychain provider status/save/delete (OpenAI-compatible) | 0c | Processing tab |
| Agent soft-forget + pin only | 0c | Agent tab |
| Notion open + refresh + dry-run backfill only | 0c | Notion tab |
| Notification suppression (app active AND Memory/Process selected) | 0c | notifier gate |

### A0.2 Test naming + registration convention

- Pure-logic asserts (election, intentId hashing, gate booleans, retention math, diff computation, envelope serialization) are **automated unit tests** in the `TheBridgeTests` harness — `await test("name") { try expect(cond, "msg") }`, registered via a `run*Tests()` entry function. These count toward the floor.
- UI/AX asserts run through `SettingsUIValidationHarness` (per CLAUDE.md + SPEC §6) and are also automated.
- New test files proposed: `MemoryHubTrustTests.swift` (0a), `MemoryHubCockpitTests.swift` (0b), `MemoryHubGuardrailTests.swift` (0c). Each adds a `runMemoryHub*Tests()` entry function wired into the test main.
- Provenance comment format on the floor bump (one per slice merge): `FLOOR=<measured>  # 2026-06-?? PKT-MEM-106 slice 0a +<N> net-new (election/intentId/processed-gate/rowId/append-only)` — where `<measured>` and `<N>` are the ACTUAL integrated green count and net-new delta, not the projection below.

### A0.3 Floor math — PROJECTED ONLY (re-measure per slice)

> **These numbers are PROJECTIONS for planning, not gates.** Each slice's PR must (a) re-measure the actual integrated green count, (b) set `FLOOR=` to the measured live count when it exceeds the entry floor, (c) add the dated provenance comment, (d) keep `make test` / `make test-floor` green. **Never bake any projection as a fixed floor and never lower the live script floor to the 2303 baseline.** The packet's `+N` placeholders are the source of truth; the floor moves up only, by measured net-new. Live multi-intent runs (Part A §A2) are operator evidence, NOT floor contributors.

| Slice | Net-new automated tests (PROJECTED) | Running floor (PROJECTED) |
|---|---|---|
| Phase-0 baseline (locked docs) | — | **2303** |
| **0a** Trust + identity core | **+25** | ~**2328** |
| **0b** Process cockpit + activity | **+26** | ~**2354** |
| **0c** Preview + guardrails + tabs | **+41** | ~**2395** |
| **Phase 0 total** | **+92** | ~**2395** |

Counts are per listed `await test(...)` block (the harness's green unit), but the actual merge gate is the measured integrated count. If this branch has already landed one or more slices and `scripts/test-floor-gate.sh` is above the projected running floor, keep the current higher floor and raise from there.

---

## §A1. Per-slice net-new AUTOMATED tests

### Slice 0a — TRUST + IDENTITY CORE (no UI) — the M5/M8 blocker set

> **Grounded code facts (verified):** `VoiceMemoIntentElection.isLowerPriority` currently compares **confidence before lane priority** — 0a inverts it to **priority-first**. `VoiceMemoReviewStore.enqueue` currently dedupes pending entries by `memoId + intentKind` (collapses same-kind lanes) — 0a rekeys to `intentId`. There is currently **no shared "no pending review for memoId" predicate**: `VoiceMemoReviewResolver` calls `VoiceMemoProcessedStore.markProcessed` at ~8 sites and `VoiceMemoProcessor` at ~lines 280/649, each independently. 0a introduces one predicate and routes ALL callsites through it. `voice_memo_commit` already accepts `intentKind`/`entityKey`/`entityHint`/`rowId`/`fields`, so the 0a rowId test asserts the EXISTING param threads to the writer.

| Test name | Asserts | DoD item covered |
|---|---|---|
| `election_priorityBeatsConfidence_reminderOverHigherConfRegistry` | Given `reminder@0.81` + `registry_update@0.95`, `split().execute` has exactly one lane and it is `.reminder` (priority overrides higher confidence). | Election lane-priority-first |
| `election_fullPriorityOrder_reminderAgentRegistryMemoryKeep` | Across all four kinds at equal confidence, elected primary = `reminder`; ordering `reminder>agent_memory>registry_update>memory_keep` holds. | Election lane-priority-first |
| `election_confidenceTiebreakWithinSameLane` | Two `registry_update` lanes, no higher-priority lane present → higher-confidence one elected; the other suppressed (priority equal ⇒ confidence breaks tie). | Election lane-priority-first |
| `election_singleExecutableLane_noSuppression` | One executable intent ⇒ `execute.count==1`, `suppressed.isEmpty` (review-kind passthrough unchanged). | Election regression guard |
| `intentId_canonicalDeterminism_stableAcrossReorder` | Same memoId+kind+entityKey+entityHint+destination fields+title, with map keys in different insertion order ⇒ identical `intent_v1_…` id. | intentId canonical determinism |
| `intentId_format_prefixAnd20HexLowercase` | id matches `^intent_v1_[0-9a-f]{20}$` (prefix + exactly 20 lowercase hex). | intentId 20-hex format |
| `intentId_canonicalization_trimWhitespaceCaseEnums` | `" Bridge  v4 "` vs `"Bridge v4"` and `kind` upper/lower variants hash equal (trimmed strings, normalized whitespace, lowercase enums). | Canonicalization rule |
| `intentId_sameMemoDistinctKind_differentId` | Two intents, same memoId, different `kind` ⇒ different ids. | Same-kind distinctness (kind axis) |
| `intentId_sameMemoSameKindDistinctTarget_differentId` | Two `registry_update` from one memo (session DST-8 vs project Bridge v4) ⇒ different ids (entityKey/entityHint in hash input). | Same-kind distinctness (target axis) — **M5/M8 core** |
| `reviewEnqueue_twoSameKindLanes_bothPersist` | Enqueue two `registry_update` entries for one memoId with distinct `intentId` ⇒ both pending (no `memoId+intentKind` collapse). | Same-kind distinctness in store — **M5/M8 core** |
| `reviewEnqueue_idempotentSameIntentId_replacesNotDuplicates` | Re-enqueue identical `intentId` ⇒ exactly one pending entry (dedupe key is intentId, not random UUID). | Review identity dedupe |
| `legacy_deriveIntentIdOnRead_marksLegacyDerived` | Load a pre-0a entry lacking `intentId` ⇒ derived id present, `legacyDerived==true`. | Legacy derive-on-read |
| `legacy_deriveFallback_usesCreatedAtAndReason` | Legacy entry with incomplete canonical fields ⇒ id derived from available fields + `createdAt`/`reason` fallback; deterministic on repeat reads. | Legacy fallback hash |
| `legacy_rewriteOnTouchOnly_untouchedFileUnchanged` | Reading a legacy manifest does NOT rewrite the file; resolving/dismissing/committing one entry rewrites only then (byte-compare before/after read vs after touch). | Legacy rewrite-on-touch |
| `processedGate_pendingSiblingReview_blocksMark` | Memo with ≥1 pending review for that memoId ⇒ `shouldMarkProcessed==false`. | Processed gate (predicate) |
| `processedGate_commit_lastLaneClearsThenMarks` | After committing the final lane and no pending review remains for memoId ⇒ processed marked; with a sibling still pending ⇒ not marked. | Processed gate (commit) |
| `processedGate_reviewResolve_marksOnlyWhenNoSiblingPending` | `voice_memo_review_resolve` on the last pending entry ⇒ processed; on a non-last entry ⇒ still not processed. | Processed gate (resolve) |
| `processedGate_alignmentAcrossAllCallsites_singlePredicate` | The shared "no pending review for memoId" predicate gates **every** `markProcessed` callsite — the three tool entry points (`process`/`commit`/`review_resolve`) AND each resolver site (~8 in `VoiceMemoReviewResolver`) AND each processor site (`VoiceMemoProcessor` ~280/649) — yielding identical processed/blocked results for identical manifest state. No callsite marks processed independently with a pending sibling. | Processed-gate alignment (ALL callsites) |
| `rowIdCommit_paramThreadsToWriterByRowId` | The EXISTING `voice_memo_commit(intentKind:registry_update, rowId:"<id>", entityHint:"wrong")` routes to the registry writer keyed by `rowId` (rowId wins over hint). Model-layer, no UI. | rowId commit (param threading, 0a) |
| `rowIdCommit_missingRowAndAmbiguousHint_routesToManual` | No `rowId` + ambiguous hint (≥2 matches) ⇒ commit does not auto-write; returns manual/ambiguous outcome. | rowId commit / ambiguity precondition |
| `appendOnly_brief_neverOverwrites` | `registry_update` on protected `brief` ⇒ read-modify-write appends; prior text retained, stamp marker present. | Append-only protected fields |
| `appendOnly_allFourProtectedFields_objectiveSummaryDescription` | Same append guarantee for `objective`, `summary`, `description` (table-driven over the four). | Append-only protected fields |
| `appendOnly_protectedField_forceFlagStillAppends` | Even with a force path set, protected fields append (no Phase 0 path may overwrite a protected field). | Append-only invariant hard-stop |
| `agentMemory_fullTranscriptStored_notFirstSentence` | Committing `agent_memory` stores the full transcript body (length ≥ multi-sentence input), preserving PKT-MEM-105 invariant under the new identity model. | Trust regression guard |
| `intentId_usedAsReviewAndReceiptKey_consistent` | The id produced by the generator equals the id stored on the review entry and referenced by an activity receipt for the same intent (one canonical generator, four consumers). | Single-generator invariant |

**0a PROJECTED: +25 net-new.** (Two non-protected per-field diff tests moved to 0c; the rowId picker test lives in 0b.) Re-measure and set `FLOOR=` to actual.

---

### Slice 0b — PROCESS COCKPIT + ACTIVITY

| Test name | Asserts | DoD item covered |
|---|---|---|
| `cockpit_threeZones_present` | View model exposes the three zones (memo list / intent table / detail-commit inspector) as distinct sections. | Split cockpit |
| `cockpit_intentTable_showsPrimaryMarkerAndColumns` | Intent table rows expose kind, confidence, entity, row hint, destination field, status, warning flag; exactly one primary-marked. | Split cockpit (intent table contract) |
| `cockpit_primaryOverride_reElectsChosenLane` | Operator override selects a non-elected lane ⇒ that lane becomes primary; previously-primary lane demoted to suppressed (no write yet). | Primary override |
| `cockpit_perIntentCommit_callsCommitWithIntentId` | "Commit" on one intent row invokes `voice_memo_commit` scoped to that `intentId`/target (one lane at a time, not fan-out). | Per-intent commit |
| `axId_zones_exactConstants` | AX IDs equal `memoryProcess.memoList`, `memoryProcess.intentTable`, `memoryProcess.detailInspector`, `memoryProcess.activityStrip`. | AX IDs (zones) |
| `axId_memoRow_suffixedWithMemoId` | Memo row AX id == `memoryProcess.memoRow.<memoId>`. | AX IDs (rows) |
| `axId_intentRow_suffixedWithIntentId` | Intent row AX id == `memoryProcess.intentRow.<intentId>`. | AX IDs (rows) |
| `axId_registryRow_entityAndRowId` | Picker row AX id == `memoryProcess.registryRow.<entity>.<rowId>`. | AX IDs (picker rows) |
| `axId_commands_commitAndPrimaryOverride` | Command AX ids == `memoryProcess.commit.<intentId>` and `memoryProcess.primaryOverride.<intentId>`. | AX IDs (commands) |
| `axHarness_memoryProcess_registeredEntries` | `SettingsUIValidationHarness` enumerates the new Process controls (no missing-entry audit failure). | AX harness coverage (SPEC §9.4) |
| `picker_liveRegistryList_populatesRows` | Picker built from a stubbed live `registry_list` response yields selectable rows per entity. | Registry picker (live) |
| `picker_liveFailure_fallsBackToCache` | When live `registry_list` errors, picker loads last-good rows from `memory-hub/registry-cache/<entity>.json` and flags `source error`. | Registry picker (cached fallback) |
| `picker_cacheStaleAfter24h_setsStaleBadge` | Cache `fetchedAt` > 24h ⇒ rows still selectable but `stale==true`; ≤24h ⇒ not stale (boundary at exactly 24h). | Registry picker (24h stale) |
| `picker_cacheFile_perEntityPathAndTTLMeta` | Cache writes to `…/memory-hub/registry-cache/<entity>.json` carrying `fetchedAt`, `ttl`, `stale`, `sourceError`. | Registry cache storage |
| `rowIdCommit_pickerSelectionFlowsIntoCommit` | The picker-selected entity/row threads its `rowId` into `voice_memo_commit` (UI-driven counterpart to 0a's param threading); commit targets the selected row, not the free-text hint. | rowId commit (picker, 0b) |
| `mirror_pendingLane_visibleInProcessAndInbox` | A suppressed/pending lane appears both grouped under its memo in Process and as an Inbox exception row (same `intentId`). | Process↔Inbox mirror |
| `mirror_resolvedLane_dropsFromBothViews` | Resolving/dismissing a lane removes it from Process group and Inbox simultaneously. | Process↔Inbox mirror |
| `activity_envelope_requiredFields` | A serialized event carries `eventId`, timestamp, `schemaVersion`, `memoId`, optional `intentId`, `phase`, `action`, `status`, `provenance`, `actor`, `detail`, `receiptHash`. | Activity receipt envelope |
| `activity_phaseEnum_constrained` | `phase` ∈ {transcribe, understand, plan, execute, review, test}; invalid phase rejected. | Activity envelope (phase domain) |
| `activity_noFullTranscript_hashPlusExcerptOnly` | `detail` for a transcript-bearing event contains a transcript **hash + short excerpt**, never the full transcript string (length/equality assertion vs source). | Activity privacy (no full transcript) |
| `activity_receiptHash_fullStored_first12Displayed` | Stored `receiptHash` is full 64-char SHA-256; the UI/markdown display accessor returns its first 12 chars. | Receipt hash full-vs-display |
| `activity_receiptHash_deterministicOverCanonicalFields` | Same canonical event fields ⇒ same `receiptHash`; one field change ⇒ different hash. | Receipt hash integrity |
| `activity_jsonl_appendOnly_oneLinePerEvent` | Writing N events yields N newline-delimited JSON objects appended in order (no rewrite of prior lines). | Append-only JSONL |
| `activity_retention_500eventCap` | 501st event prunes the oldest ⇒ ≤500 retained. | Activity retention (count) |
| `activity_retention_30dayCap_whicheverSmaller` | Events older than 30 days pruned even under 500 count; "whichever comes first" honored (boundary cases at 500 and 30d). | Activity retention (age) |
| `activity_file_path_underMemoryHub` | Activity persists to `~/Library/Application Support/TheBridge/memory-hub/activity.jsonl` (path resolved via `BridgePaths`, `overrideHomeForTesting`). | Activity/cache file location |

**0b PROJECTED: +26 net-new** (current row-list projection; includes the picker-rowId test moved in from the 0a/0b split). Re-measure and set `FLOOR=` to actual.

---

### Slice 0c — PREVIEW + GUARDRAILS + TABS

| Test name | Asserts | DoD item covered |
|---|---|---|
| `preview_heuristicFirst_provenanceHeuristic` | First rendered snapshot has `provenance==heuristic` and is produced without awaiting any provider. | Progressive preview (heuristic first) |
| `preview_localAuto_enhancesAfterHeuristic` | When local Ollama enabled, a second snapshot with `provenance==local` may supersede; heuristic snapshot retained. | Progressive preview (local auto) |
| `preview_cloudManualOnly_notAutoTriggered` | Cloud enhancement never runs without an explicit operator trigger flag (auto path leaves provenance ≤ local). | Progressive preview (cloud manual) |
| `preview_localTimeout_8s_keepsLatestValid` | Local enhancement exceeding 8s soft timeout ⇒ pipeline keeps latest valid (heuristic/local) plan and records `timeout` status in activity. | Local 8s timeout |
| `preview_cloudTimeout_20s_keepsLatestValid` | Manual cloud enhancement exceeding 20s ⇒ falls back to latest valid plan + `timeout` activity status. | Cloud 20s timeout |
| `preview_cloudFailure_keepsLatestValid_noReviewQueued` | Manual cloud enhancement failure records activity, keeps latest valid heuristic/local plan, and does not queue a review item. | Cloud failure semantics |
| `snapshot_versioned_addedChangedRemovedBadges` | Diff between two snapshots yields per-field badges: added / changed / removed(=demoted/superseded). | Versioned snapshots + diff badges |
| `snapshot_noSilentRemoval_demoteOrSupersedeOnly` | An intent present in heuristic but absent from an enhanced plan is marked demoted/superseded and stays visible — never silently dropped. | No-silent-removal |
| `snapshot_enhancementChangesLane_returnsToUncommitted` | If enhancement changes a previously-approved lane's fields, that lane reverts to uncommitted review state. | Preview commit-state contract |
| `snapshot_retention_keepsHeuristicLatestEnhancedCommitted` | After multiple enhancements, exactly the heuristic, latest-enhanced, and committed snapshots remain; intermediates pruned. | Snapshot retention |
| `snapshot_storage_perMemoJsonPath` | Snapshots persist to `memory-hub/plan-snapshots/<memoId>.json` (operator decision #2 — inspectable/prunable). | Snapshot storage (decision #2) |
| `snapshot_prunesOnWriteAndLaunchSweep` | Snapshot pruning runs during snapshot writes and launch/wake sweep, preserving heuristic/latest-enhanced/committed only. | Snapshot pruning trigger |
| `gate_globalFloor_080_blocksBelow` | Any lane below global `0.80` ⇒ not auto-eligible (requires operator commit). | Lane threshold gates (global) |
| `gate_reminder_090_threshold` | `reminder@0.89` ⇒ manual; `@0.90` ⇒ auto-eligible (boundary). | Lane threshold gates (reminder) |
| `gate_registry_086_threshold` | `registry_update@0.85` ⇒ manual; `@0.86` ⇒ auto-eligible. | Lane threshold gates (registry) |
| `gate_agent_086_threshold` | `agent_memory@0.85` ⇒ manual; `@0.86` ⇒ auto-eligible. | Lane threshold gates (agent) |
| `gate_memoryKeep_090_threshold` | `memory_keep@0.89` ⇒ manual; `@0.90` ⇒ auto-eligible. | Lane threshold gates (memory_keep) |
| `gate_ambiguousRegistryTarget_forcesManual` | Above-threshold registry lane with ambiguous/unresolved target ⇒ manual commit (no auto-write). | Commit guardrails (ambiguity) |
| `gate_staleCacheFallbackTarget_forcesManual` | Picker target sourced from a stale (>24h) cache row ⇒ manual commit. | Commit guardrails (stale fallback) |
| `dup_blockByDefault_sameDestinationKey` | Second commit with identical `memoId + intentId + destination key` ⇒ blocked by default. | Duplicate block-by-default |
| `dup_distinctDestinationKey_notBlocked` | Same memo, different destination key (different reminder/field/value) ⇒ allowed (legitimate separate lane). | Duplicate key correctness |
| `dup_forceReasonEnum_required` | Force commit without a selected reason ⇒ rejected; the reason set is exactly `{new_context, correction, operator_confirmed, live_test}` (decision #1). | Duplicate force-reason enum |
| `dup_forceReason_invalidValueRejected` | A reason outside the enum (e.g. `"because"`) ⇒ rejected. | Duplicate force-reason enum |
| `dup_forceReason_optionalNoteRecordedInActivity` | Force commit with valid reason + optional note ⇒ allowed; activity event records reason + note. | Duplicate force note (decision #1) |
| `nonProtected_perFieldDiff_computesBeforeAfter` | Non-protected property update produces a before/after diff record (old/new) per field; protected fields excluded from the overwrite set. | Non-protected per-field diff (model, 0c) |
| `nonProtected_diffDisplay_summaryAndRawJson` | Diff presentation includes a human-readable old/new summary and expandable raw before/after JSON. | Registry diff display |
| `nonProtected_diffSelectsOnlyChosenFields` | Given 3 non-protected field changes, applying a selected subset writes only chosen fields; unselected unchanged. | Non-protected per-field diff (selectable, 0c) |
| `nonProtected_diffValidationFailure_writesNothingKeepsReview` | If any selected non-protected field fails validation, no selected field writes and the intent remains uncommitted + review-visible. | Registry diff failure mode |
| `processing_providerStatus_configuredVsMissing` | Processing tab reports `configured`/`missing` from Keychain presence only (never the key value). | Keychain provider status |
| `processing_providerSaveDelete_keychainRoundTrip` | Save then delete an OpenAI-compatible provider key ⇒ status flips missing→configured→missing; no plaintext leak in any returned value. | Keychain save/delete |
| `processing_openAICompatibleFields_apiKeyBaseUrlModelEnabled` | Provider slot exposes API key + base URL + model name + enabled toggle (decision #3); base URL/model persist (non-secret), key in Keychain. | OpenAI-compatible provider fields (decision #3) |
| `processing_providerConfig_nonSecretProvidersJson_keychainKey` | Base URL/model/enabled persist in `memory-hub/providers.json`; API key persists only in Keychain and never in JSON. | Provider config storage |
| `processing_providerDefaults_baseUrlOnly_modelRequired` | New provider slot defaults base URL to `https://api.openai.com/v1`, leaves model blank, and blocks cloud enhancement until model is entered. | Provider defaults |
| `processing_providerValidation_syntaxOnSave_networkOnEnhance` | Save validates URL/model syntax only and performs no network call; manual cloud enhancement performs network/model validation. | Provider validation timing |
| `activity_corruptJsonl_skipsPreservesRepairs` | Activity loader skips corrupt JSONL lines, preserves the original file, and records a repair activity with skipped count/error offset. | Activity corruption handling |
| `agent_softForget_tombstonesNotHardDelete` | Agent forget calls `memory_forget` (soft tombstone); row not hard-deleted; no text-edit API exposed. | Agent soft-forget only |
| `agent_pinToggle_setsAndClears` | Pin toggle sets/clears pinned state; no content mutation path present. | Agent pin only |
| `notion_backfill_dryRunFirst_thenSelectedApply` | Backfill computes a dry-run plan (proposed rows/actions) and only applies the operator-selected subset; refresh + open present, full CRUD absent. | Notion open/refresh/dry-run backfill |
| `notify_suppressed_whenActiveAndProcessSelected` | App active AND Memory/Process anchor selected ⇒ notification suppressed. | Notification suppression |
| `notify_backgroundReviewError_deliversWithDeepLink` | App inactive OR non-Process surface ⇒ queued-review/error notification delivers and deep-links to the relevant Memory surface/filter. | Background review/error notifications |
| `notify_gate_truthTable_activationAndAnchor` | Truth table over {active, inactive} × {Process selected, other} ⇒ suppress only the single active+Process cell. | Notification suppression precision |

**0c PROJECTED: +41 net-new** (current row-list projection; includes cloud failure, snapshot pruning, provider config/defaults/validation, activity repair, registry diff display, and validation-failure coverage). Re-measure and set `FLOOR=` to actual.

> **Phase 0 floor closeout: PROJECTED ~2395** (2303 + 92, only as baseline math). Re-measure per slice; set `FLOOR=` to the actual green count when it exceeds the entry floor; never raise except by net-new, never lower an already-higher live floor, and never bake the projection as a fixed gate.

---

## §A2. LIVE multi-intent re-test plan (M1 → M5 → M8)

**Driver doc:** `MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md`.
**Gate:** Live pass/fail is **blocked until the Phase 0 build is installed and relaunched**. 0a+0b are the hard minimum for M1/M5/M8 election + identity + processed-gate + per-intent commit + activity evidence, but canonical closeout uses the full Phase 0 build because M8 also exercises 0c duplicate/force guardrails. Earlier recordings are REVIEW-only evidence unless the operator explicitly accepts that scope.
**Smoke build/relaunch command:** `make test` → `make app` → `make install-copy` (or signing-backed `make install`) → `open -a "The Bridge"`; then confirm `tools_list` exposes `voice_memo_get`, `voice_memo_commit`, `memory_forget`, and any new tool before M1.
**Order (operator decision #5):** **M1 → M5 → M8** — simple trust path before registry-heavy.
**Protocol:** one memo per signal (`M1 done`), single-memo `voice_memo_get` → dry-run → execute / `voice_memo_commit`; never call `voice_memo_process mode:batch` or batch the backlog. Confirm pending count with `voice_memo_review_list` after each.
**Evidence format (SPEC §0.1 "Live evidence format"):** activity-log receipt references (`memory-hub/activity.jsonl`, display first-12 of `receiptHash`) **plus** the PASS/PARTIAL/FAIL markdown grade table at `docs/operator/live-evidence/PKT-MEM-113-M1-M5-M8.md`. Template columns: case, build, memo id, grade, receipt refs, cleanup status, notes.
**Test-receipt hygiene:** any forced duplicate commit performed during the live suite uses force reason `live_test`, so audit/cleanup can filter test-originated receipts from genuine operator forces in the shared `activity.jsonl`.

### Trust invariants that MUST hold on every live case (SPEC §2, suite §Trust invariants)

| Invariant | Expected | Receipt evidence to capture |
|---|---|---|
| Primary election | Exactly **one** lane auto-executes, chosen lane-priority-first | `phase=execute, status=executed` for one lane; `provenance` shows election |
| Suppressed lanes | Each non-primary executable lane → review, reason `secondary intent suppressed` | one `phase=review` event per suppressed `intentId` |
| Same-kind distinctness | Multiple `registry_update` from one memo persist as **distinct** review entries (no `memoId+intentKind` collapse) | distinct `intentId` per registry lane in receipts (**0a**) |
| Registry writes | **Append** to protected text fields (`brief/objective/summary/description`) — never overwrite | before/after shows prior text retained |
| Processed gate | Memo absent from `processed.json` while any review pending for that memoId | processed event only after last pending clears |
| Agent memory | **Full transcript** stored, not first sentence | `agent_memory` commit detail length ≈ full script |

### Rubric (suite §Scoring)

- **PASS** — primary lane correct (priority-first); append-only verified; suppressed-lane count + identities correct and distinct; processed gate correct; activity receipts present for each phase.
- **PARTIAL** — primary correct but suppressed-lane count/identity off, OR datetime missing pre-PKT-MEM-107, OR receipt evidence incomplete (e.g. missing `intentId` on a lane) while no trust violation.
- **FAIL** — any of: protected-field **overwrite**; wrong entity (contact misfire on bare "update"); memo marked processed with a pending sibling review; agent memory **truncated**; same-kind lanes **collapsed** into one review entry.

### M1 — Morning standup (4 intents) · simple trust path

- **Unblocked by:** 0a (priority-first election, processed gate, intentId) + 0b (Process preview, activity receipts, Inbox mirror).
- **Pass criteria:** one Reminder created with a sensible title (4pm / Isaiah / test results, not the whole paragraph); three suppressed lanes (contact Jacob `brief`, project Bridge v4 `summary`, agent_memory full transcript) appear in Process **and** Inbox with distinct `intentId`; on resolving each, appends verified and agent memory holds the full script; memo not processed until the queue clears (or reminder-only with no failed review).
- **Invariants checked:** election (reminder wins by priority), append-only (Jacob/Bridge v4), full-transcript agent memory, processed gate.
- **Receipt evidence:** `execute/executed` (reminder) + 3× `review` events (distinct ids) + per-resolve `execute/executed` append receipts; reference first-12 `receiptHash` per line in the grade table.

### M5 — Registry triple (3 registry lanes, no reminder) · registry-heavy

- **Unblocked by:** 0a (same-kind distinctness — the M5 core; rowId/append-only) + 0b (registry entity/row picker live+cached, per-intent commit, mirror). 0c picker stale/ambiguity guardrails strengthen but are not strictly required for a PASS.
- **Pass criteria:** exactly **one** registry lane auto-executes (highest confidence among equal-priority registry lanes — likely session DST-8 ≈0.88); the other **two** registry lanes are **distinct** Inbox entries with `secondary intent suppressed` (no collapse); operator commits the remaining two via the Process picker / `voice_memo_commit` (by `rowId` when hint ambiguous) and each append is verified; memo not processed until operator-satisfied.
- **Invariants checked:** same-kind distinctness (3 `registry_update` stay separate), append-only, processed gate, rowId-targeted commit.
- **Receipt evidence:** 1× `execute/executed` (primary registry) + 2× distinct-`intentId` `review` events + 2× picker-targeted commit appends. **This is the case that fails on the pre-0a `memoId+intentKind` collapse — the receipts must show three distinct registry `intentId`s.**

### M8 — Ship-day cascade (5+ intents) · max fan-out + duplicate stress

- **Unblocked by:** 0a (election + distinctness across mixed lanes) + 0b (cockpit lists all intents from `voice_memo_get`, mirror, activity). 0c adds duplicate-block-by-default + force-reason enum and per-field diff — exercised here when re-committing.
- **Pass criteria:** `reminder` (5pm tag release) auto-executes; up to **four** suppressed lanes (session objective, project summary, contact Jacob, memory_keep) shown with the **same memoId** but **distinct `intentId`**; Process preview lists all intents from `voice_memo_get`; operator commits each suppressed lane individually; **no duplicate Memory rows without force** — a deliberate re-commit is blocked by default and only proceeds with a force-reason from `{new_context, correction, operator_confirmed, live_test}` (+ optional note), recorded in activity.
- **Invariants checked:** election, same-kind distinctness, append-only, processed gate, duplicate block-by-default + force-reason (decision #1).
- **Receipt evidence:** 1× `execute/executed` (reminder) + ≤4× distinct-`intentId` `review` events + per-commit appends; one `status=blocked` duplicate event and (if forced) a follow-up event carrying the reason enum + note. Live-test forces use reason `live_test`.

### Live grade artifact template (fixed columns at `docs/operator/live-evidence/PKT-MEM-113-M1-M5-M8.md`)

Use the locked artifact columns below. Put primary/suppressed counts, append-only proof, processed-gate proof, and duplicate-guard notes inside `Notes`; do not replace the fixed columns with a different grading table.

| Case | Build | Memo ID | Grade | Receipt refs (first-12 hashes) | Cleanup status | Notes |
|---|---|---|---|---|---|---|
| M1 | v3.8.3 / commit … | … | PASS/PARTIAL/FAIL | … | pending/done/partial | primary reminder; 3 suppressed distinct; append-only + processed gate evidence |
| M5 | v3.8.3 / commit … | … | PASS/PARTIAL/FAIL | … | pending/done/partial | one registry primary; 2 suppressed distinct; picker/rowId append proof |
| M8 | v3.8.3 / commit … | … | PASS/PARTIAL/FAIL | … | pending/done/partial | reminder primary; ≤4 suppressed distinct; duplicate block/force proof |

### Live → slice unblock map (summary)

| Live case | Hard-blocked until | Hardened by |
|---|---|---|
| M1 | 0a (election/intentId/processed) + 0b (preview/activity/mirror) | 0c (notification quiet during triage) |
| M5 | 0a (same-kind distinctness, rowId) + 0b (picker/per-intent commit) | 0c (stale/ambiguity gates) |
| M8 | 0a (election/distinctness) + 0b (cockpit/mirror/activity) | 0c (duplicate block + force-reason enum, per-field diff) |

### Post-live cleanup (suite §Session cleanup)

`reminders_delete` test reminders · revert/remove appended test notes on Jacob/DST-8/Bridge v4/Event block using the safest available path (protected append-only fields must not be silently overwritten; use an additive cleanup/reversal note or approved manual cleanup if needed) · `registry_delete` any test Memory rows · `memory_forget` test agent memories · `voice_memo_review_dismiss` stale inbox entries · reset Curator mode to **Auto**. Filter `activity.jsonl` test receipts by force reason `live_test` where applicable, and record cleanup status in the grade artifact.

---

# PART B — REMEDIATION PLAN

**Severity legend:** STOP = halt the slice/sprint and escalate to REVIEW · CONTINUE = remediate inline and proceed · BLOCKED = trust-invariant breach, no merge until green.

> **Owner column:** `executor` = a sub-agent can detect + fix in-repo without operator input. `operator` = requires a human decision, a fresh voice recording, a Keychain/Notion credential, or live-app smoke. Most live-test failures are dual-owned: executor diagnoses, operator confirms the fix on-device.

## §B0. Pre-flight gates (run before any slice work; failure here is STOP)

| # | Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|---|
| P-1 | `make test` red at HEAD before 0a starts | Pre-existing breakage on branch; baseline not green | Do not layer Phase 0 on a red baseline — bisect to the failing commit, restore green, record green count | executor | **STOP** until baseline green |
| P-2 | Floor gate green count < current `scripts/test-floor-gate.sh` `FLOOR=` (or <2303 on an old branch) | Branch drifted / tests deleted since the entry floor | Reconcile; restore green; never lower `FLOOR` to the 2303 baseline or a projection without a recorded reason | executor | **STOP** |
| P-3 | `tools_list` after app smoke missing `voice_memo_get`/`voice_memo_commit`/`memory_forget` or a new required tool | App not rebuilt/relaunched, or `bridge-env` LaunchAgent didn't inject env (`connectorAuth` nil) | Run `make test` → `make app` → `make install-copy` (or signing-backed `make install`) → `open -a "The Bridge"`; if env missing, reload `solutions.kup.bridge-env` LaunchAgent | operator | **STOP** live testing (unit work may continue) |
| P-4 | Doc inconsistencies still live (ledger triplicated; floor "2270"; version "v3.9.x"; 112/113 predate reflow) | Reconciliation deferred | Land the doc reconciliation FIRST (see §B10) so executors read one SSOT | executor | CONTINUE (but fix before live grading) |

## §B1. Per-slice unit-test failures

| Slice | Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|---|
| **0a** | `intentId` test fails — hash mismatch / non-deterministic across reruns | Canonicalization not applied (unsorted keys, untrimmed strings, raw whitespace, mixed-case enums) before SHA-256; or hash not truncated to exactly 20 hex after `intent_v1_` | Force **one** canonical generator (sorted keys, trimmed, normalized whitespace, lowercase enums → SHA-256 → first 20 hex). Assert byte-stable across two passes and across processor/review-store/UI/activity callsites | executor | CONTINUE (must be green before 0b) |
| **0a** | Legacy review entry test fails — `legacyDerived` not set, or id changes on second read | Derive-on-read not using `createdAt`/reason fallback when canonical fields incomplete; or rewriting on read (should be rewrite-on-touch only) | Implement compatibility shim: derive id on read, mark `legacyDerived`, persist only when entry is resolved/dismissed/committed/touched. Test: read twice → same id, file unchanged | executor | CONTINUE |
| **0a** | Election test fails — wrong lane elected | Election still confidence-first (`isLowerPriority`) instead of **lane-priority-first** (`reminder` > `agent_memory` > `registry_update` > `memory_keep`, then confidence) | Invert `VoiceMemoIntentElection` to lane priority first; add per-tie-break test fixtures matching M1/M5/M8 expectations | executor | CONTINUE |
| **0a** | Processed-gate test fails — memo marked processed with a pending sibling lane | Gate checked in only some callsites; no shared predicate (resolver ~8 sites + processor ~280/649 each mark independently) | Introduce ONE "no pending review for memoId" predicate and route **every** `markProcessed` callsite through it (the three tools AND all resolver/processor sites). Test all entry points + a processor-path callsite | executor | **STOP if it lands on a real build** (trust invariant — see §B6) |
| **0a** | Suppressed-lane / same-kind de-dupe test fails — two `registry_update` lanes collapse into one | De-dupe keyed on `memoId+intentKind` only (`VoiceMemoReviewStore.enqueue`) | Rekey de-dupe to full `intentId` (which folds `entityKey`+`entityHint`+destination fields); never collapse on `memoId+kind` alone | executor | CONTINUE |
| **0a** | `rowId` commit test fails — write lands by hint not `rowId` | Commit path matches the free-text `entityHint` before honoring the explicit `rowId` param | Bind the registry write to the existing `rowId` param first; hint is fallback only. Test: `rowId` set + wrong `entityHint` ⇒ writes to `rowId` | executor | CONTINUE |
| **0a** | Protected-field append test fails — `brief`/`objective`/`summary`/`description` overwritten | Write path not routed through read-modify-write append | Route protected text fields through append-only (`registry_get` → concat → update). Test asserts old content still present after write | executor | **STOP** (trust invariant — §B6) |
| **0b** | AX-ID test fails — zone/row/command identifier missing or unstable | Identifiers not suffixed with `memoId`/`intentId`, or text-based assertions used | Add `memoryProcess.{memoList,intentTable,detailInspector,activityStrip}` + `memoRow.<memoId>` + `intentRow.<intentId>` + `commit.<intentId>` + `primaryOverride.<intentId>` + `registryRow.<entity>.<rowId>`. Tests assert on AX IDs, never display text | executor | CONTINUE |
| **0b** | Activity-receipt test fails — envelope incomplete or full transcript leaked into JSONL | Envelope missing fields; transcript stored instead of hash+excerpt | Envelope must carry `eventId, ts, schemaVersion, memoId, intentId?, phase, action, status, provenance, actor, detail, receiptHash`. Assert: full SHA-256 stored, first 12 displayed, **no** full transcript in `detail` (hash + short excerpt only) | executor | **STOP** (privacy invariant — §B6) |
| **0b** | Retention test fails — JSONL grows past bound | Prune-by-count and prune-by-age not both applied | Prune to newest 500 events **or** 30 days, whichever is smaller. Test both axes | executor | CONTINUE |
| **0b** | Picker `rowId` test fails — selection not threaded into commit | Picker selection state not passed to `voice_memo_commit` | Wire the picker-selected `rowId` into the commit call; test the selection→commit path | executor | CONTINUE |
| **0c** | Threshold-gate test fails — lane auto-executes below threshold | Global floor used for all lanes, or lane override missing | Centralize thresholds: global `0.80`; reminder `0.90`; registry `0.86`; agent `0.86`; memory_keep `0.90`. One test per lane gate | executor | CONTINUE |
| **0c** | Duplicate-key test fails — repeat write not blocked, or legit second lane blocked | Key not `memoId + intentId + destination key` (target system + minimum stable target/field/value) | Implement exact composite key; assert repeat blocked AND two distinct lanes from one memo both allowed | executor | CONTINUE |
| **0c** | Duplicate-force-reason test fails — force commits without reason | Reason enum not enforced before write | Block force until reason ∈ `{new_context, correction, operator_confirmed, live_test}` selected (Decision 1); optional note; record both in activity. Test rejects empty/invalid reason | executor | CONTINUE |
| **0c** | Non-protected diff test fails — protected field offered as overwrite, or unselected field written | Diff model includes protected fields, or applies all fields not the selected subset | Compute per-field before/after for NON-protected only; apply only chosen fields; protected fields never in the overwrite set. Test both | executor | CONTINUE |
| **0c** | Enhancement-demotion test fails — heuristic intent silently removed | Enhancement overwrites plan instead of demote/supersede | Enhancement may add/change/**demote/supersede** only; removal candidate stays visible. Test: heuristic intent survives an enhancement that "drops" it | executor | CONTINUE |
| **0c** | Snapshot-retention test fails — intermediate drafts accumulate, or committed/heuristic lost | Prune logic wrong | Retain heuristic + latest-enhanced + committed per memo at `memory-hub/plan-snapshots/<memoId>.json` (Decision 2); prune intermediates only after a newer enhanced/committed exists | executor | CONTINUE |
| **0c** | Notification-suppression test fails — suppressed in background, or fires during active Process | Gate not checking *both* app-active AND Memory/Process-selected | Suppress only when app active **and** Memory/Process anchor selected; background review/error notifications otherwise. Test both states | executor | CONTINUE |
| **any** | Floor rises but no dated provenance comment, or rises without net-new tests | Process slip / padding | Raise `FLOOR=` only to the new measured net-new green count with a dated comment; never to absorb a regression | executor | **STOP** (constraint breach) |

## §B2. Live M1 trust failure (simple trust path — first live gate)

| Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|
| M1 returns **0 or >1** auto-executes | Election not lane-priority-first, or thresholds mis-gated | Re-verify 0a election + 0c thresholds; M1 expects exactly one `reminder` auto-execute | executor diagnoses / operator confirms | **STOP** live order (do not advance to M5) |
| Reminder created but title is the **entire paragraph** | Title extraction not scoped to the reminder clause | Treat as PARTIAL, not FAIL; log for parser refinement (PKT-MEM-107 territory). Does not block M5 if the single-execute + gate held | operator grades | CONTINUE (PARTIAL) |
| Memo marked **processed** while Jacob/Bridge v4/agent lanes still pending | Processed-gate not aligned across callsites | **BLOCKED** — fix §B6 P-gate before re-running M1 | executor | **BLOCKED** |
| Suppressed lanes absent from Inbox/Process | Review identity or Process↔Inbox mirror broken | Verify 0a `intentId`+`memoId` grouping and 0b mirror; 3 lanes (contact, project, agent_memory) must appear | executor | **STOP** |
| M1 run before Phase 0 blockers fixed | Spec §0.1 live-gate violated | M1 pre-fix is REVIEW-only evidence; do not record PASS/FAIL | operator | **STOP** recording as pass/fail |

## §B3. M5 registry-triple (election mis-pick / picker absent / wrong-row write)

M5 = three `registry_update` lanes (session DST-8, project Bridge v4, contact Jacob), **no reminder**. The registry-heavy gate and the picker's first real proof.

| Failure | Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|---|
| **Election mis-pick** | Auto-executed registry lane isn't the highest-confidence one (spec expects ~session DST-8 @0.88) | Tie-break within `registry_update` not falling through to confidence after equal lane priority | Confirm lane-priority-first leaves a confidence tie-break inside same-kind lanes; if confidences are genuinely close, this is operator-choice → route through picker rather than forcing a "correct" auto-pick | executor diagnoses / operator decides | CONTINUE if picker resolves; **STOP** if auto-write hit the wrong row |
| **Picker absent** | Multiple `registry_update` lanes but no inline entity/row picker in Process detail inspector | 0b picker not wired, or not triggered on multi-registry / ambiguous-hint condition | Picker MUST appear when >1 registry lane OR ambiguous row hint. Verify trigger condition + AX `registryRow.<entity>.<rowId>` | executor | **STOP** M5 (cannot safely commit secondaries) |
| **Wrong-row write** | Append landed on wrong session/project/contact row | Commit used hint instead of operator-selected `rowId`; or picker selection not threaded into `voice_memo_commit` | `voice_memo_commit` must bind to the **selected** `rowId`, not the free-text hint. Revert the bad append (append-only makes this additive cleanup), re-commit to correct row | executor reverts / operator confirms target | **BLOCKED** (wrong-target write — §B6) |
| **Two lanes collapse** | Inbox shows 1 suppressed instead of 2 | Same-kind de-dupe bug (§B1 0a) | Fix `intentId`-based de-dupe; M5 must show exactly 2 suppressed | executor | **STOP** |
| **Append became overwrite** | Protected field replaced on commit | Append path bypassed | **BLOCKED** — §B6 | executor | **BLOCKED** |

## §B4. M8 cascade (suppressed-lane count, duplicate)

M8 = 5+ intents (reminder 5pm + session + project + contact + memory_keep + agent_memory). Heaviest fan-out; stresses suppression count and duplicate blocking.

| Failure | Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|---|
| **Wrong suppressed count** | Inbox shows ≠ the expected ~4 suppressed lanes under one `memoId` | Some lanes dropped before review, or collapsed by de-dupe | Verify every non-primary executable lane → distinct review entry (`secondary intent suppressed`); same `memoId` grouping intact | executor diagnoses / operator counts | **STOP** M8 |
| **Duplicate write on re-commit** | Committing a suppressed lane twice writes twice (e.g. duplicate Memory row) | Duplicate key not enforced at commit, or key omits destination identity | Enforce `memoId+intentId+destination key`; block by default; force only with reason enum | executor | **STOP** (escapes into Notion churn — §B8b) |
| **Process preview incomplete** | `voice_memo_get` plan doesn't list all 5+ intents | Heuristic parse truncated, or enhancement silently removed lanes | Verify no-silent-removal (0c) + full heuristic enumeration before any enhancement | executor | **STOP** |
| **Per-lane commit fails** | Operator cannot commit each suppressed lane individually from Process | Per-intent commit not wired to `commit.<intentId>` | Wire per-intent commit; AX command per intent | executor | **STOP** |
| **memory_keep duplicates on force** | Forced re-file creates 2nd Memory row without reason | Force path skips reason picker | Block until reason selected; record in activity (live-suite forces use `live_test`) | executor / operator supplies reason | CONTINUE (force is legitimate with reason) |

## §B5. Election tension (reminder always outranks registry_update — operator-intent mismatch)

> **This is a KNOWN, ACCEPTED design tension, not a bug.** M2 and M9 explicitly document it: lane-priority-first means `reminder` wins even when the operator's *intent* was the session/project update. The fix is **UX, not election logic** — the Process override + picker exist precisely to remediate it.

| Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|
| M2/M9: `reminder` auto-executes; operator wanted session/project as primary | By-contract lane priority (`reminder` > … > `registry_update`) | **Do NOT "fix" by reordering election** (that breaks M1/M5/M8 contracts). Remediate via Process **primary override** before any write + registry **picker** — operator demotes reminder, elevates the registry lane, commits it | operator (override action) | CONTINUE — grade **PASS** if override works, **PARTIAL** if override path missing |
| Override button present but writes still go to election winner | `primaryOverride.<intentId>` not threaded into commit | Commit must honor overridden primary, not original election | executor | **STOP** (override is the whole remediation) |
| Operator surprised by behavior (no signal of why reminder won) | Election reason not surfaced in intent table | Show election reason / lane-priority marker in intent table so the mismatch is legible before commit | executor | CONTINUE |
| Tension reappears with no override available pre-fix | Running M2/M9 before 0b cockpit lands | Defer M2/M9 grading until override+picker shipped; pre-fix runs are REVIEW-only | operator | **STOP** recording as pass/fail |

## §B6. Trust-invariant violations → BLOCKED until fixed (no merge, no further live grading)

> These are **sacred** (PKT-MEM-105). Any one makes the build un-mergeable and halts the live order regardless of which test surfaced it. Grade = **FAIL**.

| Invariant breach | Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|---|
| **Registry overwrite** | Protected field (`brief`/`objective`/`summary`/`description`) replaced instead of appended; pre-existing text gone | Write bypassed read-modify-write append; or non-protected diff path touched a protected field | Restore append-only routing; add regression test asserting prior content survives; re-run M5 | executor | **BLOCKED** |
| **Truncated agent memory** | `memory_recall` returns first-sentence only, not full transcript | Regression of PKT-MEM-105 full-transcript store | Restore full-transcript persistence; test asserts char-length parity with source; re-run M1 (M6 optional, see note) | executor | **BLOCKED** |
| **Processed-with-pending** | `processed.json` contains a memo that still has pending review entries | Gate not aligned across all `markProcessed` callsites (some site marks independently) | Route every callsite through the shared no-pending-sibling predicate; test each entry point + a processor-path site; re-run M1/M5/M8 | executor | **BLOCKED** |
| **Wrong-target registry write** | Append landed on a row the operator didn't select (M5/M8) | Commit bound to hint not selected `rowId` | Bind commit to picker `rowId`; additive-revert the stray append; regression test | executor reverts / operator confirms | **BLOCKED** |
| **Full transcript in activity log** | `activity.jsonl` `detail` contains raw transcript text | Privacy contract bypassed | Strip to hash + short excerpt; purge offending events; test asserts no transcript body | executor | **BLOCKED** |

> **Note on M6 (truncated agent memory row):** The locked Phase-0 live re-test order is strictly **M1 → M5 → M8**. M6 is an **optional extended regression** for the full-transcript invariant, NOT a gated rung — an executor must not treat M6 as a required step. If the full-transcript regression test (`agentMemory_fullTranscriptStored_notFirstSentence`) is green and M1 passes, the invariant is covered; M6 may be run as extra evidence only.

**BLOCKED protocol:** stop the current slice, do not merge, do not advance the M1→M5→M8 order. Land the fix + a net-new regression test, raise floor with dated provenance, re-run the affected live case, then resume.

## §B7. Registry stale-cache / mis-target

| Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|
| Picker shows rows that no longer exist / missing new rows | Cache served past 24h without stale badge; live `registry_list` not attempted first | Picker loads **live** `registry_list` first; cached fallback only on offline/error; badge stale after 24h. Cache at `memory-hub/registry-cache/<entity>.json` with `fetchedAt`/`ttl`/stale/error | executor | CONTINUE (badge makes it safe); **STOP** if a stale row was committed silently |
| Stale row selected and committed without warning | Stale-fallback didn't force manual commit | Stale fallback MUST force manual commit (no auto-execute on stale target) | executor | **STOP** if it auto-wrote |
| Cache file corrupt / unreadable | Partial write, schema drift | Treat as cache-miss → live fetch; never block picker on bad cache; log error in cache `source error` field | executor | CONTINUE |
| Offline: picker empty, no fallback | Last-good cache not persisted | Persist last-good on every successful `registry_list`; label offline source | executor | CONTINUE |

## §B8. Enhancement timeout + silent-removal escape; duplicate-write escape

### §B8a. Enhancement timeout / silent-removal

| Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|
| Local enhance hangs > 8s; preview stuck | No soft timeout; provider stall (Ollama) | 8s soft timeout → fall back to latest valid heuristic/local plan; record `timeout` status in activity | executor | CONTINUE (heuristic is the floor) |
| Cloud enhance hangs > 20s | No manual-cloud timeout; key/network issue | 20s timeout → keep latest valid plan; record status; surface to operator | executor / operator (key) | CONTINUE |
| Heuristic intent **vanishes** after enhancement | Enhancement removed instead of demoted | **Silent-removal escape = contract breach.** Force demote/supersede semantics; removed candidate stays visible until operator acts. Regression test | executor | **STOP** (lost-lane risk) |
| Enhanced plan committed without diff review | Diff badges not shown; changed lane not returned to uncommitted | Changed lane returns to uncommitted review state; commit only the displayed approved intent; snapshot diff badges before commit | executor | **STOP** if a silently-changed lane auto-wrote |

### §B8b. Duplicate-write escape

| Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|
| Re-run / re-commit produces a 2nd Notion row or reminder | Duplicate key not enforced, or key too narrow | Enforce `memoId+intentId+destination key`; block by default | executor | **STOP** |
| Force path writes with no recorded reason | Reason enum not gating force | Require `{new_context, correction, operator_confirmed, live_test}` + optional note; record in activity | executor / operator | CONTINUE (force is valid with reason) |
| Legit separate lane wrongly blocked as duplicate | Destination key collides across distinct lanes | Destination key must include minimum stable target/field/value to disambiguate | executor | CONTINUE |

## §B9. Notification mis-suppression; floor regression

| Detection / symptom | Likely cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|
| No notification fires even though app is in background with queued review/error | Suppression gate too broad (suppressing on app-active alone, or always) | Gate must require **app active AND Memory/Process selected** to suppress; otherwise deliver + deep-link | executor | CONTINUE (recovery risk if operator is elsewhere) |
| Notification fires while operator is actively in Process | Active-detection not checking selected anchor | Add selected-Memory/Process anchor to the gate | executor | CONTINUE |
| Deep-link lands on wrong surface/filter | Anchor mapping stale (legacy `voice-memos` → Advanced) | Route to Memory/Inbox (or relevant filter); deprecate Advanced anchor | executor | CONTINUE |
| **Floor regression** — green count drops after a slice | A change broke existing tests; or a test was deleted to "pass" the gate | Never lower FLOOR to absorb a regression. Restore the broken test's green; if a test was legitimately removed, record dated reason. Floor moves **up only**, by net-new count | executor | **STOP** (constraint breach) |
| Floor raised without net-new tests | Miscount / padding | Re-measure; FLOOR = actual net-new green; dated provenance comment | executor | **STOP** |

## §B10. Doc-reconciliation failures (land before live grading)

| Detection / symptom | Cause | Remediation action | Owner | STOP / CONTINUE |
|---|---|---|---|---|
| Decision ledger conflicts between SPEC §0.1, SPEC §8, MANIFEST ~L55 | Triplicated source of truth | Make **SPEC §0.1 the SSOT**; SPEC §8 + MANIFEST L55 become explicit REFERENCES to §0.1 (no independent restatement) | executor | CONTINUE (fix before grading) |
| SPEC §0 "Test floor baseline 2270" | Stale | Update to **2303** as the locked Phase-0 baseline; never lower a live `scripts/test-floor-gate.sh` value that already exceeds it | executor | CONTINUE |
| PKT-MEM-112/113 imply A–E is next | Predate 06-25 reflow | Annotate: **Phase 0 (PKT-MEM-106) precedes A–E and SUPERSEDES B/D/E UI items** (registry picker, activity strip, cloud-key UI, Agent forget/pin) | executor | CONTINUE |
| Version drift: SPEC "v3.9.x" vs suite "v3.8.2+/v3.8.3" | Unaligned headers | Align to shipped reality (v3.8.2 installed; next published install = v3.8.3 per versioning rule) | executor | CONTINUE |
| Five new operator-locked decisions not folded into §0.1 | New locks (force-reason enum, snapshot path, OpenAI-compat fields, per-field diff apply, M1→M5→M8 order) | Fold all five into §0.1 (and reference, not duplicate, elsewhere) | executor | CONTINUE |

---

## TOP-LEVEL STOP-CONDITIONS (executor must HALT to REVIEW, not proceed)

The executor stops the slice/sprint and escalates to operator REVIEW — rather than self-continuing — when **any** of the following holds:

1. **Any trust-invariant breach (§B6):** registry overwrite of a protected field, truncated agent memory, processed-with-pending, wrong-target registry write, or a full transcript leaked into `activity.jsonl`. → **BLOCKED** until fixed + regression test + floor bump; do not merge, do not advance M1→M5→M8.
2. **Baseline not green / floor below entry floor (§B0):** never build Phase 0 on a red or under-floored baseline; 2303 is the locked minimum baseline, not permission to lower a newer script floor.
3. **Floor would regress or rise without net-new tests (§B1, §B9):** FLOOR moves up only, by measured net-new green, with dated provenance. Lowering it (or padding it) is a hard stop.
4. **Processed-gate not aligned across all `markProcessed` callsites (§B1 0a, §B6):** the three tools AND every resolver/processor callsite must consult the shared predicate before any live grading.
5. **Election mis-pick that produced an auto-write to the wrong target (§B3):** as opposed to the *accepted* reminder-vs-registry tension (§B5), which is remediated by override/picker, not a stop. A genuine wrong-lane **auto-write** halts.
6. **Registry picker absent when >1 registry lane or ambiguous row hint (§B3):** cannot safely commit secondaries; M5/M8 grading halts.
7. **M5 election contradicts operator intent and the Process override/picker is not yet shipped (§B5):** explicit REVIEW stop carried over from PKT-MEM-113 — operator must choose the registry target manually before proceeding.
8. **Silent removal of a heuristic intent by enhancement (§B8a):** lost-lane risk; demote/supersede only.
9. **Duplicate-write escape (§B4, §B8b):** a re-run/force produced a second Notion row or reminder without the reason-enum gate.
10. **Stale registry target auto-committed without forcing manual commit (§B7):** stale fallback must force manual commit; an auto-write to a stale row halts.
11. **Running M1/M5/M8 as pass/fail before Phase 0 blockers are fixed (SPEC §0.1 live gate):** pre-fix runs are REVIEW-only evidence by explicit operator acceptance; recording them as PASS/FAIL is a stop.
12. **Re-test order or single-memo protocol violated:** must be **M1 → M5 → M8** (Decision 5), one memo per signal, never `voice_memo_process mode:batch` or batch-process the backlog. A FAIL/BLOCKED at an earlier rung halts before the next (do not run M5 if M1 trust failed; do not run M8 if M5 registry path failed). M6 is NOT a gated rung (optional extended regression only).
13. **Live MCP surface unavailable (§B0 P-3):** app not relaunched or `bridge-env` not injected (`connectorAuth` nil) — halt live testing (unit work may continue) and have the operator relaunch / reload the LaunchAgent.
14. **Scope creep beyond Phase 0:** if a fix requires a new Settings section (forbidden — Memory exists), a new MCP tool without a `ToolAnnotationCatalog` entry, or new Memory controls without a `SettingsUIValidationHarness` entry → stop and re-scope.

**Resume protocol after any stop:** land the fix + net-new regression test → keep or raise `FLOOR` with dated provenance (never lower to baseline/projection) → re-run the affected live case in M1→M5→M8 order → record activity-log receipt (full SHA-256, display first 12) + a PASS/PARTIAL/FAIL markdown grade row in `docs/operator/live-evidence/PKT-MEM-113-M1-M5-M8.md` before continuing.

---

**Source docs (absolute):**
- `/Users/keepup/Developer/the-bridge/docs/operator/packets/PKT-MEM-106-phase0-trust-cockpit.md`
- `/Users/keepup/Developer/the-bridge/docs/operator/MEMORY-HUB-EXECUTION-SPEC.md` (§0.1 ledger, §2 LOCKED, §7 reflow, §8 material decisions, §9 gates)
- `/Users/keepup/Developer/the-bridge/docs/operator/MEMORY-HUB-DISPATCH-MANIFEST.md` (~L55 reflow paragraph)
- `/Users/keepup/Developer/the-bridge/docs/operator/MEMORY-HUB-UI-VISION.md` (cockpit contract)
- `/Users/keepup/Developer/the-bridge/docs/operator/MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md` (M1–M10, trust invariants, M2/M5/M9 election-tension notes)
- `/Users/keepup/Developer/the-bridge/docs/operator/packets/PKT-MEM-105-trust-integrity.md` (sacred invariants)
- `/Users/keepup/Developer/the-bridge/scripts/test-floor-gate.sh` (live `FLOOR=`; locked Phase-0 baseline was 2303, but the script may already be higher after landed slices)
- Grounded code surfaces: `TheBridge/Modules/VoiceMemo/VoiceMemoIntentElection.swift` (`isLowerPriority` confidence-first → 0a priority-first) · `VoiceMemoReviewStore.swift` (`enqueue` dedupes `memoId+intentKind` → 0a `intentId`) · `VoiceMemoReviewResolver.swift` (~8 `markProcessed` sites) · `VoiceMemoProcessor.swift` (~280/649) · `VoiceMemoModule.swift` (`voice_memo_commit` accepts `intentKind/entityKey/entityHint/rowId/fields`)
