# Memory Hub — Validated Execution Spec (v1.1 draft)

**Status:** Contract reflow locked 2026-06-25; Phase 0 (PKT-MEM-106) packaged for dispatch
**Project:** The Bridge v3.8.3 vertical — Voice capture → triage → three memory surfaces  
**SSOT for:** executor sub-agents · Settings UX · transcription ladder · review dispositions

---

## 0.1 Decision ledger (2026-06-25)

Locked by operator + Codex choice-to-contract review after code/UI/UX pass.

| Decision | Locked resolution | Why | Execution impact |
|---|---|---|---|
| Primary election | **Lane priority first**, then confidence: `reminder` > `agent_memory` > `registry_update` > `memory_keep` | Predictable live behavior and matches multi-intent suite expectations. | Update `VoiceMemoIntentElection` and tests; live grades use lane priority as contract. |
| Processed gate | A memo is marked processed only after a successful execute/commit or explicit handled disposition **and** when **no pending review remains for that memo**. | Preserves PKT-MEM-105 trust invariant; prevents hidden unresolved lanes or preview-only processing. | `voice_memo_process`, `voice_memo_commit`, and `voice_memo_review_resolve` must check sibling pending entries before writing `processed.json`; dry-run, preview, transcription, and dismiss alone never mark processed. |
| Primary surface | **Process is the default triage cockpit**. Inbox is the exception queue. | Operator needs preview -> choose -> commit in one place. | Process tab owns multi-intent preview, primary selection, per-intent commit, and activity strip. |
| Registry targeting | Registry intents require an **inline entity/row picker** when multiple registry lanes or ambiguous row hints exist. | Prevents wrong-row writes in M5/M8 and keeps append-only trust intact. | Add picker to Process preview and use selected entity/row in `voice_memo_commit`. |
| Wave 3 sequencing | **Trust + Process contract first**, then datetime/cloud polish. | Known M5/M8 blockers sit in review identity, processed gate, election, and commit UX. | Reflow Wave 3 before PKT-MEM-107 if needed; do not run live minimum until these blockers are resolved or explicitly accepted as REVIEW. |
| Process preview layout | **Split cockpit**: memo list, intent table, detail/commit inspector. | Best repeated-triage ergonomics and clearest M5/M8 comparison. | Refactor `MemoryProcessTab` from two-pane cards to a three-zone cockpit. |
| Activity strip source | **Local Memory Hub activity log**. | Durable, queryable receipts for preview, commit, and live-test evidence. | Add small local persistence surface rather than scraping audit log or losing receipts on relaunch. |
| Registry picker data | **Live `registry_list` with cached fallback**. | Current targets matter for contacts/projects/sessions, but UI must survive offline/error states. | Picker loads live rows, stores last-good rows, and labels stale/error fallback. |
| Agent memory controls | **Soft forget + pin only**. | Matches trust posture and avoids editing/overwriting agent memory content. | Agent tab adds forget via `memory_forget` and pin toggle; no text edit or hard delete. |
| Agent memory transcript | `agent_memory` commits store the **full transcript**, not a summary or first sentence. | Preserves PKT-MEM-105 trust invariant and makes later recall faithful to the captured memo. | Commit path and regression tests must assert transcript-length parity with the source memo; activity may reference only hashes/excerpts. |
| Notion tab scope | **Open + refresh + backfill only**. | Gives operator useful maintenance without turning Memory into a full Notion editor. | Notion tab gets refresh and backfill actions; no full row CRUD. |
| Preview latency | **Fast preview first**. | Operator needs immediate confidence that the memo is understood and the app is working. | Render heuristic plan first, then optionally enhance with local auto intelligence or operator-triggered cloud intelligence and provenance state. |
| Review data model | **Flat per-intent entries with stable `intentId` + `memoId` grouping**. | Smallest safe model change that preserves distinct lanes and grouped Process UX. | Extend review entries/receipts to include stable intent identity and target metadata. |
| Unresolved lane home | **Stay visible in Process and mirrored to Inbox**. | Keeps Process as the action source while preserving exception visibility. | Pending lanes remain grouped under the memo and also appear in Inbox filters. |
| Backfill safety | **Dry-run preview, then selected apply**. | Avoids accidental Notion churn and respects bulk-write caution. | Backfill UI shows planned rows/actions before selected execution. |
| Live test gate | **Fix Phase 0 blockers before M5/M8 live**. | Avoids noisy false failures from known trust/UX gaps. | Run M1 if useful; defer registry-heavy M5/M8 until Phase 0 blockers are fixed or explicitly accepted as REVIEW evidence. |
| Phase 0 live re-test order | **M1 → M5 → M8** (simple trust path before registry-heavy cases). | Validates the deterministic-ID / processed-gate / election core (M1) before the registry-picker-heavy multi-lane cases (M5, then M8). | Live closeout runs M1 first, then M5, then M8; M5/M8 stay deferred until M1 passes clean and Phase 0 blockers are fixed. |
| Activity log storage | **Append-only JSONL with bounded retention**. | Maximizes inspectability and trust while keeping implementation small. | Store preview/commit/test receipts in a capped JSONL file; do not use UserDefaults for evidence. |
| Enhancement provider policy | **Heuristic first, local auto, cloud manual**. | Keeps preview responsive and privacy-safe while allowing higher-quality operator-triggered enhancement. | Local Ollama may enhance automatically; cloud enhancement requires explicit operator action. |
| Commit guardrails | **Exactly one elected primary lane may auto-execute, and only above threshold; ambiguous/low confidence requires operator commit**. | Preserves trust while keeping clean primary lanes fast. | Confidence/ambiguity gates determine whether the elected primary auto-executes; all other executable lanes queue review. |
| Duplicate write policy | **Block duplicates by default; explicit force with reason**. | Protects Notion rows and reminders from repeat commits. | Force writes require operator-supplied reason and are recorded in activity. |
| M1 live timing | **Defer all live pass/fail tests until Phase 0 is fixed**. | Produces clean evidence and avoids known false failures from review/processed bugs. | M1/M5/M8 pass-fail waits for Phase 0; earlier runs are review-only by explicit operator choice. |
| Activity retention | **500 events or 30 days, whichever comes first**. | Enough live-test/debug evidence without unbounded local history. | JSONL retention prunes by count and age. |
| Confidence thresholds | **Lane-specific thresholds with global floor**. | Different write lanes carry different risk. | Threshold policy gates auto-execute per lane while keeping a minimum global confidence. |
| Registry cache freshness | **Last-good cache with stale badge after 24h**. | Keeps picker usable offline while warning about stale targets. | Cached registry rows remain selectable but visibly stale after 24h. |
| Phase 0 packaging | **One Phase 0 integration packet**. | Trust/UI changes are coupled and should be reviewed as one coherent unblock. | Execute Phase 0 as one integration packet/PR slice before resuming A-E. |
| Live evidence format | **Activity log receipt + markdown grade table**. | Combines machine-verifiable receipts with operator-readable review. | Live run closeout must include JSONL receipt references and a PASS/PARTIAL/FAIL markdown table. |
| Threshold values | **Calibrated defaults:** global `0.80`; reminder `0.90`; registry `0.86`; agent `0.86`; memory_keep `0.90`. | Gives implementation concrete gates without pretending all lanes carry equal risk. | Store thresholds centrally and test each lane gate. |
| Stable intent ID | **Deterministic content hash** from `memoId + kind + entityKey + entityHint + destination fields + normalized title`. | Keeps review rows stable across preview/enhancement reruns while preserving same-kind lanes. | Use as the per-intent identity for Process, Inbox, review store, and activity receipts. |
| Activity event schema | **Structured receipt envelope**. | Receipts must be machine-verifiable, compact, and readable during live grading. | Each JSONL event carries `eventId`, timestamp, `memoId`, `intentId`, phase, action, status, provenance, actor, detail, `receiptHash`, and `schemaVersion`. |
| Enhancement diff UX | **Versioned plan snapshots with diff badges**. | Operator must see what changed before committing an enhanced plan. | Store preview versions and badge added/changed/removed intent fields in Process. |
| Duplicate detection key | **Memo + intent + destination key**. | Prevents repeat writes without blocking legitimate separate lanes from the same memo. | Idempotency keys combine `memoId`, `intentId`, and destination-specific target/field/value identity. |
| Cloud key UX | **Keychain-backed provider status + save/delete in Processing**. | Supports manual cloud enhancement without broad provider admin scope. | Processing tab shows provider configured/missing state and supports secure key save/delete. |
| Enhancement timeouts | **Immediate heuristic; local 8s soft timeout; cloud 20s manual timeout**. | Keeps preview responsive while bounding provider stalls. | Timeout falls back to the latest valid heuristic/local plan and records status in activity. |
| Activity privacy | **No full transcript in activity log; hashes + short excerpts only**. | Evidence should not duplicate sensitive transcript storage. | Activity detail may include transcript hash, memo reference, and short excerpt; full transcript stays in transcript storage. |
| Registry cache storage | **Separate JSON cache per entity with TTL metadata**. | Simple, inspectable, and avoids overloading activity events. | Store last-good registry rows per entity with fetchedAt, ttl, stale state, and source error. |
| Phase 0 test shape | **Focused net-new tests: election, review identity, processed gate, rowId commit, activity receipts, AX IDs**. | Tests map directly to trust blockers and raise the floor honestly. | Add targeted tests and raise `test-floor` only by net-new coverage. |
| Legacy review migration | **Derive `intentId` on read; rewrite only when touched**. | Preserves existing pending review entries without launch-time churn. | Add compatibility shim in review loading/resolution; avoid one-time destructive migration. |
| Activity/cache file location | **`Application Support/TheBridge/memory-hub/`**. | Keeps Memory Hub receipts and caches scoped, inspectable, and separate from voice memo transcripts. | Store `activity.jsonl` and `registry-cache/<entity>.json` under the Memory Hub support directory. |
| Registry update write mode | **Append-only for protected text fields; per-field diff with individually selectable non-protected updates**. | Preserves PKT-MEM-105 trust invariants while allowing safe, granular metadata cleanup. | `brief`, `objective`, `summary`, and `description` never overwrite (append-only); non-protected updates show a per-field before/after diff and the operator selects which fields to apply. Protected fields are never offered as selectable overwrites. |
| Notification behavior | **No notification while Process is active; background notifications only for queued review/errors**. | Keeps live triage quiet while preserving recovery when the operator is elsewhere. | Suppress active Process notifications and deep-link background alerts to the relevant Memory surface/filter. |
| Cloud provider scope | **Generic provider slots; enable one OpenAI-compatible manual enhancement path first**. OpenAI-compatible provider fields = **API key + base URL + model name + enabled toggle**. | Leaves room for later providers without testing multiple cloud clients in Phase 0; explicit fields make any OpenAI-compatible endpoint configurable. | Implement provider abstraction with the four-field config (key/baseURL/model/enabled); defer Anthropic/native multi-provider behavior. Keys live in Keychain (see Cloud key UX row); base URL/model/enabled are non-secret config. |
| Intent ID format | **`intent_v1_` + truncated SHA-256 of canonical fields**. | Stable, compact, and versionable across dry-run/preview/enhancement. | Use one canonical generator for processor, review store, Process UI, activity receipts, and tests. |
| Legacy fallback hash | **Use available legacy fields plus `createdAt`/reason fallback; mark `legacyDerived`**. | Maintains deterministic identity without launch-time migration. | Legacy-derived intents are visible in receipts/debug detail and remain rewrite-on-touch only. |
| Enhancement authority | **Enhancement may add/change/demote, but not silently remove heuristic intents**. | Prevents lost lanes while still allowing better plans. | Removed-by-enhancement intents stay visible as demoted/superseded until operator commits or dismisses. |
| Process active detection | **Suppress notifications only when app is active and Memory/Process is selected**. | Precise suppression without hiding background errors. | Notification gate checks application activation plus selected Memory Process anchor. |
| AX identifier scheme | **Stable zone IDs plus row/button IDs suffixed with `memoId`/`intentId`**. | Enables robust workflow tests without text brittleness. | Add AX IDs for cockpit zones, memo rows, intent rows, picker rows, and commit/override buttons. |
| Hash length | **20 hex chars after `intent_v1_`**. | Compact, readable, and enough collision margin for local memo scale. | Intent IDs look like `intent_v1_<20hex>`. |
| Canonicalization | **Canonical JSON with sorted keys, trimmed strings, normalized whitespace, lowercase enum fields**. | Deterministic and testable across dry-runs and enhancement passes. | Hash inputs are generated from canonical JSON, not ad hoc joined strings. |
| Snapshot retention | **Keep heuristic, latest enhanced, and committed snapshot per memo**. | Preserves useful diff evidence without unbounded local clutter. | Snapshot storage prunes intermediate enhanced drafts after latest/commit is retained. |
| Snapshot storage | **Per-memo JSON at `memory-hub/plan-snapshots/<memoId>.json`**. | Inspectable and prunable on disk, parallel to the registry-cache layout. | Plan/enhancement snapshots persist as one JSON file per memo under the Memory Hub support directory; pruning follows the snapshot-retention rule (heuristic + latest enhanced + committed). |
| Receipt hash display | **Store full SHA-256, display first 12 chars**. | Maintains audit strength while keeping UI/live evidence readable. | Activity events store full `receiptHash`; UI and markdown tables may reference the first 12 chars. |
| Duplicate force reason | **Required reason picker (fixed enum) + optional free-text note**. Enum = `{new_context, correction, operator_confirmed, live_test}`. | Produces structured, filterable audit evidence without forcing free text every time. | Force duplicate flow cannot commit until one of the four enum values is selected; the free-text note is optional and stored in the activity receipt alongside the enum. |
| Cloud failure semantics | **Record activity and keep the latest valid heuristic/local plan; no review item queued**. | Cloud enhancement is optional quality polish, not a trust gate. | Cloud failure/timeout never blocks commit of the latest valid plan and does not add Inbox noise. |
| Provider defaults | **Default base URL only; require operator-entered model name**. | Avoids stale hardcoded model choices while keeping setup ergonomic. | OpenAI-compatible provider defaults base URL to `https://api.openai.com/v1`; model is blank until configured. |
| Registry diff failure mode | **Validate all selected fields before write; any failure leaves intent uncommitted and review-visible**. | Prevents partial registry updates and preserves cleanup clarity. | Per-field diff apply is all-selected-or-none after validation; no best-effort partial writes. |
| Snapshot pruning trigger | **Prune on snapshot write plus launch sweep**. | Keeps local state bounded even after crashes or interrupted sessions. | Snapshot store prunes during writes and on app launch/wake sweep. |
| Live evidence artifact | **`docs/operator/live-evidence/PKT-MEM-113-M1-M5-M8.md`**. | Gives live grades a durable, reviewable home outside transient chat. | M1 -> M5 -> M8 closeout writes/updates one markdown grade file with receipt refs. |
| Provider config storage | **Non-secret provider config in `memory-hub/providers.json`; API keys in Keychain**. | Keeps provider state inspectable and scoped with other Memory Hub files while protecting secrets. | Store base URL, model name, enabled flag, and provider id in JSON; never persist API keys outside Keychain. |
| Provider validation timing | **Validate syntax on save; validate network/model only when manual cloud enhance runs**. | Avoids surprise external calls while still catching malformed local config early. | Save rejects malformed URL/empty required local fields; network/model validation occurs only during explicit cloud enhancement. |
| Registry diff display | **Human-readable old/new summary with expandable raw JSON**. | Operator gets quick review plus debuggable detail. | Diff UI shows readable field summaries by default and raw before/after JSON on expansion. |
| Activity corruption handling | **Skip corrupt JSONL lines, record a repair activity, preserve original file**. | Resilient and non-destructive evidence handling. | Activity loader ignores malformed lines, appends a repair event when possible, and never rewrites away the original corrupt line automatically. |
| Live evidence template | **One table row per case with case, build, memo id, grade, receipt refs, cleanup status, notes**. | Durable merge-gate evidence stays reviewable and checklist-shaped. | `PKT-MEM-113-M1-M5-M8.md` uses a fixed markdown table with those columns. |

