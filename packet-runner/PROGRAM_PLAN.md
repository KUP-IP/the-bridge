# Packet Runner v1 — Implementation Program Plan

**Source of truth:** [`_refs/PRD-v1.0.md`](./_refs/PRD-v1.0.md) (Notion: Packet Runner v1 — PRD, 388cbb58889e81b187bcc2fed832dcf3).
Where executor/orchestrator/close-agent/source-packet conflict with the PRD, **the PRD governs** Packet Runner integration (PRD §14.1).

## What this system actually is (scope reality)

Packet Runner is a **repository-scoped, provider-native automation routine** (Claude Code / Cursor / Codex), not primarily Swift code in The Bridge. The work spans four surfaces:

1. **Live Notion schema migrations** — PACKETS (`078e7c9e-e53e-4c83-a893-af64f82b5123`) + AI LOGS (`992fd5ac-d938-4be4-95fb-8ef18bd86bba`). Additive-first, legacy-preserving (§8.1, §8.7).
2. **Three shared agent-skill contracts** — executor v8 → Packet-Runner-compatible, orchestrator v7, close-agent v3.1.0 (§Phase 0).
3. **Provider-native routine** — config + capability layer + controller logic; scheduling stays **disabled** until validation complete.
4. **Bridge Swift code** — registry `packet-registry-v1` hydration envelope (FR-1, §8.3) in `TheBridge/Modules/Registry/`.

## Honest gate map — what is determinable now vs. blocked

| Work | Determinable now? | Gate |
|---|---|---|
| Additive schema migration (add props/options, non-destructive) | ✅ Yes — apply live, snapshot first | reversible |
| Destructive record remap (Backlog→BACKLOG, Done→DONE, Decline→CANCELED) + legacy-option delete | ⛔ Deferred | PRD §8.1 step 4–7: "until validation passes"; irreversible |
| Skill contract revisions (executor/orchestrator/close-agent) | ✅ Author + apply with version bumps | shared infra — apply deliberately |
| Registry `packet-registry-v1` envelope + tests | ✅ Yes — Swift + `make test` | — |
| Controller logic (provider-neutral) + deterministic tests | ✅ Yes — code + unit tests | — |
| Provider **selection** with verified 9-capability evidence | ⚠️ Partial | real integration testing required; FAIL CLOSED on unverifiable cells (§8.5A, FR-9) |
| Routine config | ⚠️ Template only | operator-supplied deployment inputs (schedule, repo, creds, page IDs, reviewer identities) |
| Brief + qualification Notion docs | ✅ Create | — |
| Acceptance T1–T93, T99–T114 (deterministic / integration / governance) | ⚠️ Mixed | automatable subset runs now; integration+governance need live provider/human |
| **T94–T98 + 20-cycle production qualification** | ⛔ Impossible now | "satisfied only by the real scheduled pilot, not simulation" (PRD §11); operator sign-off |

**Directive-aligned ceiling:** implementation-complete artifacts + applied safe/reversible changes + real deterministic test evidence + provider recommendation w/ capability-evidence checklist + exact operator-gated remainder. **Scheduling OFF. No production-readiness claim** (separate 20-cycle gate + authorized operator approval — PRD §13, §8.20).

## Phases (PRD §10)

- **Phase 0** — Reconcile upstream contracts + apply PACKETS/AI LOGS target schema (additive), managed `## Packet Runner Output` structure, status model, permissions, review contract, brief, observability, self-recovery, stale-state, Output compaction, Source-of-Truth, cleanup, evidence preservation, AI LOG resolution/archival.
- **Phase 1** — Complete registry hydration foundation + tests.
- **Phase 2** — Build the primary-provider routine (config validation, preflight, QUEUE query, hydration, eligibility, ordering, cap, live check, QUEUE→FOCUS, dispatch, receipt verify, reconcile, maintenance, brief/notify, qualification row). Provider mechanics in a thin capability layer.
- **Phase 3** — Acceptance validation: deterministic tests + provider integration scenarios (no unattended schedule) + manual governance scenarios; store evidence.
- **Phase 4** — Scheduled pilot + 20-cycle qualification. **OUT OF SCOPE for this session** (operator-gated).

## Operator-supplied deployment inputs still required (§8.5A) — fail closed

`provider`, `routine_id`, provider workspace/account alias + machine-callable self-pause/disable; `schedule` (no unattended run until reviewed); `project_id`, repo owner/name + default branch + isolation mode; `brief_page_id`, `qualification_evidence_page_id`, `durable_evidence_destination`; default model + allowlist; core tool/MCP connections + safe credential aliases; authorized reviewer/operator identities + provider pause authority; provider capability results.
