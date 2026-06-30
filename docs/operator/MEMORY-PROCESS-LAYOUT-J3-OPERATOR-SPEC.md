# Memory Process Tab — J3 Operator Spec (5 variations)

**Status:** **APPROVED V1** (2026-06-30) — push drawer + J3 center + batch Confirm shipped PKT-MEM-123  
**Parent:** [`MEMORY-PROCESS-LAYOUT-J-H-VARIATIONS.md`](MEMORY-PROCESS-LAYOUT-J-H-VARIATIONS.md) · operator direction **J3** + sidebars + batch confirm  
**Product shift:** Per-intent commit cards → **multi-select intent tags** + single **Confirm** that locks selection and runs processing for the memo.

---

## Locked requirements (from operator)

| Zone | Behavior |
|------|----------|
| **Left sidebar** | Fixed, always visible — full memo backlog list. Not collapsible. Primary navigation. |
| **Right sidebar** | **Collapsible** activity drawer — **global** Memory Hub / app activity feed (not per-memo inline footer). |
| **Center** | One memo at a time, J3-inspired vertical flow. |
| **Title** | **Exactly one** title block at top of center (display + rename + optional cloud improve). No duplicate title elsewhere. |
| **Transcript** | Directly **under title**. Collapsed preview with **gradient fade**; expand for full text. |
| **Intents** | Not full-height cards. **Checkable tags** (multi-select, scales to 10–20). Primary may pre-check ★. |
| **Confirm** | One button on the memo card. Locks checked intents → runs processing/commit pipeline for those lanes. |
| **Re-run Understand** | Available on the memo (re-parses intents; invalidates triage per MEM-121/122). |

**Order (center, top → bottom):**

```
Title  →  Transcript (fade)  →  Intent tags (checkboxes)  →  Confirm
```

---

## Shared three-pane skeleton

All five variations use this outer frame; they differ in **center internals**, **confirm placement**, and **right drawer mechanics**.

```
┌─────────────┬────────────────────────────────────────────┬──────────────┐
│ MEMOS       │ CENTER — active memo                       │ ACTIVITY     │
│ (fixed)     │                                            │ (collapsible)│
│ 200–240px   │                                            │ 0 / 280–320px│
│             │                                            │              │
│  ···        │  ··· scroll or split                       │  ··· feed    │
│             │                                            │              │
└─────────────┴────────────────────────────────────────────┴──────────────┘
```

**Left memo row (all variants):** title (2 lines) · intent count badge · awaiting-agent dot · selected highlight · same AX ids as today (`memoRow.*`).

**Right activity (all variants):** global `activity.jsonl` stream — commits, understand, defer, triage events across memos. Collapsed state must stay **one-click reachable** (icon strip or header button).

---

# Variation 1 — V1 · Push drawer + wrap tags (baseline)

Right drawer **pushes** center narrower when open. Intent tags **wrap** as chips. Confirm inline below tags.

```
┌──────────────┬──────────────────────────────────────────────────┬─────────────┐
│ Memos        │ ▓ MEMO HEADER (sticky within center)              │ Activity  ◀│
│              │ [Re-run Understand ↻]                             │ ─────────  │
│ ● Voice 0629 │                                                   │ 11:02 cf42…│
│   +2 intents │  TITLE (single block)                             │ 11:01 ollama│
│              │  ┌ Display: "Call Jacob about bridge release"     │ 10:58 defer│
│   Voice 0628 │  │ [Edit title…………] [Rename] [Cloud ✨]          │ ···        │
│   awaiting   │  └ provenance badge · 3 intents detected         │            │
│              │                                                   │ [Collapse] │
│   Voice 0627 │  TRANSCRIPT (collapsed default)                   │            │
│   ···        │  ┌ "So I just had this thought about…"           │            │
│              │  │  ··· 4 lines mono · selectable                 │            │
│              │  │  ░░░░░ gradient fade ░░░░░                     │            │
│              │  └ [Expand full transcript ⌄]                     │            │
│              │                                                   │            │
│              │  ACCEPT INTENTS — check all that apply              │            │
│              │  ┌─────────────────────────────────────────────┐  │            │
│              │  │ ☑ ★ reminder   PLEASE  92%                  │  │            │
│              │  │ ☐ agent_memory System  81%                  │  │            │
│              │  │ ☐ registry     FOCUS   74%                  │  │            │
│              │  │ ☐ … (wraps to 2–3 rows at 20 tags)          │  │            │
│              │  └─────────────────────────────────────────────┘  │            │
│              │                                                   │            │
│              │  [ Confirm 2 intents ]  (disabled if none checked)  │            │
│              │                                                   │            │
└──────────────┴──────────────────────────────────────────────────┴─────────────┘

Activity collapsed (right → 40px strip):
┌──────────────┬──────────────────────────────────────────────────┬──┐
│ Memos        │ CENTER (wider)                                    │▐A│
│              │                                                   │▐c│
│              │                                                   │▐t│
└──────────────┴──────────────────────────────────────────────────┴──┘
  click ▐Act▐ or header [Activity] reopens drawer
```

