# Skill-Content Restructure Plan

> **Source:** `design/SKILL-AUDIT.md` (generated 2026-06-04, W0 audit)
> **Packet:** PKT-966 (Execution Class REVIEW-FIRST)
> **Status:** PLAN ONLY — no Notion writes attempted. Bridge long-content write tools are
> unreliable for bulk multi-block edits; every edit below must be applied by the operator
> (or a dedicated, operator-approved Notion wave) after this plan is reviewed.
> **Generated:** 2026-06-24

---

## Scope and Coverage

Seven routing-parent skill pages are in scope. Edits are purely content (Notion pages) —
no Swift code changes are required for this packet. The build should stay green.

### Unresolved IDs — resolve before de-listing

The following page IDs appear in the `Specialist` relation but have NOT been classified as
REAL vs DOC by the W0 audit. **Do not de-list these until a targeted page read confirms
their type.**

| Parent | Unresolved IDs |
|---|---|
| focus-keepr | `c57598ef`, `aa3363b9`, `23337454` |
| notion-keepr | `9a4105d0`, `c629dc07` |

Procedure: fetch each page title (one `notion_page_read` per ID). If it is a proper
specialist agent page, keep in relation. If it is a doc/sub-section page, de-list.

---

## Global Edits (apply to ALL 7 parents)

### G1 — Remove persona/identity block

