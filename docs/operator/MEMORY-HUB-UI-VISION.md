# Memory Hub UI Vision (PKT-MEM-111)

**Approved:** 2026-06-24
**Reflowed:** 2026-06-25 — Process cockpit contract locked

## Tab model

1. **Process** (default) — unprocessed memo list + 4-step pipeline drawer (Transcribe → Understand → Plan → Execute)
2. **Inbox** — review queue dispositions (existing)
3. **Notion** — registry Memory rows (read)
4. **Agent** — SQLite recall list
5. **Processing** — curator mode + transcription ladder toggles

## Shipped (U1 + U6)

- `MemoryProcessTab` — list, preview via `voice_memo_get`, dry-run / process buttons
- `MemoryProcessingTab` — curator mode picker + ladder toggles
- Deep-link anchors: `process`, `processing`

## Deferred (U2–U5, U7)

- Registry target picker on Process preview
- Agent tab forget/pin buttons
- Notion CRUD/backfill from pane
- Activity strip + notification deep-link to Process tab
- Cloud API key fields in Processing tab

## Process cockpit contract

Process is the default triage surface, not a preview-only page.

- Use a split cockpit: memo list, intent table, detail/commit inspector.
- Show every detected intent with kind, confidence, entity, row hint, destination field, and execution status.
- Elect exactly one primary lane by lane priority first, then confidence: `reminder` > `agent_memory` > `registry_update` > `memory_keep`.
- Allow operator override before any write.
- Commit one approved intent at a time via `voice_memo_commit`.
- Preserve suppressed lanes as distinct review items, including multiple `registry_update` lanes from one memo.
- Show registry entity/row picker inline when there are multiple registry intents or ambiguous row hints; source rows from live `registry_list` with cached fallback and stale badge after 24h.
- Mark a memo processed only when no pending review entry remains for that memo.
- Show activity/latency feedback for long preview/commit runs so the operator can distinguish transcribe, understand, plan, and execute work.
- Back the activity strip with a local Memory Hub activity log, not transient view state. Store activity as append-only JSONL at `~/Library/Application Support/TheBridge/memory-hub/activity.jsonl` with bounded retention: 500 events or 30 days, whichever comes first. Activity rows are structured receipt envelopes with event id, memo/intent ids, phase/action/status/provenance, actor, detail, full SHA-256 receipt hash, and schema version. Display the first 12 receipt-hash characters in UI/live evidence. Do not store full transcripts in activity; use transcript hashes and short excerpts only.
- Render fast heuristic preview first, local auto-enhancement second, and cloud enhancement only after explicit operator action; label provenance and enhancement state. Timeout policy: heuristic immediate, local enhancement 8s soft timeout, manual cloud enhancement 20s timeout.
- Store preview/enhancement results as versioned plan snapshots and badge added, changed, or demoted/superseded intent fields before commit. Retain heuristic, latest enhanced, and committed snapshot per memo. Enhancement may add/change/demote, but may not silently remove heuristic intents.
- Keep unresolved lanes visible in Process and mirrored to Inbox until resolved, dismissed, or marked handled.
- Use deterministic `intentId` + `memoId` grouping so multiple same-kind lanes stay distinct. `intentId` format is `intent_v1_` plus 20 hex chars from SHA-256 over canonical JSON with sorted keys, trimmed strings, normalized whitespace, and lowercase enum fields.
- Legacy review entries without `intentId` derive one on read from available legacy fields plus `createdAt`/reason fallback, mark `legacyDerived`, and are rewritten only when touched.
- Auto-execute only when confidence passes lane-specific thresholds, the global floor, and target resolution is unambiguous; otherwise require operator commit. Defaults: global `0.80`; reminder `0.90`; registry `0.86`; agent `0.86`; memory_keep `0.90`.
- Block duplicate writes by default using `memoId + intentId + destination key`; explicit force requires a selected reason, supports an optional note, and is recorded in activity.
- Registry protected text fields (`brief`, `objective`, `summary`, `description`) are append-only. Non-protected property updates require explicit before/after diff preview before commit.
- Suppress notifications only when the app is active and Memory/Process is selected; background notifications are limited to queued review entries and routing/transcript errors.

## Accessibility identifiers

- Cockpit zones: `memoryProcess.memoList`, `memoryProcess.intentTable`, `memoryProcess.detailInspector`, `memoryProcess.activityStrip`.
- Rows: `memoryProcess.memoRow.<memoId>`, `memoryProcess.intentRow.<intentId>`, `memoryProcess.registryRow.<entity>.<rowId>`.
- Commands: `memoryProcess.commit.<intentId>`, `memoryProcess.primaryOverride.<intentId>`.

## Secondary tab contracts

- Agent tab: scope/type filters, soft forget via `memory_forget`, and pin toggle only. No text editing or hard delete.
- Notion tab: open in Notion, refresh rows, and backfill missing Memory rows only. Backfill is dry-run preview first, then selected apply. No full row CRUD.
- Processing tab: generic cloud provider key slots plus secure save/update/delete for provider keys. Keys are stored in Keychain only; Phase 0 enables OpenAI-compatible manual enhancement first. No provider admin, billing, model catalog, or usage dashboard.
- Registry picker cache: one JSON cache per entity under `~/Library/Application Support/TheBridge/memory-hub/registry-cache/` with TTL metadata and stale/error labels.

## Readiness reflow

Trust + Process cockpit blockers come before datetime/cloud polish:

1. Review identity for multiple same-kind suppressed lanes.
2. Processed gate alignment across process, commit, and review resolve.
3. Lane-priority-first election implementation and tests.
4. Split cockpit layout with primary override, registry picker, and per-intent commit.
5. Append-only bounded JSONL activity log in the Memory Hub support directory, privacy-limited structured receipt envelope, activity strip, and long-running preview status.
6. Agent soft forget + pin.
7. Notion open + refresh + backfill.
8. Progressive preview: heuristic first, local auto, cloud manual, timeout behavior, versioned diff snapshots, snapshot retention, no silent heuristic-intent removal.
9. Deterministic per-intent identity and Process/Inbox mirroring for unresolved lanes.
10. Commit guardrails for concrete confidence thresholds, ambiguity, stale fallback, duplicates, and append-only protected registry fields.
11. Processing generic provider key slots with OpenAI-compatible manual enhancement first.
12. Legacy review migration by derive-on-read, `legacyDerived`, and rewrite-on-touch only.
13. Notification suppression only when app active and Memory/Process selected, plus background review/error notifications.
14. Stable AX identifiers for zones, rows, registry picker rows, commit, and primary override.
15. Focused net-new tests for election, review identity, canonical 20-hex `intentId`, processed gate, `rowId` commit, activity receipts/full-vs-display hash, duplicate force reason, legacy migration, enhancement demotion/no-silent-removal, precise notification suppression, and AX IDs.
16. One Phase 0 integration packet for the coupled trust + cockpit unblock.

## Live test gate

Fix Phase 0 blockers before running M1/M5/M8 as pass/fail live tests. Any earlier live recording is REVIEW evidence only if the operator explicitly accepts that scope. Live evidence uses activity-log receipt references plus a markdown PASS/PARTIAL/FAIL grade table.
