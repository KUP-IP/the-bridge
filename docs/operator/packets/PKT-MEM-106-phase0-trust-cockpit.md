# PKT-MEM-106 — Memory Hub Phase 0 (Trust + Process Cockpit Integration)

**Wave:** 3 · **Phase:** 0 (precedes A–E; supersedes their B/D/E UI items)
**Class:** Standard (integration packet — coupled trust + cockpit unblock)
**Parent packet:** [PKT-MEM-112](./PKT-MEM-112-wave3-deferred-closeout.md)
**Branch:** `feat/memory-hub-voice-curator` (integration branch — slices land back-to-back here; integrate to `main` after Wave 3)
**Spec SSOT:** `docs/operator/MEMORY-HUB-EXECUTION-SPEC.md` — **§0.1 decision ledger is the single source of truth**; §2 LOCKED contracts; §3 ladder; §4 review; §7 (18-item Wave-3 reflow); §9 gates
**UI contract:** `docs/operator/MEMORY-HUB-UI-VISION.md` (Process cockpit)
**Live suite:** `docs/operator/MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md` (M1–M10)
**Validation + remediation:** `docs/operator/MEMORY-HUB-VALIDATION-AND-REMEDIATION.md` (per-slice net-new test plan + STOP/CONTINUE remediation)
**Prerequisites shipped (do NOT re-spec):** PKT-MEM-101 Apple `tsrp` ladder · PKT-MEM-102 Memory section + Inbox · PKT-MEM-103 review-resolve + TTL · PKT-MEM-104 notify + tabs · PKT-MEM-105 TRUST (append-only registry, primary election, processed gate, full-transcript agent memory, `memory_forget`) · PKT-MEM-110a curator foundation (`voice_memo_get` / `voice_memo_commit`) · PKT-MEM-111 U1+U6 (Process + Processing tabs)
**Baseline:** test floor **2303**; `make install` notarized `/Applications/The Bridge.app` v3.8.2 (2026-06-24)

> **Ledger discipline.** The 2026-06-25 choice-to-contract decisions are recorded once, in **SPEC §0.1**. SPEC §8 and the dispatch manifest (~line 55) REFERENCE §0.1 and must not be re-litigated or re-stated here. This packet operationalizes §0.1 + §7 into three back-to-back slices; it does not redefine the ledger.

---

## Goal Contract

### Outcome

Close the Memory Hub trust + Process-cockpit blockers as **one coherent integration** so the operator can record a multi-intent memo, watch a progressive preview, choose a primary lane, commit one intent at a time with guardrails, and resolve suppressed lanes — with deterministic per-intent identity, append-only registry writes, durable receipts, and precise notification behavior. This unblocks live **M1/M5/M8** pass/fail testing (currently gated by review-identity / processed-gate / election / commit-UX gaps).

### Scope — IN

- **Trust + identity core** (Slice 0a): deterministic `intentId`, `memoId` grouping, legacy derive-on-read, processed-gate alignment, lane-priority-first election, distinct same-kind suppressed lanes, append-only protected registry fields.
- **Process cockpit + activity** (Slice 0b): three-zone split cockpit, primary override, inline registry entity/row picker with per-entity JSON cache, per-intent commit, Process↔Inbox mirror of unresolved lanes, append-only JSONL activity log + strip with structured receipt envelope, stable AX identifiers.
- **Preview + guardrails + tabs** (Slice 0c): progressive preview (heuristic → local-auto → cloud-manual) with timeouts + versioned snapshots + no-silent-removal, commit guardrails (lane thresholds / ambiguity / duplicate block + force-with-reason / stale-fallback), **per-field registry diff apply UX**, Processing Keychain provider status/save/delete (OpenAI-compatible), Agent soft-forget + pin, Notion open + refresh + dry-run backfill, precise notification suppression.

### Scope — OUT

