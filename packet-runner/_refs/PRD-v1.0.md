**Version 1.0 · Final implementation PRD · Updated 2026-06-24**
Status: Finalized for implementation. All v1 architecture, schema, lifecycle, provider, evidence, retention, rollout, and qualification contracts are defined. Packet Runner is implementation-complete when all required migrations, integrations, and acceptance tests pass; it is production-qualified only after the 20-cycle clean-run quality gate and operator sign-off.
Source packet: [Packet Runner v1](https://app.notion.com/p/Packet-Runner-v1-388cbb58889e81d8bf76d79e78361155) · Executor contract: [executor v8](https://app.notion.com/p/b2eb533e3be1465b86d41af6937db638) · Packet authoring contract: [orchestrator v7](https://app.notion.com/p/d0925acdd04c4a15b60fc1c98245ff82)
---
# 1. Executive Summary
Packet Runner is a repository-scoped, provider-native automation routine that converts a prepared Notion packet queue into verified work and a concise operator brief. Isaiah authors and matures packets during the day; Packet Runner processes qualified packets during a scheduled low-attention window, delegates each packet to the executor protocol, reconciles results back into Notion, and surfaces only the decisions or failures that require human attention.
> Remove uncertainty about the destination and authority, not about the route.
## Product outcome
A capable implementation agent can use this PRD to build one working Packet Runner routine for a single primary automation provider, connect it to the PACKETS registry surface, execute eligible packets sequentially through executor, update packet outcomes safely, and generate a reliable cycle brief without requiring additional architectural decisions.
## Primary user
Isaiah is the operator, packet author, reviewer, and final authority for review-gated, destructive, customer-facing, externally published, strategic, or ambiguous work.
## Core value
- Turn mature packets into unattended progress without duplicating native automation infrastructure.
- Preserve agent judgment inside a packet while keeping eligibility, authority, review, and failure boundaries explicit.
- Let Isaiah wake up to verified outcomes, artifacts, blockers, and exact decisions needed—not raw execution logs.
# 2. Problem and Product Rationale
The current system can author packets and execute individual packets, but it lacks a minimal unattended controller that selects the correct work, preserves repository isolation, translates executor receipts into durable packet state, and produces a consolidated brief. Earlier designs proposed new RUNS and TELEMETRY infrastructure, leases, claims, multiple schedules, and generalized provider adapters. Those additions duplicated capabilities already supplied by Claude Code, Cursor, or Codex and risked turning Notion into an execution-control bureaucracy.
Packet Runner v1 intentionally treats Notion as the mission, lifecycle, outcome, and learning layer. Native automation sessions remain the detailed execution record. The routine coordinates work; executor owns one packet; orchestrator certifies readiness; close-agent performs cycle-level reconciliation only.
## Design principles
1. QUEUE is a time-bounded readiness certificate: it means the packet passed orchestrator's autonomy gate, remains within the global freshness window, and is still subject to final live validation.
2. One packet, one executor context, one classified receipt.
3. Use live registry context instead of copied or denormalized packet data.
4. Process packets sequentially by default; parallelism is internal to one safely isolated packet.
5. Results are always recorded; telemetry is recorded only when it creates actionable learning.
6. Retry the smallest understood operation, never blindly repeat ambiguous side effects.
# 3. Scope, Non-Goals, and Definitions
## In scope for v1
- One provider-native routine for one repository or project boundary.
- Queue discovery, eligibility checks, ordering, sequential dispatch, receipt reconciliation, packet updates, selective AI LOG creation, and one cycle brief.
- A registry fetch that returns packet properties, packet body, curated one-hop relation projections, provenance, and unresolved-relation warnings.
- A minimal provider capability boundary covering non-overlap, isolation, execution mode, registry/tool access, execution references, failure signaling, self-pause, session preservation, and native completion notification.
## Explicit non-goals
- No RUNS or SESSIONS data source, normalized execution ledger, lease table, heartbeat, or claim database.
- No recursive context hydration, automatic loading of related project or skill bodies, or duplicate relation metadata on PACKETS.
- No cross-packet parallel execution, lock database, file ownership model, or global concurrency controller.
- No universal multi-provider adapter framework, authentication manager, cross-provider model-fallback framework, custom scheduler, missed-run backfill, or separate automatic-remediation cycle. Bounded same-provider model adaptation and in-cycle self-recovery remain in scope.
- No mandatory AI LOG, retrospective, confidence score, or duplicated native execution transcript for every packet.
## Definitions
- Packet: a self-contained mission file whose body defines the observable outcome, scope, constraints, success criteria, verification, review boundary, stop conditions, and operator brief.
- Cycle: one invocation of Packet Runner, from the provider non-overlap guard through packet work, maintenance, final brief and notification, and—during qualification—the compact evidence-row update.
- Native execution session: the provider-owned detailed record of one routine or worker execution. It replaces a custom RUNS database in v1.
- Receipt: executor's structured, evidence-backed classification of one packet's stopping state.
- Brief: the human-readable cycle report containing outcomes, artifacts, blockers, review items, decisions needed, notable system learning, and next actions.
- Packet Output record: the combination of the compact `Packet Output` database property and the managed `## Packet Runner Output` section in the packet page body. The property is an index; the body section is the complete structured record.
- Clean scheduled cycle: a provider-scheduled cycle that satisfies the HEALTHY and completeness requirements in §8.20.
- NOT_STARTED_OVERLAP: a provider-level refusal issued before Packet Runner begins because another invocation owns the routine guard. It is not a packet cycle, changes no packet, and does not overwrite the active brief.
- Qualification evidence document: one bounded rollout artifact that records the compact evidence for the production-qualification streak. It is not a runtime control plane or permanent RUNS database.
- Execution class: AUTO, REVIEW-FIRST, or MANUAL; the controller uses this to determine how far autonomous work may proceed.
# 4. Canonical Assets and Current System Context
PACKETS data source: 078e7c9e-e53e-4c83-a893-af64f82b5123. Existing packet records include Status, Agent Type, PROJECT, SKILLS, Blocked by, Blocking, AI LOGS, Packet Output, Source of Truth, and page-body mission context. Packet Runner must use the registry surface rather than hardcoded multi-query assembly wherever the registry supports the required projection.
AI LOGS data source: 992fd5ac-d938-4be4-95fb-8ef18bd86bba. It currently contains broad self-evaluation fields. This PRD requires refactoring it into a selective, actionable signal system before unattended rollout.
Orchestrator v7 owns packet architecture and readiness. It must set QUEUE only after the Fresh-Agent Test and Autonomy Gate pass. Executor v8 owns one qualified packet through verification and a classified receipt. Close-agent currently owns excessive post-processing and must be narrowed to mode-aware reconciliation.
## Known contract conflicts to remediate before launch
- Executor v8 still requires Run ID, worker identity, claims, leases, budgets, claim release, and mandatory telemetry fields. Packet Runner v1 removes those requirements and replaces them with best-effort QUEUE→FOCUS acquisition evidence, an immediate verification read, and a minimal dispatch contract.
- Executor v8 may currently move external blockers to Backlog. Packet Runner v1 requires a deterministic external prerequisite with a known unblock condition to resolve to BLOCKED; ambiguous failures, remediation choices, and uncertain external state resolve to REVIEW.
- Orchestrator v7 still drains every worker telemetry payload into AI LOGS and supports broad multi-packet dispatch. Packet Runner cycles require selective telemetry and sequential cross-packet execution.
- Close-agent currently performs mandatory telemetry, universal retrospectives, status cascades, skill-audit mutation, and packet finalization. Those behaviors must be split by interactive, worker, and cycle modes.
# 5. Actors and Ownership Boundaries
## Isaiah
Authors or approves packet intent, reviews gated work, requeues failed packets when a new attempt is authorized, and controls provider scheduling and credentials.
## Orchestrator
Creates and enriches packets, resolves material decisions, defines verification and review boundaries, and moves a packet to QUEUE only when it is autonomous enough for a fresh executor.
## Packet Runner
Owns one cycle: discover, qualify, order, transition QUEUE→FOCUS, dispatch one packet at a time, collect receipts, reconcile packet state, aggregate the brief, and conditionally create system-learning records. It does not own packet work or invent missing product decisions; inline mode means it invokes the executor protocol in the same provider context while preserving the executor ownership boundary.
## Executor
Owns exactly one packet. It re-fetches canonical context, validates authority and safety, adapts technically within scope, verifies the goal, preserves or restores a safe state, writes or proposes the managed packet-body Output content, and returns the receipt. Packet Runner owns final reconciliation and the compact property index. Executor never selects sibling packets or writes AI LOGS in worker mode.
## Close-agent
Interactive mode summarizes a human-led session. Worker mode is skipped because executor already returns a receipt. Cycle mode runs once after Packet Runner completes to reconcile receipts, produce the final brief, and persist only meaningful incidents or reusable learning.
## Native provider
Owns the recurring schedule, non-overlap/concurrency enforcement, repository attachment or clone, credentials, model configuration, environment variables, permissions, native execution history, pause/disable controls, session export when available, completion notification, and manual Run Now behavior. The v1 routine must be configured so a scheduled run and a manual run cannot overlap.
# 6. Target Architecture and Lifecycle
```plain text
Provider-native recurring routine
  → non-overlap guard + capability and tool preflight
  → query project-scoped QUEUE packets
  → registry hydration and eligibility filter
  → dependency-aware ordering
  → best-effort QUEUE → FOCUS acquisition + verification read
  → fresh executor worker preferred; inline executor fallback
  → executor re-fetches canonical context and executes one packet
  → Receipt + native execution reference returned
  → Packet Runner reconciles Output and final status
  → optional queue refresh within cycle limit
  → bounded maintenance: cleanup and archival
  → one cycle-level closeout, operator brief, and native notification
  → qualification evidence-row update during pilot
  → selective AI LOG only for actionable learning or incident
```
## Packet state contract
- BACKLOG: not sufficiently prepared, not currently prioritized, or intentionally held outside execution. Packet Runner does not promote it.
- QUEUE: freshness-bounded readiness certificate from orchestrator. The packet was qualified and unblocked at `Lifecycle Checked At`; it is eligible only while the seven-day freshness and final live checks pass. No separate Ready field is required.
- FOCUS: currently owned by an active human or agent execution context. Packet Runner does not automatically resume or reclaim stale FOCUS packets in v1.
- BLOCKED: cannot proceed because a concrete dependency, credential, permission, environment, timing window, or external prerequisite is unavailable. The blocker and exact unblock condition are known.
- REVIEW: requires human judgment, approval, remediation direction, or resolution of ambiguous state. Packet Runner reports but does not execute REVIEW packets.
- DONE: the goal and verification contract are satisfied and no review remains.
- CANCELED: intentionally closed without completing the original goal because it was abandoned, superseded, or no longer valuable.
## Lifecycle transition contract
- BACKLOG → QUEUE: orchestrator or an authorized human certifies readiness and confirms no known blocker.
- QUEUE → FOCUS: Packet Runner or a human begins execution after a final live eligibility check. This is best-effort single-writer acquisition, not a guaranteed database lock; Packet Runner re-reads after the write and stops if ownership or material state is ambiguous.
- QUEUE → BLOCKED: a final live check discovers a concrete unmet prerequisite with a known owner/system and exact unblock condition.
- QUEUE → REVIEW: readiness is stale, incomplete, contradictory, time-expired, materially changed, or ambiguous.
- FOCUS → DONE: Packet Runner verifies COMPLETED or ALREADY_SATISFIED, all required evidence is green, and no review remains.
- FOCUS → REVIEW: approval, judgment, remediation, ambiguous replay, receipt mismatch, or an execution-changing decision is required.
- FOCUS → BLOCKED: a concrete external prerequisite prevents continued work and the exact unblock condition is known.
- FOCUS → QUEUE: allowed only when the worker demonstrably never started and no material side effect could have occurred.
- BLOCKED → QUEUE: an authorized actor confirms the prerequisite is resolved and readiness is revalidated. Do not transition directly from BLOCKED to FOCUS.
- BLOCKED → REVIEW: the blocker, owner, resolution path, or resulting state becomes ambiguous or requires a human decision.
- REVIEW → BLOCKED: a human decision resolves ambiguity into a concrete external prerequisite with a known unblock condition.
- REVIEW → QUEUE: a decision, remediation, or explicit retry authorization makes another attempt eligible; orchestrator reapplies the autonomy gate when the mission materially changed.
- REVIEW → DONE: human approval or review verification was the only remaining completion condition.
- Any nonterminal status → CANCELED: an authorized human or upstream governance process intentionally closes an abandoned or superseded mission.
- DONE or CANCELED → REVIEW: corrective reopen only, by an authorized operator, when completion/cancellation evidence is invalid, a false terminal state is discovered, or an incident requires reconciliation. A revived or materially changed mission normally receives a new packet rather than reopening the terminal packet. Never reopen directly to QUEUE or FOCUS.
Packet Runner owns execution-time transitions from QUEUE or FOCUS. Orchestrator and authorized humans own readiness, approval, requeue, cancellation, and blocker-resolution transitions.
### Best-effort acquisition limitation
Notion provides no compare-and-swap lock for this design. Duplicate prevention therefore depends on provider-level non-overlap, sequential dispatch, immediate verification reads, and an operating rule that humans and other agents do not start the same QUEUE packet while the routine is active. Manual Run Now uses the same provider guard. Any evidence of competing acquisition is an ownership conflict, not permission to continue.
## Cycle algorithm
1. Acquire the provider's routine-level non-overlap guard. If the provider deterministically refuses this invocation because another is active, record `NOT_STARTED_OVERLAP`, start no packet, and do not overwrite the active cycle's brief. If an invocation has started but overlap cannot be ruled out, start no packet and classify it FAILED. Then preflight repository isolation, registry access, required MCP tools, model availability, native execution-reference capture, completion notification, pause control, and session-export capability.
2. Query PACKETS for Status = QUEUE and the configured PROJECT. Do not query FOCUS or REVIEW as execution candidates.
3. Hydrate each candidate through the registry: packet properties, full packet body, curated one-hop PROJECT, SKILLS, Blocked by, Blocking, and EVENT projections, provenance, and unresolved-relation warnings.
4. Classify every non-eligible candidate deterministically:
	- MANUAL: leave unchanged and report when relevant.
	- Execution window not yet open: leave QUEUE and report the next eligible time.
	- Execution window expired: move to REVIEW because the time-bound contract requires a new decision.
	- Missing execution class, mission context, required relation access, or repository identity: move to REVIEW.
	- Known unmet prerequisite with an exact unblock condition: move to BLOCKED.
	- Ambiguous blocker, ownership, collision, or repository state: move to REVIEW.
	- Active FOCUS work in the same repository whose isolation cannot be proven disjoint: start no new repository work; leave unrelated QUEUE packets unchanged and report the collision.
	- Shared repository or provider state that is untrustworthy: fail the cycle before dispatch and preserve QUEUE state.
5. Order eligible packets by a topological dependency sort, then Priority descending, then `Lifecycle Checked At` ascending, then PKT-ID ascending as the final deterministic tie-breaker. The agent may reorder only for a clear repository-safety or integration reason and must record the rationale in the cycle plan.
6. Respect max_packets_per_cycle. v1 pilot begins at one packet per cycle.
7. For each packet sequentially: re-fetch live state; confirm it remains QUEUE and eligible; inspect repository state; update Status to FOCUS and `Lifecycle Checked At` in one logical property write; re-read both fields; dispatch only after the acquisition read is consistent; record Last Executed At and Last Execution URL immediately when a worker or inline execution session is proven to have started; and await a classified receipt.
8. Verify the receipt against packet Output, referenced artifacts, and live target state before applying the final packet status.
9. Optionally refresh eligibility after a successful packet so newly unblocked work may run, but never exceed the cycle cap or start work when remaining runtime and safety are uncertain.
10. Run bounded cleanup and archival maintenance after packet reconciliation and before the final brief, within the configured maintenance budget.
11. Run cycle closeout once: aggregate outcomes, persist meaningful AI LOG signals, write the operator brief, deliver the native notification, and report stale FOCUS, skipped packets, maintenance backlog or failures, infrastructure failures, and exact decisions needed.
12. During the scheduled qualification pilot, append the compact qualification-evidence row after brief and notification results are known. A missing or unverifiable row makes the cycle non-qualifying and breaks the qualification streak, even when operational cycle health remains HEALTHY; it does not retroactively alter reconciled packet outcomes.
# 7. Functional Requirements
## FR-1 · Registry context hydration
The registry packet fetch must return the primary packet properties and page body plus compact, curated one-hop relation projections. Related page bodies are not loaded by default. Deeper reads are explicit. The response must separate primary entity, body, hydrated relations, provenance, and unresolved-relation warnings.
## FR-2 · Queue selection and readiness
Only QUEUE packets for the configured project are considered. QUEUE is the readiness certificate only while `Lifecycle Checked At` is within the global freshness window and final live dependency, capability, repository, and execution-window checks still pass. Packet Runner must not introduce or depend on a Ready checkbox.
## FR-3 · Execution classes
PACKETS must expose a queryable execution class: AUTO, REVIEW-FIRST, or MANUAL. AUTO may close DONE after verification. REVIEW-FIRST may execute to a verified review artifact but must stop in REVIEW. MANUAL is reported but never executed.
## FR-4 · Dependency, blocking, and collision control
Every direct Blocked by packet must be DONE before execution. A deterministic unmet prerequisite with a known unblock condition moves the packet to BLOCKED and records the blocker, responsible party or system, last checked time, safe state, and unblock condition in Packet Output. A self-dependency, dependency cycle, missing or inaccessible relation, canceled prerequisite, contradictory graph, or ambiguous dependency state moves the affected packet to REVIEW instead of guessing. Cross-packet work is sequential. The routine must prefer provider-native isolated clones, branches, or worktrees and must not overwrite unexplained changes.
## FR-5 · Minimal dispatch contract
The dispatch contains canonical packet page ID, source = Packet Runner, expected state = FOCUS, executor protocol/version, handoff mode, the required Receipt return contract, and the packet last-edited timestamp observed after the FOCUS transition. That timestamp is a change detector, not a lock or authorization token. Repository identity is passed only when the routine is not inherently repository-scoped. Copied packet context, Run ID, Worker ID, lease, claim token, retry count, budgets, and prior transcript are excluded.
## FR-6 · Executor revalidation
Executor must re-fetch the authoritative packet and verify FOCUS, project/repository fit, direct blockers, execution class, packet completeness, prior Output/live replay state, and approval boundaries before material work. If the packet changed after selection, executor compares the execution-critical contract—not merely the timestamp. Material changes to Goal, Scope, Constraints, Success Criteria, Verification, Review Requirement, Stop Conditions, Dependencies, Project, or Execution Class require REVIEW; non-material changes may proceed with the comparison recorded. Registry state overrides the dispatch description.
## FR-7 · Receipt reconciliation
Packet Runner must treat a receipt as a claim until verified. It compares the receipt with packet Output, referenced files/pages/records, verification evidence, repository state, and the review class before final status writes.
## FR-8 · Scheduling and provider controls
One provider-native recurring schedule performs execution, reconciliation, telemetry selection, and briefing. Missed runs are not backfilled. Manual run, time zone, daylight-saving behavior, model, credentials, repository attachment, pause, and disable remain provider-native.
## FR-9 · Provider capability boundary
The first implementation targets one provider but evaluates nine explicit capabilities: routine-level non-overlap enforcement, repository isolation, fresh-worker versus inline mode, registry/MCP availability, native execution-reference capture, runtime failure signaling, routine pause/disable control, session export, and completion notification with a brief link. Session export may be unavailable only because §8.18 defines a compact durable fallback. Every other capability is required for the selected v1 provider. No full adapter framework is built until a second provider proves the need.
## FR-10 · Selective telemetry and closeout
Executor worker mode writes no AI LOG and invokes no full close-agent chain. Packet Runner runs one cycle-level closeout. AI LOG entries are created only for actionable friction, incidents, anticipation gaps, user feedback, reusable patterns, or system recommendations.
## FR-11 · Retry and recovery
Transient tool operations may receive one bounded retry after re-reading the target. Worker dispatch may receive one retry only when there is evidence that no worker or native session was created. Whole packets are never automatically retried across cycles. Executor may adapt freely within an active packet while state and side effects remain understood.
## FR-12 · Review and safety boundary
Destructive, production, customer-facing, externally published, strategic, irreversible, subjective, ambiguous, credential-changing, or permission-changing work requires the packet's explicit review path. Packet Runner and executor must never infer approval from successful execution.
## FR-13 · Secrets and permissions
Packet Runner uses least-privilege provider and MCP configuration. Secrets remain in native secret stores and are referenced only by safe aliases. Orchestrator declares nonstandard required capabilities and prohibited actions in the packet body. Packet Runner verifies expected capability before queueing or dispatch; executor verifies actual access before consequential work. Known, appropriately scoped missing access moves the packet to BLOCKED with a concrete unblock condition. Ambiguous, excessive, or risk-changing access requests move it to REVIEW. Agents never self-elevate, repair credentials, reveal secret values, or route around denied permissions.
## FR-14 · Review contract
Every REVIEW packet must contain a structured review request identifying the reason, completed work, remaining work, evidence and artifact links, exact decision required, available outcomes, consequences, safe state, recommendation when appropriate, and designated reviewer. A valid decision requires an explicit structured human record and an authorized status transition. Approval is revision-specific and applies only to the exact packet contract, artifact, and consequential action reviewed. Packet Runner never infers approval from casual comments, reactions, silence, successful execution, available permissions, or elapsed time.
## FR-15 · Brief delivery and retention
Each project or repository routine maintains one canonical latest-brief Notion document. Every completed invocation that retains brief-write access replaces its contents with an attention-first summary, including DEGRADED or FAILED outcomes; it does not create a per-cycle page or brief database row. Packet Output, native provider sessions, Git artifacts, and selective AI LOGS remain the historical sources. Provider-native completion notification links to the canonical brief. Empty cycles still write a health-oriented brief. Brief-write failure never rolls back completed packet outcomes.
## FR-16 · Observability and cycle health
Packet Runner uses layered observability rather than a monitoring database: PACKETS hold durable mission state and evidence, the canonical brief holds the latest operator-facing health summary, the native provider session holds the detailed execution trace and correlation reference, and AI LOGS hold only meaningful incidents or reusable learning. A completed invocation emits HEALTHY, DEGRADED, or FAILED based on controller integrity—not on whether packets ended DONE, BLOCKED, or REVIEW. UNKNOWN is an operator-derived condition when an expected cycle cannot be evidenced by a provider session or fresh brief; the routine cannot emit UNKNOWN about an invocation whose existence is itself unproven.
## FR-17 · Bounded self-recovery and incident containment
Packet Runner and executor are expected to diagnose and remediate reversible, local, and authority-preserving failures without unnecessary human escalation. They may refresh context, retry bounded transient operations, repair disposable environments or branches, correct their own implementation defects, rerun verification, regenerate artifacts, and use approved fallback tools. They may resume only after proving the failure, repair, side-effect state, and continued authority. They must halt and escalate when recovery would expand authority, repeat an ambiguous or irreversible external effect, bypass review, alter credentials or permissions, or continue from untrusted state. Incidents are contained at the narrowest boundary that fully contains the risk: packet, routine, shared provider/connection, or Packet Runner system.
## FR-18 · Workflow self-modification and schedule controls
Packet Runner may adapt session-local execution settings within preapproved bounds, including approved model choice, timeout, tool selection, retry timing, execution mode, and branch/worktree strategy. Session-local changes must not persist, broaden authority, weaken verification, bypass review, change packet scope, or exceed configured ceilings. Persistent changes to schedule, cycle cap, model defaults or allowlists, timeout ceilings, provider instructions, repository/project scope, credentials, permissions, notification destination, or governance policy require explicit review and take effect only after validation. The only autonomous persistent control is a reversible pause or disable of the affected routine when a critical incident requires containment and the provider can confirm the change. Packet Runner may never re-enable itself.
## FR-19 · Global stale-state hygiene
Packet Runner v1 uses one global stale-state policy across all projects and routines. `Lifecycle Checked At` is the authoritative age clock and is updated whenever Status changes or an authorized actor explicitly revalidates the current lifecycle state. Staleness causes resurfacing, readiness refresh, or REVIEW; it never implies automatic approval, cancellation, requeue, completion, or execution. Project-specific thresholds are deferred until pilot evidence demonstrates a real need.
## FR-20 · Packet Output compaction
Packet Output stores the current canonical result plus exceptional historical events, not a complete execution-attempt ledger. Each successful reconciliation rewrites the canonical result section with the latest status, outcome, evidence, artifacts, safe state, decision or unblock condition, and native execution reference. Historical entries are retained only for critical incidents, ambiguous external effects, approval and cancellation receipts, significant recovery actions, rollbacks, authority changes, or other events necessary to interpret current state safely.
## FR-21 · Conditional Source of Truth
`Source of Truth` is required only when a packet creates, materially changes, or verifies a durable authoritative result that someone should inspect after the packet itself is forgotten. It must reference the canonical live artifact or target state—not the cycle brief, provider session, Packet Output, temporary branch, or review artifact used merely as evidence. Research, diagnosis, recommendations, and ephemeral analysis may complete without a Source of Truth when Packet Output is the appropriate final result.
## FR-22 · Automated temporary-artifact cleanup
Temporary artifacts receive a global seven-day recovery window after DONE or CANCELED, then are cleaned automatically during routine maintenance when no review, incident, rollback, replay-safety, or Source of Truth dependency remains. Packet Runner records each artifact as canonical, evidence, or temporary and sets `Cleanup Eligible At` only when temporary cleanup candidates exist. Cleanup never deletes authoritative or still-protective evidence and never changes the terminal packet outcome.
## FR-23 · Critical-session evidence preservation
Normal executions rely on provider-native session history plus Packet Output and artifact links. Critical incidents and ambiguous executions require a durable, redacted evidence bundle outside provider-only history. Packet Runner uses a deterministic preservation gate: export the native session when supported; otherwise create an independently verifiable compact incident bundle in AI LOGS. Until one of those forms is verified, the incident remains unresolved, cycle health remains FAILED, and the affected routine remains pause-required.
## FR-24 · AI LOG resolution and archival
AI LOG incidents and learning records remain active while unresolved or still actionable. Once resolved, they receive a global 90-day retention window and are then archived automatically rather than deleted. Before archival, reusable learning must be promoted into the governing PRD, skill, runbook, packet template, or another durable guidance source when it should influence future behavior.
## FR-25 · Production qualification quality gate
Packet Runner v1 is production-qualified only after 20 consecutive scheduled cycles complete cleanly from provider preflight through packet reconciliation, brief delivery, maintenance, and closeout. The 20-cycle window must include at least 10 executed packets, at least one real BLOCKED path, at least one real REVIEW path, and verified delayed cleanup. Critical-session preservation, pause behavior, archival, and other failure paths may be proven in pre-pilot provider integration tests because an actual critical incident cannot be part of a HEALTHY streak. No unresolved critical incident, duplicate execution, unauthorized action, secret exposure, false DONE, or untrusted reconciliation may exist at qualification. Any DEGRADED, FAILED, or observer-derived UNKNOWN cycle resets the consecutive-cycle count to zero after reconciliation. Capacity or risk may expand only one dimension at a time after qualification.
## FR-26 · Output storage and code-delivery boundary
The compact Packet Output property must remain within the safe rich-text property limit and point to a complete managed output section in the packet page body. Code-changing packets default to REVIEW-FIRST unless the packet explicitly authorizes a durable repository write path that can produce a valid Source of Truth. Local commits, temporary branches, and unmerged pull requests are review or recovery artifacts—not completed durable outcomes.
# 8. Data and Interface Contracts
## 8.1 PACKETS target schema and migration contract
The current live schema is not the execution-ready schema. Before any unattended pilot, apply and validate the target below. “Required” means the property must exist; Source of Truth remains conditionally populated under §8.16.
### Required target properties
- `Status` — Notion status. Options and groups:
	- To-do: BACKLOG, QUEUE, BLOCKED.
	- In progress: FOCUS, REVIEW.
	- Complete: DONE, CANCELED.
- `Lifecycle Checked At` — date with time. Written on every lifecycle transition and explicit state revalidation.
- `Execution Class` — select with AUTO, REVIEW-FIRST, MANUAL. Missing value is fail-closed and moves a QUEUE candidate to REVIEW.
- `PROJECT` — relation. Exactly one project is required for an executable packet.
- `SKILLS` — relation. Zero or more skills; bodies load only on explicit possession.
- `Blocked by` and `Blocking` — packet relations.
- `Packet Output` — rich text compact index, maximum 1,800 visible characters under §8.2A.
- `Source of Truth` — rich text containing zero or more normalized current locators under §8.16.
- `AI LOGS` — relation used only when a selective incident or learning record exists.
### Optional target properties
- `Priority` — number from 0 through 100; higher runs first; missing equals 0.
- `Execution Window` — date with optional end. A start-only value means eligible at or after the start. A valid range means eligible from start through end. Before start, leave QUEUE; after end, move to REVIEW. An end without a start, reversed range, or unparseable value moves to REVIEW. If no timezone is embedded, use the routine timezone.
- `Last Execution URL` — URL. Written only after a worker or inline execution session is proven to have started.
- `Last Executed At` — date with time, written with Last Execution URL.
- `Cleanup Eligible At` — date with time, derived by Packet Runner; never supplied by the worker.
- `EVENT` — relation for context when present.
- `Agent Type` — existing audit/routing metadata; not an eligibility authority in the single-provider pilot. Ensure the selected provider has an option before rollout.
### Source of Truth serialization
Each current locator occupies one line:
`kind=<repo|pr|commit|notion|file|database|workflow|external>; locator=<stable URL, ID, or canonical path>; label=<short description>`
Use no more than five locators. When more are required, point to one canonical index artifact.
### Coupled lifecycle write
Every authorized Status change writes Status, `Lifecycle Checked At`, and—while compatibility requires it—`fromStatus` in one logical page-property update, followed by a verification read. `fromStatus` records the immediately previous status, not the new status. A status change without a matching lifecycle timestamp or previous-state value is inconsistent and requires revalidation before execution.
### Migration sequence
1. Export the live schema and affected records.
2. Add new properties and new status options without removing legacy values.
3. Update registry bindings, views, formulas, automations, and skills.
4. Audit each current packet, map Backlog→BACKLOG, Done→DONE, Decline→CANCELED, and stamp `Lifecycle Checked At` only after confirming state. Set every legacy packet without an audited Execution Class to MANUAL; promote it to AUTO or REVIEW-FIRST only through explicit recertification.
5. Mirror target options into `fromStatus` while dependent automations remain; retire `fromStatus` only after compatibility evidence proves it unnecessary.
6. Run schema and lifecycle acceptance tests.
7. Remove legacy status options only after no record or automation references them.
Do not add Ready, Run ID, Worker ID, Claimed By, Claimed At, Lease Until, Heartbeat, Attempt, Retry Count, token budget, cost budget, or a custom cycle ID for v1.
## 8.2 Packet body contract
Orchestrator must ensure every queued Standard or Strategic packet contains the sections below. Fast packets may compress them into Goal, Scope, Success Test, Review Boundary, Stop Conditions, and Brief when no material meaning is lost.
- Goal Contract: observable outcome, allowed scope and exclusions, constraints, success criteria, verification plan, review requirement, stop conditions, and output/brief contract.
- Current System State and Context: facts required to understand the target, including links and identifiers that cannot be inferred from the repository alone.
- Dependencies: direct blocker relations plus any external prerequisites, credential owners, or environment assumptions.
- Required Capabilities and Prohibited Actions: include only when the packet needs access beyond the routine's normal core capabilities. Reference connections and secrets by safe alias only; never include secret values.
- Brief Contract: what Isaiah should learn after execution, including artifacts and the exact review or decision request when applicable.
- Review Contract: for REVIEW-FIRST or likely review-gated work, identify the designated reviewer, scope of authority, required review artifact, available decisions, and what each decision authorizes.
- `## Packet Runner Output`: a reserved managed section. Orchestrator creates the heading but does not place mission instructions beneath it. Executor proposes updates only inside this section; Packet Runner verifies and writes the final form. The section contains `### Current Canonical Result`, `### Artifact Manifest`, and `### Exceptional History`. Mission sections above it are never overwritten by reconciliation.
## 8.2A Packet Output storage contract
The `Packet Output` database property is a compact index, not the full record. Keep it at or below 1,800 visible characters and serialize these labeled fields when applicable: `Status`, `Goal state`, `Updated`, `Native execution`, `Source of Truth`, `Decision or unblock condition`, `Safe state`, and `Output section`.
The complete machine-readable record lives in the packet page under `## Packet Runner Output`:
- `### Current Canonical Result` — one fenced YAML block matching the reconciled receipt subset.
- `### Artifact Manifest` — one fenced YAML list with target, change, retention class, ownership, authoritative locator, and current existence.
- `### Exceptional History` — compact timestamped Markdown entries; each entry uses the required labeled fields from §8.15.
Packet Runner replaces the Current Canonical Result and Artifact Manifest in place while preserving required Exceptional History. If the managed section is missing, duplicated, malformed, or too large to update safely, do not improvise another location; move the packet to REVIEW and preserve the prior trustworthy record.
## 8.3 Registry packet response
```json
{
  "schemaVersion": "packet-registry-v1",
  "primary": {
    "id": "packet-page-id",
    "title": "...",
    "lastEditedTime": "ISO-8601",
    "properties": { "status": "QUEUE", "executionClass": "AUTO", "...": "..." }
  },
  "body": "full packet markdown",
  "relations": {
    "project": [{ "id": "...", "title": "...", "status": "..." }],
    "skills": [{ "id": "...", "name": "...", "version": "...", "status": "..." }],
    "blockedBy": [{ "id": "...", "title": "...", "status": "DONE" }],
    "blocking": [],
    "event": []
  },
  "provenance": { "fetchedAt": "ISO-8601", "source": "notion" },
  "warnings": []
}
```
Hydration stops after one relation hop. Relation bodies are omitted. Unknown or inaccessible relations produce warnings rather than guessed values.
## 8.4 Dispatch payload
```json
{
  "packetId": "canonical-page-id",
  "source": "packet-runner",
  "expectedStatus": "FOCUS",
  "observedLastEditedTime": "ISO-8601 captured after FOCUS transition",
  "executor": { "slug": "executor", "minimumVersion": "8.1.0-packet-runner" },
  "routineConfigVersion": "string",
  "registrySchemaVersion": "packet-registry-v1",
  "mode": "fresh-worker | inline",
  "repository": "optional when not inherent to routine",
  "returnContract": "packet-runner-receipt-v1"
}
```
The payload transfers identity, expected authority, supported contract versions, and a stale-handoff signal—not packet context. Executor must fetch the live packet through the registry and reject unsupported routine or registry versions. A timestamp mismatch triggers a material-contract comparison; it does not automatically fail a packet whose only changes were non-execution metadata.
## 8.5 Packet Runner receipt v1
```yaml
receipt_version: packet-runner-receipt-v1
packet_id: canonical-page-id
executor_version: string
started_at: ISO-8601
finished_at: ISO-8601
packet_contract_state: UNCHANGED | NONMATERIAL_CHANGE | MATERIAL_CHANGE
contract_changes: []
goal_state: COMPLETED | ALREADY_SATISFIED | REVIEW_REQUIRED | PARTIAL_SAFE | BLOCKED | FAILED_SAFE
criteria_results:
  - criterion: string
    result: PASS | FAIL | NOT_TESTABLE
    evidence: string or URL
verification_evidence:
  - type: test | live_read | screenshot | build | lint | other
    reference: string or URL
artifacts_modified:
  - target: path or URL
    change: created | updated | deleted | unchanged
    retention_class: canonical | evidence | temporary
    ownership: routine | repository | external | unknown
    authoritative_locator: string or null
replay_state: FIRST_RUN | ALREADY_SATISFIED | SAFE_RESUME | UNSAFE_AMBIGUOUS
resume_evidence: string or null
failure_class: none | transient | implementation | dependency | permission | ambiguity | verification | provider
rollback_or_safe_state: string
review_required:
  required: true | false
  decision: string or null
follow_up: string or null
native_execution_url: string or null
friction_signals: []
```
The worker writes or proposes the complete evidence in the managed packet-body output section and returns the compact receipt to Packet Runner. Packet Runner rejects a receipt whose version, packet ID, executor version, timestamps, or contract-state evidence do not match the dispatch and live packet. Packet Runner writes the final compact `Packet Output` property index after reconciliation. SAFE_RESUME requires explicit resume evidence; UNSAFE_AMBIGUOUS always stops in REVIEW. The worker does not create an AI LOG.
### Receipt-to-status mapping
- AUTO + COMPLETED or ALREADY_SATISFIED: DONE only when all required criteria pass, live verification agrees, the managed Output write succeeds, and Source of Truth is valid when required; otherwise REVIEW.
- REVIEW-FIRST + COMPLETED or ALREADY_SATISFIED: REVIEW until the exact review contract is satisfied. Approval cannot override missing verification or Source of Truth.
- BLOCKED: BLOCKED only when the prerequisite, owner/system, safe state, and exact unblock condition are known; otherwise REVIEW.
- REVIEW_REQUIRED, PARTIAL_SAFE, FAILED_SAFE, or UNSAFE_AMBIGUOUS: REVIEW.
- Missing, malformed, contradictory, or unverifiable receipt after possible work: REVIEW and cycle health FAILED when resulting state is untrusted.
- MANUAL: never dispatched.
Packet Runner derives `Cleanup Eligible At` after a terminal transition; the worker never calculates it.
## 8.5A Routine configuration and provider-selection contract
The implementation uses one version-controlled routine configuration. Secret values remain outside it; only safe aliases are stored.
### Required configuration
- `provider`, `routine_id`, and provider workspace/account alias, including a machine-callable self-pause/disable action or deterministic provider-native fail-closed latch scoped to this routine.
- `timezone` — America/Chicago for the initial routine unless Isaiah explicitly changes it.
- `schedule` — an operator-supplied provider-native schedule; no unattended run is enabled until this value is reviewed.
- `project_id`, repository owner/name, canonical default branch, and repository isolation mode.
- `brief_page_id`, `qualification_evidence_page_id`, and `durable_evidence_destination` for redacted incident exports and portable review artifacts. The destination must be a stable Notion page/file area or repository evidence path, never an ephemeral local directory.
- `max_packets_per_cycle: 1` for pilot.
- `cycle_timeout` shorter than the schedule interval and `packet_timeout` shorter than the four-hour stale-FOCUS threshold.
- `maintenance_max_items: 10` and `maintenance_time_budget_seconds: 120` for the pilot.
- default model and approved model allowlist.
- allowed execution modes, core tool/MCP connections, and safe credential aliases.
- authorized reviewer/operator identities and provider pause authority.
- provider capability results and the versions of the PRD, executor, orchestrator, close-agent, registry schema, and receipt contract.
### Provider-selection rule
Evaluate candidate providers against: non-overlap enforcement, repository isolation, worker/inline execution, registry and MCP access, native execution reference, failure signaling, machine-callable current-routine pause/disable or fail-closed latch, completion notification with brief link, and session export. Select only a provider satisfying every requirement except session export, which may use the §8.18 fallback. If several qualify, prefer the already connected provider with the strongest isolation and simplest native scheduling. Document the evidence; do not create a generalized adapter framework.
### Configuration validation
Preflight fails before packet mutation when configuration is missing, internally inconsistent, points to an inaccessible project, repository, brief, qualification document, or durable evidence destination, allows overlapping runs, or uses contract/schema versions outside the supported range.
## 8.6 Cycle brief delivery and retention contract
### Canonical destination
Each project or repository routine maintains one Notion document named `Packet Runner Brief — <Project>`. It is the current operator handoff, not an execution ledger. Every completed cycle replaces the document body with the latest brief. Do not create a brief page or database row per cycle in v1.
The project or routine configuration stores the canonical brief page ID or URL. Packet Runner must fail visibly during preflight if the configured destination cannot be resolved or updated.
### Attention-first order
The brief is ordered by operator action rather than execution chronology:
1. Decisions needed.
2. Completed work.
3. Blocked work.
4. Failures or ambiguous states.
5. Skipped, unchanged, or stale packets.
6. Meaningful system learning.
7. Cycle metadata and health summary.
### Required content
For each relevant packet include the packet title/link, current status, concise outcome, proof summary, artifact links, exact decision or unblock condition, safe state, and native execution link when useful.
Cycle metadata includes cycle health and rationale, start and finish times, provider, repository/project, native execution reference, candidate and execution counts, resulting status counts, stale FOCUS count, receipt-reconciliation completeness, brief-write status, notification status, and any safety or ambiguity indicator.
### Excluded content
Do not duplicate full receipts, packet bodies, transcripts, raw stack traces, extensive test output, secret-bearing errors, sensitive customer data, or generic no-friction telemetry. Detailed evidence remains in Packet Output and referenced artifacts.
### Empty and no-op cycles
An empty queue still replaces the brief with evidence that the routine ran: no eligible work, counts of BLOCKED/REVIEW/stale FOCUS packets, queue-hygiene observations, and infrastructure health. This distinguishes a healthy no-op from silent routine failure.
### Notification
Use the provider's native automation-completion notification and link it to the canonical brief. Reliable native completion notification is a provider-selection requirement for v1. Do not add email, Slack, SMS, or custom push infrastructure, and do not leave a fallback-channel decision to the implementation agent.
### Brief-write failure
Packet outcomes and Packet Output remain authoritative if the aggregate brief cannot be generated or written. Do not roll back completed packets. Preserve the failure in the native provider session, create an AI LOG incident only when meaningful or recurring, and do not backfill historical brief pages automatically on the next cycle.
### Retention
Keep only the latest aggregate brief in v1. Retain packet Outputs, native execution histories, Git artifacts, review decisions, and selective AI LOG records under their existing policies. Do not automatically delete Packet Output and do not create a brief archive until pilot evidence demonstrates a concrete need.
## 8.7 AI LOGS target schema and body contract
AI LOGS properties index incidents and reusable learning; the page body stores the durable evidence bundle. Preserve legacy fields during migration until compatibility is verified.
### Required target properties
- `Log Name` — title.
- `Log Type` — select: Incident, Learning, Decision, System, Packet.
- `Signal Type` — select: Friction, Anticipation Gap, Enhancement, User Feedback, Incident, Reusable Pattern.
- `Outcome` — select: Success, Partial, Failure, Abandoned.
- `Impact` — select: Low, Medium, High.
- `Disposition` — select: Open, Investigating, Mitigated, Resolved, Dismissed, Archived.
- `Summary / Observation` — rich text.
- `Recommendation` — rich text.
- `Platform` — select: Notion, Claude, Cursor, Codex, Other.
- `Source URL` — URL.
- `PACKET`, `SKILL`, `EVENT` — relations when applicable.
- `User Feedback` — rich text.
- `Resolved At` — date with time.
- `Archive Eligible At` — date with time.
- `Promoted To` — rich text containing a stable locator to the durable guidance created from the learning.
- `Created Date` — created time.
### Managed body sections
- `## Incident Evidence Bundle` — required for critical or ambiguous preservation under §8.18.
- `## Resolution` — safe state, remediation, verification, owner, and resume decision.
- `## Learning Promotion` — reusable lesson, durable destination, and exact change made.
### Migration
Add target properties and options before retiring legacy values. Map legacy `Accepted` records to Investigating or Resolved only after record-level review. Confidence, Faithful, Concise, Readable, Quality, Reflexion Used, manual Duration, Routing Chain, and Artifacts Created become optional audit-only fields or are retired after compatibility evidence confirms they are unused.
## 8.8 Idempotency and Replay Safety Contract
Idempotency is not a blanket packet property. Replay safety is determined from the intended effect, the current live state, prior Output and artifacts, external side-effect evidence, and the packet's current execution contract. Packet Runner does not add an Idempotent checkbox or a replay ledger in v1.
### Controller protections
1. Select only QUEUE packets and process them sequentially.
2. Re-read eligibility immediately before acquisition.
3. Write QUEUE → FOCUS, then re-read the packet. Treat this as best-effort single-writer acquisition, not a guaranteed lock.
4. Capture the packet's last-edited timestamp after the FOCUS write and include it in dispatch as a stale-handoff signal.
5. Never dispatch another worker while the packet remains FOCUS, and never automatically retry a whole packet across cycles.
### Material revision guard
Executor re-fetches the packet before work. When the current last-edited timestamp differs from dispatch, it compares the execution-critical contract: Goal, Scope and exclusions, Constraints, Success Criteria, Verification Plan, Review Requirement, Failure or Stop Conditions, Dependencies, Project, and Execution Class.
- Material contract change: stop in REVIEW and identify the changed field or section.
- Non-material change such as formatting, commentary, `Lifecycle Checked At`, Last Execution URL, Last Executed At, cleanup metadata, or other controller-owned fields: proceed only after recording that the execution contract is unchanged.
The timestamp is a change detector only. No persistent hash, version column, or revision ledger is required for v1.
### Executor replay-state classification
Before material action, executor classifies current state as exactly one of:
- FIRST_RUN — no evidence the intended effect has already been attempted or achieved.
- ALREADY_SATISFIED — the observable goal is already true. Perform verification and avoid duplicate work.
- SAFE_RESUME — partial work exists and executor can prove the completed effects, remaining work, and absence of duplicate or unsafe side effects.
- UNSAFE_AMBIGUOUS — prior effects, external state, ownership, or replay consequences cannot be proven. Stop in REVIEW.
### SAFE_RESUME gate
SAFE_RESUME is allowed only when all of the following are true:
- The current Goal Contract has not materially changed.
- Existing artifacts and live targets can be inspected conclusively.
- Every consequential prior effect is identifiable.
- Remaining work is distinguishable from completed work.
- Continuing will not repeat a send, publish, charge, delete, migration, deployment, or other consequential external effect unless the target system provides a conclusive idempotency mechanism.
- Verification and rollback or safe-state handling remain valid.
If any condition is uncertain, classify UNSAFE_AMBIGUOUS.
### Action-level replay patterns
Executor uses the strongest mechanism available at the target:
- Records: search by stable business key before create; update an existing match when the contract allows.
- Files: inspect existence and content or hash before write; make deterministic transformations where practical.
- Git: inspect branch, commits, diff, working tree, and remote state before applying changes.
- APIs: use provider idempotency keys or stable request identifiers when supported.
- Schemas and migrations: inspect applied migration and target schema state before execution.
- Sends, publishing, payments, destructive changes, and externally visible actions: unsafe by default unless non-execution or safe repetition can be proven. These should normally be REVIEW-FIRST or MANUAL.
### Packet authoring requirement
Orchestrator adds a compact Replay and Recovery section only when consequential external effects, migrations, infrastructure changes, resumable partial work, or non-repository state make replay inference unreliable. It states:
1. How to detect that the effect already occurred.
2. The stable key, checkpoint, or target state that identifies prior work.
3. What partial state may be safely resumed.
4. The exact condition that makes replay unsafe and requires REVIEW.
### Requeue semantics
Returning a packet to QUEUE authorizes another attempt; it does not prove replay safety. Executor must still inspect prior Output, native execution references, artifacts, current live state, and the previous failure or review reason. A materially changed mission must pass orchestrator's autonomy gate again. When the desired outcome has substantially changed, create a new packet rather than mixing old evidence with a different mission.
## 8.9 Secrets and Permissions Contract
Secrets are infrastructure, not packet content. Packet Runner may verify that an approved capability exists and may invoke it through the configured provider or MCP connection, but it must never reveal, relocate, broaden, repair, or manufacture credentials.
### Credential ownership and storage
Credential values remain in the system that already owns them: provider-native secret management, MCP connection configuration, macOS Keychain, environment variables, repository secret stores, or deployment-platform secret managers.
Secret values must never be written to PACKETS properties, packet bodies, Packet Output, AI LOGS, cycle briefs, source-of-truth documents, repository files, commits, screenshots, or test fixtures. Packets may reference only safe aliases such as `github:primary`, `notion:primary`, or `STRIPE_API_KEY`.
### Core routine capabilities
The v1 routine may receive only the access needed for its normal controller and executor work:
- Read and update PACKETS through the registry.
- Read compact related project, skill, blocker, and event metadata.
- Read and edit the configured repository inside the provider's isolated clone, branch, or worktree.
- Run local builds, tests, linting, static analysis, and other non-consequential verification.
- Read native execution references and create selective AI LOG signal records.
Capability availability does not authorize every possible use of that capability. The packet's scope, execution class, prohibited actions, and review boundary remain controlling.
### Restricted capabilities
The following require an explicit packet declaration and normally REVIEW-FIRST unless a narrower approved policy exists:
- Git push, pull-request creation, merge, release, or tag operations.
- Staging or production database writes and migrations.
- Deployment, infrastructure, DNS, billing, or environment changes.
- External SaaS writes or creation of externally visible records.
- Network calls with consequential side effects.
Executor may prepare, test, and verify the artifact while stopping before the consequential boundary.
### Prohibited unattended actions in v1
Packet Runner and executor must not autonomously:
- Send external email, messages, or customer notifications.
- Publish public content.
- Make purchases, payments, refunds, charges, or subscription changes.
- Create, rotate, move, display, or modify credentials, access tokens, passwords, private keys, app passwords, or permissions.
- Grant themselves scopes, approve their own access requests, weaken security controls, or switch to another account to bypass denial.
- Permanently delete cloud data or deploy directly to production.
These actions require MANUAL execution or a later explicitly approved and narrowly scoped policy.
### Capability declaration in packet bodies
Orchestrator adds this compact section only when a packet needs access beyond the routine's normal core capabilities:
```plain text
## Required Capabilities
- github:primary — pull-request write
- stripe:reporting — read-only

## Prohibited Actions
- No merge
- No production deployment
- No customer communication
- No credential or permission changes
```
Do not add a queryable Required Capabilities property in v1 unless routing between routines with different access profiles becomes necessary.
### Two-stage permission check
1. Queue-time expectation: orchestrator confirms that the required connection or capability is expected to exist. A known missing requirement produces BLOCKED instead of QUEUE.
2. Execution-time reality: executor rechecks actual capability before consequential work because access may have expired, changed, or been revoked after queueing.
### Permission failure classification
Use BLOCKED only when the exact missing connection or appropriately scoped permission, responsible owner or system, and concrete unblock condition are known. Packet Output records the safe alias, missing scope, completed work, safe state, owner, last checked time, and unblock condition.
Use REVIEW when the required permission is unclear, broader access is proposed than the packet justifies, the credential source is ambiguous, privilege escalation is requested, or granting access materially changes risk.
### No self-repair or privilege escalation
The agent may diagnose the issue and provide exact remediation steps. It must not retrieve secrets from unrelated sources, inspect or copy secret values, change access-control settings, grant itself new scopes, move secrets between stores, ask for secret values in Packet Output, commit temporary credentials, or use another identity to bypass denied access.
After a human or authorized system fixes access, the packet transitions BLOCKED → QUEUE and readiness is revalidated.
### Logging and redaction
Receipts, Output, AI LOGS, and briefs may include the safe credential alias, connection name, missing scope, error class, responsible owner, remediation instructions, and redacted evidence. They must exclude secret values, authorization headers, cookies, private keys, passwords, sensitive request bodies, full credential-bearing error payloads, and personal or customer data not required for diagnosis.
### Representative operating examples
- Repository bug fix: REVIEW-FIRST may edit, test, and locally commit code, but it cannot push, merge, release, or deploy unless the packet and approved policy explicitly authorize that next step.
- Pull-request creation: local upgrade and tests may complete; missing `github:primary` pull-request write access produces BLOCKED with the branch and commit preserved.
- Production migration: REVIEW-FIRST may prepare the migration, dry-run it, prove rollback, and report affected records, but it stops before production execution.
- Stripe analysis: a read-only connection may be used for reporting; refunds, charge retries, subscription changes, and customer contact remain prohibited.
- Client communication: executor may draft personalized messages as a REVIEW artifact, but sending remains MANUAL.
- Excessive privilege request: when a read-only task appears to require administrator access, the packet moves to REVIEW rather than requesting or accepting broader access automatically.
## 8.10 Review Contract
REVIEW is a controlled human decision state, not a generic holding area. A packet in REVIEW must make the required human action unmistakable and must preserve the safe state reached before review.
### Structured review request
Packet Output must include:
- Review reason: approval, remediation, ambiguous state, receipt mismatch, scope change, excessive permission request, or another explicit category.
- Work completed and work remaining.
- Evidence and review-artifact links.
- Exact decision required.
- Available decisions and the consequence of each.
- Current safe state and whether any external effect has occurred.
- Recommended action when the executor can responsibly recommend one.
- Designated reviewer and the scope of that reviewer's authority.
### Valid review outcomes
- APPROVE_COMPLETION: REVIEW → DONE when the work is complete and human approval or review verification was the only remaining success condition.
- AUTHORIZE_CONTINUATION: REVIEW → QUEUE when the reviewer approves the next consequential step, resolves ambiguity, provides remediation direction, or explicitly authorizes another attempt. The packet returns through readiness validation rather than directly to FOCUS.
- REQUEST_CHANGES: remain REVIEW. Record the exact required changes; do not requeue until the instructions are execution-ready.
- CANCEL: REVIEW → CANCELED when the mission is abandoned, superseded, or no longer worth completing.
### Explicit decision record
Approval requires both:
1. A top-level Notion comment whose first line is exactly `PACKET DECISION` and whose remaining labeled fields contain the decision, approved action, conditions, reviewer identity, and authority scope.
2. An authorized status transition that activates that exact comment.
No alternate approval channel is valid in v1 unless this PRD is revised.
Casual language such as “looks good,” reactions, artifact edits, silence, successful tests, or comments from an unauthorized person do not constitute approval.
The actor or authorized workflow applying the status transition must append a decision receipt to Exceptional History containing the decision, reviewer, timestamp, approved action, conditions, authority scope, and source-comment link or identifier. This makes the approval visible to the next executor without requiring it to reconstruct the entire discussion thread.
Required decision format:
```plain text
PACKET DECISION
Decision: APPROVE_COMPLETION | AUTHORIZE_CONTINUATION | REQUEST_CHANGES | CANCEL
Approved action: exact action or artifact covered
Conditions: constraints, stop conditions, or verification requirements
Reviewer: person
Authority scope: exact domain and action authority
```
### Revision-specific approval
Approval applies only to the exact packet contract, review artifact, and action reviewed. Material changes to Goal, Scope, Success Criteria, Verification Plan, production command, migration contents, audience, recipients, affected records, requested permissions, or the review artifact invalidate the previous approval and return the packet to REVIEW.
### Review-artifact standards
- Code change: diff or pull request, test/build evidence, changed files, known risks.
- Migration: migration script, dry-run result, affected-record count, backup/rollback procedure, exact production command.
- Customer-facing content: rendered preview, audience or recipients, final wording, personalization variables, and confirmation that nothing was sent.
- Data or automation change: before/after state, changed records or workflow, verification evidence, rollback or recovery path.
- Ambiguous failure: what may have happened, what is known, what cannot be proven, current safe state, and available investigation or continuation options.
### Reviewer identity and authority
Isaiah is the default reviewer. Another person may be named in the packet body when domain authority belongs elsewhere. Reviewer authority must be scoped; approval of copy, design, or analysis does not imply authority to approve deployment, data migration, spending, or credential changes.
A separate reviewer database field is deferred unless review routing or notification automation requires it.
### Cancellation receipt
Every transition to CANCELED requires a durable receipt in Exceptional History containing: cancellation reason, authorized actor, timestamp, prior status, safe state, whether any external effect occurred, current artifact disposition, replacement or superseding packet when applicable, and resulting `Cleanup Eligible At` behavior. Cancellation never implies success and never removes evidence immediately.
A direct authorized cancellation outside REVIEW must produce the same receipt. Missing cancellation authority or an ambiguous artifact/effect state moves the packet to REVIEW instead of CANCELED.
### No timeout inference
Elapsed time never authorizes, retries, completes, or cancels a REVIEW packet. Old review items may be resurfaced in briefs, but silence is never consent.
## 8.11 Observability and Cycle Health Contract
Observability answers four questions: did the routine run, are its packet outcomes trustworthy, what requires attention, and where does deeper evidence live. It must not recreate a RUNS, telemetry, heartbeat, or monitoring database.
### Separation of business outcomes and operational health
Packet statuses describe mission outcomes. Cycle health describes whether Packet Runner performed its controller responsibilities reliably. A cycle may be HEALTHY while packets end BLOCKED or REVIEW, provided those outcomes were correctly classified, reconciled, and reported.
### Emitted cycle-health states
- HEALTHY: the routine reached closeout; every selected packet has a trustworthy reconciled outcome; required status and Output writes succeeded; the latest brief was written; and no operational, authorization, or safety anomaly remains.
- DEGRADED: the routine reached a trustworthy stopping state and packet outcomes remain reliable, but a recoverable operational anomaly occurred. Examples include a bounded retry, detected queue-hygiene defect, stale FOCUS discovery, unavailable native notification, or aggregate brief-write failure when Packet Output and the native provider session still preserve the authoritative results.
- FAILED: Packet Runner could not complete a core controller responsibility or cannot trust the resulting state. Examples include inability to access the registry or establish repository isolation, unreconciled worker state, inconsistent packet writes, unresolved ownership collision, safety or authorization incident, or any condition where selected packet outcomes cannot be proven.
- UNKNOWN: not emitted by Packet Runner. It is an operator-derived condition when an expected cycle has neither a reliable provider execution record nor a fresh canonical brief, so it cannot be proven whether the routine started or completed.
### Health derivation precedence
1. Any safety, authorization, duplicate-execution, or untrustworthy-state incident makes the cycle FAILED and triggers the applicable pause policy.
2. If outcomes are trustworthy but an operational anomaly remains, classify DEGRADED.
3. If controller duties completed cleanly, classify HEALTHY.
Normal DONE, BLOCKED, REVIEW, CANCELED, or empty-queue outcomes do not independently change cycle health.
### Correlation and required cycle evidence
Use the native provider execution URL or provider execution identifier as the cycle correlation reference. Do not invent a separate cycle ID in v1.
The brief and, where brief writing fails, the provider session must record:
- Cycle health and concise rationale.
- Start and finish timestamps.
- Provider, repository/project, and native execution reference.
- Candidate, selected, started, executed, DONE, BLOCKED, REVIEW, CANCELED, skipped, and stale FOCUS counts.
- Queue-hygiene defects and bounded retries.
- Receipt-reconciliation completeness.
- Brief-write and notification-delivery status.
- Ambiguous outcomes, authorization violations, and safety incidents.
### Packet-level observability
Packet Output remains the durable packet record: receipt classification, concise evidence, artifacts, safe state, decision or unblock condition, and native execution reference. Optional Last Executed At and Last Execution URL are written only when a worker actually started; they must not be used to imply successful completion.
Do not add packet fields for cycle ID, duration, tokens, cost, attempt count, confidence, detailed errors, or health state unless pilot evidence demonstrates a concrete operational decision they support.
### AI LOG incident threshold
Create an AI LOG when an event represents meaningful system learning or an incident, including duplicate execution, unauthorized or unsafe side effect, false DONE, secret exposure, review bypass, unexplained repository overwrite, receipt/live-state mismatch, ambiguous consequential action, recurring registry/provider failure, repeated queue-hygiene defect, or a capability failure that should have been caught before QUEUE.
Do not create an AI LOG for a normal BLOCKED or REVIEW outcome, a recovered one-time transient retry, an empty queue, ordinary test output, or a cycle with no reusable learning.
### Missed-run detection
The pilot uses the provider's native schedule history plus canonical brief freshness. Diagnosis checks whether a provider session exists, whether the brief timestamp advanced, whether packet state changed, and whether stale FOCUS exists. No custom watchdog is built in v1. Add one later only if missed or silent cycles become an observed recurring failure mode.
### Brief-write exception
When packet outcomes are trustworthy but the brief cannot be written, classify the cycle DEGRADED in the provider session, leave the previous brief unchanged and therefore visibly stale, preserve all Packet Outputs, and do not create a historical backfill page automatically.
### No observability data source
Do not add cycle rows, health-event rows, dashboards, heartbeats, per-tool logs, token/cost telemetry, or a custom monitoring service for the pilot. The four layers are sufficient: PACKETS for durable mission state, latest brief for the current operator view, provider session for forensic detail, and selective AI LOGS for incidents and learning.
## 8.12 Bounded Self-Recovery and Incident Containment Contract
The governance goal is not maximum caution. It is maximum useful agency inside a clearly bounded authority envelope.
### Recovery principle
> The agent may repair execution, but it may not expand its own authority.
### Self-recovery ladder
1. Diagnose: inspect live packet state, prior Output, provider session, repository state, tool errors, permissions, and relevant artifacts.
2. Repair reversible execution state: refresh stale context, retry one bounded transient operation, recreate a disposable worktree or environment, repair a local branch, fix its own code, regenerate an artifact, rerun tests, or use an already approved fallback tool.
3. Prove the repair: identify what failed, what changed, whether any side effect occurred, why replay or continuation is safe, and why the repair remains inside existing packet authority and configured permissions.
4. Resume: continue the packet or cycle only while state, ownership, side effects, and authority remain trustworthy.
5. Escalate: stop when the next step requires new credentials, broader permissions, review override, irreversible or externally visible action, repetition of an ambiguous effect, or operation from untrusted state.
### Allowed autonomous recovery
Examples include temporary provider or network failure, stale registry reads, malformed disposable environment, broken local branch, missing generated artifact, test failure caused by the executor's own implementation, safe rollback and retry, or switching between tools already authorized for the same action.
Recovery may modify local or disposable execution state and packet artifacts within scope. It must preserve unexplained user work and record any material repair in Packet Output or the provider session.
### Prohibited self-unblocking
The agent must not grant itself access, alter credential stores or permission scopes, disable security controls, bypass a review gate, use another identity to evade denial, repeat an uncertain send/payment/publish/deployment/migration/deletion, or reinterpret an ambiguous state as safe merely to continue.
### Incident boundaries
- Packet boundary: isolate the affected packet when the failure and side effects are conclusively local. Other packets in the routine may continue if repository and controller integrity remain trustworthy.
- Routine boundary: stop starting new packets when repository ownership, routine configuration, provider session, or shared routine credentials are untrusted. Unstarted packets remain QUEUE.
- Shared-system boundary: mark every dependent routine pause-required when the incident involves a shared registry, executor defect, provider dispatch mechanism, identity, credential, lifecycle implementation, or another common component.
Always choose the narrowest boundary that fully contains plausible risk. Do not continue unrelated routines merely because one packet failed, and do not under-contain a shared defect.
### Critical incidents
Critical incidents include duplicate execution, unauthorized action, secret exposure, review bypass, unexplained overwrite, false DONE, conflicting ownership, inconsistent packet writes, or an ambiguous irreversible external effect. A critical incident halts new work inside the affected boundary and makes cycle health FAILED.
The affected packet moves to REVIEW when its resulting state is ambiguous. Preserve all available evidence and do not automatically restore it to QUEUE.
### Isolated failures that do not halt the cycle
A normal BLOCKED or REVIEW outcome, a verified implementation failure confined to one packet, or a fully repaired reversible issue does not halt unrelated packets when shared repository and controller integrity remain trustworthy.
### Pause and resume signaling
Packet Runner records `Pause required: YES | NO`, the affected boundary, reason, evidence, safe state, and resume checklist in the provider session and canonical brief. It must halt its current cycle when pause is required and apply the self-pause or fail-closed behavior defined in §8.13.
Resumption requires reconciliation of affected state, identified cause, remediation, manual validation of the fix, relevant acceptance evidence, documented residual risk, and explicit operator authorization when authority, safety, or shared-system trust was affected.
## 8.13 Workflow Self-Modification and Schedule-Control Contract
Packet Runner may optimize how it executes one approved mission, but it may not silently rewrite the rules that govern future missions.
### Session-local adaptations allowed
Within one invocation, Packet Runner or executor may change:
- Model choice within an approved allowlist.
- Timeout within configured minimum and maximum bounds.
- Tool choice among already authorized tools.
- Retry delay within the approved retry policy.
- Fresh-worker versus inline execution mode when both are approved.
- Branch, worktree, disposable environment, build, test, or verification strategy.
- Internal packet-level parallelism when isolation and verification remain trustworthy.
These adaptations must preserve packet scope, execution class, review requirements, permissions, prohibited actions, replay safety, and verification strength. Material adaptations are recorded in the native provider session and summarized in Packet Output when they affect reproducibility or review.
### Persistent changes requiring review
Packet Runner may recommend or prepare a patch for, but may not autonomously persist:
- Schedule cadence, time zone, execution window, or missed-run behavior.
- Enabled state or re-enablement.
- `max_packets_per_cycle` or cross-packet concurrency.
- Default model, model allowlist, timeout ceiling, or retry policy.
- Provider routine instructions, executor/orchestrator/close-agent contracts, or this PRD.
- Repository or project scope.
- Credential, connection, permission, identity, or security configuration.
- Review, safety, notification, observability, retention, or incident policy.
If a provider exposes a nominally session-local option only as a persistent setting, treat it as persistent and require review.
### Autonomous pause exception
When a critical incident requires containment, Packet Runner may pause or disable the affected provider routine—and only routines inside the established incident boundary—if the provider offers an explicit, reversible control and returns confirmation.
The pause action must record the routine, prior state, new state, incident boundary, reason, timestamp, provider confirmation, affected packets, and resume requirements. Failure to confirm the pause is itself surfaced as a critical unresolved control issue.
Packet Runner may reduce or stop future activity, but it may never enable, re-enable, broaden, accelerate, or expand the scope of a routine autonomously.
### Re-enablement
Only Isaiah or another explicitly authorized operator may re-enable a paused routine after the incident-resume checklist is satisfied. Re-enablement is an explicit governance decision, not a self-recovery step.
### Self-modifying implementation
A packet may explicitly authorize Packet Runner to prepare changes to its own code, configuration, or governing skills. Those changes must be produced as review artifacts, validated outside the active production path, and activated no earlier than a later cycle after approval. The current invocation must not rewrite the rules under which it is presently judging itself.
### Persistent change receipt
An approved persistent change records the setting, before/after values, reason, risk, validation evidence, rollback method, reviewer, and effective time. This record may live in the governing packet Output or configuration source; no separate configuration-history database is required for v1.
## 8.14 Global Stale-State and Queue-Hygiene Contract
The same thresholds apply to every Packet Runner project and routine in v1. `Lifecycle Checked At` is maintained by every authorized lifecycle transition and explicit state revalidation. General page edits and comments do not refresh this clock.
### Global defaults
- QUEUE readiness expires after 7 calendar days. Packet Runner leaves the packet in QUEUE but excludes it from execution, labels it `Readiness refresh required` in the brief, and requests orchestrator or human recertification. Recertification reruns the autonomy and dependency checks and updates `Lifecycle Checked At`.
- FOCUS becomes potentially stale after 4 hours. Packet Runner checks the native provider session and repository ownership. If active ownership is proven, FOCUS remains unchanged and is reported. If ownership is inactive or cannot be proven, do not reclaim or redispatch; move the packet to REVIEW with all evidence and classify the cycle DEGRADED or FAILED according to state trustworthiness.
- BLOCKED becomes a stale blocker after 7 calendar days. It remains BLOCKED, its unblock condition and owner are resurfaced in the brief, and no automatic cancellation or requeue occurs.
- REVIEW becomes stale after 7 calendar days. It remains REVIEW and is surfaced prominently with the outstanding decision and designated reviewer. Silence never authorizes a transition.
- BACKLOG, DONE, and CANCELED do not receive age-based automation in v1.
### No age-based lifecycle mutation
Age alone never moves QUEUE to BACKLOG, BLOCKED to CANCELED, REVIEW to QUEUE or DONE, or any packet into execution. Staleness is a signal to inspect, recertify, decide, or reconcile.
### One-time migration
Create `Lifecycle Checked At` and populate it during a deliberate lifecycle audit. Do not infer exact historical transition times from Notion last-edited timestamps. Existing packets are reviewed and stamped with the audit time after their current state is confirmed.
### Reporting
The canonical brief reports stale QUEUE, FOCUS, BLOCKED, and REVIEW counts separately from normal status counts and links each affected packet with the required next action.
## 8.15 Packet Output Compaction Contract
Packet Output is the durable packet-facing summary of current truth. It is not a transcript, run history, or append-only event stream.
### Required structure
The managed Packet Output body contains three sections:
1. `Current Canonical Result` — always rewritten to reflect the latest authoritative state.
2. `Artifact Manifest` — always rewritten to reflect current artifact identity, retention class, ownership, and existence.
3. `Exceptional History` — append-only only for events whose omission would make the current state unsafe or materially harder to interpret.
### Current Canonical Result
The current section includes:
- Current status and receipt classification.
- Concise outcome and success-criteria result.
- Verification evidence and artifact links.
- Native execution reference and last execution time when a worker started.
- Safe state, rollback position, or already-satisfied evidence.
- Exact review decision or unblock condition when applicable.
- Current approval, cancellation, or continuation receipt when it remains controlling.
A later clean attempt replaces superseded clean-attempt details rather than appending another full receipt.
### Exceptional History retention
Retain a compact timestamped entry for:
- Critical incident or safety/authorization violation.
- Ambiguous irreversible or external effect.
- Duplicate execution or ownership conflict.
- Approval, continuation, request-changes, and cancellation decision receipts when historically relevant.
- Significant rollback, recovery, or safe-resume event.
- Material packet revision that invalidated prior approval or execution authority.
- Secret exposure or credential incident, using redacted evidence only.
- False DONE correction or receipt/live-state mismatch.
Each entry records event type, time, concise facts, affected artifact or action, resulting safe state, source execution/reference, and resolution status.
### Content excluded from Packet Output
Do not retain full provider transcripts, raw command logs, repeated test output, complete clean receipts from every attempt, superseded intermediate summaries, secret-bearing errors, or duplicate evidence already preserved in Git or the native provider session.
### Compaction safety
Compaction must not remove evidence needed to determine replay safety, validate an active approval, explain a cancellation, investigate an unresolved incident, or understand why the current status is BLOCKED or REVIEW.
When uncertain whether an event remains safety-relevant, preserve the compact exceptional entry and remove only redundant detail.
### Reconciliation write sequence
Executor writes or proposes the current result. Packet Runner then:
1. Captures the prior Status, lifecycle timestamp, compact property index, managed Output section, and Source of Truth.
2. Verifies the receipt against live state and constructs the complete reconciled Output body.
3. Replaces the managed body sections and re-reads them.
4. Applies one logical property update containing the compact Packet Output index, Source of Truth changes, final Status, `Lifecycle Checked At`, previous `fromStatus`, and derived `Cleanup Eligible At` when applicable.
5. Re-reads every changed property and confirms agreement with the managed body and live target.
A deterministic property update may receive one bounded retry after the re-read. If the managed body cannot be verified, do not write DONE. If properties are partial, contradictory, or cannot be verified, preserve the prior trustworthy Output where possible, move to REVIEW only when a trustworthy status write remains possible, classify the cycle FAILED, and invoke incident preservation when state is untrusted. Compaction or reconciliation failure never erases the prior trustworthy record.
## 8.16 Conditional Source of Truth Contract
`Source of Truth` points to where a durable result now authoritatively exists. It is not a generic evidence field.
### Requirement test
Ask: `After this packet is forgotten, is there a durable place someone should inspect to see the result as it currently exists?`
- If yes, Source of Truth is required before DONE.
- If no, Packet Output may be the final result and Source of Truth remains empty.
### Required cases
- A durable artifact was created or materially changed.
- A production, repository, database, configuration, document, automation, or external-system state became the authoritative result.
- An ALREADY_SATISFIED packet verifies an existing durable target that remains the canonical place to inspect.
### Usually not required
- Research, diagnosis, recommendation, comparison, planning, or ephemeral analysis whose final deliverable properly lives in Packet Output.
- A no-op verification with no durable target beyond the evidence itself.
- A failed, BLOCKED, REVIEW, or CANCELED packet unless a durable partial artifact is itself the current authoritative result.
### Valid references
- Code: merged pull request, canonical commit, release, or stable repository path.
- Documents: canonical Notion page, file, published specification, or approved record.
- Data and automations: the actual database record, workflow, schema, or live configuration.
- External systems: the production object or authoritative system record.
The existing rich-text property stores the normalized locator lines defined in §8.1. It does not store a Notion relation or temporary evidence link.
### Invalid substitutes
Do not populate Source of Truth solely to satisfy the field with:
- The canonical brief.
- Native provider execution session.
- Packet Output or the packet page itself.
- Temporary branch, worktree, local path, draft, screenshot, raw log, or test report.
- Review artifact that has not become the accepted durable result.
These may remain evidence links in Packet Output.
### DONE reconciliation
Before applying DONE, Packet Runner determines whether the requirement test is true. If required, it verifies that Source of Truth resolves to the current authoritative result. A missing, temporary, stale, or contradictory reference blocks DONE and moves the packet to REVIEW. If not required, Packet Output must clearly state `Source of Truth: not applicable` with a concise reason; the property remains empty.
### Supersession
When the authoritative result moves, Packet Runner or an authorized workflow updates Source of Truth to the new canonical target. Superseded evidence may remain in Exceptional History when needed, but the property itself should point only to current truth.
## 8.17 Automated Temporary-Artifact Cleanup Contract
Temporary cleanup is automatic, delayed, and conservative. It runs as a maintenance step inside the normal provider routine; v1 does not add a separate cleanup service, schedule, or artifact database.
### Artifact retention classes
Every created or materially changed artifact is classified in the receipt and Packet Output:
- `canonical` — the authoritative result or part of it. Never auto-delete while it remains Source of Truth.
- `evidence` — needed for verification, review, replay safety, rollback, incident investigation, approval, cancellation, or auditability. Preserve while that need remains.
- `temporary` — disposable execution support such as worktrees, local branches without durable value, scratch files, generated previews, temporary uploads, intermediate drafts, or ephemeral build environments.
### Recovery window
When a packet enters DONE or CANCELED and temporary candidates exist, set `Cleanup Eligible At` to seven calendar days after the terminal transition. The seven-day window begins from the terminal lifecycle transition, not from later comments or ordinary edits.
If the packet leaves DONE or CANCELED before cleanup, clear `Cleanup Eligible At` and preserve every artifact until the packet reaches a new terminal state.
### Cleanup eligibility gate
At or after `Cleanup Eligible At`, Packet Runner may delete or archive a temporary artifact only after confirming:
- The packet remains DONE or CANCELED.
- Source of Truth is valid when required and does not reference the candidate.
- No open REVIEW, BLOCKED dependency, successor packet, rollback plan, replay-safety analysis, or unresolved incident depends on it.
- No approval or cancellation record identifies it as controlling evidence.
- The artifact is still identifiable and owned by the routine.
- Deletion will not remove unexplained user work or externally authoritative state.
### Protected artifacts
Never automatically delete merged commits, accepted pull requests, releases, tags, canonical repository paths, authoritative documents or records, Source of Truth targets, active review artifacts, incident evidence, rollback assets, replay-safety evidence, or artifacts whose ownership is uncertain.
An unmerged pull request or branch may be temporary only after its review is closed, its useful commits are preserved elsewhere or intentionally abandoned, and no incident or successor packet depends on it.
### Automated maintenance behavior
Each cycle may query terminal packets with a due `Cleanup Eligible At` and process a bounded number after packet reconciliation and before cycle closeout. Cleanup does not count against `max_packets_per_cycle` because it starts no mission work, but it must remain time-bounded and must not delay the operator brief materially.
After successful cleanup, verify absence or archival state, update the canonical Output with a concise cleanup receipt, and clear `Cleanup Eligible At`. Routine cleanup success does not create an AI LOG or Exceptional History entry unless it materially affects interpretation of current state.
### Cleanup failure
A failed or ambiguous cleanup does not change DONE or CANCELED. Preserve `Cleanup Eligible At`, record the candidate and failure in the brief/provider session, and retry on a later cycle only when repetition is safe. Repeated failure or evidence that protected material may have been removed creates an AI LOG incident; uncertain destructive effect follows the REVIEW and incident-containment contracts.
### CANCELED packets
Cancellation does not mean immediate deletion. Preserve temporary artifacts for seven days so a replacement packet, operator, or incident investigation can recover useful work. After the window, normal eligibility gates apply.
## 8.18 Critical-Session Evidence Preservation Contract
Provider-native history is sufficient for normal runs. Packet Runner does not export every session or create a duplicate execution archive.
### Preservation gate
Durable preservation is required when any of the following is true:
- Cycle health is FAILED because packet or controller state is untrusted.
- Replay state is UNSAFE_AMBIGUOUS.
- A worker may have acted but no trustworthy receipt exists.
- Duplicate execution, ownership conflict, false DONE, review bypass, secret exposure, unauthorized action, or unexplained overwrite occurred.
- An irreversible or externally visible effect may have occurred but cannot be proven.
- Packet, repository, provider, credential, or lifecycle state is materially inconsistent.
Normal HEALTHY runs and ordinary BLOCKED, REVIEW, or fully recovered DEGRADED runs require only the native execution reference.
### Preservation forms
Use the strongest available form:
1. Native session export — when the provider supports a durable export or downloadable artifact, preserve it under the configured `durable_evidence_destination` and link it from the AI LOG Incident.
2. Compact incident evidence bundle — when export is unavailable or incomplete, create or update an AI LOG Incident containing independently verifiable evidence.
The compact bundle includes provider and native session reference, start and finish times, affected packets, incident classification, known facts and unknowns, consequential actions that may have occurred, repository commits/diffs or external object identifiers, current safe state, redacted evidence links, and required investigation or recovery action.
### Enforcement sequence
Before critical-incident closeout:
1. Evaluate the deterministic preservation gate.
2. Create or update the linked AI LOG Incident.
3. Attach or link the native export when available; otherwise write the compact evidence bundle.
4. Re-read and verify the incident record and referenced artifacts.
5. Only then complete packet reconciliation, pause signaling, and incident handoff.
### Preservation failure
When neither a durable export nor a verified compact bundle can be preserved, Packet Runner must not represent the incident as reconciled. Cycle health remains FAILED, the affected boundary remains pause-required, Packet Output preserves the unresolved evidence gap, and the brief names the missing preservation requirement.
The system may still preserve whatever evidence is available in the provider session, but must explicitly state that durability is unverified.
### Redaction and minimization
Do not copy full sessions merely because export exists. Preserve only what is required for incident recovery, replay safety, auditability, or authority review. Exclude secrets, credentials, sensitive customer data, irrelevant prompts, and unrelated tool output. Use safe aliases and redacted excerpts.
### Resolution
An incident may move from Open to Resolved only after the preserved bundle is sufficient to explain the event, confirm the safe state, support remediation, and validate any required resume decision. Provider-session expiration after verified preservation does not reopen the incident.
## 8.19 AI LOG Resolution and Archival Contract
AI LOGS are an active incident-and-learning system, not a permanent operational inbox.
### Active states
An AI LOG record remains active while any of the following is true:
- The incident is Open, Investigating, Mitigated but unverified, or awaiting a resume decision.
- A recommendation, remediation, or owner action remains incomplete.
- The record contains evidence still required for replay safety, incident recovery, review, or auditability.
- The same failure pattern is recurring and has not yet been converted into a durable control or guidance update.
### Resolution or dismissal requirements
A record may be marked Resolved only when:
- The event and impact are understood sufficiently for the record's purpose.
- Safe state and remediation are verified.
- Required resume, review, or authority decisions are complete.
- Follow-up work is completed or represented by a linked packet with clear ownership.
- Reusable learning has either been promoted into a durable guidance source or explicitly classified as not reusable.
Set `Resolved At` when these conditions are met and set `Archive Eligible At` to 90 calendar days later.
A record may be marked Dismissed only when an authorized operator records why it is non-actionable and no active evidence dependency remains. Dismissed records use `Resolved At` as the closure timestamp and follow the same 90-day archive window. A critical incident cannot be dismissed until safe state is verified and the dismissal authority is recorded.
### Automated archival
During bounded routine maintenance, Packet Runner may archive due records only when they remain Resolved or Dismissed and no packet, incident, review, rollback, replay-safety analysis, or launch decision still depends on them.
Archival means setting Disposition to `Archived` or moving the record into the workspace's archive view. It does not mean permanent deletion or loss of links, evidence, relations, timestamps, or searchability.
### Learning promotion
Before archival, recurring or broadly useful learning must be moved into the appropriate durable source, such as:
- This PRD or another governing specification.
- Executor, orchestrator, or close-agent skill instructions.
- Packet templates, checklists, runbooks, acceptance tests, or provider configuration.
The AI LOG record links to the promoted source and records what changed. The historical incident may then archive after its normal window.
### Archival exceptions
Do not archive a record merely because 90 days elapsed when it remains unresolved, controlling evidence is still needed, a linked incident is reopened, or a production launch gate depends on its evidence.
Reopening a resolved record clears `Archive Eligible At` until it is resolved again.
### Cleanup behavior
Archival runs as bounded maintenance inside the normal routine. It does not create a separate scheduler, archive database, or deletion service. Archive failure leaves the record active and is reported only when repeated or operationally meaningful.
## 8.20 Production Qualification Quality Gate
Packet Runner v1 is production-qualified only after 20 consecutive clean scheduled cycles.
### Clean cycle
A cycle counts only when it was started by the configured provider schedule; preflight, queue discovery, execution when applicable, reconciliation, maintenance, brief delivery, and closeout completed; cycle health is HEALTHY; every started packet has trustworthy evidence and final state; and no unresolved anomaly remains.
Normal BLOCKED or REVIEW packet outcomes may occur inside a clean cycle when they are correctly classified, reconciled, and reported.
### Consecutive-window rules
- Twenty consecutive clean scheduled cycles are required.
- HEALTHY empty cycles may count, but the full window must include at least 10 executed packets.
- Any DEGRADED, FAILED, or observer-derived UNKNOWN cycle resets the streak to zero after reconciliation.
- Manual runs and simulations do not count toward the scheduled-cycle total.
- Paused, missed, or `NOT_STARTED_OVERLAP` scheduled occurrences do not advance the streak; an unexpected scheduled overlap breaks the streak.
### Required coverage
Inside the 20 scheduled cycles: at least one real BLOCKED path, at least one real REVIEW path, at least 10 executed packets, verified seven-day temporary-artifact cleanup, and correct scheduled operation of Output compaction, Source of Truth gating, stale-state hygiene, brief delivery, and selective AI LOG creation.
Linked pre-pilot integration evidence must prove critical-session export/fallback, self-pause, cancellation, permission denial, ambiguous worker handling, schema failure, and archival with a controlled clock.
At qualification there must be no duplicate execution, false DONE, review bypass, unexplained overwrite, unresolved critical incident, or other untrusted reconciliation.
### Qualification evidence document
Create one Notion document named `Packet Runner Qualification — <Project>` and store its page ID in routine configuration. During the scheduled pilot, append one compact row per scheduled cycle containing scheduled time, native execution reference, cycle health, candidate/started/final-status counts, brief-write status, maintenance status, qualifying packet links, and streak result. A non-clean cycle appends a reset marker with the reason.
This bounded rollout document is the authoritative streak record and is frozen after qualification. It is not queried for packet selection, does not control execution, and does not become a permanent RUNS database. Packet Output, provider sessions, briefs, artifacts, and AI LOGS remain the evidence behind each row.
### Qualification decision
After cycle 20, Isaiah or another explicitly authorized operator reviews the evidence document and underlying links and appends this exact decision block to the qualification document:
```plain text
QUALIFICATION DECISION
Decision: PRODUCTION_QUALIFIED
Operator: person
Evidence window: first and twentieth qualifying scheduled timestamps
PRD version: 1.0
Routine configuration version: string
Provider and routine: string
Schema and agent contract versions: string
Conditions: approved baseline and any restrictions
Timestamp: ISO-8601
```
Packet Runner does not approve its own production readiness.
### Expansion and requalification
After qualification, increase only one dimension at a time: packet cap, execution-risk class, project or repository count, or provider count. Before another dimension expands, the changed configuration must complete five consecutive HEALTHY scheduled cycles with at least three executed packets and no unresolved anomaly.
A provider change or material change to lifecycle, schema, receipt, permission, review, safety, or incident contracts invalidates the prior qualification and requires the full 20-cycle gate again. The qualification decision is revision-specific to the PRD, routine configuration, provider, schemas, and executor/orchestrator/close-agent versions recorded in the evidence document.
## 8.21 Repository execution and code-delivery contract
Repository-changing work must remain recoverable and must not confuse a temporary execution artifact with a completed durable result.
### Repository invariants
- Never modify the canonical default branch directly in unattended v1 execution.
- Use a provider-isolated clone or worktree and one packet branch named `packet/<PKT-ID>-<short-slug>` when Git changes are required.
- Before editing, record repository identity, default branch, starting commit, working-tree status, and any pre-existing changes.
- Unexplained changes or an unexpected remote/default branch make repository state untrusted; start no material work.
- Before returning a code-change receipt, create a local commit containing only attributable packet work and record the commit hash and diff summary. If the provider workspace is not guaranteed to persist through the seven-day recovery window, also export a portable patch/commit bundle to an approved durable location and classify it as evidence.
### Delivery classification
- A local commit, temporary branch, patch bundle, or unmerged pull request is an evidence/review artifact, not Source of Truth. A local branch by itself is not considered preserved unless provider workspace persistence is explicitly guaranteed.
- Code-changing packets default to REVIEW-FIRST.
- Push or pull-request creation requires an explicit declared capability and approved policy. Merge, release, tag, or deployment remains review-gated or manual under §8.9.
- A code packet may reach DONE only after the durable canonical repository state exists and Source of Truth points to the merged PR, canonical commit, release, or stable repository path.
- APPROVE_COMPLETION cannot bypass missing canonical repository state; approval of a diff may instead authorize continuation to create or merge the durable artifact under the appropriate review boundary.
### Preservation and cleanup
Preserve the branch, commit, diff, and verification evidence while REVIEW, BLOCKED, incident recovery, rollback, or successor work depends on them. Closed and superseded temporary branches follow the seven-day cleanup contract only after useful commits are preserved elsewhere or intentionally abandoned.
# 9. Failure, Retry, and Recovery Policy
> Retry the smallest operation whose failure is understood. Do not repeat a whole packet when its side effects are uncertain.
## Tool-operation retry
A transient Notion, registry, filesystem-read, provider, or network operation may be retried once after the target is re-read and the intended action is confirmed still necessary. Respect provider retry guidance when available.
Do not retry permission denial, invalid schema, malformed arguments, missing credentials, merge conflicts, failed verification, approval gates, ambiguous destructive operations, or deterministic repeated failures.
## Worker-dispatch retry
Retry dispatch once only when the provider proves that no worker or native execution session was created. If a worker may have started, the state is ambiguous: do not dispatch a duplicate. Move the packet to REVIEW if Packet Runner still controls state and include all available execution references.
## Whole-packet retry
Packet Runner never automatically retries a whole packet across cycles. A new attempt is authorized when Isaiah or an approved upstream process deliberately returns the packet to QUEUE after reviewing the prior Output and live target state.
A packet may be repeated without human requeue only when executor proves that no consequential work began, the prior attempt was fully rolled back, the operation is demonstrably safe to repeat, or the goal is already satisfied and only verification is performed. The controlling replay rules are defined in §8.8.
## Failure-state mapping
- Infrastructure failure before worker start: leave or restore QUEUE when no packet-specific prerequisite is missing; record the infrastructure blocker in the brief and do not repeatedly attempt the same packet within the cycle.
- Controlled executor outcome BLOCKED with a concrete prerequisite and exact unblock condition: persist the receipt and move FOCUS → BLOCKED.
- Controlled executor outcome REVIEW_REQUIRED, PARTIAL_SAFE, or FAILED_SAFE: persist the receipt and move FOCUS → REVIEW.
- Ambiguous worker failure or missing receipt after possible execution: move FOCUS → REVIEW, preserve execution references and repository state, and never launch a duplicate worker automatically.
- Routine crash that leaves FOCUS: the next cycle reports the stale FOCUS packet but does not reclaim or resume it automatically.
# 10. Implementation Plan and Deliverables
## Phase 0 · Reconcile upstream contracts
- [ ] Update executor to a Packet Runner-compatible revision: remove mandatory Run ID, claim, lease, heartbeat, and controller budget fields; accept best-effort FOCUS acquisition evidence plus the observed last-edited timestamp; compare material contract changes; classify FIRST_RUN, ALREADY_SATISFIED, SAFE_RESUME, or UNSAFE_AMBIGUOUS; return packet-runner-receipt-v1; forbid worker AI LOG and full close-agent behavior; align status mapping with this PRD.
- [ ] Update orchestrator so QUEUE is a freshness-bounded readiness certificate, known unmet prerequisites produce BLOCKED rather than QUEUE, Execution Class is explicit, new packets contain the reserved managed Output section, Packet Runner packets are authored to this PRD, and routine telemetry is selective rather than universally drained.
- [ ] Refactor close-agent into interactive, executor-worker, and Packet Runner cycle modes. Worker mode performs no second full closeout; cycle mode aggregates receipts and creates selective learning records.
- [ ] Apply the full PACKETS target schema in §8.1: add Execution Class, Lifecycle Checked At, Priority, Execution Window, Last Execution URL, Last Executed At, and Cleanup Eligible At with the specified types; verify existing Packet Output, Source of Truth, relations, and Agent Type; update registry bindings; and fail closed until schema validation passes.
- [ ] Add the managed `## Packet Runner Output` structure to existing nonterminal packets and migrate legacy Output into the property index plus Current Canonical Result, Artifact Manifest, and Exceptional History without losing controlling evidence.
- [ ] Migrate PACKETS Status and fromStatus options to BACKLOG, QUEUE, FOCUS, BLOCKED, REVIEW, DONE, and CANCELED; map Decline → CANCELED, normalize casing, audit existing records, and update formulas, views, automations, registry bindings, and skill instructions before deleting legacy options.
- [ ] Define the primary routine's core capability profile, restricted capabilities, prohibited unattended actions, safe connection aliases, redaction rules, and permission preflight checks. Verify no credential value can be emitted into Packet Output, receipts, AI LOGS, briefs, repository files, or native artifacts.
- [ ] Update orchestrator and executor to author and enforce Required Capabilities and Prohibited Actions only when nonstandard access is needed; add BLOCKED versus REVIEW permission-failure classification and prohibit credential self-repair or privilege escalation.
- [ ] Update orchestrator, executor, close-agent, and any status-transition workflow to generate the structured review request, validate reviewer authority, parse the exact `PACKET DECISION` comment, append the decision receipt to Exceptional History, enforce revision-specific approval, and prevent timeout-based inference.
- [ ] Create or designate one canonical `Packet Runner Brief — <Project>` document per pilot routine; store its page reference in routine or project configuration; implement attention-first overwrite, empty-cycle health output, native completion linking, redaction, and non-rollback behavior when brief writing fails.
- [ ] Implement cycle-health derivation with HEALTHY, DEGRADED, and FAILED outputs; use the native provider execution as the correlation reference; distinguish packet outcomes from controller health; record UNKNOWN only as an operator inference; enforce AI LOG incident thresholds; and verify that no observability database, heartbeat, dashboard, or watchdog is introduced for the pilot.
- [ ] Implement the bounded self-recovery ladder, proof-before-resume checks, packet/routine/shared-system containment, critical-incident halt behavior, pause-required signaling, evidence preservation, and resume checklist. Verify recovery can repair reversible local execution state without altering credentials, permissions, review authority, or ambiguous external effects.
- [ ] Implement session-local adaptation bounds and recording, persistent-change review gates, provider pause confirmation, operator-only re-enablement, later-cycle activation for self-modifying patches, and persistent change receipts. Verify Packet Runner cannot alter schedule, cycle cap, defaults, governance, scope, credentials, or permissions during an active invocation.
- [ ] Add `Lifecycle Checked At`, audit and stamp all existing packets after confirming current state, update it on every lifecycle transition or explicit revalidation, and implement the global 7-day QUEUE, 4-hour FOCUS, 7-day BLOCKED, and 7-day REVIEW stale-state rules without age-based automatic cancellation, approval, requeue, completion, or execution.
- [ ] Migrate existing Packet Output into `Current Canonical Result`, `Artifact Manifest`, and `Exceptional History`; compact routine clean-attempt detail; preserve unresolved incidents, ambiguity, controlling decisions, rollback/recovery events, replay-safety evidence, and cancellation context; and test that a failed compaction cannot erase the last trustworthy Output.
- [ ] Implement the conditional Source of Truth requirement test, valid-reference verification, `not applicable` Output rationale, DONE gating, and supersession updates. Audit existing DONE packets and repair missing, temporary, stale, or placeholder references only where a durable authoritative result exists.
- [ ] Add artifact retention classes to receipts and Packet Output; set and clear `Cleanup Eligible At`; implement bounded automated cleanup after the global seven-day recovery window; protect Source of Truth, review, incident, rollback, replay, approval, cancellation, and successor-packet evidence; verify cleanup; and preserve terminal status on cleanup failure.
- [ ] Implement the deterministic critical-session preservation gate, provider-export detection, compact AI LOG incident bundle, evidence re-read and verification, unresolved-preservation failure behavior, redaction, and incident-resolution checks. Verify normal sessions are not redundantly exported.
- [ ] Apply the full AI LOGS target schema and managed body sections in §8.7; implement critical evidence bundles, resolution checks, the global 90-day archive window, automatic archival, reopening behavior, learning-promotion links, archival protection gates, and archive-failure handling without permanent deletion.
- [ ] Migrate legacy AI LOG values and fields toward the target options and properties while preserving historical compatibility; review legacy Accepted records individually before mapping them to Investigating or Resolved.
## Phase 1 · Complete registry foundation
- [ ] Implement packet registry fetch with body plus curated one-hop relation hydration and warning/provenance envelope.
- [ ] Add or verify registry projections for packet, project, skill, blocker packet, event, and AI LOG creation/update.
- [ ] Add tests for missing relations, inaccessible relations, stale cache refresh, no recursive hydration, and explicit deeper body fetch.
## Phase 2 · Build the primary-provider routine
- [ ] Evaluate candidate providers against the nine-capability matrix in §8.5A and document evidence for non-overlap enforcement, repository isolation, worker/inline execution, registry/MCP access, native execution references, failure signaling, current-routine pause/disable, session export or fallback, and native completion notification. Select one qualifying provider.
- [ ] Create the canonical brief, qualification-evidence document, and durable evidence destination; then implement configuration validation, capability preflight, project-scoped QUEUE query, hydration, eligibility filtering, ordering, cycle cap, final live check, QUEUE→FOCUS transition, dispatch, receipt verification, packet reconciliation, bounded maintenance, brief/notification, and qualification-row update.
- [ ] Keep provider-specific mechanics inside the minimal capability/configuration layer; keep lifecycle, eligibility, receipt, and status handling provider-neutral.
## Phase 3 · Acceptance validation
- [ ] Automate deterministic schema, serialization, filtering, ordering, lifecycle, receipt-mapping, redaction, compaction, cleanup, archival, and qualification-evidence tests.
- [ ] Run provider integration scenarios with max_packets_per_cycle = 1 and no unattended schedule, including overlap prevention, repository isolation, session references, notification, pause control, and export/fallback behavior.
- [ ] Manually validate governance scenarios that require human authority: REVIEW decisions, cancellation, permission boundaries, production boundaries, and operator re-enablement.
- [ ] Store evidence for every applicable acceptance test and resolve every unsafe, ambiguous, duplicate, status-drift, or unverifiable-receipt defect before scheduled pilot.
## Phase 4 · Scheduled pilot and production qualification
- [ ] Enable one nightly provider-native schedule for one repository/project with max_packets_per_cycle = 1.
- [ ] Complete 20 consecutive clean scheduled cycles under §8.20, including at least 10 executed packets and the required BLOCKED, REVIEW, cleanup, preservation, and reconciliation coverage.
- [ ] Have Isaiah or another explicitly authorized operator review the evidence and record `PRODUCTION_QUALIFIED`.
- [ ] After qualification, expand only one dimension at a time: packet cap, execution-risk class, project/repository count, or provider count. Collect fresh validation evidence before the next expansion.
- [ ] Defer a second provider until the first implementation is production-qualified; compare actual capability differences before extracting formal adapters.
## Required deliverables
- Packet Runner routine/configuration and any repository-local implementation files.
- Updated executor, orchestrator, and close-agent contracts with version notes and migration rationale.
- Registry hydration implementation, registry bindings, and automated tests.
- AI LOGS migration plan and compatibility evidence.
- Version-controlled routine configuration with the provider capability matrix and safe aliases.
- Canonical brief and qualification-evidence documents.
- Acceptance-test evidence, pilot configuration, operator brief examples, known limitations, hardening backlog, and the frozen 20-cycle production-qualification evidence bundle.
# 11. Acceptance Matrix
Each scenario requires durable evidence appropriate to its layer: automated test output for deterministic contracts; provider session and repository evidence for integrations; durable human decision records for governance; and qualification-document entries for scheduled-pilot tests. Packet property changes, the managed Packet Output record, live target verification, native execution references, and the resulting brief are required whenever applicable. T94–T98 can be satisfied only by the real scheduled pilot, not simulation.
### T1 · Empty queue
Given no project-scoped QUEUE packets, the cycle performs no execution, changes no packet status, and produces a brief stating that no eligible work was found.
### T2 · Qualified AUTO packet
Runner selects one eligible packet, sets FOCUS, dispatches one executor, verifies COMPLETED evidence, writes Output and native execution link, then sets DONE.
### T3 · REVIEW-FIRST packet
Executor produces and verifies the authorized artifact, returns REVIEW_REQUIRED, and the packet ends in REVIEW with the exact decision and review artifact.
### T4 · MANUAL packet
Runner does not execute or mutate the packet and includes it only when relevant to the brief.
### T5 · Deterministic blocker
A QUEUE or FOCUS packet has a concrete unmet prerequisite and a known unblock condition. It moves to BLOCKED, records the blocker, responsible party or system, last checked time, safe state, and unblock condition, and is not executed again until returned to QUEUE.
### T6 · Stale or conflicting FOCUS
Runner does not reclaim, resume, or duplicate work. The brief surfaces the packet, likely owner/collision evidence, and required human resolution.
### T7 · Dispatch fails before worker creation
Runner confirms no native session exists, retries dispatch once, and restores or leaves QUEUE if the retry fails. No duplicate worker is created.
### T8 · Ambiguous worker failure
When a worker may have started but no trustworthy receipt returns, the packet moves to REVIEW, all available execution and repository evidence is preserved, and no automatic redispatch occurs.
### T9 · Transient tool failure
The smallest failed operation is retried once after target refresh. The packet itself is not restarted.
### T10 · Receipt mismatch
If receipt claims do not match Packet Output, referenced artifacts, or live state, DONE is blocked and the packet moves to REVIEW with mismatch evidence.
### T11 · Cycle cap
With several eligible packets and max_packets_per_cycle = 1, exactly one packet starts. Remaining packets stay QUEUE.
### T12 · Newly unblocked packet
After one packet completes, a queue refresh may detect newly eligible work but must respect the cap, remaining runtime, and sequential-execution rule.
### T13 · Selective telemetry
A clean cycle creates no empty AI LOG. A cycle with a meaningful incident or reusable pattern creates an actionable signal record linked to the affected packet/skill and source execution.
### T14 · Provider capability missing
If required registry access, isolation, model, or failure signaling is unavailable, the cycle fails safely before packet execution and explains the unmet capability.
### T15 · Missed schedule
The next successful invocation reads current QUEUE state. It does not replay an old candidate list or launch multiple catch-up cycles.
### T16 · Already satisfied
Executor proves the observable goal is already true, performs the required verification, makes no duplicate change, and returns ALREADY_SATISFIED.
### T17 · Safe resume
Executor identifies conclusive partial state, proves completed and remaining work, continues without repeating consequential effects, and returns SAFE_RESUME evidence in the receipt.
### T18 · Material packet change after selection
The packet changes after FOCUS. Executor detects the timestamp mismatch, compares the execution-critical contract, and stops in REVIEW when a material field or section changed.
### T19 · Ambiguous external side effect
Prior Output or external state cannot prove whether a send, publish, migration, deployment, payment, deletion, or similar effect occurred. Executor returns UNSAFE_AMBIGUOUS, performs no repeat action, and the packet ends in REVIEW.
### T20 · Ambiguous blocker
A dependency or prerequisite appears unresolved, but its validity, owner, or resolution path cannot be proven. Packet Runner does not label it BLOCKED; it moves the packet to REVIEW with the ambiguity and evidence.
### T21 · Canceled mission
An authorized human cancels an abandoned or superseded packet. It is never selected again, its reason and replacement packet or decision are recorded when applicable, and no automation treats CANCELED as successful completion.
### T22 · Core repository capability
A REVIEW-FIRST code packet edits and verifies code inside the isolated repository, creates an attributable local commit, durably exports a patch bundle when workspace persistence is not guaranteed, and ends in REVIEW with the branch, commit, diff, bundle, and verification evidence. It does not deploy, publish, push, merge, or use unrelated connected services unless the packet and approved policy explicitly authorize the next step.
### T23 · Known missing scoped permission
Executor completes safe local work but discovers that `github:primary` lacks pull-request write access. It preserves the branch and commit or exports a durable patch bundle, records the safe alias and exact missing scope without exposing a secret, and moves the packet to BLOCKED.
### T24 · Excessive privilege request
A read-only task appears to require administrator access. Executor does not request, grant, or use the broader access; it moves the packet to REVIEW with the narrower alternatives and risk change explained.
### T25 · Production boundary
A REVIEW-FIRST migration packet produces tested code, a dry run, rollback evidence, and an affected-record count. It performs no production migration and ends in REVIEW with the exact approval required.
### T26 · Prohibited external send
A packet prepares client communications but does not send them. Drafts and verification are delivered as review artifacts; no external recipient is contacted.
### T27 · Secret redaction
A tool error contains credential-bearing or sensitive data. Receipt, Output, logs, and brief retain only the safe alias, error class, missing scope, and redacted remediation evidence. No secret or customer data is persisted.
### T28 · Structured review request
A packet entering REVIEW contains the review reason, completed and remaining work, evidence links, exact decision, available outcomes, consequences, safe state, recommendation when appropriate, and designated reviewer.
### T29 · Approve completion
The authorized reviewer records APPROVE_COMPLETION for the exact reviewed artifact. The decision receipt is appended to Exceptional History and REVIEW transitions to DONE without another executor run only when verification remains valid and Source of Truth exists when required.
### T30 · Authorize continuation
The authorized reviewer records AUTHORIZE_CONTINUATION with the exact approved action and conditions. The decision receipt is stored, REVIEW transitions to QUEUE, and the packet passes readiness and replay checks before another execution.
### T31 · Request changes
The reviewer records REQUEST_CHANGES with concrete instructions. The packet remains REVIEW and is not eligible until those instructions become an executable contract.
### T32 · Material change invalidates approval
After approval, the packet contract, consequential command, affected records, requested permission, or review artifact changes materially. The prior approval is rejected and the packet remains or returns to REVIEW.
### T33 · Invalid approval signal
A reaction, casual “looks good” comment, artifact edit, silence, or comment from a person outside the declared authority scope does not produce DONE or QUEUE.
### T34 · No review timeout
A REVIEW packet remains unresolved after an extended period. It is resurfaced in the brief but is not auto-approved, requeued, completed, or canceled.
### T35 · Canonical latest brief
Two successful cycles run for the same project. The second cycle replaces the same canonical brief document; no additional brief page or database row is created.
### T36 · Attention-first ordering
A cycle contains completed, blocked, and review-required packets. The brief presents decisions first, then completed work, blockers, failures or ambiguity, skipped items, learning, and cycle metadata regardless of execution order.
### T37 · Healthy empty cycle
No packet is eligible. The canonical brief is still updated with no eligible work, BLOCKED, REVIEW, and stale FOCUS counts, queue-hygiene observations, and infrastructure health.
### T38 · Native completion notification
The selected provider's native completion surface reliably links to the canonical brief. A provider lacking this capability is rejected for v1; no custom email, Slack, SMS, or parallel notification service is created.
### T39 · Brief-write failure
Packet execution and per-packet Output succeed, but the aggregate brief write fails. Packet outcomes remain unchanged, the provider session records the failure, no historical backfill page is created automatically, and an AI LOG is created only when the failure is meaningful or recurring.
### T40 · Brief redaction and concision
The brief contains actionable outcomes and links without full receipts, transcripts, raw stack traces, extensive test output, secrets, or unnecessary customer data.
### T41 · Healthy cycle with attention outcomes
A cycle completes cleanly while one packet ends BLOCKED and another ends REVIEW. All outcomes are correctly reconciled, the brief is written, and cycle health is HEALTHY because normal business outcomes do not indicate controller degradation.
### T42 · Degraded but trustworthy cycle
A bounded retry or queue-hygiene defect occurs, or the brief write fails after packet outcomes are safely persisted. Packet outcomes remain trustworthy, the provider session records the anomaly, and cycle health is DEGRADED.
### T43 · Failed controller state
The registry, repository isolation, ownership, packet writes, or worker reconciliation fails in a way that leaves selected packet outcomes untrusted or creates a safety or authorization incident. Cycle health is FAILED and the applicable pause policy is triggered.
### T44 · Observer-derived unknown cycle
An expected schedule has no reliable provider execution record and the canonical brief did not advance. Packet Runner has not emitted an UNKNOWN result; the operator classifies the expected cycle as UNKNOWN during diagnosis.
### T45 · Native execution correlation
The brief and packet Output link to the native provider execution reference. No separate cycle ID, run row, or monitoring record is created.
### T46 · AI LOG threshold
A normal BLOCKED packet, expected REVIEW outcome, empty queue, and recovered one-time retry create no AI LOG. A duplicate execution, review bypass, secret exposure, false DONE, recurring provider failure, or receipt/live-state mismatch creates a selective incident record.
### T47 · No observability control plane
The pilot exposes trustworthy health through PACKETS, the latest brief, native provider sessions, and selective AI LOGS without a cycle database, heartbeat, custom dashboard, per-tool event log, or watchdog.
### T48 · Reversible local self-recovery
A disposable worktree, local branch, generated artifact, or executor-authored implementation fails. The executor diagnoses and repairs it within existing authority, proves no duplicate or unsafe side effect occurred, reruns verification, and resumes without human escalation.
### T49 · Approved fallback tool
A preferred tool is unavailable, but another already authorized tool can perform the same scoped action. Executor switches tools, records the adaptation, and proceeds without expanding permissions or changing the packet contract.
### T50 · Authority-expanding recovery denied
Recovery would require broader permissions, a new credential, security-control changes, review bypass, or another identity. Executor does not self-unblock; it records the exact requirement and moves to BLOCKED or REVIEW according to the permission contract.
### T51 · Ambiguous irreversible effect
The agent cannot prove whether an external send, payment, publish, deployment, migration, or deletion occurred. It performs no repeat action, moves the packet to REVIEW, halts new work within the affected boundary, and records pause-required status.
### T52 · Narrowest-boundary containment
A conclusively packet-local failure does not stop a separate repository routine. A shared registry, executor, provider-dispatch, identity, or lifecycle defect marks every dependent routine pause-required.
### T53 · Pause and resume evidence
A critical incident records the boundary, reason, evidence, safe state, affected packets, and resume checklist. Resumption does not occur until state is reconciled, remediation is validated, relevant tests pass, residual risk is documented, and required operator authorization is recorded.
### T54 · Session-local model adaptation
The preferred model is unavailable or unsuitable. Packet Runner selects another model from the approved allowlist for the current invocation, records the change, and does not alter the persistent default.
### T55 · Bounded timeout and tool adaptation
Executor changes timeout, retry delay, tool choice, execution mode, or branch strategy within configured bounds. Scope, authority, review, and verification remain unchanged.
### T56 · Persistent configuration change gated
A recurring issue suggests changing schedule, cycle cap, default model, timeout ceiling, retry policy, routine instructions, or repository scope. Packet Runner proposes the change and evidence in REVIEW but does not persist it during the active invocation.
### T57 · Autonomous incident pause
A critical incident requires routine containment. Packet Runner pauses only the affected routine, receives provider confirmation, records before/after state and resume requirements, and starts no further packets inside that boundary.
### T58 · No autonomous re-enable
A paused routine has been repaired. Packet Runner does not re-enable it; an explicitly authorized operator must record the decision after the resume checklist passes.
### T59 · Self-modifying patch isolation
A packet authorizes changes to Packet Runner code, configuration, or governing skills. The current invocation produces a validated review artifact but continues using its original governing rules; approved changes activate no earlier than a later cycle.
### T60 · Persistent change receipt
An approved persistent configuration change records before/after values, reason, risk, validation evidence, rollback, reviewer, and effective time without creating a separate configuration-history database.
### T61 · Stale QUEUE recertification
A QUEUE packet reaches 7 days since `Lifecycle Checked At`. Packet Runner skips execution, leaves it QUEUE, reports `Readiness refresh required`, and executes it only after autonomy, dependency, and capability checks are rerun and the lifecycle timestamp is refreshed.
### T62 · Stale FOCUS with active ownership
A FOCUS packet exceeds 4 hours, but the provider proves an active execution session and repository ownership. Packet Runner does not reclaim, duplicate, or change the packet and reports the active owner.
### T63 · Stale FOCUS without trustworthy ownership
A FOCUS packet exceeds 4 hours and active ownership cannot be proven. Packet Runner performs no redispatch, preserves evidence, and moves the packet to REVIEW; cycle health reflects whether resulting state is trustworthy.
### T64 · Stale BLOCKED and REVIEW
BLOCKED and REVIEW packets exceed 7 days. They remain in their existing statuses and are prominently resurfaced with the unblock condition or outstanding decision. No automatic requeue, approval, completion, or cancellation occurs.
### T65 · Lifecycle-clock integrity
Comments and ordinary page edits do not refresh `Lifecycle Checked At`. Authorized lifecycle transitions and explicit state revalidation do. Existing records receive an audit timestamp rather than an inferred historical transition date.
### T66 · Canonical-result replacement
A clean later attempt supersedes an earlier clean attempt. Packet Output rewrites `Current Canonical Result` and does not append a duplicate full receipt or repeated test evidence.
### T67 · Exceptional-history preservation
A packet experiences an ambiguous external effect, critical incident, approval, cancellation, rollback, or safe-resume event. A compact timestamped exceptional entry remains after later clean execution.
### T68 · Replay-safety preservation
Compaction is attempted, but prior evidence is still required to determine whether continuation is safe. The evidence remains in Packet Output and is not replaced by a cleaner but incomplete summary.
### T69 · Output redaction and deduplication
Packet Output excludes full transcripts, raw logs, repeated test output, superseded summaries, duplicate Git evidence, and secret-bearing payloads while preserving actionable links and redacted incident facts.
### T70 · Failed compaction safety
A compaction or Output rewrite fails validation. Packet Runner preserves the previous trustworthy Output, blocks a false clean replacement, and moves the packet to REVIEW when current state cannot be safely reconciled.
### T71 · Durable artifact requires Source of Truth
A packet creates or materially changes a durable artifact. DONE is blocked until Source of Truth resolves to the current canonical artifact or live target.
### T72 · Verified existing durable state
Executor returns ALREADY_SATISFIED for an existing durable target. Source of Truth points to that authoritative target rather than the provider session or verification evidence.
### T73 · Ephemeral analysis needs no Source of Truth
A research, diagnosis, recommendation, or ephemeral analysis packet completes with its final result in Packet Output. Source of Truth remains empty and Output records `not applicable` with the reason.
### T74 · Invalid placeholder rejected
Source of Truth points to the brief, provider session, packet page, temporary branch, draft, screenshot, or raw log. Packet Runner rejects the placeholder and prevents DONE when a durable authoritative result is required.
### T75 · Source of Truth supersession
The canonical artifact moves or is replaced. Source of Truth updates to the new authoritative target while relevant supersession context remains compactly preserved in Exceptional History.
### T76 · Seven-day temporary-artifact window
A packet reaches DONE or CANCELED with temporary artifacts. `Cleanup Eligible At` is set seven days after the terminal transition, and no cleanup occurs before that time.
### T77 · Automated cleanup after eligibility
The recovery window expires, all protection gates pass, and Packet Runner automatically removes or archives temporary worktrees, branches, scratch files, previews, uploads, or drafts, verifies the result, records a concise cleanup receipt, and clears `Cleanup Eligible At`.
### T78 · Protected artifact preserved
A candidate is Source of Truth, active review evidence, incident evidence, rollback/replay material, controlling approval or cancellation evidence, or required by a successor packet. Packet Runner does not delete it and records the preservation reason.
### T79 · Reopened terminal packet cancels cleanup
A DONE or CANCELED packet leaves terminal state before cleanup. `Cleanup Eligible At` is cleared and all artifacts remain available until a later terminal transition creates a new recovery window.
### T80 · Cleanup failure preserves outcome
Automated cleanup fails or becomes ambiguous. DONE or CANCELED remains unchanged, the candidate and error are reported, `Cleanup Eligible At` remains set, and no unsafe repeated deletion occurs.
### T81 · No cleanup control plane
Automated cleanup runs as bounded routine maintenance without a separate schedule, artifact database, cleanup ledger, or mission-cycle slot.
### T82 · Normal session remains native-only
A HEALTHY execution completes without incident. Packet Output and the brief retain the native execution link, but no session export or duplicate incident archive is created.
### T83 · Provider-supported critical export
A critical incident occurs and the provider supports session export. Packet Runner preserves the export in an approved durable location, links it from the AI LOG Incident, verifies access, and keeps the routine pause-required until incident reconciliation is complete.
### T84 · Compact bundle fallback
A critical or ambiguous execution requires preservation, but the provider offers no durable export. Packet Runner creates a verified, redacted AI LOG incident bundle containing all required independently verifiable evidence.
### T85 · Preservation failure remains unresolved
Neither export nor compact bundle can be verified. Cycle health remains FAILED, the affected boundary remains pause-required, Packet Output records the evidence gap, and the incident cannot be marked Resolved.
### T86 · Preservation redaction
A provider session contains secrets, customer data, unrelated prompts, or excessive tool output. The preserved evidence excludes sensitive and irrelevant content while retaining what is required for incident recovery and replay safety.
### T87 · Resolution requires sufficient evidence
An incident cannot transition to Resolved until the durable bundle explains the event, confirms safe state, supports remediation, and validates any resume decision.
### T88 · Closed record receives archive date
An AI LOG record satisfies all resolution requirements, or an authorized operator validly dismisses a non-actionable record. `Resolved At` is set as the closure timestamp and `Archive Eligible At` is set exactly 90 calendar days later.
### T89 · Open record never auto-archives
An unresolved, reopened, or still-actionable record passes 90 days since creation. It remains active because archival is based on verified resolution, not age alone.
### T90 · Reusable learning promoted before archive
A resolved record contains a recurring or broadly useful lesson. Before archival, the lesson is incorporated into a governing PRD, skill, runbook, template, checklist, acceptance test, or provider configuration, and the AI LOG links to that durable source.
### T91 · Automated archival preserves searchability
A resolved record reaches `Archive Eligible At`, no protection gate remains, and Packet Runner automatically marks it Archived without deleting its evidence, links, relations, or timestamps.
### T92 · Reopened record cancels archival
A resolved record is reopened before or after becoming archive-eligible. `Archive Eligible At` is cleared until the record is resolved again.
### T93 · Archive protection gate
A resolved record is still required by an active incident, packet, review, rollback, replay-safety analysis, or launch decision. Packet Runner preserves it as active and records the dependency.
### T94 · Twenty-cycle clean streak
Twenty provider-scheduled cycles complete with HEALTHY status and the full controller path intact. The qualification streak reaches 20 and the supporting evidence is reviewable.
### T95 · Empty cycles cannot satisfy volume alone
Some clean cycles contain no eligible work. They may count toward continuity, but production qualification remains blocked until at least 10 packets have actually executed within the evidence window.
### T96 · Non-clean cycle resets qualification
A DEGRADED, FAILED, or observer-derived UNKNOWN cycle occurs during the streak. The streak resets to zero after the issue is reconciled; the cycle is not waived into the clean count.
### T97 · Qualification coverage
The 20-cycle window includes a correctly handled real BLOCKED path, real REVIEW path, at least 10 executed packets, delayed temporary-artifact cleanup, Output compaction, Source of Truth gating, stale-state hygiene, brief delivery, and selective AI LOG behavior. Linked pre-pilot evidence covers critical-session preservation and other failure paths.
### T98 · Operator qualification and controlled expansion
After the twentieth clean cycle, an authorized operator reviews the evidence and writes the exact `QUALIFICATION DECISION` block with the approved PRD, configuration, provider, schema, and agent versions. Packet Runner does not self-approve, and only one capacity or risk dimension is expanded at a time.
### T99 · Routine overlap prevention
A scheduled invocation is active when another schedule or manual Run Now attempts to start. The provider guard permits only one cycle; the second invocation records `NOT_STARTED_OVERLAP`, starts no packet, and does not overwrite the active cycle or brief. If overlap cannot be proven absent after an invocation begins, that invocation is FAILED.
### T100 · Target-schema preflight and migration
The live PACKETS or AI LOGS schema lacks a required property, target option, or supported type. Packet Runner fails before packet mutation. The migration adds and audits target fields, preserves legacy compatibility until tests pass, and removes no legacy value while referenced.
### T101 · Coupled lifecycle write
A lifecycle transition updates Status, `Lifecycle Checked At`, and compatibility `fromStatus` in one logical write and verifies all fields. A partial or contradictory result is not treated as successful acquisition or completion.
### T102 · Execution-window semantics
A packet before its window remains QUEUE; a packet inside its window may execute; an expired window moves to REVIEW. Time interpretation uses the embedded timezone or the configured routine timezone.
### T103 · Two-layer Packet Output
A packet completes with evidence exceeding the compact-property budget. The complete structured result is written to the managed page-body section, the property remains at or below 1,800 visible characters, and both are verified to agree.
### T104 · Durable repository delivery
A code-changing packet creates a local commit and review artifact but no canonical repository change. If workspace persistence is not guaranteed, it exports a durable patch bundle. It ends in REVIEW, not DONE, and the local branch, patch bundle, or unmerged PR is rejected as Source of Truth. DONE becomes available only after canonical durable state exists.
### T105 · Cancellation receipt
An authorized actor cancels a packet. Exceptional History records authority, reason, prior status, safe state, external effects, artifact disposition, replacement packet when applicable, and cleanup timing. Missing authority or ambiguous effects produce REVIEW instead.
### T106 · Provider and configuration validation
The routine configuration is complete, versioned, uses safe aliases, prevents overlap, and points to accessible project, repository, brief, qualification document, and durable evidence destination. A provider missing any required capability other than session export is rejected.
### T107 · Maintenance ordering and budget
Due cleanup and archival run after packet reconciliation and before the brief, within 10 items and 120 seconds. Remaining maintenance is reported without delaying or falsifying cycle closeout. The qualification row is written separately after brief and notification results are known.
### T108 · Qualification evidence document
Each real scheduled pilot cycle appends one compact, linked qualification row. A non-clean or undocumented cycle appends a reset marker or breaks the streak. The document is frozen after operator qualification and is never used for runtime packet selection.
### T109 · Controlled expansion and requalification
One post-qualification dimension changes and completes five consecutive HEALTHY scheduled cycles with at least three executed packets before another expansion. A provider or material lifecycle/schema/receipt/permission/review/safety/incident-contract change requires the full 20-cycle qualification again.
### T110 · Invalid dependency graph
A packet has a self-dependency, dependency cycle, canceled prerequisite, inaccessible blocker, or contradictory graph. Packet Runner performs no execution and moves the affected packet to REVIEW with graph evidence.
### T111 · Corrective terminal reopen
An authorized operator discovers a false DONE or invalid CANCELED state. The packet reopens only to REVIEW, cleanup eligibility is cleared, evidence is preserved, and a materially changed mission is created as a new packet rather than reopened directly to QUEUE.
### T112 · Reconciliation write integrity
The managed Output body writes successfully but the coupled property/status update is partial or unverifiable. Packet Runner does not report DONE, preserves the prior trustworthy record, performs only the bounded safe retry, and classifies the cycle FAILED when state remains inconsistent.
### T113 · Exact decision syntax
A review comment omits the `PACKET DECISION` first line or a required labeled field. It is ignored as approval. A complete authorized decision comment plus matching status transition produces the decision receipt.
### T114 · Ephemeral workspace artifact export
A code-changing worker runs in a workspace that will not persist for seven days. Before ending REVIEW or BLOCKED, it exports a durable patch/commit bundle under the configured evidence destination and verifies the link.
## Definition of Done for Packet Runner v1
- [ ] All Phase 0 contract conflicts are resolved and versioned.
- [ ] Registry hydration contract and tests pass.
- [ ] Acceptance tests T1–T114 pass with stored evidence.
- [ ] One scheduled pilot runs with max_packets_per_cycle = 1, writes the qualification evidence document, and completes 20 consecutive clean scheduled cycles under §8.20.
- [ ] The qualification window includes at least 10 executed packets and the required real BLOCKED, real REVIEW, delayed cleanup, brief, Output, Source of Truth, stale-state, and reconciliation coverage; pre-pilot evidence covers critical preservation and other failure paths.
- [ ] No duplicate execution, false DONE, review bypass, unexplained repository overwrite, unresolved critical incident, or untrusted reconciliation occurs in the qualification window.
- [ ] The final brief is sufficient for Isaiah to understand every outcome and required decision without opening raw provider logs.
- [ ] An explicitly authorized operator records `PRODUCTION_QUALIFIED` after reviewing the evidence.
# 12. Rollout, Operations, and Success Metrics
## Pilot safeguards
- One primary provider, one repository/project, one recurring trigger, and max_packets_per_cycle = 1.
- Manual Run Now validation precedes unattended scheduling.
- Provider pause/disable is the v1 kill switch. No separate Notion control plane is required.
- Any duplicate execution, unauthorized or unsafe action, false DONE, secret exposure, review bypass, inconsistent packet state, or unexplained repository overwrite halts new work within the narrowest boundary that fully contains the risk and records whether the routine or shared system is pause-required.
## Operational success metrics
- Production qualification streak: 20 consecutive HEALTHY scheduled cycles.
- Executed packets inside the qualification window: at least 10.
- Duplicate packet executions: 0.
- Unsafe or unauthorized side effects: 0.
- False DONE transitions: 0.
- Receipts verified against live state before final status: 100%.
- Every invocation that retains brief-write access updates the canonical brief; when brief writing fails, the native provider session records a DEGRADED or FAILED result with Packet Outputs preserved.
- Empty or non-actionable AI LOG creation rate: 0 after migration.
- Isaiah can identify every required review or decision from the brief without opening raw execution logs.
# 13. Final Production Gate
All product, lifecycle, governance, retention, and rollout decisions required for v1 are now defined. The remaining gate is execution evidence, not another architecture decision.
Packet Runner may be implemented and manually validated from this PRD. It becomes production-qualified only after satisfying §8.20 and the Definition of Done. Until then, keep the pilot at one provider, one project/repository, and max_packets_per_cycle = 1.
# 14. Implementation Agent Instructions
1. Treat this PRD as the current Packet Runner architecture. Where executor, orchestrator, close-agent, the source packet, or legacy telemetry rules conflict, this PRD governs Packet Runner integration until those assets are remediated.
2. Do not enable unattended scheduling by default. Complete contract remediation, schema and registry work, implementation, automated/provider/manual acceptance validation, and operator review first.
3. No v1 architecture decision remains open. Treat operator-supplied schedule time, provider credentials, safe aliases, and authorized identities as deployment inputs. If a required input or provider capability is unavailable, document it and leave unattended behavior disabled rather than redesigning the contract.
4. Keep changes minimal and testable. Prefer native provider capabilities over custom scheduling, session, credential, or logging infrastructure.
5. Return implementation files, changed Notion assets, test evidence, example briefs, known limitations, and the exact remaining gates for unattended rollout.
# 15. Revision Log
- 2026-06-24 · v1.0 — Final top-to-bottom implementation review. Added exact PACKETS and AI LOGS target schemas and migration defaults; two-layer Packet Output storage; coupled reconciliation writes; deterministic receipt/status mapping; routine configuration and nine-capability provider selection; non-overlap semantics; exact execution-window and ordering rules; exact `PACKET DECISION` syntax; dependency-cycle and corrective-reopen handling; durable code-review artifact export; qualification evidence storage, revision-specific sign-off, expansion/requalification rules; and acceptance tests T99–T114. Removed stale and contradictory language and closed all v1 architecture decisions.
- 2026-06-24 · v0.25 — Added the final production qualification gate: 20 consecutive clean scheduled cycles, at least 10 executed packets, required coverage paths, strict streak reset rules, operator sign-off, one-dimension-at-a-time expansion, implementation and rollout updates, and acceptance tests T94–T98.
- 2026-06-24 · v0.24 — Added AI LOG resolution and archival: resolution gates, `Resolved At`, global 90-day `Archive Eligible At`, automatic non-destructive archival, reopening and protection behavior, mandatory promotion of reusable learning, implementation work, and acceptance tests T88–T93.
- 2026-06-24 · v0.23 — Added critical-session evidence preservation: deterministic export gate, provider-native export when available, verified compact AI LOG fallback, enforcement sequence, unresolved-preservation failure behavior, redaction and minimization, incident-resolution requirements, implementation work, and acceptance tests T82–T87.
- 2026-06-24 · v0.22 — Added automated temporary-artifact retention and cleanup: canonical/evidence/temporary classes, queryable cleanup date, global seven-day recovery window, protection gates, bounded in-routine maintenance, verified cleanup receipts, failure handling, cancellation recovery, implementation work, and acceptance tests T76–T81.
- 2026-06-24 · v0.21 — Added the conditional Source of Truth contract: durable-result requirement test, valid and invalid reference rules, DONE gating, `not applicable` rationale, supersession handling, implementation work, and acceptance tests T71–T75.
- 2026-06-24 · v0.20 — Added Packet Output compaction: current canonical result plus exceptional history, preservation rules for incidents/ambiguity/decisions/recovery, exclusion of routine logs and duplicate evidence, compaction-safety requirements, migration work, and acceptance tests T66–T70.
- 2026-06-24 · v0.19 — Added global stale-state defaults and lifecycle clock: one `Lifecycle Checked At` field, 7-day QUEUE recertification, 4-hour FOCUS investigation, 7-day BLOCKED/REVIEW resurfacing, no age-based lifecycle mutation, one-time state audit, implementation work, and acceptance tests T61–T65.
- 2026-06-24 · v0.18 — Added workflow self-modification and schedule controls: broad bounded session-local adaptation, review-gated persistent settings, provider-confirmed autonomous pause, operator-only re-enablement, later-cycle activation for self-modifying patches, persistent change receipts, implementation tasks, and acceptance tests T54–T60.
- 2026-06-23 · v0.17 — Added bounded self-recovery and incident containment: recovery ladder, proof-before-resume, allowed local repairs and approved fallbacks, prohibited authority expansion, packet/routine/shared-system boundaries, critical incident handling, pause-required and resume evidence, rollout changes, implementation tasks, and acceptance tests T48–T53.
- 2026-06-23 · v0.16 — Added layered observability and cycle health: separated packet outcomes from controller health, defined HEALTHY/DEGRADED/FAILED and observer-derived UNKNOWN, established native execution correlation, cycle evidence and health precedence, packet-level observability, AI LOG incident thresholds, missed-run diagnosis, brief-write exception handling, no observability database/watchdog, implementation tasks, and acceptance tests T41–T47.
- 2026-06-23 · v0.15 — Added brief delivery and retention: one canonical latest-brief document per project, attention-first overwrite, empty-cycle health reporting, native completion links, redaction and content rules, non-rollback behavior on brief-write failure, no per-cycle archive, implementation tasks, and acceptance tests T35–T40.
- 2026-06-23 · v0.14 — Added the review contract: structured review requests, four valid decisions, explicit human decision records, Output decision receipts, revision-specific approval, artifact standards, scoped reviewer authority, no timeout inference, implementation tasks, and acceptance tests T28–T34.
- 2026-06-23 · v0.13 — Added the secrets and permissions contract: native credential ownership, safe aliases, least-privilege core capabilities, restricted and prohibited unattended actions, capability declarations, queue-time and execution-time checks, BLOCKED versus REVIEW classification, no self-repair or privilege escalation, redaction requirements, representative scenarios, and acceptance tests T22–T27.
- 2026-06-23 · v0.12 — Added the target lifecycle status model: BACKLOG, QUEUE, FOCUS, BLOCKED, REVIEW, DONE, and CANCELED. Defined transition ownership, deterministic blocker requirements, queue-hygiene handling, PACKETS Status/fromStatus migration work, failure mapping, and acceptance tests T20–T21.
- 2026-06-23 · v0.11 — Added the idempotency and replay-safety contract: best-effort acquisition semantics, material revision guard, four replay states, SAFE_RESUME gate, action-level replay patterns, conditional Replay and Recovery packet requirements, requeue semantics, receipt updates, and tests T16–T19.
- 2026-06-23 · v0.10 — Rebuilt the PRD from a chronological decision log into a self-contained implementation specification. Added full context, ownership boundaries, lifecycle, cycle algorithm, functional requirements, data contracts, selective telemetry model, retry/recovery policy, implementation plan, acceptance matrix, rollout gates, and integration deltas for executor, orchestrator, and close-agent.
- 2026-06-23 · v0.1–0.9 — Architecture decisions locked through scheduling and retry/recovery.