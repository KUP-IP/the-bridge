# Upstream contract conflicts — live skills vs. PRD (Phase 0)

Live skill bodies cached in `_refs/`: executor → `executor-v8.0.0.md`. Orchestrator v7.0.0 and close-agent v3.1.0 read 2026-06-23 (summaries below).

## executor v8.0.0 (page `b2eb533e3be1465b86d41af6937db638`)

| Conflict | Live (v8) | PRD requires |
|---|---|---|
| Claim/identity | §0.SA.4 + §3.PF.2 + §3.R **require** Run ID, Worker ID, claim/lease/heartbeat metadata | Remove all; best-effort QUEUE→FOCUS evidence + `observedLastEditedTime` only (FR-5, §8.4) |
| Budgets | §3.PF.5 requires turn/time/retry/cost budgets in envelope | Excluded from dispatch (FR-5) |
| Concurrency | §3.R: controller "enforces global concurrency… renews/monitors leases… reclaims stale runs" | No leases/reclaim; provider non-overlap; no auto-reclaim of stale FOCUS (§6, FR-4) |
| Replay states | Informal "first-run / safe replay / resume / already satisfied" | Explicit FIRST_RUN / ALREADY_SATISFIED / SAFE_RESUME / UNSAFE_AMBIGUOUS + SAFE_RESUME gate (§8.8) |
| Material-revision guard | Idempotency check; no explicit timestamp→contract-diff rule | On lastEditedTime mismatch, compare execution-critical contract; MATERIAL_CHANGE→REVIEW (FR-6, §8.8) |
| Receipt | "v8 Completion Receipt" (GOAL_STATE…) free-form | `packet-runner-receipt-v1` YAML (§8.5): packet_contract_state, criteria_results, verification_evidence, artifacts_modified{retention_class,ownership,authoritative_locator}, replay_state, failure_class, native_execution_url… |
| Status mapping | Backlog/Done/Review; **BLOCKED→Backlog** | BLOCKED = own status only when prereq+owner+unblock known; ambiguous→REVIEW (§8.5 mapping, §6) |
| Telemetry | Session posture writes full AI LOG + close-agent | Worker writes **no** AI LOG, **no** close-agent chain (FR-10) |
| Output target | Overwrites `## Output` | Proposes only inside reserved `## Packet Runner Output` (### Current Canonical Result / ### Artifact Manifest / ### Exceptional History); Packet Runner writes final (§8.2, §8.15) |

## orchestrator v7.0.0 (page `d0925acdd04c4a15b60fc1c98245ff82`)

| Conflict | Live (v7) | PRD requires |
|---|---|---|
| QUEUE semantics | QUEUE set when Fresh-Agent Test + Autonomy Gate pass | QUEUE = **freshness-bounded** readiness cert; stamp `Lifecycle Checked At`; expires at 7d (FR-2, §8.14) |
| Known blockers | Phase 2 queues; blockers→Backlog note | Known unmet prereq w/ unblock condition → **BLOCKED**, not QUEUE (FR-4, two-stage permission §8.9) |
| Execution Class | "execution class/review signal where supported" (soft) | **Explicit** Execution Class property required; missing → fail-closed REVIEW (FR-3) |
| Managed Output | Body ends at `## Output` | Author reserved `## Packet Runner Output` heading (empty managed section) (§8.2) |
| Telemetry | Phase 5 "**drain every** sub-agent payload into AI LOGS" | **Selective** telemetry — AI LOG only for actionable friction/incident/learning (FR-10, §8.11) |
| Dispatch breadth | broad multi-packet waves | Packet Runner cycles are **sequential** cross-packet (design principle 4) |
| Capability/permission | not authored | Author Required Capabilities / Prohibited Actions only when nonstandard; BLOCKED vs REVIEW classification (FR-13, §8.9) |
| Replay/recovery section | not authored | Add compact Replay and Recovery section when consequential external effects (§8.8) |

## close-agent v3.1.0 (page `6673dba826b14b1daa0a6aad084a861c`)

| Conflict | Live (v3.1.0) | PRD requires |
|---|---|---|
| Mode split | One 7-phase chain for all sessions | **interactive / worker / cycle** modes (FR-10, §Phase 0) |
| Worker mode | runs full closeout (retro, telemetry, finalize) | **Skipped** — executor returns receipt; no second closeout |
| Telemetry | Phase 5 mandatory AI LOG every session | Cycle mode: **selective** — only meaningful incident/learning |
| Status cascade | Phase 3 child Done→parent REVIEW etc. | Cycle mode reconciles **receipts**, not generic cascades |
| Skill-audit mutation | Phase 6 sets SKILLS Status→Auditing | Not a Packet Runner cycle responsibility |
| Packet finalize | Phase 7 sets packet Status→DONE | Packet Runner owns final reconciliation + status; DONE gated on receipt+verify+Source-of-Truth (§8.5) |
| Cycle brief | none | Cycle mode produces attention-first canonical brief (§8.6) |

## Remediation outputs (artifacts in `skills/`)
- `executor-v8.1.0-packet-runner.md` — revised body + evolution-log entry.
- `orchestrator-v7.1.0.md` — revised body + evolution-log entry.
- `close-agent-v3.2.0.md` — mode-split body + evolution-log entry.
Each preserves the skill's existing structure (MC JSON, §CC capsule, §R synced block, version refs in all locations) and bumps version per the skill's own conventions.