- The older A–E phases themselves: **PKT-MEM-107** (datetime/calendar), **PKT-MEM-108** UI closeout, **PKT-MEM-109** spec v1.1 refresh, **PKT-MEM-110b** cloud curator, **PKT-MEM-111b** Process polish. Phase 0 **precedes** A–E and **supersedes their B/D/E UI items** (registry picker, activity strip, cloud-key UI, Agent forget/pin); the residual A/C/D/E work resumes after Phase 0 merges.
- Embeddings / `recall`, backwards-sync outbox, `registry_remove_entity`, v2 entity types (Events · BLOCKS · AI Logs as hardcoded seeds).
- Anthropic/native multi-provider cloud behavior (generic slots + **one** OpenAI-compatible manual path only in Phase 0).
- Full Notion row CRUD (Data Sources remains the schema/config surface); full provider admin / billing / model catalog / usage dashboard.
- New Settings section (Memory already exists). UNNotificationCategory quick actions (Phase 2+).
- A production release tag (operator decides after live smoke).

### Constraints

- **Trust invariants are sacred** (PKT-MEM-105): exactly one primary lane auto-executes; suppressed lanes queue to review with reason `secondary intent suppressed`; protected registry text fields (`brief`, `objective`, `summary`, `description`) are **append-only, never overwritten**; a memo is marked processed **only when no pending review remains for that memo**; agent memory stores the **full transcript**. No Phase 0 path may weaken these for automation rate.
- **Floor rises only by net-new tests** from **2303**, each slice raising `scripts/test-floor-gate.sh` `FLOOR=` with a dated provenance comment (order-inversion rule). Floor numbers in the validation plan are PROJECTED; each slice re-measures the actual integrated green and sets `FLOOR=` to that count. Never lower without a recorded reason.
- **No new Settings section** — all UI lands on existing Memory tabs (Process / Inbox / Notion / Agent / Processing).
- Every new MCP tool requires a `ToolAnnotationCatalog` entry (audit invariant hard-fails the build otherwise). New Memory controls require `SettingsUIValidationHarness` entries.
- Memory Hub files live under `~/Library/Application Support/TheBridge/memory-hub/` only (`activity.jsonl`, `registry-cache/<entity>.json`, `plan-snapshots/<memoId>.json`) — separate from voice-memo transcripts; never UserDefaults for evidence.
- No regression: `job_run` on paused jobs still works (`allowPaused: true`); stdio / legacy SSE / `/health` / connector paths byte-for-byte unchanged.
- Do not run M1/M5/M8 as pass/fail live evidence until Slice 0a lands (earlier recordings are REVIEW-only if the operator explicitly accepts that scope).

### Success Criteria

1. `intentId` is `intent_v1_` + first 20 hex of SHA-256 over canonical JSON (sorted keys, trimmed strings, normalized whitespace, lowercase enums) of `memoId + kind + entityKey + entityHint + destination fields + normalized title`, produced by **one** canonical generator shared by processor, review store, Process UI, activity receipts, and tests.
2. Two same-kind lanes (e.g. two `registry_update` from one memo) never collapse; they remain distinct review items grouped by `memoId` and mirrored to Inbox.
3. Election is lane-priority-first (`reminder` > `agent_memory` > `registry_update` > `memory_keep`), then confidence — implementation and tests agree.
4. Processed marking is aligned across **all** `markProcessed` callsites (the `voice_memo_process` / `voice_memo_commit` / `voice_memo_review_resolve` tool entry points AND every internal resolver/processor callsite): processed only when no sibling pending review remains for that memo.
5. Process is a three-zone cockpit (memo list / intent table / detail-commit inspector) with primary override, inline registry picker, and per-intent commit.
6. Activity log is append-only JSONL at `memory-hub/activity.jsonl` with the structured receipt envelope, transcript hash + ≤short excerpt only (no full transcripts), full SHA-256 stored / first 12 displayed, retained to 500 events or 30 days.
7. Preview is progressive with provenance labels, 8s local / 20s cloud timeouts, versioned plan snapshots with diff badges, and demote/supersede (never silent removal).
8. Commit guardrails enforce lane thresholds (global 0.80 / reminder 0.90 / registry 0.86 / agent 0.86 / memory_keep 0.90), ambiguity, duplicate-block-by-default + force-with-reason, and stale-fallback.
9. Stable AX identifiers exist for zones, memo rows, intent rows, picker rows, commit, and primary override.
10. `make test` green and floor raised per slice with dated provenance; M1 → M5 → M8 live re-test produces a PASS/PARTIAL/FAIL grade table + activity-receipt references.