---

## 0. Validation summary (assumptions tested)

| Assumption | Verdict | Evidence |
|---|---|---|
| "Transcription didn't work" on 20260613 memo | **FALSE (UX bug)** | Apple `tsrp` embedded in `.m4a`; Parakeet wrote 3825-byte `.txt` sidecar. Failure was **routing → review**, not ASR. |
| Apple transcripts available on disk | **TRUE (undocumented API)** | `tsrp` atom JSON in `moov/trak/udta/tsrp`; no separate file; `CloudRecordings.db` has metadata not transcript text. |
| Bridge already uses Apple transcripts | **FALSE** | `VoiceMemoDiscovery.loadTranscriptSidecar` reads **only** adjacent `.txt`. `hasTranscript` in `voice_memo_list` ignores Apple. |
| Review belongs in Advanced | **FALSE (product)** | `AdvancedSection.voiceMemosReviewCard` — operator-confirmed wrong IA. |
| Data Sources should absorb Memory | **PARTIAL** | Registry config stays in **Data Sources**. Capture inbox + agent memory + Notion preview belong in **Memory** (new section). |
| `memory_remember` has UI | **FALSE** | `MemoryStore` at `~/.config/notion-bridge/memory.sqlite` — MCP only (`docs/operator/v3.7.7-memory-design-questions.md`). |
| Review has dispositions beyond dismiss | **FALSE** | Only `voice_memo_review_dismiss`; no resolve-with-action, no retry-routing tool. |
| Review entries expire | **FALSE** | `VoiceMemoReviewStore` — pending forever until dismiss. |
| Processed = transcribed | **FALSE** | `VoiceMemoProcessedStore` marks only after an executed/handled memo has **no pending review entries for that memo**. |
| Tool docs match Wave 2 | **FALSE (stale)** | `voice_memo_process` metadata still says "transcript must exist as .txt sidecar in Wave 1". |
| Test floor baseline | **2303** | `scripts/test-floor-gate.sh` FLOOR=2303 (PKT-MEM-105 shipped baseline); must raise only with net-new tests. |

