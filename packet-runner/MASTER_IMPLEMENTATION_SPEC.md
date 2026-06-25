# Packet Runner v1 — Master Implementation Spec

**Version 1.1 · 2026-06-24 · execution-ready build sheet.** Governing contract: PRD v1.0 (`_refs/PRD-v1.0.md`). This spec locks the architecture/scope decisions and decomposes the build into ready work units. It **amends** the PRD's provider/scheduler choice (Decisions D1/D1′); where they differ, this spec governs the *deployment topology* and the PRD governs *lifecycle/safety/acceptance semantics*. v1.1 reflects the 2026-06-24 reachability spike → executor surface refined to **fully local** (D1′).

> Status unchanged: **NOT production-qualified.** Unattended scheduling stays OFF until Pilot Phase 1 + the live capability tests pass and the §8.20 20-cycle gate + operator sign-off complete.

## 0. Decision Ledger (locked 2026-06-24, operator: Isaiah, via choice-to-contract)

| # | Decision | Rationale | Impact |
|---|---|---|---|
| **D1** | Control plane = a Bridge/local scheduler that runs the cycle; executor agent does packet work. *(Executor surface refined by D1′ — fully local; the "cloud routine" half is dropped.)* | Close #1/#7/#8 on native local surfaces rather than the cloud-only path that failed #8. | **Amends PRD** "provider-native cloud routine + no custom scheduler" → "app-local scheduled agent + Bridge MCP," using **existing** schedulers (no custom scheduler built). |
| **D1′** | **Executor surface = fully-local app-local Claude Code scheduled agent.** The whole cycle runs as ONE autonomous agent run (the proven `keep-os-daily-people-report` pattern): preflight → latch → query/hydrate → execute inline → receipt → reconcile → brief → notify, **failing closed** if the Bridge tunnel is down. No cloud `/fire`. | Spike (2026-06-24) proved this surface works **today** + reachability is live (`bridge_status` online, `macToolsAvailable: true`); even a cloud routine would need the Mac online for its Bridge calls, so cloud bought little. **Eliminates the async dispatch/reconcile split.** | **#1** = controller latch (scheduled-task single-flight not guaranteed); **#7** = `update_scheduled_task enabled:false` (+ optional Bridge `job_pause`); **#8** = Bridge `notify`/Inbox (D4); **#5** exec-ref = the task run record/output (local, not a cloud session URL). **Cost:** the Claude Code app must be open at the window (else runs on next launch). **Enhancement (deferred):** a Bridge launchd job → headless `claude` run removes the app-open need + adds native single-flight/`job_pause`. |
| **D2** | Pilot on **Ship The Bridge v4** (the-bridge repo). | Dogfood; local repo; lowest blast radius; tightest feedback. | Config concretized to the-bridge; pilot packets improve The Bridge itself. |
| **D3** | **Operator hand-picks** each packet to QUEUE. | Max control during a first pilot; gates QUEUE membership. | Operator manually qualifies each packet; the cycle auto-selects from QUEUE (cap 1). |
| **D4** | **§8.6 sign-off = Option 1:** in this local model the **Bridge** is the notifying "provider"; native `notify` + a **Bridge Inbox** mirror (brief summary + Notion URL) satisfies §8.6 via **one hop**. | Fully native (`notify` already exists — not custom/parallel infra); tappable Inbox holds the brief; avoids the Cursor cost. §8.6 line 367 reserves this call to the operator. | Closes the last #8 governance fork. **Follow-up (Option 3, deferred):** amend §8.6/T38 wording next PRD revision so the model passes the acceptance test on its face. |
| **D-assume** | (agent-decided) Latch + brief + qual docs live in `durable_evidence_destination`; cron stays **null** (one-shot manual fire) through Phase 1; `max_packets_per_cycle = 1`; timezone America/Chicago; Bridge reached via **loopback** when the agent runs on the Mac, connector otherwise. | Low-impact; consistent with PRD §8.5A + the proven daily-report pattern. | — |

## 1. Architecture (fully local — app-local scheduled agent)