### GOAL_CONDITION

Phase 0 is DONE when, on `feat/memory-hub-voice-curator`: all three slices' Definition-of-Done checklists are green; `make test` passes with `FLOOR=` raised by net-new tests (`≥2303` → the per-slice measured green count, set after re-measuring — the validation plan's projected totals are NOT inherited as hard targets) with dated provenance; the trust invariants above hold under the Slice-0a tests; the cockpit renders the three zones with stable AX IDs and per-intent commit; the activity log, registry cache, and plan snapshots persist at their locked paths; and the operator runs the live re-test order **M1 → M5 → M8** against `make install`-built `The Bridge.app`, producing a markdown grade table with activity-receipt references (per the live suite). Each slice is independently reviewable and shippable; **0a lands first** because it unblocks live M5/M8.

---

## Slice 0a — TRUST + IDENTITY CORE (no UI)

**Purpose:** the M5/M8 blocker set. Establish deterministic per-intent identity, the processed gate, election, distinct same-kind lanes, and append-only protected registry writes in the model/processor layer — independent of any cockpit UI. Ships first.

### Definition of Done

- [ ] **Canonical generator.** One shared `intentId` generator: `intent_v1_` + **first 20 hex** of SHA-256 over canonical JSON of `memoId`, `kind`, `entityKey`, `entityHint`, destination fields, and normalized title. Canonical JSON = sorted keys, trimmed strings, normalized whitespace, lowercase enum fields. No ad-hoc string joins. Used by processor, review store, (downstream) Process UI, activity receipts, and tests.
- [ ] **`memoId` grouping.** Review entries carry stable `intentId` + `memoId`; pending entries are grouped by `memoId`.
- [ ] **Legacy derive-on-read.** Legacy review entries without `intentId` derive one on read from available legacy fields plus `createdAt`/reason fallback when canonical fields are incomplete; such entries/receipts are marked `legacyDerived`. Legacy files are rewritten **only when touched** (resolved, dismissed, committed) — no launch-time destructive migration.
- [ ] **Processed-gate alignment (ALL callsites).** A single shared "no pending review remains for `memoId`" predicate gates **every** `markProcessed` callsite — the three tool entry points (`voice_memo_process`, `voice_memo_commit`, `voice_memo_review_resolve`) AND every internal callsite in `VoiceMemoReviewResolver` (the ~8 `VoiceMemoProcessedStore.markProcessed` sites, e.g. lines ~101/135/157/172/209/219/304) and `VoiceMemoProcessor` (lines ~280, ~649). No callsite may mark processed independently while a sibling review for that memo is still pending.
- [ ] **Lane-priority-first election.** `VoiceMemoIntentElection` elects by lane priority first (`reminder` > `agent_memory` > `registry_update` > `memory_keep`), then confidence. Today the election compares confidence before lane priority (`isLowerPriority`); invert it. Implementation and tests both encode this contract.
- [ ] **Distinct same-kind suppressed lanes.** De-dupe never collapses two intents solely because they share `memoId` and `intentKind`; multiple `registry_update` lanes from one memo remain distinct review items (reason `secondary intent suppressed`), preserving session/project/contact separately via target metadata in review identity. Today `VoiceMemoReviewStore.enqueue` dedupes by `memoId + intentKind`; rekey to `intentId`.
- [ ] **`rowId` commit threads to writer (model layer).** The EXISTING `voice_memo_commit` `rowId` parameter routes to the registry writer keyed by `rowId` (rowId wins over a free-text `entityHint` match). No UI dependency — this asserts the existing param plumbing under the new identity model. (Picker-driven `rowId` selection is Slice 0b.)
- [ ] **Append-only protected registry fields.** `brief`, `objective`, `summary`, `description` are append-only in all write paths touched here; no path overwrites them. (The per-field diff apply UX for NON-protected fields is Slice 0c — not in 0a.)
- [ ] Review data model extended to flat per-intent entries: `intentId`, `memoId`, `kind`, `entityKey`, `entityHint`, optional `rowId`, destination fields, status, reason, provenance, timestamps.
- [ ] `make test` green; floor raised (see below).

