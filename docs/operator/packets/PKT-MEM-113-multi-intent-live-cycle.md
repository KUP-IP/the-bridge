# PKT-MEM-113 — Multi-Intent Live Testing & Wave 3 Execution

**Wave:** 3 (execution packet — child of PKT-MEM-112)  
**Class:** Standard  
**Execution Class:** REVIEW-FIRST  
**Priority:** 85  
**Orchestrator:** v7.1.0 · dispatched 2026-06-24  
**Branch:** `feat/memory-hub-voice-curator` (rebase onto `origin/main` before merge)  
**Lifecycle Checked At:** 2026-06-24  
**Status:** QUEUE  
**Fetch priority:** `executor` → then `mac-keepr` for live MCP ops

---

## Goal Contract

**Outcome:** Operator completes multi-intent voice memo live suite (M1–M10) against notarized Bridge v3.8.2+ with trust invariants verified; Wave 3 code phases (107–111b) execute sequentially with floor raised per phase.

**Scope IN:**
- Live MCP testing via single-memo `voice_memo_get` → dry-run → execute / `voice_memo_commit`
- Multi-intent suite: `docs/operator/MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md`
- Wave 3 implementation per `docs/operator/packets/PKT-MEM-112-wave3-deferred-closeout.md`
- PR #57 integration path to `main`

**Scope OUT:**
- Batch `voice_memo_process` on 238-memo backlog
- Production release tag (operator decides)
- Notion PACKETS DS page sync (repo packets are SSOT for Cursor)

**Constraints:**
- PKT-MEM-105 trust invariants are sacred (append-only, primary election, processed gate, full agent transcript)
- `make test-floor` must stay green; raise FLOOR only with net-new tests
- Install ladder: `make test` → `make app` → `make install-copy` or `make install` → `open -a "The Bridge"`

**Success Criteria:**
- [ ] M1, M5, M8 live passes documented (minimum bar for multi-intent)
- [ ] Smoke script 21/21 green post-relaunch
- [ ] At least one Wave 3 phase merged with tests + floor bump
- [ ] No registry overwrites in live verification

**Verification:**
- `python3 scripts/memory_hub_smoke.py` exit 0
- Per-memo MCP receipts with intent outcomes logged
- `make test-floor` green
- Operator sign-off on Process tab preview accuracy

**Review Requirement:** Operator reviews live test grades (PASS/PARTIAL/FAIL) before merge to `main`. Executor stops at REVIEW if M5 election behavior contradicts operator intent without Phase B registry picker.

**Failure / Stop Conditions:**
- Batch process timeout on full backlog → STOP, use single-memo only
- Trust invariant violation (overwrite, truncated agent memory) → BLOCKED until PKT-MEM-105 regression fixed
- `make install` unavailable → fall back to `install-copy`, note in receipt

**GOAL_CONDITION:** Achieve documented multi-intent live pass on Bridge v3.8.2+ (M1/M5/M8 minimum) within single-memo MCP workflow, prove append-only + election invariants, execute Wave 3 phases 107→111b sequentially with green test-floor, stop in REVIEW when operator must choose registry target or execution class ambiguity.

---

## Current System State

| Surface | State |
|---------|-------|
| Binary | `/Applications/The Bridge.app` v3.8.2 notarized (2026-06-24) |
| Branch | `feat/memory-hub-voice-curator` · PR #57 |
| Test floor | **2303** (2292 + 11) |
| Tools | 187 MCP tools incl. `voice_memo_get`, `voice_memo_commit`, `memory_forget` |
| Unprocessed memos | **238** — do NOT batch |
| Registry entities | memory, contact, project, session, block |
| Shipped | PKT-MEM-105, 110a, 111 U1+U6 |

**Key docs:**
- `docs/operator/MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md` (M1–M10)
- `docs/operator/packets/PKT-MEM-112-wave3-deferred-closeout.md`
- `docs/operator/MEMORY-HUB-DISPATCH-MANIFEST.md`

---

## Dependencies

| Upstream | Status |
|----------|--------|
| PKT-MEM-105 trust | ✓ shipped |
| PKT-MEM-110a curator | ✓ shipped |
| PKT-MEM-111 U1+U6 UI | ✓ shipped |
| `make install` | ✓ done 2026-06-24 |
| Operator voice recordings | **BLOCKING live suite** |
| PKT-MEM-107 datetime | Optional for M7 B2 due-date pass |

---

## Execution Directives (§SB Boot)

1. Load `executor` skill — Goal Contract governs.
2. **Live testing:** one memo per operator signal (`M5 done`). Never `mode: batch`.
3. **Development:** one Wave 3 phase per branch; tests + floor bump each phase.
4. Resolve suppressed intents via Inbox or `voice_memo_commit`.
5. Cleanup after session: reminders_delete, registry revert, memory_forget, registry_delete test rows.
6. Propose completion receipt in managed Output section below.

---

## Brief Contract

Operator sees: live test grade table, Inbox count, floor number, PR readiness, explicit deferrals remaining.

---

## Packet Runner Output

### Current Canonical Result

*(Executor writes here)*

### Artifact Manifest

*(Executor writes here)*

### Exceptional History

*(Executor writes here)*
