# Integration Test — Capability #1: Routine-level non-overlap (T99)

**Date:** 2026-06-23 · **Provider under test:** Claude Code (Routines / scheduled cloud agents) · **PRD:** §6 step 1, §8.5A FR-9 #1, §8.13, T99.

> **Why blocking:** Notion has no compare-and-swap lock, so Packet Runner's "best-effort QUEUE→FOCUS acquisition" (§6) depends on the provider guaranteeing only one cycle of a routine runs at a time. If two cycles overlap, two workers could claim the same packet → duplicate execution (the #1 thing the qualification gate forbids). §6 step 1: a provider that "deterministically refuses this invocation because another is active" → `NOT_STARTED_OVERLAP`; if an invocation started but overlap "cannot be ruled out" → **FAILED**.

## Finding — provider behavior is UNDOCUMENTED (a gap, not a pass)

Authoritative doc research (Claude Code Routines docs + Routines API + scheduled-tasks docs):

| Question | Verdict | Source |
|---|---|---|
| Does a second trigger while a run is active get skipped/queued/refused? | **UNKNOWN — undocumented** | [routines](https://code.claude.com/docs/en/routines) |
| Config for single-flight / `max_concurrency=1`? | **None exists** in the documented API/UI | [routines](https://code.claude.com/docs/en/routines), [routines-fire API](https://platform.claude.com/docs/en/api/claude-code/routines-fire) |
| Manual "Run now" vs in-progress scheduled run? | **Undocumented** (trigger returns once the session is *created*; overlap semantics silent) | [routines-fire API](https://platform.claude.com/docs/en/api/claude-code/routines-fire) |
| Missed-run: backfill or skip? | `/loop`: **skip-to-next (verified)**; **Routines: undocumented** | [scheduled-tasks](https://code.claude.com/docs/en/scheduled-tasks) |
| Skip-due-to-overlap signal exposed? | **None documented** | [routines](https://code.claude.com/docs/en/routines) |

**Verdict: capability #1 is NOT satisfied by Claude Code Routines on documented evidence.** Default assumption for any scheduler lacking a documented non-overlap guarantee = *concurrent runs are possible*. This was the matrix's #1 BLOCKING cell; the research **confirms** it is a gap, not a pass. *(Same gap, or worse, applies to Cursor and Codex — Codex is parallel-by-design.)*

## Resolution — controller-side fail-closed latch (PRD §8.5A-permitted)

§8.5A explicitly permits "a deterministic provider-native **fail-closed latch** scoped to this routine." Since the provider guard is absent, the controller enforces non-overlap itself with a single-writer latch checked **before any FOCUS write**:

**Latch record** (persisted in `durable_evidence_destination` — a stable Notion page/property or repo path; never ephemeral): `{ holder: <native execution reference>, acquired_at, expires_at = acquired_at + cycle_timeout }`. `cycle_timeout < schedule interval` (§8.5A), so a healthy cycle always releases before the next fires.

**Cycle-start protocol (before any packet mutation):**
1. Read the latch.
2. `overlap_gate(latch, now, our_id)` (implemented + tested — `controller/decisions.py`, T99):
   - absent → **ACQUIRE**: write `{our_id, now, now+cycle_timeout}`, then re-read and `overlap_verify` → PROCEED only if the re-read shows **our** holder (best-effort single-writer; a concurrent writer winning ⇒ **FAILED**, no packet).
   - held by us → PROCEED (idempotent re-entry).
   - **fresh latch held by another** → `NOT_STARTED_OVERLAP`: start no packet, **do not overwrite the active brief** (§6 step 1). Does not advance the qualification streak (§8.20).
   - **stale latch held by another** (past `expires_at`) → **FAILED** + pause-required: a prior cycle left a latch past `cycle_timeout`; overlap cannot be ruled out (the prior may be hung). Operator confirms the prior is dead and clears the latch (does not auto-reclaim — mirrors §8.14 stale-FOCUS caution).
3. On cycle exit (success or handled failure) → release the latch (clear holder).

**Deterministic coverage:** `overlap_gate` + `overlap_verify` are unit-tested (T99) — absent/held/fresh-other/stale-other and the re-read race. This is the AUTOMATABLE core of T99; **PASS** (`python3 controller/test_decisions.py` → 55/55).

## Still required — live end-to-end experiment (operator, when a routine exists)

The latch proves the *controller* refuses overlap deterministically. A live run must still confirm (a) the provider's *actual* overlap behavior, and (b) the latch holds end-to-end against a real concurrent trigger. **Minimal experiment:**

1. Create a routine whose prompt acquires the latch, writes a marker, **sleeps ~90s**, then releases.
2. Schedule at the minimum interval; while run #1 is in its sleep, fire a **manual "Run now"** (and/or let the next scheduled tick fire).
3. **Observe** the routine's run list + the marker/latch:
   - Two concurrent sessions both past the gate → provider has **no** non-overlap AND the latch failed (investigate). 
   - Second session present but it **recorded `NOT_STARTED_OVERLAP` and started no packet / left the brief unchanged** → latch works (the target result).
   - Provider itself skipped/queued the second → provider *does* enforce non-overlap (bonus; latch still belt-and-suspenders).
4. Repeat with a **scheduled+scheduled** overlap (force a cycle to exceed the interval once) to exercise the stale-latch → FAILED path.

Record the run URLs + latch states as the T99 integration evidence. Until this passes, **scheduling stays disabled** (§13).

## Net status of capability #1
- Provider-native guarantee: **absent (documented gap).**
- Controller mitigation: **implemented + unit-tested (deterministic, PASS).**
- End-to-end live proof: **PENDING** — needs a real routine (operator deployment input). **Capability #1 remains a gate** until the live experiment passes; the latch makes it *closable* rather than a hard blocker.