### Net-new tests (Slice 0a)

- `intentId` format: `intent_v1_` prefix + exactly 20 hex chars; determinism across reruns; same-kind lanes produce **different** ids when target differs; canonicalization (sorted keys / trimmed / whitespace / lowercase enums) yields stable hash.
- Election: lane-priority-first ordering across all four lanes; confidence tie-break within a lane; M5-shaped triple (one auto-execute, two suppressed) and M8-shaped cascade.
- Processed gate: a single shared predicate yields the same "no pending review for memoId" result across `process` / `commit` / `review_resolve` AND the resolver/processor callsites; not processed while a sibling review is pending; processed once siblings clear.
- Distinct lanes: two `registry_update` intents (session + project) never de-duped; both queued with `secondary intent suppressed`.
- Legacy migration: `intentId` derived on read for a legacy entry, marked `legacyDerived`; file rewritten only after touch.
- `rowId` commit (model): existing `voice_memo_commit(rowId:…)` param routes to the registry writer by `rowId` over `entityHint`.
- Append-only protected fields: a `registry_update` to `brief`/`summary` appends and never overwrites.

> **Floor bump (0a):** measure the integrated green after 0a; raise `scripts/test-floor-gate.sh` `FLOOR=` to that count with a dated provenance comment, e.g. `# PKT-MEM-106 0a trust+identity (2026-06-25): +N VoiceMemoIdentity/Election/ProcessedGate tests; canonical intent_v1_ 20-hex, lane-priority election, processed-gate alignment across all markProcessed callsites, distinct same-kind lanes, legacy derive-on-read, rowId-param threading. Measured green 2303 + N.` (`+N` = the actual net-new count measured at merge, not a pre-baked target.)

---

## Slice 0b — PROCESS COCKPIT + ACTIVITY

**Purpose:** refactor Process into the locked split cockpit, surface the registry picker, add per-intent commit and Process↔Inbox mirroring, and back it with a durable local activity log + strip and stable AX identifiers. Depends on 0a identity.

### Definition of Done