---

## 1. Product goal (market framing)

**Operator promise:** "I speak → Bridge captures → I triage once → durable memory lands where it belongs (Notion, agent, reminders, registry) without babysitting Advanced settings."

**Success metrics (ship gate):**
- Median voice memo: **zero Advanced-tab visits** for triage
- Transcription: **≥95%** of iCloud memos get text without manual sidecar (Apple + Parakeet ladder)
- Process cockpit: **<30s** to preview, choose a primary lane, and commit or queue review
- Review inbox: **<30s** to disposition exceptions (Memory Keep / Dismiss / Retry route)
- No duplicate Notion Memory rows on re-run (idempotency preserved)

---

## 2. Information architecture (LOCKED)

### New Settings section: **Memory** (`SettingsSection.memory`)

| Tab | Content | Data source |
|---|---|---|
| **Process** (default) | Split cockpit: unprocessed memo list, intent table, detail/commit inspector, activity strip | `voice_memo_list`, `voice_memo_get`, `voice_memo_commit`, local Memory Hub activity log |
| **Inbox** | Review queue exceptions + transcript preview + dispositions | `~/Library/Application Support/The Bridge/voice-memos/review.json` + sidecars |
| **Notion** | Recent Memory registry rows, open in Notion, refresh, and backfill | `registry_list entity=memory` |
| **Agent** | SQLite agent memories (scope/type filters, soft forget, pin toggle) | `~/.config/notion-bridge/memory.sqlite` via `MemoryStore` |
| **Processing** | Curator mode, transcription ladder toggles, cloud key status | UserDefaults + Keychain status |

