# Provider Decision Proposal — Packet Runner v1

**Date:** 2026-06-24 · **Author:** implementation agent · **Decision owner:** Isaiah (operator).
Synthesizes the three BLOCKING capability findings (#1 non-overlap, #7 pause, #8 completion notification) into a recommended provider decision + the exact remaining operator inputs. Grounded in doc research (`evidence/INTEGRATION_NON_OVERLAP.md`, the §8 capability research) + the implemented controller latches. **Scheduling stays disabled until this decision is made and the live checks pass.**

## TL;DR
Two of the three blocking gaps are **resolved by controller-side fail-closed latches** the PRD explicitly permits (§8.5A), implemented + unit-tested. The third — **#8 native completion notification — is the real decision**, because §8.6 forbids the obvious workaround (custom Slack/email). Recommendation: **try to keep Claude Code (already-connected) by resolving #8 via a 10-minute live check + a light §8.6 interpretation you sign off on; fall back to Cursor only if that fails.**

## Capability findings (Claude Code Routines)

| # | Capability | Documented? | PRD workaround allowed? | Status |
|---|---|---|---|---|
| **1** | Routine non-overlap | ❌ none | ✅ §8.5A fail-closed latch | **Resolved** — `overlap_gate`/`overlap_verify` built + tested (T99). Live overlap experiment pending. |
| **7** | Machine-callable pause | ❌ UI-toggle only (no API; only `POST …/fire` exists) | ✅ §8.5A fail-closed latch | **Resolved** — `pause_gate`/`request_pause`/`may_reenable` built + tested (T57/T58), same latch store + a `disabled` flag. Live pause-confirm check pending. |
| **8** | Native completion notification **linking to the brief** | ❌ **no native completion notification documented** (only a session-transcript URL; channels are inbound-only) | ❌ **NO** — §8.6: "Do not add email, Slack, SMS, or custom push infrastructure"; "a provider lacking this is rejected for v1" (T38) | **DECISION REQUIRED** (below). |

#1 and #7 share one mechanism: a single-writer latch in the `durable_evidence_destination` (a Notion property / page / repo path) holding `{holder, acquired_at, expires_at, disabled}`. The cycle reads it first and (a) refuses on a fresh foreign holder → `NOT_STARTED_OVERLAP`, (b) aborts if `disabled` → paused. The controller never clears `disabled` (operator-only re-enable). This is provider-neutral — it works the same if we switch providers.

## The #8 decision (the only true fork)

§8.6 makes a *native* completion notification that links to the canonical brief a hard selection requirement and **forbids** building our own Slack/email/SMS. Claude Code Routines documents **no** native completion notification at all — only a run-history entry + session-transcript link. Three options:

**Option A — Keep Claude Code; resolve #8 by interpretation (RECOMMENDED to try first).**
- **Live check (~10 min):** create a throwaway routine, run it, observe whether claude.ai / Claude Code emits *any* native completion notification (in-app/email/push) and what it links to.
- If it notifies but links only to the **session**: adopt the convention that the routine's **final session message leads with the canonical brief URL**, so the native completion surface reaches the brief in one hop. This uses only the provider's own surface + our own output — **not** custom push infrastructure — but it's a borderline reading of "links to the canonical brief," so it needs your explicit **sign-off that it satisfies §8.6's intent** (a light governance call, recorded in the routine config).
- **Pro:** Claude Code is already-connected; #1/#7 already mitigated; smallest path to a pilot. **Con:** depends on an undocumented notification existing; the "one-hop" reading is a judgment call only you can ratify.

**Option B — Switch v1 provider to Cursor (PRD-faithful fallback).**
- Cursor documents **native completion signals** — ERROR/FINISHED **webhooks** + Slack completion (matrix capabilities 5/6/8 verified-by-doc) — so #8 is closest to natively satisfiable (verify the notification can carry the brief URL).
- **Cost:** Cursor is **not already-connected** → new integration + credentials; and #1 (non-overlap) is `unknown` for Cursor too (the same latch applies, but must be tested), plus re-verify isolation/exec-reference/pause. **Con:** more setup; **Pro:** strict §8.6 compliance without an interpretation call.

**Option C — Revise PRD §8.6 (governance).** You amend §8.6 to accept a degraded model (e.g., "native session-completion surface + brief URL as the session's first output line"). This is a PRD change — your call as author; I will not make it unilaterally. (Option A is effectively C-lite, scoped to one provider, pending your sign-off rather than a PRD edit.)

**Recommendation:** Try **A** first (run the live notification check; if it only session-links, ratify the one-hop convention). If you judge that insufficient, take **B (Cursor)**. Either way #1/#7 are already handled by the latches.

## What's resolved vs. what still needs you

**Resolved (deterministic, tested — no operator action):** #1 non-overlap latch, #7 pause/kill-switch latch (controller suite 57/57 green; `evidence/CONTROLLER_TEST_RESULTS.txt`).

**Operator decisions:**
1. **#8 path:** A (Claude Code + §8.6 sign-off) vs B (switch to Cursor) vs C (PRD revision). ← the gating decision.
2. If A: ratify the "brief-URL-first-line" convention as satisfying §8.6.

**Operator inputs still required (unchanged from the completion report):** provider `routine_id` + workspace alias; reviewed `schedule`; `project_id` + repo owner/name/branch/isolation; `durable_evidence_destination` (also hosts the latch); model allowlist; credential aliases; reviewer/operator identities.

**Live checks before scheduling (per chosen provider):**
- #1 overlap experiment (`evidence/INTEGRATION_NON_OVERLAP.md`) — fire a manual run during a sleeping scheduled run; confirm `NOT_STARTED_OVERLAP`, no packet, brief untouched.
- #7 pause-confirm — set the `disabled` flag mid-incident; confirm the next cycle aborts and the write is re-read-confirmed.
- #8 notification — per the chosen option, confirm the operator actually receives a completion signal that reaches the brief.

**Status unchanged: NOT production-qualified.** This proposal closes the *analysis* on #1/#7 and frames the #8 decision; the 20-cycle pilot + operator `PRODUCTION_QUALIFIED` sign-off remain (§8.20).
