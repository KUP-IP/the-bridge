# Memory Hub — Wave 1 Dispatch Manifest

**Orchestrator:** orchestrator v7.0.0  
**Dispatched:** 2026-06-24  
**Spec:** [MEMORY-HUB-EXECUTION-SPEC.md](./MEMORY-HUB-EXECUTION-SPEC.md)

## Decision survey (pre-resolved — no operator block)

| # | Decision | Resolution | Impact if wrong |
|---|---|---|---|
| D1 | Memory vs Data Sources merge | Separate Memory section | Wrong IA, operator friction |
| D2 | Apple-first transcription | ON + Parakeet fallback | Slow batch, wasted GPU |
| D3 | Review UI location | Memory/Inbox, not Advanced | Product failure |
| D4 | PKT-MEM-102 review class | REVIEW-FIRST (UI smoke) | Self-ship bad UX |

## Wave 1 — DISPATCHED (parallel)

| Packet | Branch | Executor | Status |
|---|---|---|---|
| [PKT-MEM-101](./packets/PKT-MEM-101-apple-transcript-ladder.md) | `feat/pkt-mem-101-apple-transcript` | [sub-agent](91ba97f8-dc86-4aad-840a-0d310f91030c) | **DONE** — verify-back OK; live 20260613 memo not smoke-tested |
| [PKT-MEM-102](./packets/PKT-MEM-102-memory-settings-inbox.md) | `feat/pkt-mem-102-memory-inbox` | [sub-agent](7cd556eb-9293-4aac-af64-498de75196f8) | **DONE** — verify-back OK; **REVIEW-FIRST** pending operator smoke |

### GOAL_CONDITION (Wave 1)

**101:** Achieve Apple `tsrp` extraction + transcription ladder within VoiceMemo; prove with `make test` + floor green and hermetic Apple sidecar tests.

**102:** Add Memory Settings section + Inbox UI; remove Advanced review card; prove with test green + AX harness entries; operator smoke before merge.

## Wave 2 — DISPATCHED (2026-06-24)

| Packet | Branch | Executor | Status |
|---|---|---|---|
| [PKT-MEM-103](./packets/PKT-MEM-103-review-resolve-ttl.md) | `feat/pkt-mem-103-review-resolve` | [sub-agent](190ab25b-a582-4873-b3e7-0b80ae595e6d) | **DONE** — commit `9003740`; operator File-as-Memory smoke pending |
| [PKT-MEM-104](./packets/PKT-MEM-104-notifications-deeplink-tabs.md) | `feat/pkt-mem-104-notify-tabs` | [sub-agent](99afb1de-8d9d-46dc-8c75-fe690bf819ff) | **DONE** — verify-back OK (2292/2292); operator notification smoke pending |

## Verify-back checklist (orchestrator)

