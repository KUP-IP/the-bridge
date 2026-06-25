# Memory Hub — Multi-Intent Live Test Suite

**Version:** 1.0  
**Date:** 2026-06-24  
**Parent:** [PKT-MEM-112](./packets/PKT-MEM-112-wave3-deferred-closeout.md)  
**Prerequisite:** `/Applications/The Bridge.app` **v3.8.3** (Phase 0 / PKT-MEM-106 build), single-memo processing only (never batch 238 backlog)

---

## How to run

1. Record **one memo per test** in Voice Memos; wait for iCloud sync.
2. Reply in chat: **`M1 done`** (etc.) — agent runs `voice_memo_get` → dry-run → execute (single `memoId`).
3. Verify pass criteria; resolve **Inbox** items for suppressed secondaries via Process tab or `voice_memo_review_resolve`.
4. **Cleanup** after the session (reminders_delete, registry revert, memory_forget, registry_delete for test rows).

### Trust invariants (must hold on every test)

| Invariant | Expected |
|-----------|----------|
| Primary election | **One** lane auto-executes per memo |
| Suppressed lanes | Queued to **review** with reason `secondary intent suppressed` |
| Registry writes | **Append** to text fields — never overwrite |
| Processed gate | Memo **not** in `processed.json` if any review pending for that memo |
| Agent memory | **Full transcript** stored, not first sentence only |

### Primary-lane priority (tie-break)

`reminder` > `agent_memory` > `registry_update` > `memory_keep` (then highest confidence)

---

## Suite overview

| ID | Name | Intents in speech | Expected auto-execute | Expected review |
|----|------|-------------------|----------------------|-----------------|
| M1 | Morning standup | 4 | `reminder` | contact, project, agent_memory |
| M2 | Session + block closeout | 4 | `registry_update` (session) | block, memory_keep, reminder |
| M3 | ASR homophone torture | 3 | `registry_update` (contact) | agent_memory, reminder |
| M4 | Negation trap | 3 | `registry_update` (project) | memory_keep suppressed by negation |
| M5 | Registry triple | 3 | one `registry_update` | other two registry lanes |
| M6 | Agent ops briefing | 4 | `agent_memory` | reminder, memory_keep, contact |
| M7 | Deep work block + calendar | 3 | `reminder` (block title) | block update; due date when PKT-MEM-107 ships |
| M8 | Ship-day cascade | 5+ | `reminder` | session, project, contact, memory_keep |
| M9 | Inbox zero ritual | 4 | `memory_keep` | reminder, agent_memory, project |
| M10 | Curator agent defer | 3 | **none** (agent mode) | all → review; operator `voice_memo_commit` |

---

## M1 — Morning standup (4 intents)

**Script (read naturally, ~45s):**

> Remind me at 4pm to send Isaiah the Memory Hub test results.  
> Log that I talked with Jacob — he's good with the append-only registry fix.  
> Update project Bridge v4 — Wave 3 packet is drafted and install is green.  
> Agents should know: when running live voice memo tests, always use single-memo mode, never batch the whole backlog.

**Expected detection**

| Lane | entity | hint | conf (approx) |
|------|--------|------|---------------|
| reminder | — | 4pm / send Isaiah | ≥0.85 |
| registry_update | contact | Jacob | ≥0.85 |
| registry_update | project | Bridge v4 | ≥0.86 |
| agent_memory | global | — | ≥0.85 |

**Expected auto-execute:** `reminder` only → title mentions Isaiah / 4pm / test results.

**Expected review (3):** contact brief append, project summary append, agent_memory full transcript.

**Pass criteria**

- [ ] One Reminder created; sensible title (not entire paragraph)
- [ ] Jacob `brief` **appended** (if manually resolved from Inbox)
- [ ] Bridge v4 `summary` **appended** (if resolved)
- [ ] Agent memory contains **full** script text (if resolved)
- [ ] Memo **not** marked processed until Inbox cleared OR only reminder executed and no review queued for failures

---

## M2 — Session + block closeout (4 intents)

**Script:**

