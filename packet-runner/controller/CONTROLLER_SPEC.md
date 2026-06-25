# Packet Runner — Provider-Neutral Controller Specification

**Lane G deliverable.** Precise, deterministic pseudocode + decision tables for one Packet Runner cycle.
**Source of truth:** [`_refs/PRD-v1.0.md`](../_refs/PRD-v1.0.md). Every non-obvious rule cites its PRD anchor (FR-n / §8.x / §6 / §9). Where the PRD conflicts with the live skills or source packet, the PRD governs (§14.1, PROGRAM_PLAN).

> **Scope of this document.** This specifies the **provider-neutral controller logic** only. All provider mechanics (scheduling, non-overlap, isolation, worker spawn, notification, export) are reached through a thin **Provider Capability Layer** (§A below) so the same cycle runs on any provider satisfying the FR-9 / §8.5A nine-capability boundary. No generalized adapter framework is built for v1 (FR-9, §8.5A provider-selection rule).

---

## 0. Architecture split — neutral core vs. thin provider layer

### A. Provider Capability Layer (thin; the ONLY provider-specific surface)

The controller calls these capability operations and never reaches a provider SDK directly. Each maps to one of the nine FR-9 / §8.5A capabilities. A provider qualifies for v1 only if every capability except `session_export` is satisfied; `session_export` may degrade to the §8.18 compact-bundle fallback (FR-9, §8.5A).

| Capability op | FR-9 capability | Contract returned to neutral core |
|---|---|---|
| `provider.acquireNonOverlapGuard()` | routine-level non-overlap | `STARTED` \| `REFUSED_OVERLAP` (deterministic refusal) \| `AMBIGUOUS` (started but overlap not ruled out) (§6.1) |
| `provider.repoIsolation(repo, mode)` | repository isolation | isolated clone/branch/worktree handle, or `UNAVAILABLE` (§8.21, FR-4) |
| `provider.dispatchWorker(payload, mode)` | fresh-worker vs inline | `{started:bool, sessionRef, receipt?}`; `started` MUST be provider-proven (§8.4, FR-5, §9 worker-dispatch) |
| `registry.fetchPacket(id)` / `registry.queryQueue(project)` | registry / MCP availability | `packet-registry-v1` envelope (§8.3) |
| `provider.nativeExecutionRef()` | native execution-reference capture | stable URL/identifier, used as the cycle correlation reference (§8.11) |
| `provider.failureSignal()` | runtime failure signaling | structured runtime-failure indication |
| `provider.pauseOrDisableSelf(boundary)` | routine pause/disable (machine-callable) or fail-closed latch | `CONFIRMED` \| `UNCONFIRMED` — scoped to THIS routine only; re-enable is never available to the controller (FR-18, §8.13) |
| `provider.notifyCompletion(briefLink)` | completion notification w/ brief link | delivery status; native channel only — no email/Slack/SMS/custom push (§8.6) |
| `provider.exportSession(sessionRef, dest)` | session export | exported artifact ref, or `UNAVAILABLE` → triggers §8.18 fallback |

**Neutral-core invariant:** the controller treats every capability result as data. It never assumes a provider-level lock (Notion offers no compare-and-swap — §6 best-effort acquisition limitation); duplicate prevention rests on non-overlap + sequential dispatch + verification reads + the operating rule that humans/agents do not start the same QUEUE packet while the routine runs (§6).

### B. Provider-neutral core (everything else in this document)

Preflight, QUEUE query, hydration, eligibility classification, ordering, cap, coupled QUEUE→FOCUS write+re-read, dispatch-payload build, receipt→status reconciliation, Output compaction, Source-of-Truth gating, cleanup, cycle-health derivation, redaction, retry. All deterministic given the same live state + config.

---

## 1. Top-level cycle

