# PKT-MEM-112 — Memory Hub Wave 3 (Deferred Closeout)

**Wave:** 3  
**Class:** Standard (orchestrator-dispatched)  
**Orchestrator:** orchestrator v7.0.0  
**Dispatched:** 2026-06-24  
**Parent branch:** `feat/memory-hub-voice-curator` → integrate to `main` after Wave 3  
**Spec SSOT:** `docs/operator/MEMORY-HUB-EXECUTION-SPEC.md` (refresh in Phase C)  
**UI vision:** `docs/operator/MEMORY-HUB-UI-VISION.md`  
**Prerequisite shipped:** PKT-MEM-105 (trust), PKT-MEM-110a (curator foundation), PKT-MEM-111 U1+U6 (Process + Processing tabs)

---

## Objective

Close every item deferred from the approved Memory Hub sprint: automation lanes (datetime/calendar), operator UI affordances (registry picker, agent forget, Notion backfill), cloud/agent curator completion, and spec/manifest hygiene — without regressing PKT-MEM-105 trust invariants.

## Goal Contract

**Success looks like:** An operator can record voice memos, preview on Process tab, auto-route or agent-commit with append-only registry writes, forget agent memories from UI, and run the 8-case live regression suite green — with floor raised and manifest updated.

**Non-goals:** Embeddings/recall (`recall` via Ollama), backwards-sync outbox, `registry_remove_entity`, v2 entity types (Events·BLOCKS·AI Logs as hardcoded seeds).

---

## Scope