```
Claude Code SCHEDULED TASK (scheduled-tasks MCP; cron in local TZ; app-local —
   runs while the Claude Code app is open, else on next launch)
  → ONE autonomous Packet Runner agent run (the keep-os-daily-people-report pattern):
      0. PREFLIGHT — Bridge reachable? (loopback 127.0.0.1:9700 / connector). If down →
         ABORT + report (FAIL CLOSED, no partial writes). Verify repo/registry/tools/model.
      1. read control latch → overlap_gate + pause_gate
            fresh-other holder → NOT_STARTED_OVERLAP, no packet, brief untouched, exit
            disabled flag      → PAUSED, exit
            else → acquire latch (holder = run id), re-read verify → FAILED if not ours
      2. query QUEUE (project = Ship The Bridge v4) → registry_hydrate top eligible packet
      3. eligibility classify → QUEUE→FOCUS coupled write (Status + Lifecycle Checked At [+fromStatus])
      4. EXECUTE INLINE — load executor v8.1.0-packet-runner; §8.8 material-revision +
         replay-state gates; edit/verify within scope / execution-class / review
      5. write packet-runner-receipt-v1 into "## Packet Runner Output"; FOCUS→{DONE|REVIEW|BLOCKED}
      6. reconcile receipt vs live state; bounded cleanup/archival (≤10 items / 120s);
         compact Output index + Source-of-Truth gate
      7. write the canonical brief (attention-first); mirror summary + Notion URL → Bridge Inbox
      8. release latch; call Bridge notify (Notion brief URL in body + openSettingsSection → Inbox)
      [qualification pilot only] append the compact qualification-evidence row after 7–8

  Pause/kill-switch: update_scheduled_task enabled:false (machine-callable) + latch `disabled`
     flag (operator-only re-enable). ONE run = the whole cycle (synchronous) — no async split.
```

**Component split (who owns what):**
- **Scheduler:** a Claude Code scheduled task (`scheduled-tasks` MCP; cron, local TZ). App-local — **proven** by the live `keep-os-daily-people-report` task. (Optional hardening: a Bridge launchd job → headless `claude` to drop the app-open requirement.)
- **Executor + controller (one agent):** the scheduled run **is** the cycle — it loads the executor skill, applies the controller logic (`controller/decisions.py` semantics), runs the inline executor, and calls Bridge tools. **Fails closed** if the Bridge is unreachable (abort + report, no partial writes) — the daily-report pattern verbatim.
- **Control guarantees:** #1 controller latch · #7 `enabled:false` + latch · #8 Bridge `notify`/Inbox. All provider-neutral; survive a later surface swap.

## 2. Capability resolution (per §8.5A/FR-9 cell)