```
function runCycle(config):
    cycle = newCycleContext(config)          # holds counts, anomalies, retries, brief model
    cycle.health = HEALTHY                    # optimistic; only downgraded, never upgraded (§8.11 precedence)

    # ---- STEP 1a: non-overlap guard (§6.1) ----
    guard = provider.acquireNonOverlapGuard()
    if guard == REFUSED_OVERLAP:
        record NOT_STARTED_OVERLAP; start no packet
        DO NOT overwrite the active cycle's brief         # §6.1
        return            # not a FAILED emission — the prior cycle owns the brief
    if guard == AMBIGUOUS:                                 # started but overlap not ruled out
        start no packet; cycle.health = FAILED; goto CLOSEOUT_MINIMAL   # §6.1

    # ---- STEP 1b: preflight / capability gate (§8.5A validation, §6.1, FR-9) ----
    pf = preflight(config)
    if pf != OK:
        # configuration/capability failure BEFORE any packet mutation
        cycle.health = FAILED
        restore/leave all QUEUE untouched                 # §9 infra-before-start
        goto CLOSEOUT_MINIMAL

    # ---- STEP 2: project-scoped QUEUE query (§6.2, FR-2) ----
    candidates = registry.queryQueue(config.project_id)   # Status==QUEUE AND PROJECT==project_id
    # NEVER query FOCUS or REVIEW as execution candidates (§6.2)

    # ---- STEP 3: hydrate (§6.3, FR-1, §8.3) ----
    for c in candidates: c.hydrated = registry.fetchPacket(c.id)   # one-hop; bodies not loaded (§8.3)

    # ---- STEP 4: eligibility classification (§6.4) ----
    (eligible, sideEffects) = classifyAll(candidates, cycle, config)
    applyDeterministicTransitions(sideEffects)            # MANUAL=noop; window/missing/blocked/ambiguous → see §3

    if cycle.repoStateUntrusted:                          # §6.4 last two bullets
        # "shared repository or provider state untrustworthy: fail the cycle BEFORE dispatch, preserve QUEUE"
        cycle.health = FAILED; goto CLOSEOUT_MINIMAL

    # ---- STEP 5: ordering (§6.5) ----
    ordered = order(eligible)                             # topo → Priority desc → LifecycleCheckedAt asc → PKT-ID asc

    # ---- STEP 6: cap (§6.6, §8.5A) ----
    cap = config.max_packets_per_cycle                    # v1 pilot == 1
    executedThisCycle = 0

    # ---- STEP 7-9: sequential execution loop (§6.7-6.9) ----
    for packet in ordered:
        if executedThisCycle >= cap: break
        if remainingRuntimeOrSafetyUncertain(cycle): break   # §6.9 never start when uncertain
        result = executeOnePacket(packet, cycle, config)     # §4 (coupled FOCUS write, dispatch, receipt verify, reconcile)
        if result.started: executedThisCycle += 1
        # §6.9 optional intra-cycle refresh:
        if executedThisCycle < cap and result.terminal and not remainingRuntimeOrSafetyUncertain(cycle):
            ordered = refreshEligibility(config, cycle)       # newly unblocked work may run; never exceed cap

    # ---- STEP 10: bounded maintenance (§6.10, §8.17) ----
    runMaintenance(cycle, config)        # cleanup + archival; AFTER reconciliation, BEFORE closeout; time-bounded

  CLOSEOUT_MINIMAL:
    # ---- STEP 11: single closeout (§6.11, FR-15, §8.6, §8.11) ----
    closeout(cycle, config)              # aggregate, selective AI LOG, write brief, notify, report stale/skipped/failures

    # ---- STEP 12: qualification row during pilot only (§6.12, §8.20) ----
    if config.qualification_pilot_active:
        appendQualificationRow(cycle, config)   # AFTER brief+notify known; missing/unverifiable ⇒ non-qualifying + breaks streak
    return cycle
```

---

## 2. Preflight / capability gate (§8.5A configuration validation, §6.1, FR-9)

**Fail closed before any packet mutation** (§8.5A: "Preflight fails before packet mutation when…"). All checks below are AND-ed; any failure ⇒ `FAILED`, leave QUEUE untouched, go straight to minimal closeout (§9 infra-before-start).

| # | Preflight check | Source | Fail action |
|---|---|---|---|
| P1 | Config present, internally consistent, contract/schema versions in supported range (PRD, executor, orchestrator, close-agent, `packet-registry-v1`, `packet-runner-receipt-v1`) | §8.5A validation; §8.4 ("reject unsupported routine/registry versions") | FAILED preflight |
| P2 | `project_id` resolvable & accessible | §8.5A validation | FAILED preflight |
| P3 | Repository owner/name + default branch resolvable; repository isolation establishable in `repo_isolation_mode` | §8.5A; §8.21; FR-9 repo isolation | FAILED (cannot establish isolation ⇒ §8.11 FAILED example) |
| P4 | `brief_page_id` resolvable & updatable | §8.5A; §8.6 ("fail visibly during preflight if destination cannot be resolved or updated") | FAILED preflight |
| P5 | `qualification_evidence_page_id` resolvable (only when pilot active) | §8.5A; §8.20 | FAILED preflight (pilot) |
| P6 | `durable_evidence_destination` resolvable & is a stable Notion/repository area (never ephemeral local dir) | §8.5A; §8.18 | FAILED preflight |
| P7 | Required MCP tools available (registry read/update PACKETS, related-metadata read) | §6.1; §8.9 core capabilities | FAILED preflight |
| P8 | Default model available and within approved allowlist | §6.1; §8.5A | FAILED preflight |
| P9 | Native execution-reference capture available | §6.1; FR-9 | FAILED preflight |
| P10 | Completion-notification capability available | §6.1; FR-9; §8.6 ("reliable native completion notification is a selection requirement") | FAILED preflight |
| P11 | Pause/disable (machine-callable) or fail-closed latch available, scoped to this routine | §6.1; FR-9; §8.13 | FAILED preflight |
| P12 | Session-export capability available **OR** §8.18 compact-bundle fallback path is configured (`durable_evidence_destination` valid) | §6.1; FR-9 ("session export may be unavailable only because §8.18 defines a fallback") | FAILED only if BOTH export and fallback are unusable |
| P13 | Config does not allow overlapping runs | §8.5A validation | FAILED preflight |
| P14 | `cycle_timeout` < schedule interval; `packet_timeout` < 4h stale-FOCUS threshold; maintenance budgets present | §8.5A; §8.14 | FAILED preflight (internally inconsistent) |

> **Capability gate vs. preflight.** The capability gate (P9–P12) is the controller-side re-assertion of the §8.5A provider-selection evidence. Even if config records a capability as "verified", preflight must observe it live; a capability that selection recorded but preflight cannot confirm is fail-closed (FR-9 — "every other capability is required").