- [x] 101: `voice_memo_list.transcriptSource` + `resolveTranscript` ladder in source
- [x] 101: stale `voice_memo_process` description updated (per executor receipt)
- [ ] 101: operator 20260613 memo — delete sidecar, `voice_memo_process` live smoke
- [x] 102: Advanced has no review card (`voiceMemosReviewCard` removed from source)
- [ ] 102: Memory Inbox shows pending entry — **operator smoke** (REVIEW-FIRST)
- [ ] 102: `bridge_settings_navigate(section: Memory)` works — **operator smoke**
- [x] 102: test floor **2284** (+14 tests)
- [x] Merge integration branch → PR [#57](https://github.com/KUP-IP/the-bridge/pull/57) (`feat/memory-hub-voice-curator`)
- [ ] Operator smoke after `open -a "The Bridge"` (MCP still on pre-restart server until relaunch)
- [x] Wave 2 complete — floor **2292**

## Wave 3 — DISPATCHED (2026-06-24, deferred closeout)

**Parent packet:** [PKT-MEM-112](./packets/PKT-MEM-112-wave3-deferred-closeout.md)

**Active execution packet (QUEUE):** [PKT-MEM-113](./packets/PKT-MEM-113-multi-intent-live-cycle.md) — multi-intent live testing + Wave 3 dev cycle · REVIEW-FIRST · Priority 85

**Choice-to-contract reflow (2026-06-25):** Trust + Process cockpit blockers precede datetime/cloud polish. Locked decisions: lane-priority-first election; Process as default triage cockpit; split cockpit layout; distinct suppressed lanes with deterministic `intentId` + `memoId` grouping; `intentId` format = `intent_v1_` + 20 hex chars from SHA-256 over canonical JSON (sorted keys, trimmed strings, normalized whitespace, lowercase enum fields); legacy review entries derive `intentId` on read from available fields plus `createdAt`/reason fallback, mark `legacyDerived`, and rewrite only when touched; unresolved lanes visible in Process and mirrored to Inbox; processed only when no pending review remains for that memo; inline registry entity/row picker before ambiguous registry commits; protected registry text fields (`brief`, `objective`, `summary`, `description`) append-only; non-protected registry updates require explicit diff preview; live registry rows with separate per-entity JSON cache, TTL metadata, cached fallback, and stale badge after 24h; Memory Hub files live under `~/Library/Application Support/TheBridge/memory-hub/` (`activity.jsonl`, `registry-cache/<entity>.json`); fast heuristic preview before local auto-enhancement; local enhancement 8s soft timeout; cloud enhancement manual only with 20s timeout; enhancement may add/change/demote but may not silently remove heuristic intents; retain heuristic, latest enhanced, and committed snapshot per memo; generic cloud provider slots with OpenAI-compatible manual enhancement first; cloud keys stored in Keychain with provider status/save/delete in Processing; versioned preview/enhancement snapshots with diff badges; append-only bounded JSONL Memory Hub activity log retained for 500 events or 30 days; structured activity receipt envelope with transcript hashes/short excerpts only; receipt hashes store full SHA-256 and display first 12 chars; notifications suppressed only when app active and Memory/Process selected; background notifications only for queued review/errors; lane-specific confidence thresholds with global floor `0.80` and lane defaults reminder `0.90`, registry `0.86`, agent `0.86`, memory_keep `0.90`; commit guardrails for confidence/ambiguity/stale fallback/duplicates; duplicate key = `memoId + intentId + destination key`; duplicate force requires reason picker plus optional note; AX identifiers use stable zone IDs plus row/button IDs suffixed with `memoId`/`intentId`; Agent soft forget + pin only; Notion open + refresh + dry-run-first backfill only; one Phase 0 integration packet; fix Phase 0 blockers before M1/M5/M8 pass/fail live tests; live evidence = activity receipt + markdown grade table; Phase 0 test shape = election, review identity, canonical 20-hex `intentId`, processed gate, `rowId` commit, activity receipts, duplicate force reason, legacy migration, enhancement demotion/no-silent-removal, precise notification suppression, AX IDs.

| Phase | Packet | Branch (planned) | Status |
|---|---|---|---|
| 0 | Trust + Process cockpit contract | `feat/memory-hub-voice-curator` | **READY NEXT** — one integration packet for review identity, `intent_v1_` 20-hex canonical JSON ID format, legacy review migration with `legacyDerived`, processed gate, election alignment, progressive preview with timeouts/versioned diffs/snapshot retention/no silent removals, split cockpit, primary override, registry picker/per-entity JSON cache, append-only protected registry fields, deterministic `intentId`, per-intent commit, Process/Inbox mirror, Memory Hub support files, JSONL activity log/strip with privacy-limited receipt envelope/full hash + 12-char display, lane thresholds, duplicate key/force reason picker, precise active-Process notification suppression, stable AX IDs, Processing keychain key status/save/delete with OpenAI-compatible manual enhancement, Agent forget/pin, Notion refresh/dry-run backfill, focused net-new tests |
| A | PKT-MEM-107 datetime/calendar | `feat/pkt-mem-107-datetime` | **QUEUED** |
| B | PKT-MEM-108 UI closeout | `feat/pkt-mem-108-ui` | **QUEUED** |
| C | PKT-MEM-109 spec v1.1 | `feat/pkt-mem-109-spec` | **QUEUED** (parallel with A) |
| D | PKT-MEM-110b cloud curator | `feat/pkt-mem-110b-cloud` | **QUEUED** |
| E | PKT-MEM-111b Process polish | `feat/pkt-mem-111b-polish` | **QUEUED** (after B+D) |

### GOAL_CONDITION (Wave 3)

**112:** Close all sprint deferrals; 8-case live regression green; floor **≥2303** maintained and raised per phase; Process tab supports operator preview + commit path.

### Shipped baseline (Wave 2.5 on `feat/memory-hub-voice-curator`)

- PKT-MEM-105 trust integrity ✓ · floor **2303**
- PKT-MEM-110a curator foundation (`voice_memo_get` / `voice_memo_commit`) ✓
- PKT-MEM-111 U1+U6 Process + Processing tabs ✓
- `make install` notarized to `/Applications/The Bridge.app` (2026-06-24)

## Telemetry

Sub-agent payloads to drain at Wave 1 closeout (AI LOG deferred — repo packets are SSOT for Cursor dispatch).