| | |
|---|---|
| **Confirm flow** | Click Confirm → tags lock (checked = readonly chips with ✓); unchecked hidden or greyed; Bridge runs commit/processing **sequentially** for locked set; activity drawer streams receipts. |
| **Re-run** | Top of center, left of title or opposite corner — always visible. |
| **Triage banner** | Spans center + optionally nudges activity strip; does not cover memo list. |
| **Best for** | Straightforward mapping from today’s three zones to new intent UX. |

---

# Variation 2 — V2 · Overlay activity + sticky confirm dock

Activity drawer **overlays** center (does not resize). Confirm lives in a **sticky bottom dock** inside center only.

```
┌──────────────┬──────────────────────────────────────────────────────────────┐
│ Memos        │ [Re-run Understand ↻]              [Activity 🔔] ← toggles   │
│              ├──────────────────────────────────────────────────────────────┤
│ ● …          │ ░ SCROLL                                                     │
│              │  Title block (single)                                        │
│              │  Transcript + fade + [Expand]                                │
│              │  Intent tags (wrap chips, scroll if >12)                     │
│              │                                                              │
│              ├──────────────────────────────────────────────────────────────┤
│              │ ▓ CONFIRM DOCK (56px, sticky bottom of center)                │
│              │  2 intents selected · ★ reminder + agent_memory              │
│              │                          [ Configure… ]  [ Confirm & run ] │
└──────────────┴──────────────────────────────────────────────────────────────┘

Activity overlay (slides over center from right, 340px):
                    ┌─────────────────────────┐
                    │ Global activity      ✕  │
                    │ ─────────────────────── │
                    │ ··· jsonl feed          │
                    └─────────────────────────┘
  center dimmed 20% optional · Esc or ✕ closes
```

| | |
|---|---|
| **Confirm dock** | Shows live count + names of checked tags. `[Configure…]` opens sheet for registry row picks **per checked intent** before confirm (required when registry lane selected). |
| **Pros** | Center width stable; confirm always reachable without scrolling past 20 tags. |
| **Cons** | Dock reduces scroll viewport (~56px). |

---

# Variation 3 — V3 · Vertical checklist (many intents)

For **10–20 intents**: tags become a **vertical checklist** with lane group headers instead of wrap chips. Confirm at list footer.

```
┌──────────────┬──────────────────────────────────────────────────┬─────────────┐
│ Memos        │ [Re-run Understand ↻]                             │ Activity ◀  │
│              │                                                   │             │
│              │  TITLE — single block                             │             │
│              │  TRANSCRIPT — fade + expand                       │             │
│              │                                                   │             │
│              │  ── PLEASE ───────────────────── [Select primary]│             │
│              │  ☑ ★ reminder · 92% · reminders_create            │             │
│              │  ☐ note · 68% · (suppressed lane)                 │             │
│              │  ── System ─────────────────────                  │             │
│              │  ☑ agent_memory · 81%                             │             │
│              │  ☐ skill_sync · 55% · low conf                    │             │
│              │  ── FOCUS ──────────────────────                  │             │
│              │  ☐ registry · 74%                                 │             │
│              │  ··· (scroll, max ~40% center height)             │             │
│              │                                                   │             │
│              │  ─────────────────────────────────────────────  │             │
│              │  3 selected          [ Confirm & process ]        │             │
└──────────────┴──────────────────────────────────────────────────┴─────────────┘
```

| | |
|---|---|
| **Density** | Each row: checkbox · primary star · kind badge · confidence · destination one-liner. |
| **Bulk actions** | `[Select primary]` checks ★ only; `[Select all ready]` checks conf ≥ threshold. |
| **Best for** | High intent count memos; scanning beats chip wrap. |

---

# Variation 4 — V4 · Compact tags + expand-on-check configure

Tags stay **small** (pill toggles). Checking a tag **expands a slim configure row** beneath it (registry picker only when needed). One Confirm at bottom.