---

## 3. Eligibility classification (§6.4) — decision table

Run per candidate, in this **precedence order** (first match wins). Every non-eligible branch is deterministic; "when in doubt, REVIEW, never guess" (§6.4, FR-4). The coupled lifecycle write (§8.1) applies to **every** status change a branch performs.

| # | Condition (evaluated in order) | PRD anchor | Classification → action |
|---|---|---|---|
| E1 | `Execution Class == MANUAL` | §6.4; FR-3 | **SKIP** — leave unchanged; report when relevant. Never dispatched (§8.5). |
| E2 | Missing/unparseable `Execution Class` (no AUTO/REVIEW-FIRST/MANUAL) | §6.4; FR-3 ("missing is fail-closed"); §8.1 | **REVIEW** (fail-closed) |
| E3 | Missing mission context (Goal Contract not interpretable from body) | §6.4; §8.2 | **REVIEW** |
| E4 | Missing/inaccessible required relation (esp. PROJECT not exactly one; or required relation read fails) | §6.4; §8.1 ("exactly one project required"); FR-4 | **REVIEW** |
| E5 | Missing repository identity when packet requires repo work | §6.4; §8.21; FR-5 | **REVIEW** |
| E6 | Dependency fault: self-dependency, dependency cycle, canceled prerequisite, contradictory graph, missing/inaccessible blocker relation, or ambiguous dependency state | FR-4; §6.4 | **REVIEW** (never guess) |
| E7 | A direct `Blocked by` packet is **not DONE** AND the unmet prerequisite has a **concrete owner/system + exact unblock condition** | FR-4; §6.4; §8.9 perms | **BLOCKED** — record blocker, owner/system, last checked, safe state, unblock condition in Packet Output (FR-4) |
| E8 | `Execution Window`: end without start, reversed range, or unparseable | §8.1 optional-props (`Execution Window`) | **REVIEW** |
| E9 | `Execution Window`: now **before** start | §6.4; §8.1 | **LEAVE QUEUE**; report next eligible time (no mutation) |
| E10 | `Execution Window`: now **after** end | §6.4; §8.1 ("after end, move to REVIEW") | **REVIEW** (time-bound contract needs a new decision) |
| E11 | Queue-time capability/permission expectation fails with **known** missing scope + owner + unblock condition (two-stage check, stage 1) | §8.9 two-stage; FR-13 | **BLOCKED** |
| E12 | Capability/permission expectation **unclear / broader-than-justified / ambiguous source / escalation / risk-changing** | §8.9; FR-13 | **REVIEW** |
| E13 | Active FOCUS work in the **same repository** whose isolation cannot be proven disjoint | §6.4 | **COLLISION** — start no new repository work; leave unrelated QUEUE packets unchanged; report collision (do NOT mutate the colliding packet) |
| E14 | Ambiguous blocker, ownership, collision, or repository state (not resolved above) | §6.4 | **REVIEW** |
| E15 | Shared repository / provider state untrustworthy | §6.4 | **CYCLE-FAIL before dispatch** — set `cycle.repoStateUntrusted=true`; preserve all QUEUE state |
| E16 | Otherwise: QUEUE, fresh (`Lifecycle Checked At` within freshness window), all live checks pass | FR-2; §8.14 | **ELIGIBLE** |

### Freshness sub-gate (applies before E16; §8.14, FR-2)

```
if now - packet.LifecycleCheckedAt > 7 calendar days:        # global default §8.14
    LEAVE in QUEUE, EXCLUDE from execution
    label "Readiness refresh required" in brief
    request orchestrator/human recertification               # no mutation, no auto-requeue (§8.14 "no age-based mutation")
    classification = NOT_ELIGIBLE (reported), not REVIEW
```

> Freshness expiry is **not** a status mutation — it leaves QUEUE and reports (§8.14, FR-19). Contrast E10 (window expiry) which **does** move to REVIEW because the *time-bound contract* itself expired (§6.4).

### Eligibility side-effect transition table

| Branch outcome | Status write? | Coupled write (§8.1) | Counts toward |
|---|---|---|---|
| SKIP (MANUAL, E1) | no | — | skipped |
| LEAVE QUEUE (E9, freshness) | no | — | skipped / stale-QUEUE (reported) |
| BLOCKED (E7, E11) | QUEUE→BLOCKED | Status + `Lifecycle Checked At` + `fromStatus`, then re-read | BLOCKED |
| REVIEW (E2–E6, E8, E10, E12, E14) | QUEUE→REVIEW | same coupled write + re-read | REVIEW |
| COLLISION (E13) | no (colliding packet untouched) | — | skipped + collision reported |
| CYCLE-FAIL (E15) | no | — | cycle FAILED, QUEUE preserved |
| ELIGIBLE (E16) | deferred to §4 (coupled QUEUE→FOCUS at dispatch) | — | candidate→eligible |

---

## 4. Per-packet execution (§6.7-6.9, §8.4, §8.8, §8.5)