**Data Sources** (`SettingsSection.datasources`): **unchanged scope** — entity → Notion DS → property map, introspect, cache TTL. Add cross-link chip: "Memory entity → open Memory pane".

**Advanced:** Local Models (Parakeet/Gemma) **stays** — infrastructure, not content. **Remove** `voiceMemosReviewCard`.

**Sidebar order (after Jobs):** Commands · Skills · Jobs · Tools · Security · Connection · **Memory** · Data Sources · Advanced

### MCP / deep-link

- `bridge_settings_navigate(section: "Memory", anchor: "process"|"inbox"|"notion"|"agent"|"processing")`
- Legacy alias: `voice-memos` → Memory/Inbox (deprecate Advanced anchor)

### Process cockpit contract (LOCKED)

Process is the default operator flow for live voice capture:

1. Select one unprocessed memo.
2. Load transcript + parsed intent plan.
3. Show every detected intent with kind, confidence, entity, row hint, destination field, and execution status.
4. Elect exactly one primary lane by lane priority first, then confidence.
5. Allow the operator to override the primary lane before any write.
6. Commit one approved intent at a time via `voice_memo_commit`.
7. Auto-execute at most one lane per memo: the elected primary only, and only when commit guardrails pass.
8. Queue every non-primary executable lane as a distinct review item with reason `secondary intent suppressed`.
9. Mark the memo processed only after a successful execute/commit or explicit handled disposition and no pending review entry remains for that memo.
10. Keep unresolved lanes visible in Process and mirrored to Inbox until resolved, dismissed, or marked handled.
11. Operate on the selected memo only; Phase 0 and the live suite must never call `voice_memo_process mode:batch` or batch-process the existing memo backlog.

