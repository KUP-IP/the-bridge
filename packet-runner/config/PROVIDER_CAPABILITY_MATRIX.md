# Provider Capability Matrix — Packet Runner v1 (Lane F)

**Purpose:** Evaluate Claude Code, Cursor, and Codex against the nine capabilities the PRD requires of the v1 provider (FR-9, §8.5A provider-selection rule). This is a **recommendation + evidence checklist**, not a final selection. Provider selection is operator-gated and **fails closed** on every cell that cannot be verified from real docs or that needs a live routine to confirm (PROGRAM_PLAN "honest gate map"; §8.5A "document the evidence").

**Captured:** 2026-06-23 (read-only; no Notion writes, no builds). Provider features evolve — re-confirm against live docs at deployment.

**EVIDENCE STATUS legend**
- `verified-by-doc` — the assessment is directly supported by an official provider doc cited in the cell.
- `plausible-needs-integration-test` — documented capability exists but the *PRD-required behavior* (e.g. deterministic non-overlap refusal, fail-closed latch, exact failure signal) cannot be confirmed without running the real routine. **These cells gate scheduling.**
- `unknown` — not addressed in any doc found; must be established before reliance.

**Surface note (Claude Code).** "Claude Code" below means **Claude Code Routines** (Anthropic-managed cloud), not in-session `/loop`/`CronCreate` or Desktop scheduled tasks. The PRD requires an unattended provider-native routine that runs "when your laptop is closed" (§8.5A `schedule`, FR-8); only Routines meets that. In-session `/loop`/Desktop "only fire while Claude Code is running" / "require machine on" ([scheduled-tasks doc](https://code.claude.com/docs/en/scheduled-tasks)) and are therefore disqualified as the v1 execution surface.

---

## Matrix (rows = capabilities, cols = providers)

Each cell: **{assessment} · EVIDENCE STATUS · source**.

### (1) Routine-level non-overlap enforcement
*PRD: §6 cycle algorithm step 1 — provider must "deterministically refuse this invocation because another is active" → `NOT_STARTED_OVERLAP`; if overlap "cannot be ruled out" → FAILED. §8.5A lists "non-overlap enforcement" as a hard requirement. Best-effort acquisition (§6) depends on it because Notion has no compare-and-swap lock.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **CONFIRMED GAP (doc research 2026-06-23) → mitigated by a controller latch.** Routines docs document NO non-overlap guard, NO single-flight/`max_concurrency` config, and NO skip-on-overlap signal; "Run now" vs an in-progress scheduled run is undocumented (GitHub triggers explicitly fan out). The provider does **not** satisfy this on its own. **Resolution (§8.5A-permitted fail-closed latch):** controller-side single-writer latch checked *before any FOCUS write* — `overlap_gate` + `overlap_verify` **implemented + unit-tested (T99 PASS)**; design + live experiment in [`evidence/INTEGRATION_NON_OVERLAP.md`](../evidence/INTEGRATION_NON_OVERLAP.md). **Status: latch deterministically verified; live end-to-end overlap experiment PENDING (operator — needs a real routine). Capability gated until that passes.** [routines](https://code.claude.com/docs/en/routines) | **Not documented.** Automations doc does not state overlapping runs of the same automation are prevented; one secondary source claims "Each run executes in isolation. Multiple automations can run in parallel" (parallelism, not same-automation non-overlap). **unknown**. [automations](https://cursor.com/docs/cloud-agent/automations) | **Not documented for same-task non-overlap.** Codex cloud emphasizes the opposite — "work on tasks in the background (including in parallel)". No per-automation overlap-refusal contract found. **unknown**. [codex cloud](https://developers.openai.com/codex/cloud) |

### (2) Repository isolation (clone / branch / worktree)
*PRD: §6, FR-4 "prefer provider-native isolated clones, branches, or worktrees and must not overwrite unexplained changes"; §8.5A `repository isolation mode`.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **Fresh clone + isolated branch per run.** "Each repository is cloned at the start of a run, starting from the default branch. Claude creates `claude/`-prefixed branches for its changes" and pushes are restricted to `claude/` branches by default. **verified-by-doc**. [routines](https://code.claude.com/docs/en/routines) | **Isolated VM + separate branch per agent.** "Cloud agents... run in isolated VMs in the cloud"; "clone your repo... and work on a separate branch, then push changes". **verified-by-doc**. [cloud-agent](https://cursor.com/docs/cloud-agent) | **Isolated ephemeral container, repo checked out per task.** "Codex creates a container and checks out your repo at the selected branch or commit SHA"; secondary: "Each task runs in its own cloud sandbox... ephemeral — created for the task and destroyed after completion." Caveat: official page says container state is **cached up to 12h**, and per-task destruction is "not mentioned" officially. **verified-by-doc** (isolation) / branch-push-back model differs from the others. [environments](https://developers.openai.com/codex/cloud/environments) |

### (3) Fresh-worker vs inline execution
*PRD: §6 "fresh executor worker preferred; inline executor fallback"; §8.13 allows switching "fresh-worker versus inline" when both approved.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **Fresh cloud session per run (fresh worker).** "Routines run autonomously as full Claude Code cloud sessions"; "Each run creates a new session." Inline fallback is satisfied by the in-session executor path on the same host. **verified-by-doc** (fresh-worker); inline-fallback is a controller design choice, not provider-blocked. [routines](https://code.claude.com/docs/en/routines) | **Fresh cloud agent (worker) per run.** Cloud agents run as independent background agents in their own VMs. **verified-by-doc**. [cloud-agent](https://cursor.com/docs/cloud-agent) | **Fresh cloud task per run.** Each cloud task runs in its own environment; subagents each "in its own isolated cloud sandbox." **verified-by-doc**. [codex cloud](https://developers.openai.com/codex/cloud) |

### (4) Registry / MCP availability in the routine
*PRD: §6 preflight of "required MCP tools"; FR-1 registry hydration runs through MCP. Registry hydration = The Bridge MCP must be reachable inside the run.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **MCP connectors available in-run; routed through Anthropic.** "Routines can use your connected MCP connectors"; "all of your currently connected connectors are included by default"; "MCP connector traffic is routed through Anthropic's servers, so the connectors you add to the routine work without adding their hosts to Allowed domains." Caveat: only **claude.ai-account connectors** appear; local `claude mcp add` servers do not — The Bridge must be registered as a claude.ai connector or via committed `.mcp.json`. **verified-by-doc** (MCP available) / **plausible-needs-integration-test** (The Bridge registry reachable + within net policy in the cloud env). [routines](https://code.claude.com/docs/en/routines) | **MCP supported.** "Cloud agents support MCP servers, giving them access to external tools and data sources." Reaching The Bridge specifically is unproven. **verified-by-doc** (MCP support) / **plausible-needs-integration-test** (Bridge reachability). [cloud-agent](https://cursor.com/docs/cloud-agent) | **MCP supported via config.** "MCP servers and multi-agent setup are defined in config.toml." Cloud agent internet access is **off by default** ([environments](https://developers.openai.com/codex/cloud/environments)), so a network-reachable Bridge MCP needs explicit allow. **verified-by-doc** (MCP support) / **plausible-needs-integration-test** (cloud net policy + Bridge reachability). [best-practices](https://developers.openai.com/codex/learn/best-practices) |

### (5) Native execution-reference capture (session URL / id)
*PRD: §6, FR-5 (passes "packet last-edited timestamp" but Output stores native execution reference), §8.6 "native execution reference," §8.15 "Native execution reference and last execution time when a worker started." Packet Runner must record `Last Execution URL` per §8.1 schema.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **Session id + URL returned natively.** `/fire` API returns `{"claude_code_session_id": "...", "claude_code_session_url": "https://claude.ai/code/session_..."}`; every run "creates a new session" viewable in the session list. Caveat: schedule/GitHub-triggered runs surface the session in the UI; the **clean id+URL JSON is the API-trigger path** — capturing the reference for a *scheduled* run needs confirming. **verified-by-doc** (API trigger) / **plausible-needs-integration-test** (capture on scheduled-trigger runs). [routines](https://code.claude.com/docs/en/routines) | **Agent id + URL returned natively.** `POST /v1/agents` returns `id` (`bc-...`) and `url` (`https://cursor.com/agents/bc-...`); `GET /v1/agents/{id}` for metadata. **verified-by-doc**. [api/endpoints](https://cursor.com/docs/cloud-agent/api/endpoints) | **Task page exists (UI); programmatic id/URL for a scheduled automation run not clearly documented.** SDK controls *local* agents; no doc found returning a cloud-task id+URL from an automation fire. **plausible-needs-integration-test** (UI task link likely exists; machine-capturable reference unproven). [sdk](https://developers.openai.com/codex/sdk) |

### (6) Runtime failure signaling
*PRD: §6 step 1 (overlap/ambiguous → FAILED), FR-16 HEALTHY/DEGRADED/FAILED on controller integrity, §8.11 health derivation. Provider must surface that a run errored vs. silently no-op'd.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **Coarse infra status only; task-success is NOT signaled.** Doc is explicit: "A green status... means the session started and exited without an infrastructure error. It does not mean the task in your prompt succeeded... Blocked network requests, missing connector tools, and task-level failures all surface [in the transcript] rather than in the status indicator." So Packet Runner must **derive** failure from receipt/state, not from provider status. **verified-by-doc** (the limitation is documented) / **plausible-needs-integration-test** (controller-derived FAILED/DEGRADED mapping must be validated end-to-end). [routines](https://code.claude.com/docs/en/routines) | **Structured ERROR/FINISHED webhook.** Webhooks fire on "statusChange... when an agent encounters an ERROR or FINISHED state," payload includes agent id, status, PR URL, summary. Strongest machine-readable failure signal of the three. **verified-by-doc**. [api/webhooks](https://cursor.com/docs/cloud-agent/api/webhooks) | **Not clearly documented for cloud automations.** No doc found defining how a scheduled cloud task's runtime failure is surfaced programmatically; community reports of "Failed to cancel task" suggest control-plane rough edges. **unknown**. [community](https://community.openai.com/t/unable-to-cancel-codex-task-failed-to-cancel-task-error/1302989) |

### (7) Machine-callable current-routine pause/disable OR deterministic fail-closed latch
*PRD: §8.5A REQUIRES "a machine-callable self-pause/disable action or deterministic provider-native fail-closed latch scoped to this routine"; §8.13 autonomous-pause exception requires the provider to "return confirmation"; FR-18 "the only autonomous persistent control is a reversible pause or disable... when the provider can confirm the change." This is a hard config field.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **Pause/disable exists but as a UI toggle; no documented machine-callable pause API.** "Use the toggle in the **Repeats** section to pause or resume the schedule"; admins can disable org-wide; `CLAUDE_CODE_DISABLE_CRON=1` disables *in-session* cron (not Routines). One-off routines "auto-disable" after firing (a fail-closed property for single-shot). **No documented HTTP/CLI call to pause a specific routine** with returned confirmation. **plausible-needs-integration-test** — must prove a machine-callable pause/disable with confirmation, OR implement a deterministic fail-closed latch (e.g. routine prompt reads a Bridge/Notion kill-switch and self-aborts before mutation). [routines](https://code.claude.com/docs/en/routines) | **Machine-callable terminal cancel + archive.** `POST /v1/agents/{id}/runs/{runId}/cancel` ("cancellation is terminal"; `409 run_not_cancellable` if already terminal), `POST /v1/agents/{id}/archive`, `DELETE /v1/agents/{id}`. This is a per-run cancel, not a per-automation "stop future runs" toggle — disabling the *schedule* via API is not clearly documented. **verified-by-doc** (run cancel) / **plausible-needs-integration-test** (disable the recurring automation itself, not just one run). [api/endpoints](https://cursor.com/docs/cloud-agent/api/endpoints) | **No reliable machine-callable cloud pause documented; failures reported.** SDK pause/resume is for *local* goals; community threads report cloud-task cancel failures. **unknown / plausible-needs-integration-test** (fail-closed latch in the prompt would be the safe path). [community](https://community.openai.com/t/unable-to-cancel-codex-task-failed-to-cancel-task-error/1302989) |

### (8) Completion notification with a brief link
*PRD: §8.6 "Use the provider's native automation-completion notification and link it to the canonical brief. Reliable native completion notification is a provider-selection requirement for v1. Do not add email, Slack, SMS, or custom push infrastructure." FR-15.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **No documented native completion notification (push) for Routines.** The doc surfaces runs in the session list and via the `/fire` response, but describes **no automatic on-completion notification channel** linking to a brief. The PRD forbids us adding Slack/email/SMS ourselves. **plausible-needs-integration-test** — this is the **highest-risk gap**; must confirm a native completion notification exists (e.g. claude.ai run-complete notification) that can carry/point at the brief link, else §8.6 cannot be met without a forbidden custom channel. [routines](https://code.claude.com/docs/en/routines) | **Native completion notification (Slack) + webhook.** "When Cloud Agent completes, you get a notification in Slack and an option to view the created PR"; webhook FINISHED carries a summary + PR URL. The brief link can be surfaced in the run summary. **verified-by-doc**. [slack](https://cursor.com/docs/integrations/slack) · [api/webhooks](https://cursor.com/docs/cloud-agent/api/webhooks) | **Not clearly documented.** Codex automations "summarize Slack channels"/post results as task output, but a guaranteed native completion notification linking to a brief is not documented. **unknown**. [automations](https://developers.openai.com/codex/app/automations) |

### (9) Session export (or §8.18 compact-bundle fallback)
*PRD: FR-9 — session export "may be unavailable only because §8.18 defines a compact durable fallback." §8.18: "Native session export — when the provider supports a durable export or downloadable artifact... otherwise... Compact incident evidence bundle." So export is the ONLY non-required capability: its absence is acceptable iff the §8.18 compact AI-LOG bundle fallback is used.*

| Claude Code | Cursor | Codex |
|---|---|---|
| **No documented durable session export/download.** Runs are viewable in the session UI but no doc describes a downloadable export artifact. **Acceptable** under FR-9/§8.18 by falling back to the compact incident evidence bundle in AI LOGS. **plausible-needs-integration-test** (confirm no export exists → fallback path is the design) — **but this does NOT block selection** (export is the sole optional capability). [routines](https://code.claude.com/docs/en/routines) | **No durable transcript export documented; run viewable via UI/API + SSE stream.** `GET /v1/agents/{id}/runs/{runId}/stream` streams during execution (not a durable export). Fallback to §8.18 bundle applies. **plausible-needs-integration-test** (non-blocking). [api/endpoints](https://cursor.com/docs/cloud-agent/api/endpoints) | **No durable cloud-session export documented.** Fallback to §8.18 bundle applies. **unknown / non-blocking** under FR-9. [codex cloud](https://developers.openai.com/codex/cloud) |

---

## Scorecard (required cells — export excluded per FR-9)

| Capability | Claude Code | Cursor | Codex |
|---|---|---|---|
| 1 Non-overlap | gap confirmed → latch built+tested (T99); live test pending | unknown | unknown (parallel-by-design) |
| 2 Repo isolation | ✅ verified | ✅ verified | ✅ verified |
| 3 Fresh worker | ✅ verified | ✅ verified | ✅ verified |
| 4 Registry/MCP | ✅ MCP / test Bridge reach | ✅ MCP / test reach | MCP / net-off default, test |
| 5 Exec reference | ✅ (API) / test scheduled | ✅ verified (id+url) | needs-test |
| 6 Failure signaling | coarse-only (documented) / derive+test | ✅ verified (ERROR webhook) | unknown |
| 7 Pause / fail-closed latch | toggle only / needs API or latch | ✅ run-cancel / disable-schedule test | unknown |
| 8 Completion notification | **gap — needs-test (high risk)** | ✅ verified (Slack) | unknown |
| 9 Session export (optional) | absent → §8.18 fallback | absent → §8.18 fallback | absent → §8.18 fallback |

---

## RECOMMENDATION

**Recommend Claude Code (Routines) as the v1 provider candidate**, subject to passing the fail-closed integration checklist below.

**Why, against the §8.5A tie-breaker "prefer the already-connected provider with the strongest isolation and simplest native scheduling":**
1. **Already connected.** This program runs *inside* Claude Code; The Bridge MCP and the registry hydration path are already integrated, and the `schedule`/`CronCreate`/scheduled-tasks tooling plus the Routines `/fire` API are first-party. Cursor and Codex would each require standing up a new provider integration — directly counter to §8.5A "do not create a generalized adapter framework" and FR-9 "No full adapter framework is built until a second provider proves the need."
2. **Strong isolation, verified.** Fresh clone + `claude/`-prefixed branch per run with default-deny pushes (capability 2, verified-by-doc) satisfies FR-4's "isolated clones/branches... must not overwrite unexplained changes."
3. **Simplest native scheduling.** Native cloud routine with cron-capable schedule (1-hour minimum, which fits a pilot `max_packets_per_cycle: 1`), API trigger, and a session id+URL returned on fire (capabilities 3, 5 verified-by-doc).

**Honest counterweight (why this is a recommendation, not a selection):** Cursor has the strongest *documented machine-control surface* — REST endpoints returning `id`+`url`, terminal `cancel`, and ERROR/FINISHED webhooks + Slack completion (capabilities 5, 6, 8 verified-by-doc). On raw capability evidence Cursor leads on signaling/pause/notification. It loses the §8.5A tie-breaker only because it is **not already connected** and would force a new adapter. If Claude Code fails the checklist below — **especially capability 8 (native completion notification) and capability 7 (machine-callable pause / fail-closed latch)** — Cursor is the fallback candidate and must itself be integration-tested for non-overlap (capability 1, currently `unknown` for all three). **Codex is not recommended for v1**: its cloud model is parallel-by-design (works against non-overlap), and signaling/pause/notification/exec-reference for *scheduled cloud automations* are largely undocumented or community-reported-broken.

---

## FAIL-CLOSED INTEGRATION CHECKLIST (must pass before the routine may be scheduled)

Per PROGRAM_PLAN ("FAIL CLOSED on unverifiable cells (§8.5A, FR-9)") and PRD §8.5A "document the evidence," the following Claude-Code cells are **NOT** `verified-by-doc` and **MUST be integration-tested** (a real, non-mutating Routines dry-run) before scheduling is enabled. Until each passes, **scheduling stays OFF**.

1. **Non-overlap (capability 1) — PARTIALLY RESOLVED, live test PENDING.** Doc research (2026-06-23) **confirmed** Claude Code Routines documents no non-overlap guard → built the §8.5A fail-closed latch instead: `overlap_gate`/`overlap_verify` (cycle reads a single-writer flag before any FOCUS write; fresh-other → `NOT_STARTED_OVERLAP`, stale-other → FAILED, re-read-verified acquisition) — **implemented + unit-tested (T99 PASS)**. **Remaining blocker:** the live end-to-end overlap experiment (`evidence/INTEGRATION_NON_OVERLAP.md`) against a real routine, which needs the operator's `routine_id`. Until it passes, scheduling stays OFF.
2. **Completion notification (capability 8) — BLOCKING.** Confirm a **native** Routines completion notification exists that can link to the canonical brief (§8.6). If none exists, §8.6 forbids adding Slack/email/SMS — selection must move to a provider that has one (Cursor). *Highest-risk undocumented cell.*
3. **Machine-callable pause / fail-closed latch (capability 7) — BLOCKING.** Confirm a machine-callable pause/disable of *this routine* with returned confirmation (FR-18 "when the provider can confirm the change"), OR implement+test the fail-closed kill-switch latch. UI-toggle-only does not satisfy the autonomous-pause exception (§8.13).
4. **Execution-reference capture on scheduled runs (capability 5).** Confirm `Last Execution URL` (§8.1) is capturable for **schedule-triggered** runs, not just `/fire` API runs.
5. **Failure-signal derivation (capability 6).** Validate the controller maps provider state → HEALTHY/DEGRADED/FAILED correctly given that provider "green" ≠ task success (documented limitation).
6. **Registry/MCP reachability in cloud (capability 4).** Confirm The Bridge MCP is reachable as a claude.ai connector (or committed `.mcp.json`) inside the routine's cloud network policy; registry hydration (FR-1) must succeed in-run.
7. **Session-export absence → §8.18 fallback (capability 9) — non-blocking.** Confirm no durable export exists and that the compact AI-LOG incident bundle fallback is wired (acceptable per FR-9; does not block selection).

**BLOCKED (operator-supplied, cannot be resolved here — §8.5A required config):** the chosen `provider`, `routine_id`, provider workspace/account alias, the machine-callable self-pause/disable action **or** the fail-closed latch implementation+authority, the reviewed `schedule`, and the `durable_evidence_destination`. These are deployment inputs and operator decisions; this lane recommends the provider and the evidence gates only. **Final provider selection and scheduling remain operator-gated; no production-readiness is claimed (PRD §11, §13, FR-25 — separate 20-cycle qualification).**

---

### Sources
- Claude Code Routines — https://code.claude.com/docs/en/routines
- Claude Code scheduled tasks (`/loop`, in-session) — https://code.claude.com/docs/en/scheduled-tasks
- Claude Code Routines announcement — https://claude.com/blog/introducing-routines-in-claude-code
- Cursor Cloud Agents (overview) — https://cursor.com/docs/cloud-agent
- Cursor Automations — https://cursor.com/docs/cloud-agent/automations
- Cursor Cloud Agents API endpoints — https://cursor.com/docs/cloud-agent/api/endpoints
- Cursor webhooks — https://cursor.com/docs/cloud-agent/api/webhooks
- Cursor Slack integration — https://cursor.com/docs/integrations/slack
- OpenAI Codex cloud (web) — https://developers.openai.com/codex/cloud
- OpenAI Codex cloud environments — https://developers.openai.com/codex/cloud/environments
- OpenAI Codex automations — https://developers.openai.com/codex/app/automations
- OpenAI Codex SDK — https://developers.openai.com/codex/sdk
- OpenAI Codex best practices (MCP) — https://developers.openai.com/codex/learn/best-practices
- Codex cloud task cancel issue (community) — https://community.openai.com/t/unable-to-cancel-codex-task-failed-to-cancel-task-error/1302989