```
function executeOnePacket(packet, cycle, config):
    # ---- 4.1 re-fetch + re-confirm (§6.7, §8.8 protections 1-2) ----
    live = registry.fetchPacket(packet.id)
    if live.status != QUEUE or not stillEligible(live, config):
        report drift; return {started:false, terminal:false}     # do not dispatch
    inspectRepositoryState(live, config)                          # §8.21 invariants (record identity/branch/commit/tree)
    if repositoryUntrusted(): cycle.health = FAILED; preserve QUEUE; return {started:false}

    # ---- 4.2 coupled QUEUE→FOCUS write + verification re-read (§6.7, §8.1, §8.8 protection 3) ----
    writeProperties(packet.id, {                                   # ONE logical property write
        Status: FOCUS,
        LifecycleCheckedAt: now,
        fromStatus: QUEUE                                          # previous status (§8.1 coupled write)
    })
    reread = registry.fetchPacket(packet.id)                       # immediate re-read (best-effort single-writer, NOT a lock §6)
    if reread.status != FOCUS or ownershipOrMaterialStateAmbiguous(reread):
        # acquisition read inconsistent → stop (§6.7, §6 best-effort limitation)
        treat as ownership conflict; move to REVIEW if controller still owns state; cycle.health = FAILED
        return {started:false, terminal:true}
    observedLastEditedTime = reread.primary.lastEditedTime         # §8.4 stale-handoff signal (change detector, NOT a lock)

    # ---- 4.3 build dispatch payload (§8.4, FR-5) ----
    payload = {
        packetId: packet.id, source: "packet-runner", expectedStatus: "FOCUS",
        observedLastEditedTime,
        executor: {slug:"executor", minimumVersion: config.contract_versions.executor},
        routineConfigVersion: config.version,
        registrySchemaVersion: "packet-registry-v1",
        mode: chosenMode(config),                                  # fresh-worker preferred; inline fallback (§6, FR-9)
        repository: repoIfNotInherent(config),                    # only when routine is not inherently repo-scoped (FR-5)
        returnContract: "packet-runner-receipt-v1"
    }
    # EXCLUDED by FR-5: copied packet context, Run ID, Worker ID, lease, claim token, retry count, budgets, transcript.

    # ---- 4.4 stamp execution markers WHEN a session is proven started (§6.7, §8.1 optional props) ----
    disp = provider.dispatchWorker(payload, payload.mode)
    if disp.started:
        writeProperties(packet.id, {LastExecutedAt: now, LastExecutionURL: disp.sessionRef})  # only when proven started
    else:
        # dispatch did not start — §9 worker-dispatch retry (one retry ONLY if provider proves no session created)
        if provider proves NO worker/session created:
            disp = retryOnce(provider.dispatchWorker, payload)    # single bounded retry
        if still not started and worker MAY have started:
            move FOCUS→REVIEW; preserve all execution refs; never launch duplicate; return {started:false, terminal:true}
        if confirmed no session AND infra-class failure:
            # §9 infra-before-start: this packet did start FOCUS though — treat as ambiguous: REVIEW, do not retry within cycle
            move FOCUS→REVIEW; report; return {started:true, terminal:true}

    # ---- 4.5 await + classify receipt (§8.5) ----
    receipt = disp.receipt or awaitReceipt(disp.sessionRef, config.packet_timeout)

    # ---- 4.6 receipt validity gate (§8.5) ----
    if not receiptValid(receipt, payload, live):                  # version/packetId/executorVersion/timestamps/contract-state must match
        # missing/malformed/contradictory/unverifiable after possible work
        move FOCUS→REVIEW; if resulting state untrusted: cycle.health = FAILED; invoke §8.18 preservation if untrusted
        return {started:true, terminal:true}

    # ---- 4.7 reconcile → final status (§5 mapping + §8.15 write sequence) ----
    final = reconcile(packet, live, receipt, cycle, config)
    return {started: true, terminal: final.isTerminal}
```

### Material-revision guard inside dispatch (§8.4, §8.8, FR-6)

`observedLastEditedTime` is a **change detector, not a lock or authorization token** (FR-5, §8.4). On the executor side (per FR-6/§8.8): if live `lastEditedTime` ≠ dispatch value, compare the **execution-critical contract** — Goal, Scope/exclusions, Constraints, Success Criteria, Verification Plan, Review Requirement, Stop Conditions, Dependencies, Project, Execution Class. **Material** change ⇒ stop in REVIEW; **non-material** (formatting, `Lifecycle Checked At`, `Last Execution URL`/`At`, cleanup metadata, controller-owned fields) ⇒ proceed with the comparison recorded. The controller honors the receipt's `packet_contract_state` (`MATERIAL_CHANGE` ⇒ REVIEW path in §5).

---

## 5. Receipt → status mapping (§8.5 receipt-to-status) — decision table

The receipt is a **claim until verified** (FR-7). Packet Runner compares it against packet Output, referenced files/pages/records, verification evidence, repository state, and review class before any final write (FR-7). Mapping is keyed on `Execution Class` × (`goal_state` / `replay_state` / `failure_class` / receipt validity).

