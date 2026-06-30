# PKT-MEM-120 — Memory Hub Routing + Quality + UX

**Status:** QUEUE (validated 2026-06-30)  
**Class:** Standard · **Execution Class:** REVIEW-FIRST  
**Project:** Ship The Bridge v4  
**Branch:** `feat/mem-120-routing-quality-ux` (single integration PR)  
**Spec SSOT:** [`MEMORY-HUB-EXECUTION-SPEC.md`](../MEMORY-HUB-EXECUTION-SPEC.md) + **§PKT-MEM-120 amendments** (below)  
**Plan SSOT:** `.cursor/plans/memory_hub_sprint_e107afc7.plan.md` (21 C2C decisions locked)  
**Baseline:** test floor **2783** · app v3.9.2 build 68 (worktree `9lxf`)

> **Validate pass (2026-06-30).** This packet supersedes stale rows in PKT-MEM-110 and amends spec §0.1 for autonomous cloud Understand. Executor must treat **this packet + plan decision ledger** as authoritative over PKT-MEM-110 and over spec rows explicitly amended here.

---

## Goal Contract

### Outcome

When Processing mode is **Auto**, Bridge **defers Execute to a connected MCP agent** (queue + `voice_memo_get` → `voice_memo_commit`) and runs **autonomous cloud→local→heuristic Understand + Bridge auto-execute** only when no interactive MCP session is present. Process cockpit surfaces **provenance, degraded state, agent-awaiting, and plan diff badges**; notifications respect the Process-active gate; Processing tab copy matches behavior.

### Scope — IN

**W1 Routing**
- `MCPClientPresence` actor: HTTP `/mcp` + legacy SSE sessions only (**not** stdio); 4s disconnect grace aligned with `StatusBarController`; test override.
- `VoiceMemoCuratorRouter.deferExecuteToAgent()` async: `.agent` always; `.auto` when `MCPClientPresence.hasConnectedClient`.
- All call sites updated (processor, curator job, preview paths).
- Agent defer: `reviewTag: .awaitingAgent`; **no** `markProcessed` on defer; activity receipt `agent_deferred`; notifier lane (background only per gate).
- Hermetic tests + floor raise.

**W2 Quality / transparency**
- Provenance + Degraded badges (always visible per R2.3).
- `reviewTag` enum on `VoiceMemoReviewEntry`; `awaitingAgent` Inbox filter; legacy derive-on-read.
- Wire existing `MemoryHubPlanSnapshot.diffBadges` into Process UI (storage/logic already shipped).

**W3 UX**
- Processing tab accurate helper + live MCP status line.
- Settings dedup: Processing = mode + ladder + cloud; Advanced = model picks.
- Wire `MemoryHubNotificationGate` into `VoiceMemoNotifier`.
- Notion tab **Refresh** button only (backfill deferred).

**Docs**
- Refresh PKT-MEM-110 mode table.
- Live smoke evidence rows in `docs/operator/live-evidence/PKT-MEM-113-M1-M5-M8.md`.

### Scope — OUT

- Notion backfill dry-run/apply (follow-up packet).
- Guardrail threshold tuning (post-W1 smoke evidence only).
- New LLM parser / AgentParseProvider in-process.
- `registry_remove_entity`, embeddings/recall, v2 entity seeds.
- Version bump (full sprint closeout only, separate release commit).
- Clearing ~220 memo backlog (operator MCP batches on **Connected MCP agent** mode until W1 ships).

### Constraints

- PKT-MEM-105 trust invariants: processed gate, append-only registry, full-transcript agent memory, election lane priority.
- Swift 6 strict concurrency; hermetic tests via `BridgePaths.overrideHomeForTesting`.
- One integration PR; **W1 live smoke PASS required before merge to main**.
- No secrets in docs/commits.

### Spec amendments (PKT-MEM-120)

| Spec §0.1 row | Was | Now (locked) |
|---------------|-----|--------------|
| Enhancement provider policy | Heuristic first, local auto, **cloud manual** | **Split policy:** (A) **Process preview** — heuristic → local-auto → cloud-manual unchanged. (B) **Autonomous batch Understand** (Auto/Cloud modes, `voice_memo_process` batch + 9am job) — **cloud→local→heuristic** when provider enabled, with W4 activity receipt + macOS notify. |
| Auto curator mode | (undefined in spec) | **Auto:** if interactive MCP session present → defer Execute to agent; else autonomous Understand + guarded auto-execute. |

### Success Criteria

| ID | Criterion | Evidence |
|----|-----------|----------|
| SC-1 | Auto + MCP connected → `voice_memo_process` does **not** auto-call `memory_remember` / `registry_create` | Hermetic test + live smoke memo A |
| SC-2 | Auto alone → existing autonomous path unchanged | Hermetic test + live smoke memo B |
| SC-3 | Agent mode unchanged | Hermetic test + live smoke memo C |
| SC-4 | Deferred memo stays `processed: false` until commit/dismiss | Processed gate test + live receipt |
| SC-5 | Process shows provenance + degraded + awaiting-agent + diff badges | UI inspection + cockpit label tests |
| SC-6 | Notification suppressed when app active + Memory→Process | Gate integration test |
| SC-7 | Agent-defer notify fires when background | Manual/live check |
| SC-8 | Processing helper text matches behavior | AX/screenshot |
| SC-9 | `make test-floor` green; floor raised by net-new count only | CI / local gate output |