Registry intent rows must remain distinct even when they share `intentKind == registry_update`; review identity must include enough target information to preserve session/project/contact lanes separately.

### Process layout contract (LOCKED)

Use a three-zone split cockpit:

| Zone | Role | Required behavior |
|---|---|---|
| Memo list | Select the working memo | Shows transcript source, processed/review state, and latest activity. |
| Intent table | Compare lanes | Shows primary marker, kind, confidence, entity, row hint, destination field, status, and warning state. |
| Detail/commit inspector | Approve one lane | Shows transcript/detail, registry entity/row picker when needed, field preview, primary override, dry-run, and commit. |

The activity strip is backed by a local Memory Hub activity log, not transient view state. It should show recent preview/commit receipts and live-test evidence across relaunch. Storage is append-only JSONL with bounded retention: retain the newest 500 events or 30 days, whichever is smaller. File location: `~/Library/Application Support/TheBridge/memory-hub/activity.jsonl`.

Activity corruption handling is non-destructive: malformed JSONL lines are skipped during load, the original file is preserved, and a repair activity is appended when possible with the skipped line count and first error offset.

Each activity event uses a structured receipt envelope:

- `eventId`, timestamp, `schemaVersion`
- `memoId`, optional `intentId`
- `phase` (`transcribe`, `understand`, `plan`, `execute`, `review`, `test`)
- `action`, `status`, `provenance`, `actor`
- `detail` object with lane-specific payloads; do not store full transcripts in activity events
- Transcript evidence is limited to a transcript hash, memo reference, and short excerpt when useful for live grading
- `receiptHash` over canonical event fields for evidence references; store the full SHA-256 and display/reference the first 12 characters in UI and live-test markdown tables

Registry picker data comes from live `registry_list` with a last-good cached fallback. Cache storage is one JSON file per entity at `~/Library/Application Support/TheBridge/memory-hub/registry-cache/<entity>.json` with TTL metadata (`fetchedAt`, `ttl`, stale state, and source error). The UI must label fallback rows stale after 24 hours.

### Preview latency contract (LOCKED)

Preview is progressive:

1. Fast heuristic preview appears first with provenance `heuristic`.
2. Local Ollama may auto-enhance summary, confidence, or fields after the first render.
3. Cloud enhancement is manual only: the operator must explicitly choose it from the UI.
4. The UI labels provenance and stale/enhancing states clearly.
5. Operator can commit only the currently displayed approved intent; if enhancement changes an intent, the changed lane returns to uncommitted review state.
6. Preview/enhancement results are stored as versioned plan snapshots in a per-memo JSON file at `~/Library/Application Support/TheBridge/memory-hub/plan-snapshots/<memoId>.json` (inspectable and prunable); the UI badges added, changed, or removed intent fields before commit.
7. Timeout policy: heuristic renders immediately; local enhancement gets an 8s soft timeout; manual cloud enhancement gets a 20s timeout. Timeouts keep the latest valid plan and record timeout status in activity.
8. Enhancement may add new intents, change fields, or demote/supersede heuristic intents, but it may not silently remove a heuristic intent. Any removal candidate remains visible as demoted/superseded until the operator commits, dismisses, or marks handled.
9. Snapshot retention keeps the heuristic snapshot, latest enhanced snapshot, and committed snapshot per memo in `plan-snapshots/<memoId>.json`. Intermediate enhanced snapshots may be pruned from that file after a newer enhanced or committed snapshot exists.
10. Cloud enhancement failures record an activity event, keep the latest valid heuristic/local plan, and do not queue a review item.
11. Snapshot pruning runs on each snapshot write and during launch/wake sweep.

### Processing cloud key contract (LOCKED)

- Processing tab shows provider configured/missing status for supported cloud enhancement providers.
- Provider keys are stored in Keychain only.
- UI supports save/update and delete for each provider key.
- Phase 0 uses generic provider slots but only enables an OpenAI-compatible manual enhancement path. The OpenAI-compatible provider exposes four fields: **API key** (Keychain-stored), **base URL**, **model name**, and an **enabled** toggle. Base URL, model name, and the toggle are non-secret config; only the API key is held in Keychain.
- Provider defaults: base URL defaults to `https://api.openai.com/v1`; model name has no default and must be operator-entered before cloud enhancement can run.
- Non-secret provider config lives at `~/Library/Application Support/TheBridge/memory-hub/providers.json`; API keys live only in Keychain.
- Validation timing: save validates local syntax only (URL shape, required model/enabled fields); network/model validation happens only when the operator manually runs cloud enhancement.
- No full provider administration, billing, model catalog, or usage dashboard in Phase 0.

### Commit guardrails (LOCKED)