```
┌──────────────┬──────────────────────────────────────────────────┬─────────────┐
│ Memos        │ Title · transcript (fade)                         │ Activity ◀  │
│              │                                                   │             │
│              │  [★ reminder] [agent_memory] [registry] [note] …  │             │
│              │   ↑ toggle pills — selected = filled accent       │             │
│              │                                                   │             │
│              │  ▼ reminder (expanded because checked)            │             │
│              │    Registry [Projects ▾]  Row [DST-8 ▾]  preview…  │             │
│              │                                                   │             │
│              │  ▼ agent_memory (expanded)                        │             │
│              │    (no picker — auto destination)                 │             │
│              │                                                   │             │
│              │  registry (unchecked — collapsed, no row)         │             │
│              │                                                   │             │
│              │  [Re-run Understand ↻]          [ Confirm 2 ]     │             │
└──────────────┴──────────────────────────────────────────────────┴─────────────┘
```

| | |
|---|---|
| **Interaction** | Toggle pill → expand configure strip if registry/reminder needs picker; collapse when unchecked. |
| **Pros** | Clean tag row at top; detail only for selected intents; scales visually. |
| **Cons** | Expand rows add vertical jump when toggling many tags. |

---

# Variation 5 — V5 · Processing state card (post-confirm)

Same layout as **V1 or V3**, but after Confirm the center **replaces tag section** with a **processing checklist** until all locked intents complete (then memo leaves list or shows done).

```
BEFORE CONFIRM (same as V1):
  tags + [ Confirm 3 intents ]

AFTER CONFIRM — center locks:
┌──────────────┬──────────────────────────────────────────────────┐
│ Memos        │ Title · transcript (read-only)                    │
│              │ ▓ Processing 2 of 3…                              │
│ ● memo       │  ✓ reminder — committed · cf424aa3                │
│   processing │  ◐ agent_memory — running…                        │
│              │  ○ registry — queued                              │
│              │  [View in activity →]  (opens right drawer)       │
└──────────────┴──────────────────────────────────────────────────┘

Done → memo row greys out / removes from list · auto-advance to next memo optional
```

| | |
|---|---|
| **Activity drawer** | Auto-opens on Confirm (optional setting) so global feed mirrors inline progress. |
| **Pros** | Clear feedback for batch processing; operator not left wondering after Confirm. |
| **Cons** | Extra state machine in center column. |

---

# Cross-variation comparison

| Code | Activity right | Intent UI | Confirm location | Scales to 20 intents | Registry config |
|------|----------------|-----------|------------------|------------------------|-----------------|
| **V1** | Push drawer | Wrap chips | Below tags | Good (wrap) | Pre-confirm sheet or post-check V4-style |
| **V2** | Overlay | Wrap chips | Sticky dock | Good | `[Configure…]` in dock |
| **V3** | Push drawer | Vertical checklist | List footer | **Best** | Inline row expand or sheet |
| **V4** | Push or overlay | Toggle pills + expand rows | Bottom | Good | Per-tag expand on check |
| **V5** | Push + auto-open | V1 or V3 + processing UI | Same as base | Same as base | Same as base |

---

# Recommended combinations

| If you prioritize… | Pick |
|--------------------|------|
| Simplest build from today’s columns | **V1** |
| Never lose Confirm off-screen | **V2** |
| Many intents per memo | **V3** |
| Minimal visual noise until intent selected | **V4** |
| Clear post-confirm feedback | **V5** (add to V1 or V3) |

**Suggested default:** **V3 checklist + V2 overlay activity + V5 processing state** — checklist for scale, overlay so center doesn’t jump width, processing card after Confirm.

---

# Open decisions (answer when picking a variation)

1. **Primary intent:** Auto-check ★ on load, or operator must opt in every time?
2. **Registry intents:** Configure pickers **before** Confirm (V2/V4), or block Confirm until configured?
3. **Unchecked intents after Confirm:** Leave for a second pass, or auto-dismiss / move to Inbox review?
4. **Activity drawer default:** Open, closed, or remember last state?
5. **Triage session (MEM-122):** Agent opens memo — tags pre-checked to primary only, or all ready intents?
6. **Title edit timing:** Rename allowed anytime, or lock title after Confirm starts?

---

# Operator decision

Reply with **V1–V5** (or compose e.g. `V3 + V2 activity + V5 processing`).

| Field | Value |
|-------|-------|
| Chosen variation | _(pending)_ |
| Activity | _(push drawer / overlay / default open?)_ |
| Intent tags | _(wrap chips / checklist / pills+expand)_ |
| Include processing state (V5)? | _(yes/no)_ |
| Notes | _(optional)_ |