| # | Inputs | Condition for the "good" status | Final status | PRD anchor |
|---|---|---|---|---|
| R1 | AUTO + `goal_state ∈ {COMPLETED, ALREADY_SATISFIED}` | **ALL** of: every required criterion `PASS`; live verification agrees; managed Output write succeeds; **Source of Truth valid when required** (§8.16 test) | **DONE** | §8.5 (1) |
| R1′ | AUTO + COMPLETED/ALREADY_SATISFIED but any R1 condition fails | — | **REVIEW** | §8.5 (1) |
| R2 | REVIEW-FIRST + `goal_state ∈ {COMPLETED, ALREADY_SATISFIED}` | exact review contract satisfied (§8.10) — approval cannot override missing verification or Source of Truth | **REVIEW** until satisfied (never auto-DONE) | §8.5 (2); FR-3 |
| R3 | `goal_state == BLOCKED` | prerequisite + owner/system + safe state + exact unblock condition ALL known | **BLOCKED** | §8.5 (3); FR-4 |
| R3′ | `goal_state == BLOCKED` but any of those unknown/ambiguous | — | **REVIEW** | §8.5 (3) |
| R4 | `goal_state ∈ {REVIEW_REQUIRED, PARTIAL_SAFE, FAILED_SAFE}` OR `replay_state == UNSAFE_AMBIGUOUS` | — | **REVIEW** | §8.5 (4); §8.8 |
| R5 | Receipt missing / malformed / contradictory / unverifiable after possible work | — | **REVIEW**; **cycle health FAILED when resulting state untrusted** + §8.18 preservation | §8.5 (5) |
| R6 | `Execution Class == MANUAL` | n/a | **never dispatched** | §8.5 (6); E1 |

**Replay-state interaction (§8.8):** `replay_state == SAFE_RESUME` is honored only with explicit `resume_evidence` (non-null) AND the SAFE_RESUME gate (Goal Contract unchanged, artifacts/targets conclusively inspectable, every consequential prior effect identifiable); otherwise treat as ambiguous ⇒ REVIEW. `UNSAFE_AMBIGUOUS` **always** stops in REVIEW (R4).

**Failure-state mapping cross-check (§9):** BLOCKED receipt → FOCUS→BLOCKED (R3); REVIEW_REQUIRED/PARTIAL_SAFE/FAILED_SAFE → FOCUS→REVIEW (R4); ambiguous failure / missing receipt → FOCUS→REVIEW, preserve refs, no duplicate worker (R5/§4.6).

**`Cleanup Eligible At`** is derived by Packet Runner **only after a terminal transition** (DONE/CANCELED) and only when temporary candidates exist; the worker never calculates it (§8.5, §8.17, FR-22).

### Reconcile write sequence (§8.15 reconciliation write sequence, §8.2A)

```
function reconcile(packet, live, receipt, cycle, config):
    # 1. capture prior trustworthy record
    prior = {status, lifecycleTs, outputIndex, managedBody, sourceOfTruth} from live
    # 2. verify receipt vs live + construct complete reconciled Output body (§8.15)
    if not receiptVerifiedAgainstLive(receipt, live): return toReview(preserve=prior)   # §8.15: don't write DONE if body unverifiable
    body = buildManagedBody(receipt)        # ### Current Canonical Result (rewrite) + ### Artifact Manifest (rewrite) + ### Exceptional History (append-only, §3.15 retention)
    # 3. replace managed body sections + re-read (§8.2A: if section missing/duplicated/malformed/too-large → REVIEW, preserve prior)
    if managedSectionMissingOrMalformed(live): return toReview(preserve=prior)
    writeManagedBody(packet.id, body); rereadBody = readManagedBody(packet.id)
    if rereadBody != body: return toReview(preserve=prior)
    # 4. determine final status via §5 mapping + Source-of-Truth gate (§6)
    status = mapReceiptToStatus(packet.executionClass, receipt)        # §5
    if status == DONE and not sourceOfTruthGate(receipt, live): status = REVIEW   # §6 below
    # 5. ONE logical property update (§8.15 step 4): compact Packet Output index + Source of Truth + Status + Lifecycle Checked At + fromStatus + Cleanup Eligible At (if terminal+temp)
    props = {PacketOutput: compactIndex(body, ≤1800 chars),            # §8.2A
             SourceOfTruth: normalizedLocators(receipt),               # §8.1 serialization, ≤5 lines
             Status: status, LifecycleCheckedAt: now, fromStatus: prior.status}
    if status in {DONE, CANCELED} and hasTemporaryArtifacts(receipt): props.CleanupEligibleAt = now + 7d   # §8.17
    writeProperties(packet.id, props)
    # 6. re-read every changed property; confirm agreement with managed body + live target (§8.15 step 5)
    if not verifyPropertyReread(packet.id, props):
        retryOnce(writeProperties, packet.id, props)                  # one bounded retry after re-read (§8.15)
        if still inconsistent:
            preserve prior trustworthy Output; move to REVIEW only if a trustworthy status write remains possible
            cycle.health = FAILED; invoke §8.18 preservation when state untrusted
    return {status, isTerminal: status in {DONE, CANCELED}}
```

### Packet Output compaction rules (§8.15, §8.2A, FR-20)