- Exactly one elected primary lane may auto-execute per memo, and only when confidence passes the lane-specific threshold, the global floor, and registry target resolution is unambiguous.
- Default thresholds: global floor `0.80`; `reminder` `0.90`; `registry_update` `0.86`; `agent_memory` `0.86`; `memory_keep` `0.90`.
- Low-confidence, ambiguous, duplicate, stale-fallback, or non-primary executable lanes require operator commit or review resolution.
- Duplicate writes are blocked by default across reminders, registry updates, memory_keep, and agent_memory.
- Duplicate detection key: `memoId + intentId + destination key`, where destination key is the target system plus the minimum stable target/field/value identity.
- Force duplicate writes require a selected reason from a fixed enum `{new_context, correction, operator_confirmed, live_test}` and are recorded in the activity log; an optional free-text note may accompany the enum.

### Accessibility identifier contract (LOCKED)

- Cockpit zone IDs: `memoryProcess.memoList`, `memoryProcess.intentTable`, `memoryProcess.detailInspector`, `memoryProcess.activityStrip`.
- Row IDs use stable suffixes: `memoryProcess.memoRow.<memoId>` and `memoryProcess.intentRow.<intentId>`.
- Command IDs use the target identity when applicable: `memoryProcess.commit.<intentId>`, `memoryProcess.primaryOverride.<intentId>`, `memoryProcess.registryRow.<entity>.<rowId>`.
- Tests should prefer AX identifiers over display text for Process workflow proof.

### Registry write mode (LOCKED)

- Protected registry text fields are append-only: `brief`, `objective`, `summary`, `description`.
- Non-protected property updates may be committed only from an explicit per-field before/after diff preview; the operator selects which non-protected fields to apply. Protected fields (`brief`, `objective`, `summary`, `description`) are never offered as selectable overwrites.
- Diff display shows a human-readable old/new summary by default and expandable raw before/after JSON for debugging.
- All selected non-protected fields validate before any write. If validation fails, no selected field is written; the intent stays uncommitted and visible in Process/Inbox.
- Ambiguous field mappings, stale registry cache targets, or missing selected rows force manual commit.
- No Phase 0 path may silently overwrite a protected registry field.

---

## 3. Transcription ladder (LOCKED)

Priority order in `VoiceMemoDiscovery.resolveTranscript(for:)`:

```
1. Bridge sidecar (.txt) — canonical cache if non-empty
2. Apple tsrp atom — extract, write sidecar + transcript.meta.json {source:"apple", extractedAt, charCount}
3. Parakeet (FluidAudio) — only if 1–2 fail/empty AND toggle ON; write sidecar {source:"parakeet"}
4. nil → review reason "no transcript" (distinct from "unclassified")
```

**Settings toggles** (Local Models or Memory → Inbox footer):
- `Prefer Apple transcript` — default **ON**
- `Parakeet fallback` — default **ON**
- `Re-transcribe` — per-memo action only (force Parakeet, overwrite sidecar with `{source:"parakeet", forced:true}`)

**Quality heuristic (Parakeet fallback even when Apple exists):** Only if Apple text length `< max(80, 0.05 × audioDurationSec × 15)` chars — tunable constant in tests.

**Do NOT rely on Apple alone:** Apple breaks, truncates, mis-hears (`outposting` vs `not posting` on live memo). Parakeet remains override path.

**RAM discipline (M1 16GB):** Transcribe (Apple sync extract OR Parakeet) **then** route (Gemma) — never concurrent.

---

## 4. Review UX & dispositions (LOCKED)

### Inbox row fields

- Title · recorded date · **transcript source badge** (Apple | Parakeet | Sidecar | Missing)
- **Status:** Transcribed · Routing failed · Low confidence · No transcript
- Confidence · suggested lane · reason
- Expandable full transcript · Reveal in Finder

### Dispositions

| Action | Backend | Marks processed? |
|---|---|---|
| **File as Memory** | `registry_create` + `notion_blocks_append` transcript | After successful write, only if no sibling pending review remains |
| **Add reminder** | `reminders_create` | After successful write, only if no sibling pending review remains |
| **Agent should know** | `memory_remember` with the full transcript | After successful full-transcript write, only if no sibling pending review remains |
| **Registry update…** | picker → append-only `registry_update` | After successful append/diff write, only if no sibling pending review remains |
| **Retry routing** | re-run Ollama/heuristics only (no re-transcribe) | No; any later processed mark follows the successful action + no-sibling rule |
| **Dismiss** | `voice_memo_review_dismiss` | No |
| **Mark handled (no write)** | `voice_memo_review_resolve`; explicit handled disposition | Conditional: only when no sibling pending review remains |

New MCP tools (Wave 2): `voice_memo_review_resolve` (action + fields), optional `voice_memo_transcript_refresh` (force ladder step).

### Review data model (LOCKED)

Use a flat review-entry model with stable per-intent identity:

- Each intent receives stable `intentId`, `memoId`, `kind`, `entityKey`, `entityHint`, optional `rowId`, destination fields, status, reason, provenance, and timestamps.
- `intentId` format is `intent_v1_` plus the first 20 hex characters of a SHA-256 over canonical fields.
- Canonical fields are represented as canonical JSON: sorted keys, trimmed strings, normalized whitespace, lowercase enum fields.
- Canonical JSON includes `memoId`, `kind`, `entityKey`, `entityHint`, destination fields, and normalized title.
- Legacy review entries without `intentId` derive it on read using available legacy fields plus `createdAt` and/or reason fallback when canonical fields are incomplete; mark these entries/receipts `legacyDerived`.
- Legacy review files are rewritten only when the entry is resolved, dismissed, committed, or otherwise touched.
- Pending entries are grouped by `memoId` in Process.
- The same pending entries are mirrored to Inbox as exception rows.
- De-dupe never collapses two intents solely because they share `memoId` and `intentKind`.

### Agent and Notion tab boundaries (LOCKED)

- Agent tab supports scope/type filters, pin toggle, and soft forget via `memory_forget`.
- Agent tab does **not** support editing memory text or hard deletion.
- Notion tab supports open in Notion, refresh rows, and backfill missing Memory rows when the registry binding is healthy.
- Backfill is always dry-run preview first; operator selects which proposed rows/actions to apply.
- Notion tab does **not** implement full row CRUD; Data Sources remains the schema/config surface.

### TTL (Wave 2)

| State | TTL | Action |
|---|---|---|
| `pending` | 30 days | auto-dismiss + single notify |
| `dismissed` | 7 days | purge from manifest |
| `resolved` | immediate | remove from pending |

Implement via launch/on-wake sweep (reuse `JobsReconciler` pattern), not LaunchAgent job initially.

---

## 5. Notifications (LOCKED)

**Replace** generic "open Advanced" copy.

| Condition | Title | Body | Tap action |
|---|---|---|---|
| Review queued | Voice Memos need triage | "N transcribed, need disposition" | `bridge_settings_navigate(Memory, inbox)` + focus |
| No transcript | Voice Memos skipped | "N missing transcript" | Memory/Inbox filtered view |
| Routing failed | Voice Memos routing failed | detail count | Memory/Inbox |

**Phase 2:** UNNotificationCategory quick actions (File as Memory, Dismiss) — requires app delegate wiring; defer to PKT-MEM-104+.

**Phase 0 notification policy:** no notification is sent while the Memory Process surface is active. Background notifications are limited to queued review entries and routing/transcript errors, and they deep-link to the relevant Memory surface/filter.

---

## 6. Current system state (code map)

| Component | Path |
|---|---|
| Voice discovery | `TheBridge/Modules/VoiceMemo/VoiceMemoDiscovery.swift` |
| Processor | `TheBridge/Modules/VoiceMemo/VoiceMemoProcessor.swift` |
| Review store | `TheBridge/Modules/VoiceMemo/VoiceMemoReviewStore.swift` |
| Notifier | `TheBridge/Modules/VoiceMemo/VoiceMemoNotifier.swift` |
| Parakeet | `TheBridge/Modules/VoiceMemo/VoiceMemoTranscriber.swift` |
| Agent memory | `TheBridge/Modules/MemoryStore.swift`, `MemoryModule.swift` |
| Registry Memory entity | `Modules/Registry/*`, bound in live `registry.json` |
| Settings sections | `UI/SettingsWindow.swift`, `SettingsWindow+Sections.swift` |
| Advanced review card | `UI/Sections/AdvancedSection.swift` (REMOVE) |
| Data Sources | `UI/Sections/DataSourcesSection.swift` (unchanged scope) |
| Settings nav MCP | `Modules/BridgeAutomationModule.swift` |
| AX harness | `Modules/SettingsUIValidationHarness.swift` |

---

## 7. Wave plan & packet dispatch

### Wave 1 (parallel — no cross-deps)

| Packet | Class | Outcome |
|---|---|---|
| **PKT-MEM-101** | Standard | Apple `tsrp` extractor + transcription ladder + tests |
| **PKT-MEM-102** | Standard | `SettingsSection.memory` + Inbox UI P0 + remove Advanced card |

### Wave 2 (sequential after Wave 1)

| Packet | Class | Outcome |
|---|---|---|
| **PKT-MEM-103** | Standard | Review resolve tools + TTL sweep + disposition wiring |
| **PKT-MEM-104** | Standard | Notification/deep-link + Agent/Notion tabs + AX harness |

### Wave 3 (reflowed 2026-06-25) — Phase 0 = PKT-MEM-106

Before datetime/cloud polish, close the trust + Process cockpit blockers found during review.
Phase 0 (packet **PKT-MEM-106**) **precedes** the older A–E phases (PKT-MEM-107/108/109/110b/111b)
and **supersedes** their B/D/E UI items (registry picker, activity strip, cloud-key UI, Agent
forget/pin). The 18 items below are PKT-MEM-106's scope, sliced into 0a (trust+identity core),
0b (Process cockpit + activity), and 0c (preview + guardrails + tabs):