- [ ] **Split cockpit.** Refactor `MemoryProcessTab` from two-pane cards into three zones — **memo list** (transcript source, processed/review state, latest activity), **intent table** (primary marker, kind, confidence, entity, row hint, destination field, status, warning state), **detail/commit inspector** (transcript/detail, registry picker when needed, field preview, primary override, dry-run, commit).
- [ ] **Primary override.** Operator can override the elected primary lane before any write.
- [ ] **Registry entity/row picker.** Inline picker appears when multiple registry lanes or ambiguous row hints exist. Rows load from live `registry_list` with last-good cached fallback; cache = one JSON file per entity at `memory-hub/registry-cache/<entity>.json` with TTL metadata (`fetchedAt`, `ttl`, stale state, source error); fallback rows are labeled **stale after 24h**. Selected entity/row flows into `voice_memo_commit`.
- [ ] **Per-intent commit.** Commit one approved intent at a time via `voice_memo_commit`; suppressed lanes remain distinct review items.
- [ ] **Picker-selected `rowId` flows into commit.** The entity/row selected in the picker threads its `rowId` into `voice_memo_commit` (the UI-driven counterpart to 0a's param-threading); the commit targets the selected row, not the free-text hint.
- [ ] **Process↔Inbox mirror.** Unresolved lanes stay visible in Process (grouped by `memoId`) and are mirrored to Inbox as exception rows until resolved, dismissed, or marked handled.
- [ ] **Activity log + strip.** Append-only JSONL at `~/Library/Application Support/TheBridge/memory-hub/activity.jsonl`. Each event uses the structured receipt envelope: `eventId`, timestamp, `schemaVersion`, `memoId`, optional `intentId`, `phase` (`transcribe`/`understand`/`plan`/`execute`/`review`/`test`), `action`, `status`, `provenance`, `actor`, `detail`, `receiptHash`. **No full transcripts** — transcript evidence limited to a transcript hash + memo reference + short excerpt. Store **full SHA-256** `receiptHash`; display/reference **first 12 chars** in UI and live-test tables. Retention prunes by **500 events or 30 days, whichever comes first**. The strip shows recent preview/commit receipts and survives relaunch (not transient view state); long `voice_memo_get`/commit runs show progress across the four phases.
- [ ] **Stable AX identifiers.** Zones: `memoryProcess.memoList`, `memoryProcess.intentTable`, `memoryProcess.detailInspector`, `memoryProcess.activityStrip`. Rows: `memoryProcess.memoRow.<memoId>`, `memoryProcess.intentRow.<intentId>`, `memoryProcess.registryRow.<entity>.<rowId>`. Commands: `memoryProcess.commit.<intentId>`, `memoryProcess.primaryOverride.<intentId>`. Tests prefer AX IDs over display text.
- [ ] `SettingsUIValidationHarness` entries added for the new Process controls.
- [ ] `make test` green; floor raised (see below).

### Net-new tests (Slice 0b)

- Activity receipt envelope: required fields present; `receiptHash` is full SHA-256 with a 12-char display projection; no full transcript in `detail` (hash + excerpt only); retention prunes at 500 events / 30 days.
- Registry cache: per-entity JSON read/write at `memory-hub/registry-cache/<entity>.json`; TTL metadata; last-good fallback selectable; stale flag after 24h.
- Cockpit/AX: zone + row + command AX identifiers resolve via `SettingsUIValidationHarness`; intent rows keyed by `intentId`; registry rows keyed by `<entity>.<rowId>`.
- Process↔Inbox mirror: a suppressed lane appears in both Process (grouped) and Inbox; resolving in one clears the mirror.
- `rowId` commit (picker): the picker-selected `rowId` reaches `voice_memo_commit` and flows into the registry write path.

> **Floor bump (0b):** raise `FLOOR=` to the post-0b measured green with a dated provenance comment, e.g. `# PKT-MEM-106 0b cockpit+activity (2026-06-25): +N MemoryProcess/ActivityLog/RegistryCache tests; three-zone cockpit + AX IDs, JSONL receipt envelope (full-hash/12-char display, 500/30d retention, no transcripts), per-entity registry cache + 24h stale, Process↔Inbox mirror, picker rowId commit. Measured green <0a> + N.` (`+N` measured at merge.)

---

## Slice 0c — PREVIEW + GUARDRAILS + TABS

**Purpose:** make preview progressive and safe, gate commits, and complete the secondary-tab affordances (Processing provider keys, Agent forget/pin, Notion refresh/backfill) plus precise notification suppression. Depends on 0a (identity) + 0b (cockpit + activity + snapshots surface).

### Definition of Done

- [ ] **Progressive preview.** Fast heuristic plan renders first (`provenance: heuristic`); local Ollama may **auto**-enhance after first render; cloud enhancement is **manual only** (explicit operator action). UI labels provenance and stale/enhancing states. Operator can commit only the currently displayed approved intent; if enhancement changes an intent, that lane returns to uncommitted review state.
- [ ] **Timeouts.** Heuristic immediate; local enhancement **8s** soft timeout; manual cloud enhancement **20s** timeout. On timeout, keep the latest valid heuristic/local plan and record timeout status in activity.
- [ ] **Versioned plan snapshots + diff badges.** Preview/enhancement results stored as versioned plan snapshots; UI badges added / changed / demoted-superseded intent fields before commit. **Decision 2 — snapshot storage:** per-memo JSON at `~/Library/Application Support/TheBridge/memory-hub/plan-snapshots/<memoId>.json` (inspectable, prunable). Retention keeps the **heuristic, latest enhanced, and committed** snapshot per memo; intermediate enhanced drafts pruned after a newer enhanced/committed snapshot exists.
- [ ] **No silent removal.** Enhancement may add, change, or demote/supersede heuristic intents but may **not** silently remove one; any removal candidate stays visible as demoted/superseded until the operator commits, dismisses, or marks handled.
- [ ] **Commit guardrails.** Auto-execute only when confidence passes the lane-specific threshold AND the global floor AND registry target resolution is unambiguous. Defaults stored centrally: global **0.80**, `reminder` **0.90**, `registry_update` **0.86**, `agent_memory` **0.86**, `memory_keep` **0.90**. Low-confidence, ambiguous, duplicate, or stale-fallback lanes require operator commit.
- [ ] **Duplicate block + force.** Duplicate writes blocked by default across reminders, registry updates, `memory_keep`, and `agent_memory`. Duplicate key = `memoId + intentId + destination key` (target system + minimum stable target/field/value identity). **Decision 1 — force reason:** force requires a selected reason from a fixed enum `{new_context, correction, operator_confirmed, live_test}` plus an **optional** free-text note; the commit cannot proceed until a reason enum is selected; the reason + optional note are recorded in the activity log.
- [ ] **Registry per-field diff apply UX (Decision 4).** Non-protected property updates are committed only from an explicit before/after **per-field diff** with selectable non-protected updates (the diff model itself lands here in 0c, not in 0a). Protected fields (`brief`, `objective`, `summary`, `description`) stay **append-only** and are never offered as overwritable diffs. Ambiguous mappings, stale cache targets, or missing selected rows force manual commit.
- [ ] **Processing Keychain provider status/save/delete.** Processing tab shows provider configured/missing status; keys stored in **Keychain only**; supports save/update and delete per provider. **Decision 3 — provider fields:** generic provider slot with **API key + base URL + model name + enabled toggle**, enabling one **OpenAI-compatible** manual enhancement path. Base URL, model name, and the enabled toggle are non-secret config; only the API key is held in Keychain. No provider admin / billing / model catalog / usage dashboard.
- [ ] **Agent tab — soft forget + pin only.** Scope/type filters, pin toggle, and soft forget via `memory_forget`. **No** text editing or hard delete.
- [ ] **Notion tab — open + refresh + dry-run backfill only.** Open in Notion, refresh rows, and backfill missing Memory rows when the registry binding is healthy; backfill is **dry-run preview first, then selected apply**. No full row CRUD.
- [ ] **Notification suppression.** No notification while the app is active AND Memory/Process is selected; background notifications limited to queued review entries and routing/transcript errors, deep-linking to the relevant Memory surface/filter.
- [ ] Any new MCP tool gets a `ToolAnnotationCatalog` entry; stale `voice_memo_process` description updated if behavior changed; `SettingsUIValidationHarness` entries for new Processing/Agent/Notion controls.
- [ ] `make test` green; floor raised (see below).

### Net-new tests (Slice 0c)

- Thresholds: each lane gate (global 0.80 / reminder 0.90 / registry 0.86 / agent 0.86 / memory_keep 0.90) gates auto-execute vs manual; stored centrally; below-threshold → manual.
- Duplicate force: blocked by default on `memoId + intentId + destination key`; force requires a reason from `{new_context, correction, operator_confirmed, live_test}` (commit refused without one); optional note accepted; reason + note recorded in activity.
- Enhancement authority: demote/supersede keeps the lane visible; **no** silent removal of a heuristic intent; changed lane returns to uncommitted.
- Timeouts: local 8s soft / cloud 20s fallback to latest valid plan; timeout status recorded in activity.
- Snapshots: per-memo JSON at `plan-snapshots/<memoId>.json`; retention keeps heuristic + latest-enhanced + committed; diff badges for added/changed/demoted.
- Registry diff (0c): non-protected per-field selectable apply (before/after computed, only chosen fields written); protected fields never overwritable.
- Notification suppression: suppressed only when app active AND Memory/Process selected; background review/error otherwise (precise gate).
- Provider keychain: save/status/delete for the OpenAI-compatible slot (API key + base URL + model + enabled); never plaintext surfaced.

> **Floor bump (0c):** raise `FLOOR=` to the post-0c measured green with a dated provenance comment, e.g. `# PKT-MEM-106 0c preview+guardrails+tabs (2026-06-25): +N PreviewSnapshot/Threshold/DuplicateForce/RegistryDiff/Provider/Notification tests; progressive preview + 8s/20s timeouts, per-memo plan-snapshots/<memoId>.json (heuristic/latest/committed), lane thresholds, duplicate force reason enum {new_context,correction,operator_confirmed,live_test}+note, per-field registry diff (protected append-only), OpenAI-compatible provider slot (key+baseURL+model+enabled), precise active-Process notification suppression, Agent forget/pin, Notion refresh/dry-run backfill. Measured green <0b> + N. Phase 0 final floor.` (`+N` measured at merge.)

---

## Execution Directives (executor sub-agent)

1. **Branch:** work on `feat/memory-hub-voice-curator` (rebase if `main` moved). Land slices **0a → 0b → 0c** back-to-back; each slice is an independently reviewable/shippable commit (or sub-PR) with its own green floor. **0a first** — it unblocks live M5/M8.
2. **Trust invariants are sacred:** append-only protected registry fields, lane-priority-first primary election, processed-gate (no pending review for the memo, enforced at every `markProcessed` callsite), full-transcript agent memory. Do not weaken any for automation rate or convenience.
3. **Ledger is referenced, not rewritten:** SPEC §0.1 is the SSOT; do not duplicate or re-decide the ledger. Bake the five 2026-06-25 operator decisions only where they apply (all five land in **0c**: duplicate-reason enum + note; plan-snapshot path; OpenAI-compatible provider fields; registry per-field diff with append-only protected fields; live re-test order M1 → M5 → M8 pointing at the live suite).
4. **Per-slice gate:** run `make test`; raise `scripts/test-floor-gate.sh` `FLOOR=` to the measured integrated green **only by net-new tests**, each with a dated provenance comment (order-inversion rule; never lower without a recorded reason). The validation plan's projected per-slice totals are guidance only — re-measure and set the floor to actual. Add `ToolAnnotationCatalog` entries for any new MCP tool (audit hard-fails otherwise) and `SettingsUIValidationHarness` entries for new Memory controls.
5. **No new Settings section** — all UI lands on existing Memory tabs; match `BridgeTokens` and existing Memory tab patterns. Memory Hub files live only under `~/Library/Application Support/TheBridge/memory-hub/` (`activity.jsonl`, `registry-cache/<entity>.json`, `plan-snapshots/<memoId>.json`).
6. **Install ladder for operator smoke:** `make test` → `make app` → `make install-copy` (or `make install` if signing available) → `open -a "The Bridge"`. After relaunch, confirm `voice_memo_get`, `voice_memo_commit`, `memory_forget` (and any new tool) appear in `tools_list` (MCP stays on the pre-restart server until relaunch).
7. **Live re-test order (Decision 5):** after 0a (and ideally the full slice set) lands, run **M1 → M5 → M8** per `docs/operator/MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md` — simple trust path (M1) before registry-heavy (M5/M8). Single-memo mode only; never batch the backlog. Live evidence = activity-log receipt references + a PASS/PARTIAL/FAIL markdown grade table. **Any forced duplicate commit performed during the live suite uses force reason `live_test`** so that audit/cleanup can filter test-originated receipts from genuine operator forces in the shared `activity.jsonl`.
8. **No regression:** `job_run` on paused jobs still works (`allowPaused: true`); stdio / legacy SSE / `/health` / connector paths byte-for-byte unchanged.

### Doc reconciliation (fold in during this packet's lifecycle; PKT-MEM-109 owns the full §0 refresh)

- (a) Decision ledger is triplicated (SPEC §0.1, SPEC §8, MANIFEST ~line 55) → **SPEC §0.1 is SSOT**; §8 and the manifest REFERENCE it.
- (b) SPEC §0 "Test floor baseline **2270**" is stale → **2303**.
- (c) PKT-MEM-112/113 predate the 06-25 reflow → note that **Phase 0 (PKT-MEM-106) precedes A–E and supersedes their B/D/E UI items** (registry picker, activity strip, cloud-key UI, Agent forget/pin).
- (d) Version drift (spec "v3.9.x" vs suite "v3.8.2+/v3.8.3") → align on the shipped baseline (v3.8.2 installed; next published increment v3.8.3).

---

## Dependencies

| Upstream | Provides | Blocks |
|---|---|---|
| PKT-MEM-105 ✓ | Trust base (append-only, election, processed gate, full transcript, `memory_forget`) | All slices |
| PKT-MEM-110a ✓ | `voice_memo_get` / `voice_memo_commit` (commit already accepts `intentKind`/`entityKey`/`entityHint`/`rowId`/`fields`) | 0a `rowId` threading, 0b per-intent commit, 0c preview |
| PKT-MEM-111 U1+U6 ✓ | Process + Processing tabs | 0b cockpit refactor, 0c Processing keys |
| Registry W2/W3 (`registry_list`, `registry_update`) ✓ | Live picker rows + append-only writes | 0b picker/cache, 0c registry diff |
| **Slice 0a** | Deterministic `intentId`, election, processed gate, distinct lanes, `rowId`-param threading | **Live M5/M8**; 0b grouping/mirror/picker-rowId; 0c snapshots/guardrails |
| **Slice 0b** | Cockpit, activity log, registry cache, AX IDs, picker `rowId` | 0c diff badges on snapshots, activity-recorded guardrails |

**Downstream (resume after Phase 0 merges):** PKT-MEM-107 (datetime/calendar), PKT-MEM-109 (spec v1.1 refresh — owns §0 truth-sync + floor + tool count), PKT-MEM-110b residual cloud curator, PKT-MEM-111b residual polish. (Phase 0 supersedes the B/D/E UI items those packets carried.)

---

## Verification gates

Per SPEC §9 (global), every slice must:

1. `make test` green; raise `FLOOR=` only by net-new tests with a dated provenance comment.
2. `ToolAnnotationCatalog` updated for any new MCP tool (tier audit green).
3. Stale `voice_memo_process` (and any other) tool description updated if behavior changed.
4. `SettingsUIValidationHarness` entries present for new Memory section controls (AX-ID-first).
5. No regression: paused-job `job_run` (`allowPaused: true`) still works; trust invariants hold under Slice-0a tests.

**Phase-0 closeout gate (after 0c):**

- [ ] All three slices' DoD checklists green; final `FLOOR=` raised by net-new tests with dated provenance (Phase 0 final floor recorded — the measured count, not a pre-baked target).
- [ ] Trust invariants verified by tests (election, processed gate across all callsites, distinct same-kind lanes, append-only protected fields, full-transcript agent memory).
- [ ] Cockpit renders three zones with stable AX IDs; per-intent commit + primary override + registry picker functional.
- [ ] `activity.jsonl`, `registry-cache/<entity>.json`, and `plan-snapshots/<memoId>.json` persist at their locked Memory Hub paths with correct retention.
- [ ] Live re-test **M1 → M5 → M8** on `make install`-built `The Bridge.app` produces a PASS/PARTIAL/FAIL grade table with activity-receipt references (per the live suite); session cleanup performed (reminders_delete, registry revert, `memory_forget`, `voice_memo_review_dismiss`, curator mode → Auto). Forced live duplicate commits used reason `live_test`.
- [ ] Manifest Wave-3 Phase-0 row updated to DONE with verify-back; SPEC §0/§8 + manifest reconciled to reference §0.1 and floor 2303 (full §0 refresh deferred to PKT-MEM-109).
