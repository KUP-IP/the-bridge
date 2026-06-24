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
- [ ] Merge integration branch → main (single commit or PR; WIP still unstaged: Ollama, docs, 104 notifier files)
- [x] Wave 2 complete — floor **2292**

## Telemetry

Sub-agent payloads to drain at Wave 1 closeout (AI LOG deferred — repo packets are SSOT for Cursor dispatch).