1. Preserve distinct suppressed review lanes, including multiple `registry_update` intents from one memo.
2. Align processed marking across `voice_memo_process`, `voice_memo_commit`, and `voice_memo_review_resolve` so no path writes `processed.json` until a successful execute/commit or explicit handled disposition has occurred and no sibling review remains.
3. Align election implementation and tests to lane-priority-first behavior.
4. Refactor Process into split cockpit with primary override, registry entity/row picker, and per-intent commit.
5. Add local Memory Hub activity log + activity strip so long `voice_memo_get` runs show progress and outcome; events use the structured receipt envelope, exclude full transcripts, and live at `~/Library/Application Support/TheBridge/memory-hub/activity.jsonl`.
6. Add Agent soft forget + pin only.
7. Add Notion open + refresh + backfill only.
8. Make preview progressive: heuristic first, local auto enhancement second, cloud enhancement manual-only, with provenance labels, timeout/failure behavior, versioned diff snapshots, and snapshot retention/pruning for heuristic/latest-enhanced/committed states.
9. Add deterministic `intentId` + `memoId` grouping and Process/Inbox mirroring for unresolved lanes.
10. Store activity as append-only bounded JSONL.
11. Gate commits by concrete lane thresholds, ambiguity, duplicate status, and stale-fallback state.
12. Support explicit duplicate force only with a required picker reason and optional note.
13. Add legacy review compatibility by deriving `intentId` on read and rewriting only touched entries.
14. Use append-only protected registry writes and explicit diff previews for non-protected updates; validate all selected non-protected fields before any write.
15. Suppress notifications only when the app is active and Memory/Process is selected; allow background review/error notifications otherwise.
16. Enable generic cloud provider slots with OpenAI-compatible manual enhancement first; default base URL only and require operator-entered model.
17. Execute Phase 0 as one integration packet so review identity, processed gate, election, cockpit UI, activity, cloud key status/config, notifications, and guardrails are validated together.
18. Add focused net-new tests for election, review identity, 20-hex canonical `intentId`, processed gate, `rowId` commit, full-transcript `agent_memory`, activity receipts/full-hash-plus-display-hash, activity corruption handling, duplicate force reason, cloud failure semantics, provider config storage/defaults/validation timing, registry diff display/validation failure, snapshot pruning, legacy review migration, enhancement demotion/no-silent-removal, precise notification suppression, and AX IDs.

Do not run M1/M5/M8 live tests as pass/fail evidence until Phase 0 (PKT-MEM-106) blockers are fixed. When Phase 0 is green, run the live suite in the locked order **M1 → M5 → M8** (simple trust path before registry-heavy cases): M1 first, and defer M5 then M8 until M1 passes clean. Run one memo per signal in single-memo mode; never batch-process the backlog. Live closeout writes the durable grade artifact at `docs/operator/live-evidence/PKT-MEM-113-M1-M5-M8.md` with one table row per case: case, build, memo id, grade, receipt refs, cleanup status, notes. Earlier operator recordings may be used only as REVIEW evidence if explicitly accepted. Then continue PKT-MEM-107 datetime/calendar, PKT-MEM-108 UI closeout, PKT-MEM-109 spec refresh, PKT-MEM-110b cloud curator, and PKT-MEM-111b Process polish.

---

## 8. Material decisions (pre-resolved)

> **SSOT: see §0.1 Decision ledger (2026-06-25).** All material decisions — IA, transcription,
> election, processed gate, full-transcript agent memory, Process cockpit, activity log,
> preview/enhancement, guardrails, thresholds, intent identity, registry write mode,
> cloud provider, notifications, AX scheme, single-memo live mode, and Phase 0 packaging — are locked there with their rationale and execution impact. Do not
> re-litigate in packets. This section intentionally holds no duplicate table; §0.1 is authoritative.

---

## 9. Verification gates (global)

Every packet must:
1. `make test` green; raise `FLOOR=` only by net-new tests with provenance comment
2. Update `ToolAnnotationCatalog` for new MCP tools
3. Update stale `voice_memo_process` tool description when transcription changes
4. `SettingsUIValidationHarness` entries for Memory section
5. No regression: `job_run` on paused jobs still works (`allowPaused: true`)

---

## 10. Known imperfections owned by this spec

1. **`hasTranscript` lie** — lists false until sidecar exists even when Apple embedded — **PKT-MEM-101 fixes**
2. **Stale MCP tool metadata** — Wave 1 sidecar wording — **PKT-MEM-101**
3. **Review ≠ transcription failure** — conflated in notify copy — **PKT-MEM-102/104**
4. **No resolve path** — dismiss-only — **PKT-MEM-103**
5. **237+ memos without sidecar** — Apple ladder improves future targeted processing without 2min Parakeet each; Phase 0/live-suite execution remains single-memo only — **PKT-MEM-101**
6. **Duplicate Memory rows** — idempotency by memo id; UI should warn on force re-file — **PKT-MEM-103**
7. **Executor packets live in repo** — Notion PACKETS DS sync is operator follow-up, not blocking code execution

---

## Appendix A — Apple tsrp extraction reference

- Atom path: `moov/trak/udta/tsrp` (also byte-scan fallback for `{"attributedString":`)
- Formats: interleaved runs + attributeTable (see uasi/extract-apple-voice-memo-transcript)
- `.qta` containers: may use `moov.meta.ilst` / `com.apple.VoiceMemos.tsrp` — handle in 101 if tests find qta samples

---

## Appendix B — Live operator memo (20260613)

- Path: `~/Library/Group Containers/.../20260613 120059-BC1F09DE.m4a`
- Apple transcript: present (`attributedString` at byte ~2.8MB)
- Parakeet sidecar: 3825 bytes (shorter than Apple)
- Review reason: `parser could not classify` — expected without "keep this" phrasing
