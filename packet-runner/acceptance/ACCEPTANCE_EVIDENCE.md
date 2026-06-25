# Acceptance Evidence — T1–T114 (run 2026-06-23)

Honest, non-fabricated evidence status for every acceptance test. Classification +
how-to-verify in [`ACCEPTANCE_MATRIX.md`](./ACCEPTANCE_MATRIX.md).

## Summary

| Class | Count | Evidence status |
|---|---:|---|
| **AUTOMATABLE-NOW** | 51 | ✅ **51/51 PASS** — deterministic controller core (`controller/decisions.py`), 53 test functions, `python3 test_decisions.py` → 53 passed / 0 failed. Raw: [`evidence/CONTROLLER_TEST_RESULTS.txt`](../evidence/CONTROLLER_TEST_RESULTS.txt). |
| **PROVIDER-INTEGRATION** | 48 | ⛔ BLOCKED — require a live provider routine + repo. Deterministic **sub-helpers** verified where they exist (10 IDs below). End-to-end pending provider selection + pilot. |
| **GOVERNANCE** | 9 | ⛔ BLOCKED — require a real authorized-human decision artifact (PACKET DECISION comment / cancellation / operator re-enable / qualification sign-off). Cannot be fabricated; sub-helpers verified where they exist. |
| **PILOT-ONLY** | 6 | ⛔ BLOCKED — require the real 20-cycle scheduled streak (T94–T98, T109). "Satisfied only by the real scheduled pilot, not simulation" (§11). |

Plus: **registry hydration** (FR-1/§8.3) — 10 Swift tests in `TheBridgeTests/RegistryHydrationTests.swift`, green inside the full **2252-pass** harness (`make test`, 0 failed; floor 2242→2252).

## AUTOMATABLE-NOW — 51/51 PASS (deterministic, controlled inputs, no provider/human)

Each maps to a `decisions.py` function exercised by a named test (T-id in the test label):
- Receipt→status §8.5: T10, T70 (+ sub-helpers T2/T3/T8/T19). Replay §8.8: T16, T17.
- Eligibility §6: T1, T4, T5, T20, T110. Cap/order: T11, T12.
- Window §8.1: T102. Stale-state §8.14: T61, T64, T65. Material/approval §8.8/§8.10: T18, T32.
- Source of Truth §8.16: T71, T72, T73, T74, T75. PACKET DECISION §8.10: T33, T113, T31 (+ T29/T30 sub).
- AI-LOG threshold §8.11: T13, T46. Health §8.11: T37 (+ T42/T43 sub).
- Compaction §8.15: T66, T67, T68, T70, T69, T103. Cleanup §8.17: T76, T78, T79, T81, T107.
- Archival §8.19: T88, T89, T92 (+ T93 sub). Schema preflight §8.1: T100.
- Brief §8.6: T36, T40. Review/cancel completeness §8.10: T28, T105 (sub).
- Adaptation §8.13: T49, T54, T55, T56, T60. Privilege guard §8.9: T24.

## Deterministic sub-helpers of GATED tests — also verified (10)
T2, T3, T8, T19 (receipt-mapping floor) · T29, T30 (decision-transition floor) · T42, T43 (health-precedence floor) · T93 (archive protection-gate floor) · T105 (cancellation-receipt completeness floor). The **end-to-end** rows remain gated; only the named deterministic floor is unit-tested.

## PROVIDER-INTEGRATION (48) — BLOCKED on live provider + repo
T2, T3, T6, T7, T8, T9, T14, T15, T19, T22, T23, T25, T26, T27, T34, T35, T38, T39, T41, T42, T43, T44, T45, T47, T48, T50, T51, T52, T53, T57, T59, T62, T63, T77, T80, T82, T83, T84, T85, T86, T91, T93, T99, T101, T104, T106, T112, T114.
*Unblock:* select the provider (§8.5A), bind a routine to a real repo/project, run manual `Run Now` integration scenarios (no unattended schedule) per PRD §10 Phase 3 bullet 2.

## GOVERNANCE (9) — BLOCKED on authorized-human decision
T21 (cancel), T29 (approve), T30 (continue), T58 (operator re-enable), T87 (resolution authority), T90 (learning promotion), T105 (cancellation authority), T108 (operator-frozen qual doc), T111 (operator corrective reopen).
*Unblock:* a real `PACKET DECISION` / cancellation / re-enable / qualification record by an identity in the declared authority scope. The system must never self-approve (§8.10, §8.13, §8.20).

## PILOT-ONLY (6) — BLOCKED on the 20-cycle scheduled streak
T94, T95, T96, T97, T98, T109. *Unblock:* the real scheduled pilot (max_packets_per_cycle=1) running 20 consecutive clean cycles + operator `PRODUCTION_QUALIFIED` sign-off (§8.20). **No simulation permitted (§11).**

## Pre-pilot integration evidence still required (§8.20)
Critical-session export/fallback, self-pause, cancellation, permission denial, ambiguous-worker handling, schema failure, archival-with-controlled-clock — provable in pre-pilot provider integration tests (a real critical incident cannot be part of a HEALTHY streak). All gated on provider selection.
