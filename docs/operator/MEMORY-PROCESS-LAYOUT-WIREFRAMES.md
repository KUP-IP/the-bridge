# Memory Process Tab — Layout Wireframes (Wave 4)

**Status:** **PENDING OPERATOR APPROVAL** — no Swift layout changes until one option is chosen.  
**Recommendation:** **Option B** (master + stacked center).  
**Source critique:** sprint plan §Wave 4 · current layout in `MemoryProcessTab.swift`.

## Current layout (baseline)

```
┌─────────┬──────────────┬──────────────┐
│ Memos   │ Intents      │ Detail       │  ← 3 columns, 2 flex equal
│ 210-250 │   flex 1     │   flex 1     │
├─────────┴──────────────┴──────────────┤
│ Activity strip (fixed 96px)             │
└───────────────────────────────────────┘
```

**Issues:** horizontal squeeze on intents + inspector; fixed activity tax; detail column scroll overload; duplicate title affordances; Re-run Understand buried; weak pick→intent→commit hierarchy.

---

## Option A — Weighted three-pane (minimal churn)

```
┌──────┬────────────────┬─────────────────────┐
│Memos │ Intents 38%    │ Inspector 42%       │
│ 18%  │                │ Transcript collapsible│
├──────┴────────────────┴─────────────────────┤
│ Activity: collapsible drawer (default closed)│
└─────────────────────────────────────────────┘
```

| Pros | Cons |
|------|------|
| Smallest diff | Still three-way split |
| Fixes proportion problem | Detail scroll remains |

---

## Option B — Master + stacked center **(recommended)**

```
┌──────┬──────────────────────────────────────┐
│Memos │ ┌ Intents (top 45%) ───────────────┐ │
│ 22%  │ └──────────────────────────────────┘ │
│      │ ┌ Inspector (bottom 55%) ──────────┐ │
│      │ │ Transcript | Title | Commit      │ │
│      │ └──────────────────────────────────┘ │
├──────┴──────────────────────────────────────┤
│ Activity: 64px slim bar OR popover          │
└─────────────────────────────────────────────┘
```

| Pros | Cons |
|------|------|
| Clear top-to-bottom workflow | Loses side-by-side intent+commit glance |
| Intents get full width | Moderate refactor |
| Inspector breathes | |

---

## Option C — Two-pane with intent rail

```
┌──────────────────┬─────────────────────────┐
│ Memos + Intents  │ Inspector (full height) │
│ (split upper/    │ Sticky commit bar bottom│
│  lower in 40%)   │                         │
├──────────────────┴─────────────────────────┤
│ Activity toggle chip in toolbar             │
└─────────────────────────────────────────────┘
```

| Pros | Cons |
|------|------|
| Inspector dominates | Intent list shorter |
| Commit bar always visible | Memo list compressed |

---

## Option D — Focus mode toggle

```
Default: Option B layout
Focus ☐: hides memo list → Intents 30% | Inspector 70%
```

| Pros | Cons |
|------|------|
| Operator control | Extra toggle state |
| Works with `process/<memoId>` anchor | Two layouts to maintain |

---

## Option E — Horizontal workflow strip

```
┌ Memo picker dropdown / horizontal chips ────┐
├ Intents table (full width) ─────────────────┤
├ Inspector drawer (expandable, default half) ┤
└ Activity footer (48px) ─────────────────────┘
```

| Pros | Cons |
|------|------|
| Maximum width for intents | Largest refactor |
| Modern pipeline feel | Loses persistent memo list scan |

---

## Operator decision

Reply with **A**, **B**, **C**, **D**, **E**, or hybrid notes. Layout implementation is a **follow-on wave** (same branch or post-merge patch); it does **not** block PKT-MEM-121/122 merge.

| Field | Value |
|-------|-------|
| Chosen option | _(pending)_ |
| Approved by | _(pending)_ |
| Approved at | _(pending)_ |
