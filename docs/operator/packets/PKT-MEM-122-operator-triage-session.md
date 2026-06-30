# PKT-MEM-122 — Operator Triage Session (Agent↔UI Handoff)

**Status:** REVIEW (2026-06-30 · triage tools + hermetic tests green; W5-Triage live partial)  
**Class:** Standard · **Execution Class:** REVIEW-FIRST  
**Project:** Ship The Bridge v4 · Memory Hub Sprint  
**Parent sprint:** hub packet [PKT-MEM-120](./PKT-MEM-120-memory-hub-routing-quality-ux.md)  
**Plan SSOT:** [`.cursor/plans/memory_hub_sprint_e107afc7.plan.md`](../../../.cursor/plans/memory_hub_sprint_e107afc7.plan.md) §Wave 5  
**Branch:** `feat/mem-120-routing-quality-ux`  
**Depends on:** PKT-MEM-121 (preview cache), PKT-MEM-120 (defer-to-agent, MCP presence)  
**Baseline:** test floor post-121

> **GOAL_CONDITION:** Achieve Operator Triage Session (`voice_memo_triage_open` / `voice_memo_triage_await`, durable queue, Bridge-executes commit+title, `summaryRequested` vs Bridge ladder per R12.3, triage banner) on `feat/mem-120-routing-quality-ux` within this packet scope, prove with hermetic triage tests + live smoke row **W5-Triage** in `PKT-MEM-113` doc + `make test-floor` green, respect opener-not-stdio and **no double-commit** on `committed` events, Execution Class REVIEW-FIRST — stop after live triage smoke PASS; do not merge to main.

---

## Goal Contract

### Outcome

MCP agent and operator **share one triage session per memo**: agent calls `triage_open` → Bridge focuses Process + loads preview → agent blocks on `triage_await` → operator acts in UI → Bridge executes commit/title (where locked) + emits structured events → agent **advances** (does not re-commit). Standalone UI without session unchanged (R12.2).

### Scope — IN (v1)

- **`TriageSession` actor:** `sessionId`, `memoId`, `openerClientId` (HTTP/SSE transport id — **not stdio**), event log, expiry.
- **MCP tools (required v1):**
  - `voice_memo_triage_open(memoId)` → `sessionHandle`; focuses Settings → Memory → Process; selects memo.
  - `voice_memo_triage_await(sessionHandle, events?, timeoutSeconds=1800)` → blocking return with event payload or `timeout` / `sessionEnded`.
- **Durable queue (R8.2):** on opener disconnect, events persist; drain on reconnect + `awaitingAgent` review tag.
- **UI:** prominent "Agent triage active" banner + **End session** → `sessionEnded`.
- **Dual-path handlers (R12.2):** all Process actions work standalone; when session active ⇒ execute + emit.
- **Protocol (R8.3–R8.4):** Bridge executes title improve + commit; `committed` payload includes receipt — agent **must not** call `voice_memo_commit` again.
- **Summary (R12.3):** triage active ⇒ `summaryRequested` only; no triage ⇒ Bridge summarizer ladder.
- `ToolAnnotationCatalog` entries for both new tools (audit invariant).
- Hermetic tests + **W5-Triage** live smoke (merge gate R11.3).

### Scope — OUT (v1)

- CLI `bridge triage watch` (follow-up — MCP-only v1).
- Cross-module triage beyond Memory Process.
- Raw bash stdout as protocol.
- Version bump (sprint closeout).

### Locked decisions (C2C R8–R12)

See sprint plan §Round 8–12 ledger. Critical executor rules:

| Rule | Behavior |
|------|----------|
| No double-commit | `committed` event means Bridge already ran commit path |
| Opener identity | HTTP/SSE session only |
| Refresh | MEM-121 invalidates session (R10.3) |
| Timeout | 30m default; returns typed `timeout` event |
| Summary split | R12.3 |

### Success Criteria

| ID | Criterion | Evidence |
|----|-----------|----------|
| SC-1 | `triage_open` focuses Process + selects memo | Manual / AX |
| SC-2 | `triage_await` unblocks on UI commit with receipt payload | Hermetic + live |
| SC-3 | Agent does not double-commit after `committed` event | Live script + code review |
| SC-4 | End session / timeout returns typed event | Hermetic |
| SC-5 | Disconnect → queue → reconnect drain | Hermetic |
| SC-6 | Standalone UI commit without session unchanged | Manual |
| SC-7 | Banner visible when session active | Manual |
| SC-8 | `ToolAnnotationCatalog` audit passes for new tools | `make test` |
| SC-9 | `make test-floor` green | Gate |

### Verification Plan — W5-Triage live smoke

| Step | Action | Pass |
|------|--------|------|
| 1 | Agent: `voice_memo_triage_open(memoId)` | Settings opens Process; memo selected |
| 2 | Agent: `voice_memo_triage_await(handle)` (background) | Tool blocked |
| 3 | Operator: commit one intent in UI | |
| 4 | Agent: await returns `committed` with receipt | Agent does **not** call `voice_memo_commit` |
| 5 | Record row in `PKT-MEM-113` §W5-Triage | Receipt hash + build id |

### Failure / Stop Conditions

- Double-commit (UI + agent) → **BLOCKER**.
- stdio client counted as opener → **BLOCKER**.
- Long-poll breaks Cursor MCP client → document + timeout fallback; stop in REVIEW if unusable.
- Missing tool annotations → build fails audit — fix before REVIEW.

### Replay and Recovery

- **Detect prior effect:** activity receipt hash on `committed` event matches `MemoryHubActivityLog`.
- **Stable key:** `sessionId` + `memoId`.
- **Safe resume:** drain durable queue after reconnect.
- **Unsafe:** two agents await same session — second open returns error or supersedes (executor must pick one; recommend **409 session already open**).

### Dependencies

- PKT-MEM-121 merged to branch (preview cache + tab keep-alive).
- PKT-MEM-120 MCP presence + Process cockpit.

### Prohibited Actions

- No merge to `main`.
- No broadcast event delivery (R8.2).

---

## Brief Contract

The chat agent pauses at a well-defined turn; the operator uses Bridge as the rich control surface; the agent wakes with structured receipts — **without re-running inference or re-committing in chat**.

---

## Packet Runner Output

### Current Canonical Result

_Validated QUEUE 2026-06-30 — execute after PKT-MEM-121._

### Artifact Manifest

- Packet: this file
- Sprint plan: `.cursor/plans/memory_hub_sprint_e107afc7.plan.md` §Wave 5
- Live evidence template: `docs/operator/live-evidence/PKT-MEM-113-M1-M5-M8.md` §W5-Triage

### Exceptional History

- 2026-06-30 Validate #2: no double-commit protocol; CLI deferred v1; W5-Triage smoke table added.