### Verification Plan

1. `make test` — full harness green.
2. `make test-floor` — count ≥ floor; update `scripts/test-floor-gate.sh` with provenance comment.
3. `make install-copy` → relaunch via `open -a "The Bridge"` (launchd OAuth env).
4. **W1 live smoke (merge gate)** — three memos, grades in `PKT-MEM-113-M1-M5-M8.md`:

| Case | Mode | MCP | Steps | Pass |
|------|------|-----|-------|------|
| A | Auto | Cursor connected | `voice_memo_process` one memo → verify defer → `voice_memo_get` → `voice_memo_commit` | No autonomous write; commit succeeds; processed after commit |
| B | Auto | Bridge alone (quit Cursor) | Process one memo | Autonomous execute or review per guardrails |
| C | Connected MCP agent | connected | Same as A with explicit agent mode | Behavior matches A |

5. W2/W3 smoke at closeout: provenance badges, Inbox filter, Refresh, notification gate.

### Review Requirement (REVIEW-FIRST)

**Reviewer:** Operator (Isaiah)  
**Artifact:** Install at `/Applications/The Bridge.app` + live smoke table PASS + PR diff review  
**Decisions:** Approve merge · Request changes · Defer Notion backfill follow-up  
**Stop in REVIEW** until SC-1–SC-4 pass on device.

### Failure / Stop Conditions

- MCP presence counts stdio → false-positive defer (BLOCKER — fix before merge).
- Disconnect grace < 4s → race autonomous execute during Cursor reconnect → REVIEW.
- Spec conflict unresolved (cloud policy) → do not merge without amendment doc updated.
- W1 smoke FAIL → PR stays open; no version bump.

### Dependencies

- Shipped: PKT-MEM-106 Phase 0 core, PKT-MEM-110 foundation, VoiceMemoParseRouter W4, MemoryHubPlanSnapshot store.
- Operator: Memory entity bound in Data Sources; Cursor MCP connected for smoke A/C.
- **Blocked by:** none (QUEUE).

### Required Capabilities

- Local git branch + Swift build + test harness.
- `make install-copy` (Developer ID sign).
- MCP tools: `voice_memo_process`, `voice_memo_get`, `voice_memo_commit`, `voice_memo_list`.

### Prohibited Actions

- No production release tag / DMG / appcast hand-build.
- No guardrail threshold changes without smoke evidence.
- No force-push to main.

### Operational playbook (backlog)

Until W1 ships: Processing mode = **Connected MCP agent**; commit 3 memos/session via MCP. After W1 + install-copy: switch to **Auto**.

---

## W1 implementation notes (executor-critical)

### MCPClientPresence

```text
recordConnect(name, version)   — from SSEServer onClientConnected ONLY
recordDisconnect(name)         — 4s grace, mirror StatusBarController.removeClient
hasConnectedClient             — count > 0 after grace
```

**Do NOT** increment on stdio synthetic session (`ServerManager.stdioSessionID`). Stdio is always "local" and must not trigger Auto defer (would block all autonomous processing in test/CLI paths).

### Curator job

`VoiceMemoCuratorJob` → `voice_memo_process` batch must `await deferExecuteToAgent()`. When Cursor open at 9am → defer all (R1.2). Session idle >300s → sessions expire → autonomous fallback is **expected** overnight unless client reconnects.

### Process + Inbox mirror

Deferred memos: `processed: false` + review entry `reviewTag: .awaitingAgent`. Process memo list must show **Awaiting agent** chip; plan preview from Understand step remains available (agent is not re-parsing in-process).

---

## Implementation sequence (branch checkpoints)

| Checkpoint | Deliverable | Gate |
|------------|-------------|------|
| CP-1 | W1 code + tests | Hermetic routing tests green |
| CP-2 | W1 live smoke | SC-1–4 PASS on device |
| CP-3 | W2 + W3 | Full test floor |
| CP-4 | Docs + PKT-MEM-110 refresh | Packet closeout |

---

## Brief Contract

After merge + install: operator opens Memory → Process, sees accurate routing status under Processing, Auto defers to Cursor when connected, and triage shows why a plan is degraded — without opening Advanced.

---

## Packet Runner Output

### Current Canonical Result

_Implemented 2026-06-30 in worktree `9lxf`; hermetic floor 2796. Awaiting W1 live smoke before PR._

### Artifact Manifest

- Plan: `.cursor/plans/memory_hub_sprint_e107afc7.plan.md`
- Packet: `docs/operator/packets/PKT-MEM-120-memory-hub-routing-quality-ux.md`
- Spec amendments: §PKT-MEM-120 amendments (this file)

### Exceptional History

- 2026-06-30 Validate: 7×3 C2C locked; spec cloud-policy conflict resolved via amendment table; stdio exclusion + 4s grace added as hard requirements.
