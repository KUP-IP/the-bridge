# Phase 0 — Real-World Test Playbook + Results

**Build:** v3.8.2/61 notarized + installed 2026-06-25 (PKT-MEM-106 Phase 0).
**Roles:** **You (operator)** record memos + take on-device actions. **Claude (driver)** validates with MCP tools, grades, and logs friction.
**Mode:** single-memo, **real writes** (live). Never `voice_memo_process mode:batch`. Forced duplicate commits use reason `live_test`.

---

## How to run + track (read first)

**The loop for every test:**
1. **You** do the listed action (record a memo / click in the app). Memos are named (e.g. `Bridge RT1`) so I find them instantly.
2. **I** validate **read-only first** (`voice_memo_get`, `voice_memo_process dryRun:true`, `voice_memo_review_list`) and tell you the predicted routing.
3. **You** approve the **write** (a commit creates a real reminder / Notion row). Nothing writes without your explicit "go".
4. **I** confirm the write held the invariant, then **grade** it and **log friction**.

**Where results live (this file):**
- **Results table** (below) — one row per test: `PASS / PARTIAL / FAIL` + the evidence (intentIds, registry content, receipt hashes).
- **Friction log** (below) — anything that slowed you, surprised you, or read wrong (latency, parser miss, UX confusion) with a severity + a fix idea.
- **Durable receipts** — every write appends to `~/Library/Application Support/The Bridge/memory-hub/activity.jsonl`; I cite the **first-12 chars of each `receiptHash`** so a grade is auditable later.

**Grade rubric:**
- **PASS** — the invariant held *and* the routing matched the expected outcome.
- **PARTIAL** — primary lane correct but a non-trust issue (e.g. reminder title too broad, evidence incomplete, datetime missing).
- **FAIL** — a trust breach: protected-field **overwrite**, same-kind lanes **collapsed**, **processed while a sibling review is pending**, **truncated** agent memory, or a write to the **wrong target**.

---

## The tests

### RT-1 — Multi-intent election + suppression  ★ headline
**Proves:** lane-priority-first election; exactly **one** primary auto-executes; the rest are suppressed as **distinct** review lanes.
**Prereq:** review queue empty (confirmed: 0 pending).

**Steps**
1. **You:** Voice Memos → record, rename **`Bridge RT1`**, read naturally, stop:
   > *"Remind me at four PM to send Jacob the Phase 0 test results. Also update the Bridge v4 project — we shipped the trust fixes this week. And keep this note: I prefer adversarial sub-agent reviews per slice."*
2. **Me:** `voice_memo_get` → show the transcript + the **3 parsed intents** with their `intentId`s.
3. **Me:** `voice_memo_process dryRun:true` → show the election: **execute = 1** (reminder), **suppressed = 2** (project, keep).
4. **You:** "go" → I commit the reminder; the two suppressed lanes stay in review.

**Expected:** reminder elected primary (title scoped to *"send Jacob Phase 0 test results"*, due 4 PM — not the whole paragraph); `registry_update`(project Bridge v4) + `memory_keep` suppressed with **two different** `intentId`s.
**PASS if** 1 reminder in `execute`, 2 distinct suppressed. **FAIL if** 0 or >1 primary, or the two suppressed share an `intentId`.
**Track:** the 3 `intentId`s + election outcome; reminder receipt hash; friction = transcription latency + parse accuracy + title scoping.

---

### RT-2 — Same-kind registry distinctness  (the M5 core)
**Proves:** two `registry_update` lanes from one memo stay **distinct**, never collapsed (the bug 0a fixed).

**Steps**
1. **You:** record + rename **`Bridge RT2`**, read:
   > *"Update session DST-8 — focus is the trust fixes. And update the Bridge v4 project — we ship Phase 0 this week."*
2. **Me:** `voice_memo_get` → confirm **two** `registry_update` intents (entity `session`/hint `DST-8`, and entity `project`/hint `Bridge v4`) with **different** `intentId`s.
3. **Me:** `voice_memo_process dryRun:true` → one registry lane auto (higher confidence), the **other distinct** lane suppressed.

**Expected:** 2 registry lanes, 2 different `intentId`s; one auto, one suppressed-distinct.
**PASS if** two distinct registry `intentId`s. **FAIL if** they collapse to one review entry.
**Track:** the two `intentId`s side by side (must differ); friction = did the parser separate "session DST-8" from "project Bridge v4".

---

### RT-3 — Append-only protected fields  ★ trust
**Proves:** protected registry text (`brief`/`objective`/`summary`/`description`) **appends**, never overwrites.

**Steps**
1. **Me:** `registry_get` the **Bridge v4** project row → record its current `summary` (baseline).
2. **You:** record **`Bridge RT3a`**: *"Update the Bridge v4 project summary — first append test."* → "go", I commit.
3. **Me:** `registry_get` again → `summary` = baseline **+** "first append test" (prior text intact, stamped).
4. **You:** record **`Bridge RT3b`**: *"Update the Bridge v4 project summary — second append test."* → "go", I commit.
5. **Me:** `registry_get` → `summary` = baseline + first + **second** (all three retained).

