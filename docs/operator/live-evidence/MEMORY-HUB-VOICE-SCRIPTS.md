# Memory Hub — Operator Voice Scripts (HITL)

Agent-maintained copy-paste blocks for tiered live testing. Record in **Voice Memos.app**; agent discovers via `voice_memo_list`.

**Order:** T0 → T5 (easy → hard). Do not skip tiers until green or explicitly deferred.

---

## Tier 2 — Understand tracks

### T2a — Cloud memory keep (~15 sec)

> Reminder for the test harness: tomorrow at four PM, follow up with Anna about the nutrition tracker demo. Keep this as a memory in Notion.

**Expect:** `memory_keep` intent; summary-first Notion row; no full transcript in page body.

### T2b — Multi-intent (~45 sec)

> Project update for DST-8: the registry layout is done; next step is batch confirm testing. Personally I felt slow clicking memos — the app should ask before running local models. Remember that insight for agents too.

**Expect:** `registry_update` + `memory_keep` and/or `agent_memory`; multiple checkable tags.

### T2c — Local (same script as T2a)

Use **T2a** script. Agent sets Processing → Local or taps **Process locally** in Process tab.

### T2d — Local under load (same script as T2b)

Use **T2b** script under Local curator mode; activity drawer shows understand phases.

### T2e — No cloud linked

Use **T2a** script with cloud provider unset; **Process with cloud** should offer link/settings path.

---

## Tier 3 — Trust + Confirm

### T3a — Batch happy path (~30 sec)

> Test batch confirm: remind me to send the invoice by Friday. Also keep a memory that batch confirm testing passed on a disposable memo.

**Operator:** Approve notify-tier **Confirm** when macOS prompts.

### T3b — Registry sheet (~25 sec)

> Update packet PKT-MEM-TEST — ready for operator review on the registry sheet flow.

**Expect:** Registry intent without row → configure sheet → pick row → Confirm.

### T3c — Partial fail (~35 sec)

> Remind me to water plants tomorrow. Update the nonexistent-project-XYZZY-404 brief with this voice note. Keep a memory that partial batch failure was tested.

**Expect:** Middle lane fails; others may succeed; summary shows ✓/✗.

### T3e — Triage handoff

Re-use **T3a** memo after agent runs `voice_memo_triage_open`. **Operator:** click Confirm in UI; agent runs `voice_memo_triage_await`.

---

## Tier 4 — Endurance (optional voice)

### T4a — Long memo

Record 2+ minutes covering multiple topics (project status, personal note, reminder). Agent selects longest backlog memo if available.

### T4c — Re-run Understand

After T2a completes, agent taps **Re-run Understand**; plan refreshes; triage invalidated if active.

---

## Tier 5 — Ship gate

No voice. Operator replies **GO** in chat for merge + tag after agent reports Tier 0–4 PASS + CI green.