> Don't create a memory for this — just update the records.  
> Update session DST-8 — objective is close Wave 2.5 and open Wave 3 executor dispatch.  
> Update block Event block — add that live multi-intent suite passed.  
> Remind me tomorrow to archive the test Notion rows.

**Expected detection**

| Lane | Notes |
|------|-------|
| memory_keep | **Suppressed by parser** (`don't create a memory`, `just update`) |
| registry_update | session DST-8 |
| registry_update | block Event block |
| reminder | tomorrow archive |

**Expected auto-execute:** `reminder` wins priority over registry_update → **known gap**: operator may want session instead. Document actual behavior; if reminder wins, session/block go to review.

**Pass criteria**

- [ ] No new Memory registry row (`memory_keep` blocked)
- [ ] Primary lane executed; DST-8 objective **appended** (via Inbox resolve if suppressed)
- [ ] Event block description **appended** (via resolve if suppressed)
- [ ] Reminder created OR queued to review with clear reason

**Critique note:** This test **documents** election priority vs operator intent. Phase B registry picker should let operator commit session from Process preview.

---

## M3 — ASR homophone torture (3 intents)

**Script:**

> Blog that I spoke with Sarah about the Notion sync — she wants fewer overwrites.  
> Remind me to blog the changelog when we ship.  
> Agents should know the word blog in a changelog context means write the changelog, not Apple blog.

**Expected detection**

| Lane | Notes |
|------|-------|
| registry_update | contact Sarah (`blog that` → `log that`) |
| reminder | changelog (may misfire on "blog" — acceptable to review) |
| agent_memory | agents should know |

**Expected auto-execute:** `reminder` (highest priority) OR `registry_update` if reminder confidence low.

**Pass criteria**

- [ ] Sarah contact lane fires (not session/contact misfire on bare "update")
- [ ] Homophone normalized in parser output (`log that` in plan)
- [ ] Suppressed lanes visible in Inbox with election reason

---

## M4 — Negation trap (3 intents)

**Script:**

> Keep this in mind but don't create a memory — just update the project.  
> Update project The Bridge — trust sprint is done, multi-intent tests are next.  
> Remember that for agents too.

**Expected detection**

| Lane | Notes |
|------|-------|
| memory_keep | Blocked by negation |
| registry_update | project The Bridge |
| agent_memory | "remember that for agents" (borderline — may fire) |

**Expected auto-execute:** `registry_update` (project) — no memory_keep row.

**Pass criteria**

- [ ] No `registry_create` for memory entity
- [ ] Project summary **appended**
- [ ] If agent_memory fires and wins election, document; else queued to review

---

## M5 — Registry triple (3 registry lanes, no reminder)

**Script:**

> Update session DST-8 — add that multi-intent testing started.  
> Update project Bridge v4 — add that PKT-MEM-112 is dispatched.  
> Log that I talked with Jacob — he approved the complicated test scripts.

**Expected detection:** three `registry_update` intents (session, project, contact).

**Expected auto-execute:** **one** registry lane (highest confidence — likely session DST-8 at 0.88).

**Expected review (2):** other registry lanes suppressed.

**Pass criteria**

- [ ] Exactly **one** registry write auto-executed
- [ ] Two Inbox entries with `secondary intent suppressed`
- [ ] Operator resolves remaining two via Process/`voice_memo_commit` — each append verified
- [ ] Memo not processed until operator satisfied OR primary-only path with no failed review

---

## M6 — Agent ops briefing (4 intents, agent should win if no reminder)

**Script:**

> Agents should know: the live test suite uses codes M1 through M10, and cleanup is mandatory after each session.  
> Remind me to update the test doc after M10.  
> Keep this: Isaiah prefers complicated multi-intent scripts over single-lane memos.  
> Log that I talked with Jacob about test coverage.

**Expected auto-execute:** `reminder` (priority) — **not** agent_memory despite opening with it.

**Pass criteria**

- [ ] Reminder created for test doc update
- [ ] Agent memory + memory_keep + contact in review
- [ ] Resolving agent_remember from Inbox stores **full transcript**

**Variant (M6b):** Same script but **remove** the reminder sentence → expect `agent_memory` auto-execute.

---

## M7 — Deep work block + calendar (3 intents, datetime stress)