- **Three managed sections** under `## Packet Runner Output`: `### Current Canonical Result` (always rewritten), `### Artifact Manifest` (always rewritten — target, change, retention class, ownership, authoritative locator, current existence), `### Exceptional History` (append-only, retention-gated).
- **Current Canonical Result** carries: current status + receipt classification; concise outcome + success-criteria result; verification evidence + artifact links; native execution ref + last execution time (when a worker started); safe state / rollback position / already-satisfied evidence; exact review decision or unblock condition; controlling approval/cancellation/continuation receipt. **A later clean attempt replaces superseded clean-attempt detail — never appends another full receipt** (§8.15).
- **Exceptional History retains ONLY** (§8.15 retention list): critical incident / safety-authorization violation; ambiguous irreversible or external effect; duplicate execution / ownership conflict; approval / continuation / request-changes / cancellation decision receipts when historically relevant; significant rollback / recovery / safe-resume; material packet revision that invalidated prior approval/authority; secret-exposure/credential incident (redacted only); false-DONE correction or receipt/live-state mismatch. Each entry: event type, time, concise facts, affected artifact/action, resulting safe state, source execution/reference, resolution status.
- **Excluded from Packet Output** (§8.15): full provider transcripts, raw command logs, repeated test output, complete clean receipts from every attempt, superseded intermediate summaries, secret-bearing errors, duplicate evidence already in Git / native session.
- **Compaction safety** (§8.15): never remove evidence needed to determine replay safety, validate an active approval, explain a cancellation, investigate an unresolved incident, or understand why status is BLOCKED/REVIEW. When uncertain whether an event is still safety-relevant, **preserve the compact entry and remove only redundant detail**. Compaction/reconciliation failure **never erases the prior trustworthy record**.
- **Compact `Packet Output` property** ≤ 1,800 visible chars (§8.2A); labeled fields when applicable: `Status`, `Goal state`, `Updated`, `Native execution`, `Source of Truth`, `Decision or unblock condition`, `Safe state`, `Output section` (pointer to body section).

---

## 6. Source-of-Truth requirement test + DONE gating (§8.16, FR-21)

**Requirement test (§8.16):** *"After this packet is forgotten, is there a durable place someone should inspect to see the result as it currently exists?"*

```
function sourceOfTruthGate(receipt, live) -> bool:   # returns true if DONE may proceed
    required = sotRequired(receipt)                  # see table
    if not required:
        require Packet Output states "Source of Truth: not applicable" + concise reason; property stays empty   # §8.16
        return true
    sot = normalizedLocators(receipt.SourceOfTruth)
    if sot resolves to the CURRENT authoritative result (valid kind, not temporary/stale/contradictory):
        return true
    else:
        return false        # missing/temporary/stale/contradictory ⇒ blocks DONE ⇒ packet moves to REVIEW (§8.16 DONE reconciliation)
```

| Source-of-Truth **required** (§8.16) | Source-of-Truth **usually NOT required** (§8.16) |
|---|---|
| A durable artifact was created or materially changed | Research, diagnosis, recommendation, comparison, planning, ephemeral analysis whose deliverable lives in Packet Output |
| Production / repository / database / config / document / automation / external-system state became the authoritative result | A no-op verification with no durable target beyond the evidence itself |
| ALREADY_SATISFIED verifying an existing durable target that remains the canonical inspect point | Failed / BLOCKED / REVIEW / CANCELED packet (unless a durable partial artifact is itself the authoritative result) |

**Valid references (§8.16):** merged PR / canonical commit / release / stable repo path; canonical Notion page / file / published spec / approved record; the actual DB record / workflow / schema / live config; the production object / authoritative system record. Stored as the normalized locator lines of §8.1 (no Notion relation, no temporary evidence link).

**Invalid substitutes (§8.16) — never populate SoT solely to fill the field:** the cycle brief; native provider session; Packet Output or the packet page itself; temporary branch / worktree / local path / draft / screenshot / raw log / test report; a review artifact that has not become the accepted durable result. (These may remain *evidence* links in Packet Output.)

**Code-delivery interaction (§8.21, FR-26):** a local commit / temp branch / patch bundle / unmerged PR is evidence, not SoT. A code packet reaches DONE only after durable canonical repository state exists and SoT points to the merged PR / canonical commit / release / stable path. `APPROVE_COMPLETION` cannot bypass missing canonical repository state.

**Supersession (§8.16):** when the authoritative result moves, update SoT to the new canonical target; superseded evidence may remain in Exceptional History.

---

## 7. Cleanup-eligibility gate (§8.17, FR-22) — maintenance step

Runs **after packet reconciliation, before closeout**, within `maintenance_max_items` / `maintenance_time_budget_seconds` (§6.10, §8.17). Cleanup **does not count against `max_packets_per_cycle`** (starts no mission work) but must stay time-bounded and must not materially delay the brief (§8.17).

```
function runMaintenance(cycle, config):
    due = query terminal packets (DONE|CANCELED) with CleanupEligibleAt <= now
    processed = 0
    for p in due:
        if processed >= config.maintenance_max_items or timeBudgetExceeded(config): break
        for artifact in temporaryArtifacts(p):            # retention_class == temporary only
            if cleanupAllowed(p, artifact):               # ALL gates below (§8.17)
                deleteOrArchive(artifact)
                verifyAbsenceOrArchival(artifact)
                updateCanonicalOutput(p, conciseCleanupReceipt)   # NOT an AI LOG / Exceptional entry unless it affects interpretation
                clearCleanupEligibleAt(p)
            else:
                record candidate + reason in brief/provider session; retry later only if safe   # §8.17 cleanup failure
        processed += 1
    # archival of resolved AI LOGS (§8.19): Resolved + 90d ⇒ Archive Eligible At ⇒ auto-archive (NOT delete); promote learning first
```

