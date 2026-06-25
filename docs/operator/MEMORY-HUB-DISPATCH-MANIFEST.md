# Memory Hub — Dispatch Manifest

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

**Active execution packet (READY NEXT):** [PKT-MEM-106](./packets/PKT-MEM-106-phase0-trust-cockpit.md) — Phase 0 trust + Process cockpit integration. [PKT-MEM-113](./packets/PKT-MEM-113-multi-intent-live-cycle.md) remains the gated live-test/evidence path after Phase 0 blockers are fixed.

**Choice-to-contract reflow (2026-06-25):** Trust + Process cockpit blockers precede datetime/cloud polish, packaged as **Phase 0 = PKT-MEM-106** (sliced 0a trust+identity core · 0b Process cockpit + activity · 0c preview + guardrails + tabs). **All locked decisions live in [MEMORY-HUB-EXECUTION-SPEC.md §0.1 Decision ledger](./MEMORY-HUB-EXECUTION-SPEC.md#01-decision-ledger-2026-06-25) (SSOT)** — this manifest references rather than restates them. Process is the default triage cockpit; Inbox is the exception queue. Phase 0 precedes the older A–E phases and supersedes their B/D/E UI items (registry picker, activity strip, cloud-key UI, Agent forget/pin).

**Contract status (2026-06-25):** Phase 0 feature/design decisions are closed for execution. New survey work applies only to residual post-Phase-0 lanes unless implementation evidence reveals a trust-invariant conflict.

| Phase | Packet | Branch (planned) | Status |
|---|---|---|---|
| 0 | **[PKT-MEM-106](./packets/PKT-MEM-106-phase0-trust-cockpit.md)** — Trust + Process cockpit (precedes A–E; supersedes B/D/E UI) | `feat/memory-hub-voice-curator` | **READY NEXT** — one integration packet, sliced **0a** trust+identity core · **0b** Process cockpit + activity · **0c** preview + guardrails + tabs. Full DoD + per-slice net-new tests in the packet and in [MEMORY-HUB-VALIDATION-AND-REMEDIATION.md](./MEMORY-HUB-VALIDATION-AND-REMEDIATION.md). Locked decisions are SSOT in [SPEC §0.1](./MEMORY-HUB-EXECUTION-SPEC.md#01-decision-ledger-2026-06-25). Floor rises from **2303** only by net-new; 0a lands first (unblocks live M5/M8). PKT-MEM-105 trust invariants remain hard gates: exactly one primary auto-executes, suppressed lanes stay distinct in review, protected registry fields append only, processed waits for no pending review, and agent memory stores the full transcript. |
| A | PKT-MEM-107 datetime/calendar | `feat/pkt-mem-107-datetime` | **QUEUED** |
| B | PKT-MEM-108 UI closeout | `feat/pkt-mem-108-ui` | **QUEUED** — UI items (registry picker, Agent forget/pin) **superseded by PKT-MEM-106 0b/0c**; residual = Inbox→Process deep link |
| C | PKT-MEM-109 spec v1.1 | `feat/pkt-mem-109-spec` | **QUEUED** (parallel with A) |
| D | PKT-MEM-110b cloud curator | `feat/pkt-mem-110b-cloud` | **QUEUED** — cloud-key UI **superseded by PKT-MEM-106 0c** (Processing Keychain provider); residual = `CloudCuratorClient` classify path + agent 9am notify |
| E | PKT-MEM-111b Process polish | `feat/pkt-mem-111b-polish` | **QUEUED** (after B+D) — activity strip + preview→commit **superseded by PKT-MEM-106 0b**; residual = remaining U2–U5/U7 polish only |

### GOAL_CONDITION (Wave 3)

**112:** Close all sprint deferrals; live regression green in locked order **M1 → M5 → M8** using single-memo processing only, never backlog/batch processing, with durable grade artifact `docs/operator/live-evidence/PKT-MEM-113-M1-M5-M8.md` (columns: case, build, memo id, grade, receipt refs, cleanup status, notes); floor **≥2303** (PKT-MEM-105 baseline) maintained and raised per phase by net-new tests only; Process tab is the default triage cockpit and supports operator preview + per-intent commit. Phase 0 = PKT-MEM-106 lands first (see Wave-3 table); A–E remain queued until their own verified work lands.

### Shipped baseline (Wave 2.5 on `feat/memory-hub-voice-curator`)

- PKT-MEM-105 trust integrity ✓ · floor **2303**
- PKT-MEM-110a curator foundation (`voice_memo_get` / `voice_memo_commit`) ✓
- PKT-MEM-111 U1+U6 Process + Processing tabs ✓
- `make install` notarized to `/Applications/The Bridge.app` (2026-06-24)

## Telemetry

Sub-agent payloads to drain at Wave 1 closeout (AI LOG deferred — repo packets are SSOT for Cursor dispatch).