> **Phase 0 supersession (2026-06-25 reflow):** A trust + Process-cockpit integration packet,
> **PKT-MEM-106** (sliced 0a trust+identity core · 0b Process cockpit + activity · 0c preview +
> guardrails + tabs), **precedes** all four phases below and **supersedes their B/D/E UI items**:
> PKT-MEM-108's registry picker + Agent forget/pin (→ PKT-MEM-106 0b/0c), PKT-MEM-110b's cloud
> API-key UI (→ Processing Keychain provider in 0c), and PKT-MEM-111b's activity strip +
> preview→commit (→ 0b). The phase rows below retain only their **residual** scope after PKT-MEM-106.
> Locked decisions are SSOT in [MEMORY-HUB-EXECUTION-SPEC.md §0.1](../MEMORY-HUB-EXECUTION-SPEC.md#01-decision-ledger-2026-06-25).

### IN (four phases — critical path below)

| Phase | Packet ID | Deliverable |
|-------|-----------|-------------|
| **A** | PKT-MEM-107 | Datetime NLP in parser; optional `due` on reminders; calendar lane stub → `calendar_create` when date+time resolved |
| **B** | PKT-MEM-108 | Process tab registry target picker *(→ superseded by PKT-MEM-106 0b)*; Agent tab forget/pin *(→ PKT-MEM-106 0c)*; Notion tab row actions (open + soft refresh) *(→ PKT-MEM-106 0c)*; **residual:** Inbox → Process deep link |
| **C** | PKT-MEM-109 | `MEMORY-HUB-EXECUTION-SPEC.md` v1.1 (§0 truth sync, floor, tool count); live regression harness wired in CI floor comment; notification copy audit |
| **D** | PKT-MEM-110b | `CloudCuratorClient` (Anthropic/OpenAI via Keychain); Processing tab API key fields *(→ superseded by PKT-MEM-106 0c Keychain provider: key/baseURL/model/enabled)*; **residual:** classify-transcript path + agent-deferred 9am job notify copy |
| **E** | PKT-MEM-111b | Activity strip on Process *(→ superseded by PKT-MEM-106 0b)*; preview → `voice_memo_commit` button *(→ PKT-MEM-106 0b per-intent commit)*; **residual:** remaining U2–U5/U7 cloud settings UX polish |

### OUT

- Cursor-native API (use connected MCP agent or user cloud keys)
- Full calendar recurrence / natural-language date library dependency beyond lightweight heuristics
- Production release tag (operator decides after live smoke)

---

## Critical path & parallelism

```
PKT-MEM-105 ✓ (merged)
    │
    ├──► Phase C (PKT-MEM-109 spec) ── parallel with A ──► merge doc commit anytime after A/B land
    │
    ├──► Phase A (PKT-MEM-107 parser/datetime) ── sequential before live B2/B3 re-test
    │
    ├──► Phase B (PKT-MEM-108 UI) ── parallel with D after 110a ✓
    │
    └──► Phase D (PKT-MEM-110b cloud) ── parallel with B; blocks Phase E cloud slice
              │
              └──► Phase E (PKT-MEM-111b polish) ── after B + D
```

| Can run in parallel | Must run in sequence |
|---------------------|----------------------|
| A + C | A before B2/B3 live datetime tests |
| B + D (after 110a) | D before E cloud settings |
| C anytime after code lands | E after B |

---

## Definition of Done (by phase)

### Phase A — PKT-MEM-107
- [ ] Parser extracts ISO-ish due dates from "tomorrow at 9", "Friday 9am", "next week"
- [ ] `reminders_create` receives `due` when parsed
- [ ] Optional `calendar_create` lane when transcript matches schedule-event phrases
- [ ] +≥6 tests in `VoiceMemoLiveRegressionTests` or `VoiceMemoModuleTests`
- [ ] `make test-floor` green, floor raised

### Phase B — PKT-MEM-108
- [ ] Process preview shows registry entity picker when multiple `registry_update` intents
- [ ] Agent tab: Forget (calls `memory_forget`) + Pin toggle
- [ ] Notion tab: refresh row list + open-in-Notion (existing) verified
- [ ] `bridge_settings_navigate(section: Memory, anchor: process)` deep link
- [ ] AX harness updated for new controls

### Phase C — PKT-MEM-109
- [ ] `MEMORY-HUB-EXECUTION-SPEC.md` §0 matches shipped reality (tools, tabs, floor)
- [ ] `MEMORY-HUB-DISPATCH-MANIFEST.md` Wave 3 closed with verify-back
- [ ] Stale Advanced/MCP metadata grep clean

### Phase D — PKT-MEM-110b
- [ ] Keychain keys: `anthropic_api_key`, `openai_api_key` (names TBD in `BridgeKeychain`)
- [ ] `CloudCuratorClient` actor: classify transcript → `VoiceMemoPlan` JSON
- [ ] Curator mode `cloud` uses client; `agent` 9am job posts distinct notify
- [ ] Tool annotations for any new tools; tier audit green

### Phase E — PKT-MEM-111b
- [ ] Process activity strip (last N receipts from local log or dry-run summary)
- [ ] "Commit" on preview calls `voice_memo_commit` with selected intent
- [ ] Processing tab shows cloud key status (set/missing, never plaintext)

---

## QA Checklist (operator live — same 8 cases as 2026-06-24 suite)

See also: **[MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md](../MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md)** (M1–M10, multi-request per memo).

> **Phase 0 live re-test order (locked 2026-06-25):** run **M1 → M5 → M8** — simple trust path
> (M1) before registry-heavy multi-lane cases (M5, then M8). Do not run any of M1/M5/M8 as
> pass/fail until PKT-MEM-106 (Phase 0) is green; defer M5/M8 until M1 passes clean.

| ID | Scenario | Pass criteria |
|----|----------|---------------|
| A1 | Remind | Reminder created; sensible title |
| A2 | Agent should know | Full transcript in `memory_recall` |
| A3 | Contact log | Append to contact `brief`; no overwrite |
| A4 | Session DST-N | Routes to `session` not contact |
| A5 | Memory keep | Notion Memory row + body transcript |
| B1 | Project update | Append `summary`; confidence auto-execute |
| B2 | Time block + remind | Block title + due date when Phase A shipped |
| B3 | Block update | Append block `description` |

Post-sprint: cleanup test artifacts (registry_delete, reminders_delete, memory_forget) as in prior runbook.

---

## Execution Directives (executor sub-agent)

1. **Branch:** `feat/pkt-mem-112-wave3` off current `feat/memory-hub-voice-curator` (rebase if main moved).
2. **Trust invariants are sacred:** append-only registry, primary intent election, processed gate — do not weaken for automation rate.
3. **Tests define done:** each phase raises `scripts/test-floor-gate.sh` FLOOR with dated comment.
4. **UI phases:** match `BridgeTokens` / existing Memory tab patterns; no new Settings section.
5. **Install ladder for operator smoke:** `make test` → `make app` → `make install-copy` (or `make install` if signing available) → `open -a "The Bridge"`.
6. **MCP verify:** `voice_memo_get`, `voice_memo_commit`, `memory_forget` appear in `tools_list` after relaunch.

---

## Dependencies

| Upstream | Blocks |
|----------|--------|
| PKT-MEM-105 ✓ | All phases (trust base) |
| PKT-MEM-110a ✓ | Phase D, E cloud slice |
| PKT-MEM-111 U1 ✓ | Phase B picker, Phase E strip |
| Phase A | B2 live datetime pass |
| Phase D | Phase E cloud UI |

---

## Telemetry / closeout

- Update `MEMORY-HUB-DISPATCH-MANIFEST.md` Wave 3 table when each phase completes.
- Operator AI LOG optional; repo packets are SSOT for Cursor dispatch.