**`cleanupAllowed` — ALL must hold (§8.17 eligibility gate):**
1. Packet remains DONE or CANCELED.
2. Source of Truth valid when required AND does not reference the candidate.
3. No open REVIEW, BLOCKED dependency, successor packet, rollback plan, replay-safety analysis, or unresolved incident depends on it.
4. No approval/cancellation record identifies it as controlling evidence.
5. Artifact still identifiable and owned by the routine.
6. Deletion will not remove unexplained user work or externally authoritative state.

**Protected — never auto-delete (§8.17):** merged commits, accepted PRs, releases, tags, canonical repo paths, authoritative documents/records, Source-of-Truth targets, active review artifacts, incident evidence, rollback assets, replay-safety evidence, ownership-uncertain artifacts. An unmerged PR/branch is `temporary` only after its review is closed, useful commits preserved/abandoned, and no incident/successor depends on it.

**Recovery window (§8.17):** `Cleanup Eligible At = terminal transition + 7 calendar days`. If the packet leaves DONE/CANCELED before cleanup, **clear** `Cleanup Eligible At` and preserve every artifact until a new terminal state. CANCELED packets also keep temp artifacts 7 days for recovery.

**Cleanup failure (§8.17):** does not change DONE/CANCELED. Preserve `Cleanup Eligible At`, record candidate+failure, retry later only when safe. Repeated failure or evidence that protected material may have been removed ⇒ **AI LOG incident**; uncertain destructive effect ⇒ REVIEW + incident-containment (§8.12).

---

## 8. Cycle-health derivation (§8.11) — HEALTHY / DEGRADED / FAILED precedence

Health describes **controller integrity**, not packet outcomes. Normal DONE/BLOCKED/REVIEW/CANCELED/empty-queue outcomes **do not** independently change health (§8.11). UNKNOWN is **never** emitted by the controller — it is operator-derived when an expected cycle has neither a reliable provider record nor a fresh brief (§8.11, FR-16).

**Strict precedence (first match wins; §8.11 health derivation precedence):**

```
function deriveHealth(cycle) -> {HEALTHY, DEGRADED, FAILED}:
    # 1. FAILED — any of:
    if cycle has ANY safety / authorization / duplicate-execution / untrustworthy-state incident
       or could-not-establish-registry-access / repo-isolation
       or unreconciled worker state
       or inconsistent packet writes
       or unresolved ownership collision
       or selected-packet outcomes cannot be proven
       or (§8.18) required preservation could not be verified:
        return FAILED            # also triggers applicable pause policy (§8.13)
    # 2. DEGRADED — outcomes trustworthy BUT a recoverable operational anomaly remains:
    if cycle had ANY of: a bounded retry consumed / detected queue-hygiene defect / stale FOCUS discovery
       / unavailable native notification / aggregate brief-write failure (with Packet Output + native session still authoritative):
        return DEGRADED
    # 3. HEALTHY — controller duties completed cleanly:
    return HEALTHY
```

**HEALTHY requires ALL (§8.11):** routine reached closeout; every selected packet has a trustworthy reconciled outcome; required status + Output writes succeeded; latest brief written; no operational/authorization/safety anomaly remains.

**Stale-FOCUS interaction (§8.14):** discovering a stale FOCUS (>4h, ownership not provable) moves that packet to REVIEW and classifies the cycle **DEGRADED or FAILED according to state trustworthiness** — DEGRADED if outcomes remain trustworthy, FAILED if not.

**Brief-write exception (§8.11, §8.6):** trustworthy outcomes + brief un-writable ⇒ **DEGRADED** (record in provider session, leave prior brief visibly stale, preserve all Packet Outputs, no auto-backfill).

**Qualification interaction (§8.20):** ANY DEGRADED / FAILED / observer-UNKNOWN cycle resets the consecutive-cycle count to zero after reconciliation; a missing/unverifiable qualification row makes the cycle non-qualifying and breaks the streak **even when health is HEALTHY** (§6.12, §8.20) — but it does not retroactively alter reconciled packet outcomes.

---

## 9. Redaction rules (§8.9 logging-and-redaction, §8.18 redaction-and-minimization, §8.6 excluded content)

Applied to every controller write surface: receipts, Packet Output, AI LOGS, briefs, Source-of-Truth docs, evidence bundles, repository files/commits, screenshots, test fixtures.

**MAY include (§8.9):** safe credential alias (e.g. `github:primary`, `notion:primary`, `STRIPE_API_KEY`), connection name, missing scope, error class, responsible owner/system, remediation instructions, redacted evidence excerpts.

**MUST exclude (§8.9 + §8.18):** secret values; authorization headers; cookies; private keys; passwords; sensitive request bodies; full credential-bearing error payloads; personal/customer data not required for diagnosis; full sessions copied merely because export exists; irrelevant prompts; unrelated tool output. Secrets never land in PACKETS properties, packet bodies, Packet Output, AI LOGS, briefs, SoT docs, repo files, commits, screenshots, or test fixtures (§8.9 storage).

**Brief-specific exclusions (§8.6):** no full receipts, packet bodies, transcripts, raw stack traces, extensive test output, secret-bearing errors, sensitive customer data, or generic no-friction telemetry — detailed evidence stays in Packet Output + referenced artifacts.