Each parent currently opens with a first-person persona/identity block ("I am X, my purpose
is…"). Remove that block from every parent. **One identity lives in standing orders.**
Parents become thin dispatchers whose opening section is §1 Role Overview (structural
summary only, no persona prose).

**Keep intact:** §1.2 through §1.5 operating standards (behavior rules, not persona).

### G2 — Rename "Reminders" sections to "Operating Notes"

Where any section is titled "Reminders" or "Memory" and contains actionable operating
content, rename it to **"Operating Notes"**. Where the section is an empty placeholder with
no items, **drop the section entirely**.

Destination routing for section contents (decide per item):
- Active ops/build tasks → move to Standing Orders (or the operator's task manager)
- Durable cross-session patterns (mac-keepr M1–M3, time-keepr M1–M3) → note in plan as
  candidates for unified memory (3.7.5 wave, separate ticket)
- Items with no live value → delete

### G3 — Brand normalize: "KUP·OS" → "KEEP OS"

Wherever the text "KUP OS", "KUP·OS", or "KUP-OS" appears in a skill body, replace with
"KEEP OS".

---

## Per-Parent Edits

### 1. focus-keepr (v11, Stable)

| # | Action | Detail |
|---|---|---|
| F1 | Remove persona block | Opening identity prose → delete |
| F2 | Drop empty Reminders/Memory | Both sections are empty placeholders; delete them |
| F3 | Resolve 3 specialist IDs before any de-list | `c57598ef`, `aa3363b9`, `23337454` — read each; decide REAL vs DOC (see Unresolved IDs above) |
| F4 | Tighten Tool Permissions | `Tool Permissions` field currently includes `"All"` + Delete-pages, which conflicts with read-only posture. Narrow to the minimum required set. Confirm with operator before write. |

**PROTECT:** nothing specifically flagged as do-not-touch on focus-keepr. Exercise caution
around §1.2–§1.5 operating standards.

---

### 2. mac-keepr (v4.1, Stable)

| # | Action | Detail |
|---|---|---|
| M1 | Remove persona block | Opening identity prose → delete |
| M2 | Dedup triple machine-JSON blocks | Collapse the three machine-definition JSON blocks into a single §EX (Execution) block following the established collapse pattern |
| M3 | Rename §7 Reminders → Operating Notes | 3 ops task items; assess each: active ops → orders, otherwise → drop |
| M4 | Flag M1–M3 memory items | mac-keepr M1, M2, M3 (durable cross-session patterns) are candidates for the unified memory wave (3.7.5); note in the section header, do not delete yet |

**PROTECT:** nothing specifically called out; mac-keepr is a leaf specialist (no children)
so no relation cleanup needed.

---

### 3. notion-keepr (v8.1)

| # | Action | Detail |
|---|---|---|
| N1 | Remove persona block | Opening identity prose → delete |
| N2 | Rename "Reminders" → "Operating Notes" | Apply G2 routing rules |
| N3 | De-list "NOTION Keepr Changelog" doc-specialist | Remove from `Specialist` relation — it is a changelog doc, not a routable agent |
| N4 | Resolve 2 extra relation IDs | `9a4105d0`, `c629dc07` — read each title; de-list if doc/sub-section (see Unresolved IDs above) |
| N5 | Flag stray `<synced_block>` | Locate the one stray `<synced_block>` noted in audit; confirm with operator whether to unwrap or delete |

**PROTECT — DO NOT TOUCH:** §Write-Mechanics (cross-skill SSOT, referenced by 5 parents).
Do not move, rename, restructure, or edit §Write-Mechanics content.

---

### 4. people-keepr (v3.0.1)

| # | Action | Detail |
|---|---|---|
| P1 | Remove persona block | Largest persona block of the 7 parents — fully delete |
| P2 | Rename "Reminders" → "Operating Notes" OR drop | people-keepr has no current Reminders/Memory sections; add an "Operating Notes" section header + register in unified memory candidates for 3.7.5 |
| P3 | De-list 9 folded legacy stubs from Specialist relation | The 9 stubs are dead pages that appeared in the relation. Remove them. Do NOT remove stripe-keepr or service-coach. |
| P4 | Keep stripe-keepr in relation | stripe-keepr is a real specialist; keep it in the `Specialist` relation |
| P5 | Keep service-coach in relation | service-coach is a real specialist; keep it in the `Specialist` relation |
| P6 | Register stripe-keepr + service-coach in §9 body registry | Body §9 currently does not list them; the relation and body disagree. Add entries for both in §9. |
| P7 | Remove §7 Prospecting section | RETIRED by Amendment 7. Delete the section. |
| P8 | Fix Maturity metadata | Currently "Genesis" at v3.0.1 — that pairing is inconsistent. Set Maturity to "Stable" (or the correct value per the versioning policy). Confirm with operator. |
| P9 | Brand normalize | Apply G3 — KUP·OS → KEEP OS wherever it appears |

**PROTECT — DO NOT TOUCH:**
- **§LD** (Leadership Domain rules): do not move, rename, or edit
- **§Amendments**: do not edit the amendment record

---

### 5. project-keepr (body v2.0 / property v1.0 / maturity Genesis)

| # | Action | Detail |
|---|---|---|
| PJ1 | Remove persona block | Opening identity prose → delete |
| PJ2 | Reconcile 3-way version drift | Body says v2.0; the property field says v1.0; maturity is Genesis. Fix: set property version to match body (v2.0) and set maturity to Stable (if feature-complete) — confirm with operator before writing. |
| PJ3 | Convert `<callout>` blocks → FR-21 markdown | Replace Notion callout blocks with the standard FR-21 markdown heading/bullet format used in the other parents |
| PJ4 | Brand normalize | Apply G3 — "KUP·OS"/"KUP OS" → "KEEP OS" |
| PJ5 | Drop empty Reminders/Memory sections | Both are empty placeholders; delete them |
| PJ6 | Confirm specialist relation is clean | Audit notes 4 clean specialists; no de-list action needed unless a subsequent read finds a doc page |

**PROTECT — DO NOT TOUCH:** **§3 Universal Project Protocols** (cross-skill SSOT). Do not
move, rename, restructure, or edit §3 content.

---

### 6. skill-keepr

| # | Action | Detail |
|---|---|---|
| SK1 | Remove persona block | Opening identity prose → delete |
| SK2 | Rename "Reminders" → "Operating Notes" | Apply G2 routing |
| SK3 | De-list doc specialists from relation | Remove: §7 Evolution Log, §6 Test Matrix, Phase 2.3 Pruning pages from the `Specialist` relation — these are doc sub-sections, not routable agents |
| SK4 | De-list duplicate Skill Builder / Skill Evolver stubs | The relation contains both the real pages (`a342d6dc` Skill Builder, `9992a79b` Skill Evolver) and duplicate stub pages (`334cbb58…`). Remove the duplicate stubs; keep the real ones. |
| SK5 | Verify 3 remaining real specialists | After de-listing, the relation should contain exactly 3 entries: Skill Auditor, `a342d6dc` Skill Builder, `9992a79b` Skill Evolver. Confirm page reads match. |

**PROTECT:** nothing specially called out beyond standard §1.2–§1.5 operating standards.

---

### 7. time-keepr (v0.1, Genesis — not production-ready)

| # | Action | Detail |
|---|---|---|
| T1 | Remove persona block | Opening identity prose → delete |
| T2 | Rename §7 Reminders → Operating Notes | 4 build tasks listed; these are active build work → move to Standing Orders / operator task manager, then drop the section or keep as a minimal header |
| T3 | Flag M1–M3 memory items | Same as mac-keepr — durable patterns are candidates for 3.7.5 unified memory wave; note in plan, do not delete |
| T4 | Collapse §R JSON → §EX | Move/convert the raw JSON machine blocks into a §EX (Execution) section following the collapse pattern |
| T5 | Fix routing-index summary | The routing index shows "calendar/planning" but the body describes BLOCK↔EVENT transitions. Update the routing `Summary` property to accurately reflect the body. |
| T6 | Document R6 UPDATE gap | R6 appears to have an undocumented update path; add a note in the body flagging the gap (or fill the gap if the operator provides the detail) |
| T7 | No relation cleanup needed | time-keepr has no children specialist entries that need de-listing (no doc-as-specialist problem here per audit) |

**PROTECT:** nothing specially called out. Note that time-keepr is v0.1/Genesis —
treat as a work-in-progress and avoid any changes that assume production readiness.

---

## PROTECT Summary (do not touch under any circumstances)

| Page | Protected Section | Reason |
|---|---|---|
| notion-keepr | §Write-Mechanics | Cross-skill SSOT, referenced by 5 parents |
| project-keepr | §3 Universal Project Protocols | Cross-skill SSOT |
| people-keepr | §LD | Load-bearing Leadership Domain rules |
| people-keepr | §Amendments | Amendment record integrity |

---

## Application Sequence (recommended order)

Apply in this order to minimize risk of cross-references breaking mid-edit:

1. **Resolve unresolved IDs first** (focus-keepr `c57598ef`/`aa3363b9`/`23337454`; notion-keepr `9a4105d0`/`c629dc07`) — 5 page reads, no writes. Gate: IDs classified before any de-list.
2. **Global G3 brand pass** across all 7 parents (find-replace safe, low risk).
3. **De-list operations** (N3, N4, SK3, SK4, P3) — relation edits only, no body content risk.
4. **Body content removals** (persona blocks G1, retired §7 Prospecting P7, empty Reminders G2 drops) — destructive content deletes, do carefully one parent at a time.
5. **Renames and restructures** (G2 "Reminders"→"Operating Notes", PJ3 callout→FR-21, T4 §R→§EX, M2 machine-JSON dedup).
6. **Additions and registrations** (P6 §9 body registry, T6 R6 gap note).
7. **Metadata fixes** (P8 Maturity, PJ2 version drift, T5 routing summary, F4 Tool Permissions — operator confirmation required before each).
8. **Unified memory candidates** (mac M1–M3, time M1–M3) — note in place; defer writes to 3.7.5 wave.

---

## Tooling Note

The Bridge `notion_page_edit` / `notion_blocks_append` tools work reliably for surgical
single-block or small multi-block edits. For any section involving more than ~5 block
operations (e.g., a full persona-block removal spanning 10+ paragraphs), break the edit
into sub-steps and verify each step before proceeding. Do NOT use bulk-replace patterns
against long-form page bodies — the W0 audit flagged this as a reliability risk.

Suggested per-edit workflow:
1. `notion_page_markdown_read` → confirm current state
2. Construct the minimal `notion_block_delete` / `notion_block_update` / `notion_blocks_append` call
3. Re-read the affected section to verify
4. Proceed to next edit

---

## Completion Criteria

This plan is complete when:
- [ ] All 5 unresolved IDs are read and classified (REAL or DOC)
- [ ] operator has reviewed and approved each action group (global, per-parent)
- [ ] Each action is applied and verified via a re-read of the affected section
- [ ] Protected sections (§Write-Mechanics, §3, §LD, §Amendments) are confirmed untouched
- [ ] Specialist relation for skill-keepr resolves to exactly 3 real entries
- [ ] people-keepr relation has stripe-keepr + service-coach and no legacy stubs
- [ ] All 7 parents have had persona/identity block removed
- [ ] No parent has a "Reminders" section title (renamed or dropped)
- [ ] All occurrences of "KUP·OS" / "KUP OS" / "KUP-OS" in skill bodies replaced with "KEEP OS"