| # | Capability | Resolution | Status |
|---|---|---|---|
| 1 | Non-overlap | **Controller latch** (`overlap_gate`/`overlap_verify`) is primary — the scheduled-task surface does not guarantee single-flight. (Optional Bridge job single-flight as belt-and-suspenders.) | latch tested T99; **reachability live-confirmed** — verify coincident-run behavior in Phase 1 |
| 2 | Repo isolation | Agent works on a per-packet branch/worktree `packet/<PKT-ID>-<slug>` in the local the-bridge clone. | verified pattern |
| 3 | Worker/inline | Single agent runs the executor **inline** (§6 inline mode). | verified |
| 4 | Registry/MCP access | Bridge tools via **loopback** (token-free, PKT-810 R5) when local, connector otherwise. | **confirmed** (`bridge_status` online; daily task writes Notion via Bridge) |
| 5 | Native execution reference | The **scheduled-task run record** (`lastRunAt` + the task's run output/transcript). Local, not a cloud session URL. | native (local) |
| 6 | Failure signaling | Agent abort-and-report output + latch state + `lastRunAt`. | native |
| 7 | Pause/kill-switch | **`update_scheduled_task enabled:false`** (machine-callable) + controller `pause_gate`/`disabled` flag; `may_reenable` = operator-only. (+ optional `job_pause`.) | native + latch (tested T57/T58) — live test pending |
| 8 | Completion notification → brief | Mirror brief summary + Notion URL → **Bridge Inbox**; call Bridge **`notify`** (native macOS notification) with the URL in the body + `openSettingsSection`→Inbox deep-link. | **native ✓**; §8.6 sign-off GIVEN (D4); brief one hop away (Inbox/body) |
| 9 | Session export | §8.18 compact-bundle fallback in AI LOGS. | fallback (non-blocking) |

## 3. Work units (execution-ready)

### WU-1 · The Packet Runner scheduled agent (the cycle) — **largest**
- **Objective:** a self-contained agent prompt/skill that runs ONE qualified packet through the full cycle (steps 0–8 of §1) in a single autonomous run.
- **In scope:** preflight/fail-closed; latch gate; QUEUE query + `registry_hydrate`; eligibility + QUEUE→FOCUS; inline execute (load executor 8.1.0); receipt + managed Output + status; reconcile + bounded maintenance; brief; Inbox mirror + `notify`; latch release. Modeled on `keep-os-daily-people-report` (load Bridge tools via ToolSearch; abort if Bridge down).
- **Out of scope:** multi-packet sweeps; auto-qualifying QUEUE (operator does, D3).
- **Deps:** WU-3 (latch + Inbox/notify), WU-4 (config); the executor skill (applied ✓).
- **DoD:** one real the-bridge packet runs end-to-end to a verified receipt + correct status + brief + notification; aborts cleanly if the Bridge is down.
- **Verify:** Phase-1 one-shot fire on a hand-picked AUTO packet; inspect receipt + live state + Inbox + notification.
- **Output:** the task prompt (`{taskId}/SKILL.md`). **Handoff:** taskId → config.

### WU-2 · Scheduler + pause control
- **Objective:** register the cycle as a scheduled task + wire the machine-callable pause.
- **In scope:** `create_scheduled_task{taskId: packet-runner-ship-the-bridge-v4, prompt: <WU-1>, cron|fireAt}` — **cron null / one-shot `fireAt`** through Phase 1; `update_scheduled_task enabled:false` = the kill-switch; (optional) a Bridge launchd job for native single-flight + `job_pause` + app-independent headless `claude`.
- **Deps:** WU-1, WU-3.
- **DoD:** a one-shot fire runs exactly one cycle; `enabled:false` stops automatic runs; a second concurrent run → `NOT_STARTED_OVERLAP` (latch).
- **Verify:** the #1 + #7 live experiments (`evidence/INTEGRATION_NON_OVERLAP.md`).
- **Output:** the task registration. **Handoff:** taskId → operator.

### WU-3 · Latch + Inbox/notify wiring
- **Objective:** the single-writer latch store + the brief notification.
- **In scope:** latch = a Notion property/row (or file) in `durable_evidence_destination` `{holder, acquired_at, expires_at, disabled}`; #8 = agent step 7–8 mirrors brief summary + Notion URL to the **Bridge Inbox** + calls `notify` (URL in body + `openSettingsSection`→Inbox). (`notify` has no arbitrary-URL tap target — verified.)
- **Deps:** D1′/D4; Bridge reachable (confirmed).
- **DoD:** latch acquire/verify/release works across a real run; operator receives a native notification and reaches the brief in one hop.
- **Verify:** Phase-1 #7 pause-confirm + #8 notification.
- **Output:** latch location + the notify/Inbox steps. **Handoff:** documented in config.

### WU-4 · Config (concrete, Ship The Bridge v4)
- **Objective:** fill `routine.config.template.json` for the pilot.
- **Decided values:** `provider = "Claude Code app-local scheduled agent + Bridge MCP (loopback/connector)"`; `taskId = packet-runner-ship-the-bridge-v4`; `project_id = <Ship The Bridge v4 PROJECT page id>`; repo `KUP-IP/the-bridge`, branch `main`, isolation `worktree`; `max_packets_per_cycle = 1`; `cron = null` (one-shot fire, Phase 1); `pause_action = update_scheduled_task enabled:false`; contract versions executor `8.1.0-packet-runner` / orchestrator `7.1.0` / close-agent `3.2.0` / registry `packet-registry-v1` / receipt `packet-runner-receipt-v1`.
- **Operator inputs still required:** `taskId` confirm, `brief_page_id` (`389cbb58-889e-8165-…`), `qualification_evidence_page_id` (`389cbb58-889e-8184-…`), `durable_evidence_destination` (+ latch location), the Ship The Bridge v4 PROJECT page id, model allowlist, reviewer/operator identities. *(No `executor_routine_id` — removed with the cloud path.)*
- **DoD:** config validates (preflight passes); no secret values.

### WU-5 · Pilot execution (two phases)
- **Phase 1 — operator hand-picked, one-shot fire (D3):** operator qualifies one packet → QUEUE → `create_scheduled_task` with `fireAt ≈ now+2min` (or an ad-hoc task started manually) → the agent runs the whole cycle → inspect receipt/brief/Inbox/notification → repeat. Run the **live capability tests**: #1 overlap (fire a second run mid-cycle → `NOT_STARTED_OVERLAP`), #7 pause-confirm (`enabled:false` mid-incident → next run aborts), #8 notification (one-hop brief reached). Plus pre-pilot evidence (§8.20): session export/fallback, cancellation, permission-denial, schema-failure, archival.
- **Phase 2 — scheduled 20-cycle qualification:** only after Phase 1 + all live tests pass, set `cron`; run **20 consecutive clean cycles** (§8.20: ≥10 executed, ≥1 real BLOCKED, ≥1 real REVIEW, delayed cleanup) → operator writes `PRODUCTION_QUALIFIED`. *(Confirm the Claude Code app stays open at the window, or adopt the launchd→headless-`claude` enhancement first.)*
- **DoD:** Phase 1 green on all live tests; Phase 2 streak = 20 + sign-off.

## 4. Open verification points (fail-closed until closed)
1. ✅ **RESOLVED — cloud→Bridge reachability:** `bridge_status` online + `macToolsAvailable: true`; the live daily task writes Notion via Bridge. Local agent reaches Bridge via loopback.
2. ✅ **RESOLVED — `notify` affordance:** no arbitrary URL; brief via body-text URL + Inbox deep-link (D4).
3. ✅ **DISSOLVED — async reconcile:** one synchronous agent run does execute→reconcile→brief→notify; no async handoff.
4. ❌ **N/A — `http_fetch`→`/fire`:** removed with the cloud path.
5. ⏳ **App-open at the window (NEW):** the scheduled task fires only while the Claude Code app is open (else on next launch). Confirm the app is left open overnight, **or** adopt the launchd→headless-`claude` enhancement for app-independence before Phase 2.
6. ⏳ **Coincident-run behavior (NEW):** scheduled-task single-flight is not guaranteed → the controller latch is the #1 guard (built/tested); confirm two overlapping runs resolve to one `NOT_STARTED_OVERLAP` in Phase 1.

## 5. Readiness map
- **Build now (no operator input):** WU-3 latch store (logic in `decisions.py`), WU-4 config defaults, WU-1 cycle prompt (model on `keep-os-daily-people-report`), WU-2 task skeleton. **No blocking spike remains** — the reachability unknown is closed.
- **Blocked on operator inputs:** `durable_evidence_destination` (+ latch), the Ship The Bridge v4 PROJECT page id, reviewer/operator identities, model allowlist.
- **Decision to confirm before Phase 2:** app-open-overnight vs the launchd→headless-`claude` enhancement (open-pt #5).
- **Gated (unchanged):** Phase-2 scheduled 20-cycle + `PRODUCTION_QUALIFIED`. Scheduling stays OFF. **Not production-qualified.**
- **Next execution batch:** (1) WU-3 + WU-4; (2) WU-1 cycle prompt + WU-2 task; (3) Phase-1 one-shot cycle on one hand-picked AUTO the-bridge packet.