**Minimization principle (§8.18):** preserve only what is required for incident recovery, replay safety, auditability, or authority review; use safe aliases + redacted excerpts.

---

## 10. Retry policy (§9, FR-11) — tool / dispatch / whole-packet

| Layer | Allowed retry | Precondition | Forbidden / fall-through | Anchor |
|---|---|---|---|---|
| **Tool operation** (Notion/registry/filesystem-read/provider/network) | **one** retry | re-read target first AND confirm the intended action is still necessary; respect provider retry guidance | NEVER retry: permission denial, invalid schema, malformed arguments, missing credentials, merge conflicts, failed verification, approval gates, ambiguous destructive ops, deterministic repeated failures | §9 tool-operation; FR-11 |
| **Worker dispatch** | **one** retry | provider **proves** no worker / native session was created | if a worker **may** have started ⇒ state is ambiguous: do NOT dispatch a duplicate; move FOCUS→REVIEW (if controller still owns state) with all execution references | §9 worker-dispatch; FR-11; §4.4 |
| **Property reconciliation write** | **one** bounded retry | after the re-read (§8.15 step 5) | still inconsistent ⇒ preserve prior trustworthy Output, REVIEW only if a trustworthy status write remains possible, FAILED + §8.18 preservation | §8.15; §9 |
| **Whole packet** | **never** automatic across cycles | a new attempt is authorized only when Isaiah / approved upstream deliberately returns it to QUEUE after reviewing prior Output + live target; OR executor proves no consequential work began / prior attempt fully rolled back / op demonstrably safe to repeat / goal already satisfied (verify only) — per §8.8 | — | §9 whole-packet; FR-11; §8.8 |

**Executor in-packet adaptation (§9, FR-11, §8.13):** executor may adapt freely *within* an active packet while state and side effects remain understood — bounded by §8.13 session-local limits (model in allowlist, timeout in bounds, authorized tools, retry delay, fresh-worker/inline, branch/worktree strategy), preserving scope, execution class, review requirement, permissions, replay safety, verification strength.

**Self-recovery boundary (FR-17, §8.12):** repair reversible/local/authority-preserving failures, then prove (what failed, what changed, side-effect state, why replay/continuation is safe, why it stays inside packet authority) before resuming. **Halt + escalate** when the next step would expand authority, repeat an ambiguous/irreversible external effect, bypass review, alter credentials/permissions, or continue from untrusted state. The only autonomous persistent control is a **reversible pause/disable of the affected routine** within the incident boundary, with provider confirmation; Packet Runner may **never re-enable itself** (FR-18, §8.13).

---

## 11. Cross-cutting invariants (quick reference)

- **Coupled lifecycle write (§8.1):** every authorized Status change writes Status + `Lifecycle Checked At` + (while compat requires) `fromStatus` in one logical update, then re-reads. `fromStatus` = the *previous* status. A status change without a matching timestamp/previous-state value is inconsistent ⇒ revalidate before execution.
- **No lock (§6):** QUEUE→FOCUS is best-effort single-writer, not a CAS lock. Any evidence of competing acquisition is an ownership conflict, not permission to continue.
- **No FOCUS reclaim (§6, §8.14):** never auto-resume or redispatch stale FOCUS; report it, move to REVIEW only when ownership is inactive/unprovable.
- **Sequential cross-packet (§6, design principle 4):** packets run one at a time; no multi-packet waves.
- **`max_packets_per_cycle == 1` for the pilot (§6.6, §8.5A).** Intra-cycle refresh never exceeds the cap (§6.9).
- **No forbidden schema fields (§8.1):** never add Ready, Run ID, Worker ID, Claimed By/At, Lease Until, Heartbeat, Attempt, Retry Count, token/cost budget, or a custom cycle ID. Use the native provider execution URL/identifier as the cycle correlation reference (§8.11).
- **Selective telemetry (FR-10, §8.11):** worker writes no AI LOG and no full close-agent chain; one cycle-level closeout; AI LOG only for actionable friction / incident / anticipation gap / user feedback / reusable pattern / system recommendation.
- **Missed runs are not backfilled (FR-8, §8.6).**

---

## 12. BLOCKED / open items

- **No BLOCKED controller-logic items.** Every cycle rule above is fully determined by the cited PRD sections; this is a neutral logic + decision-table specification and required no live Notion mutation.
- **Operator-supplied / deployment inputs** (not controller logic — captured in [`config/routine.config.template.json`](../config/routine.config.template.json), fail-closed per §8.5A): `provider`, `routine_id`, provider workspace/account alias + self-pause action, `schedule`, `project_id`, repo owner/name + default branch + isolation mode, `brief_page_id`, `qualification_evidence_page_id`, `durable_evidence_destination`, default model + allowlist, tool/MCP connections + safe credential aliases, authorized reviewer/operator identities + provider pause authority, and the **provider 9-capability evidence**.
- **Provider capability evidence (FR-9, §8.5A):** the concrete mapping of each capability op (§A) to a *specific* provider's mechanism is BLOCKED: requires real provider integration testing — fail closed on any unverified capability cell. The neutral core here is provider-agnostic and complete; only the thin layer's bindings await that evidence.
- **Scheduling stays disabled** until the §8.20 20-cycle qualification + operator sign-off (PRD §13, §8.20; out of scope for this session). The config template ships with `"schedule": null`.