**Expected:** every prior line survives; each commit adds a stamped append.
**PASS if** baseline + both appends all present after step 5. **FAIL if** any prior content is gone (overwrite).
**Track:** the `summary` value after each step (paste the before/after); receipt hashes.

---

### RT-4 — Processed-gate  ★ trust  (uses the RT-1 memo)
**Proves:** a memo is marked processed **only** when no pending sibling review remains.

**Steps**
1. **Me:** right after RT-1's commit (reminder done, 2 lanes pending): `voice_memo_get` on the RT-1 memo → `processed: false`; `voice_memo_review_list` → **2 pending** for that memo.
2. **You:** resolve the **project** lane (cockpit commit, or tell me to `voice_memo_review_resolve`). **Me:** `processed` still **false** (1 sibling left).
3. **You:** resolve the **keep** lane. **Me:** now `processed: true`.

**Expected:** processed flips to true **only** after the last pending lane clears.
**PASS if** false→false→true across steps 1-3. **FAIL if** processed becomes true while any sibling is pending.
**Track:** `processed` + `pendingCount` at each step.

---

### RT-5 — Cloud provider config  (no recording — quick)
**Proves:** non-secret config → `providers.json`; API key → Keychain only; status reflects it.

**Steps**
1. **You:** Settings → Memory → **Processing** → "Cloud enhancement (OpenAI-compatible)": leave **Base URL** at `https://api.openai.com/v1`, set **Model** = `gpt-4o`, toggle **Enabled** on, type any **API key** (a throwaway like `sk-test-123` is fine), click **Save**.
2. **Me:** read `~/Library/Application Support/The Bridge/memory-hub/providers.json` → has `baseURL`/`model`/`enabled`, and **no key field anywhere**.
3. **Me:** confirm the card status shows **"Key configured"** (key is in the Keychain, not the JSON).
4. **You:** click **Delete key** → status flips to **"Key missing"**.

**Expected:** JSON holds only non-secret config; status tracks the Keychain key; delete flips it.
**PASS if** JSON has no key + status flips correctly. **FAIL if** the key appears in `providers.json`, or status is wrong.
**Track:** paste the `providers.json` contents (proves no key); note the two status states.

---

### RT-6 — Cockpit per-intent commit (UI)  (uses an RT memo)
**Proves:** the 0b three-zone cockpit renders intents, marks one primary, commits one lane, and writes an activity receipt.

**Steps**
1. **You:** Settings → Memory → **Process** → click the **`Bridge RT2`** memo row.
2. **You:** observe — the **intent table** fills (the registry lanes), **one row is starred** (primary), the **detail inspector** shows the transcript + a **Commit** button; if both registry lanes are present, the **registry picker** appears (multiple registry lanes).
3. **You:** select the suppressed lane row → **Commit** (pick a picker row if shown).
4. **You:** watch the **activity strip** at the bottom — a receipt line appears.
5. **Me:** read `activity.jsonl` → confirm the commit event (envelope: phase/action/status/receiptHash; **no transcript** in `detail`).

**Expected:** cockpit shows the lanes with one primary; commit routes the selected lane; activity strip + `activity.jsonl` get a receipt.
**PASS if** the lane commits from the UI and a receipt lands. **FAIL if** the cockpit is empty/broken, the wrong lane commits, or the receipt holds a full transcript.
**Track:** a screenshot of the populated cockpit + the receipt hash.

---

### RT-7 — Duplicate guard probe  (expected to expose the deferred gap)
**Proves / measures:** whether duplicate-block + force-reason is **enforced** at the commit path. This one is an **honest gap check** — the *logic* is unit-tested, but wiring it into the live commit is a **documented deferred item**, so I expect this to show the gap.

**Steps**
1. **You:** commit a lane once (e.g. the `Bridge RT1` `memory_keep`) → succeeds.
2. **You:** commit the **same** lane again.
3. **Me:** observe — does the second commit get **blocked** (duplicate), or does it write a second row?

**Expected (current build):** the second commit is **not** blocked → it writes again (the enforcement gap). That **confirms** the deferred status, not a regression.
**Grade:** **PASS** = blocked-by-default + force-reason demanded (would mean the gap is already closed); **PARTIAL/known-gap** = not blocked (matches the documented deferral); record which.
**Track:** note whether a duplicate row appeared; this row feeds the "wire duplicate enforcement" follow-up.

---

## Results

| Test | Grade | Evidence (intentIds / registry / receipt-12) | Notes |
|---|---|---|---|
| RT-1 | — | — | — |
| RT-2 | — | — | — |
| RT-3 | — | — | — |
| RT-4 | — | — | — |
| RT-5 | — | — | — |
| RT-6 | — | — | — |
| RT-7 | — | — | — |

## Friction log

| # | Test | Severity | Friction observed | Suggested fix |
|---|---|---|---|---|

## Cleanup (end of session)

`reminders_delete` the test reminders · additively revert the Bridge v4 `summary` test appends (protected = append-only; use a reversal/cleanup note, don't silently overwrite) · `registry_delete` any test rows · `memory_forget` the RT-1 keep note · `voice_memo_review_dismiss` leftover entries · curator mode → Auto · filter `activity.jsonl` test receipts by force reason `live_test`.
