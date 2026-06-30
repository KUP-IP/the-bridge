# PKT-MEM-113 — Live Multi-Intent Grade Artifact (M1 → M5 → M8)

**Status:** ⏳ PENDING — operator-run after `make install` + relaunch. Phase 0 (PKT-MEM-106) code is
green at floor 2508 (0a 25 + 0b 26 + 0c 31 tests); the live suite is the on-device acceptance gate.
**Re-test order (locked, Decision 5):** **M1 → M5 → M8** — simple trust path before registry-heavy.
**Mode:** single-memo only — **never** `voice_memo_process mode:batch` or batch the backlog.
**Evidence:** activity-log receipt refs (first-12 of `receiptHash` from
`~/Library/Application Support/The Bridge/memory-hub/activity.jsonl`) **plus** the fixed table below.

| Case | Build | Memo ID | Grade | Receipt refs (first-12 hashes) | Cleanup status | Notes |
|---|---|---|---|---|---|---|
| M1 | v3.8.3 / commit … | … | PASS/PARTIAL/FAIL | … | pending/done/partial | primary reminder; 3 suppressed distinct; append-only + processed-gate evidence |
| M5 | v3.8.3 / commit … | … | PASS/PARTIAL/FAIL | … | pending/done/partial | one registry primary; 2 suppressed distinct; picker/rowId append proof |
| M8 | v3.8.3 / commit … | … | PASS/PARTIAL/FAIL | … | pending/done/partial | reminder primary; ≤4 suppressed distinct; duplicate block/force proof |

## PKT-MEM-120 W1 merge gate (2026-06-30)

Required **before** merging `feat/mem-120-routing-quality-ux`. Single-memo only.

| Case | Build | Mode | MCP | Memo ID | Grade | Receipt refs | Notes |
|------|-------|------|-----|---------|-------|--------------|-------|
| W1-A | v3.9.2 build 68 / `037a70b` | Auto | Cursor connected | `20260204 200742-56AF3049.m4a-17800675-1770264815` | PASS | `cf424aa32421` | defer — no autonomous write; `agent_memory` commit OK; `processed:true` after commit |
| W1-B | v3.9.2 build 68 / `037a70b` | Auto | Bridge alone | — | **PARTIAL** | _(hermetic)_ | **Blocked in-session:** Cursor HTTP MCP keeps `clients:1` → presence true. Hermetic `deferExecute_autoMode_alone_autonomous` green. Operator: quit Cursor ≥5s, process one memo, fill row. |
| W1-C | v3.9.2 build 68 / `037a70b` | Connected MCP agent | Cursor connected | `20260130 171649-D4A3F901.m4a-426976-1769816399` | PASS | `f9b6f22239e4` | defer matches W1-A; review dismissed after smoke (memo stays unprocessed) |

## Protocol (operator)

1. **Build/relaunch:** `make test` → `make app` → `make install-copy` (or signing-backed `make install`) → `open -a "The Bridge"`.
2. **Tool check:** confirm `tools_list` exposes `voice_memo_get`, `voice_memo_commit`, `memory_forget`.
3. **Per case:** record ONE memo per signal → `voice_memo_get` → dry-run → `voice_memo_commit` per intent.
   Confirm pending count with `voice_memo_review_list` after each. Halt the order on a FAIL/BLOCKED rung
   (don't run M5 if M1 trust failed; don't run M8 if M5 registry path failed).
4. **Trust invariants to capture every case:** exactly one primary auto-executes (lane-priority-first);
   suppressed lanes stay distinct (`secondary intent suppressed`, distinct `intentId`); protected registry
   fields append-only; processed only when no pending sibling review; agent memory stores the full transcript.
5. **Force hygiene:** any forced duplicate commit during the suite uses force reason `live_test`.
6. **Cleanup (record status above):** `reminders_delete` test reminders · additively revert appended test
   notes on Jacob/DST-8/Bridge v4 (protected fields are append-only — never silently overwrite) ·
   `registry_delete` test rows · `memory_forget` test memories · `voice_memo_review_dismiss` stale inbox ·
   curator mode → Auto · filter `activity.jsonl` test receipts by force reason `live_test`.

## Rubric

- **PASS** — primary correct (priority-first); append-only verified; suppressed count + identities correct/distinct; processed gate correct; activity receipts present per phase.
- **PARTIAL** — primary correct but suppressed count/identity off, OR datetime missing (pre-PKT-MEM-107), OR receipt evidence incomplete with no trust violation.
- **FAIL** — protected-field overwrite; wrong-entity write; processed-with-pending-sibling; truncated agent memory; same-kind lanes collapsed.