**Script:**

> Block deep work on Memory Hub multi-intent testing tomorrow at 9am.  
> Update block Focus block — description is run M1 through M5 today.  
> Remind me at 8:45 to start Parakeet if Apple transcript is missing.

**Expected auto-execute:** `reminder` with block-derived title (not "with pass phrase" tail).

**Pass criteria**

- [ ] Reminder title references deep work / Memory Hub (not entire memo)
- [ ] Block registry append on resolve
- [ ] **After PKT-MEM-107:** due date on 8:45 or 9am reminder; **before 107:** due may be null — note in results

---

## M8 — Ship-day cascade (5+ intents)

**Script:**

> Remind me at 5 to tag the release after tests pass.  
> Update session DST-8 — objective is ship v3.8.3 with Memory Hub.  
> Update project Bridge v4 — summary is multi-intent live suite green.  
> Log that I talked with Jacob — ship day coordination.  
> Keep this: release notes must mention append-only registry and primary intent election.  
> Agents should know: never batch-process the 238 memo backlog.

**Expected auto-execute:** `reminder` (5pm tag release).

**Expected review:** up to **four** suppressed lanes.

**Pass criteria**

- [ ] Inbox shows multiple suppressed intents with same memo id
- [ ] Process tab preview lists all intents from `voice_memo_get`
- [ ] Operator can commit each suppressed lane individually via `voice_memo_commit`
- [ ] Trust: no duplicate Memory rows without force

---

## M9 — Inbox zero ritual (memory_keep wins)

**Script:**

> Keep this note: multi-intent tests belong in MEMORY-HUB-LIVE-MULTI-INTENT-SUITE.md.  
> Remind me to link that doc from PKT-MEM-112 when done.  
> Update project Bridge v4 — documentation track is active.  
> Agents should know the suite codes are M1 through M10.

**Expected auto-execute:** `reminder` still wins unless reordered — **document actual winner**.

**Alternative M9b (memory_keep wins):** Remove reminder sentence; expect `memory_keep` → Notion Memory row + transcript on page body.

**Pass criteria**

- [ ] Notion Memory row created (M9b) OR reminder + memory in review (M9)
- [ ] Transcript appended to page body on memory_keep path

---

## M10 — Curator agent defer (Processing tab → Agent mode)

**Setup:** Settings → Memory → Processing → Curator routing → **Connected MCP agent**.

**Script:**

> Log that I talked with Jacob about agent-deferred curation.  
> Update session DST-8 — agent should commit this after review.  
> Remind me to switch curator mode back to Auto when done.

**Expected auto-execute:** **none** — memo skipped with `deferred to connected MCP agent`.

**Pass criteria**

- [ ] Review entry: `curator mode agent — transcribed; awaiting connected agent commit`
- [ ] `voice_memo_get` returns plan with all intents
- [ ] Agent calls `voice_memo_commit` with chosen `intentKind` → single write
- [ ] Switch Processing back to **Auto** after test

---

## Scoring rubric

| Grade | Meaning |
|-------|---------|
| **PASS** | Primary lane correct; append-only verified; review queue correct; processed gate correct |
| **PARTIAL** | Primary correct but suppressed lanes wrong count, or datetime missing pre-107 |
| **FAIL** | Overwrite detected, wrong entity (contact misfire), batch marked processed with pending review, agent memory truncated |

---

## Session cleanup checklist

After M1–M10 (or subset):

- [ ] `reminders_delete` for test reminders
- [ ] `registry_update` revert or append test notes removed on Jacob, DST-8, Bridge v4, Event block
- [ ] `registry_delete` for any test Memory rows
- [ ] `memory_forget` for test agent memories
- [ ] `voice_memo_review_dismiss` for stale inbox entries
- [ ] Curator mode reset to **Auto**

---

## Agent MCP commands (per memo)

```json
{"memoId": "<id>", "mode": "single", "dryRun": true}
{"memoId": "<id>"}
{"memoId": "<id>", "intentKind": "registry_update", "entityKey": "contact", "entityHint": "Jacob"}
```

Use `voice_memo_review_list` to confirm pending count after each test.
