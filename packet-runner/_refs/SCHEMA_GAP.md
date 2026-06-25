# Schema Gap — live vs. PRD target (captured 2026-06-23, read-only)

## PACKETS — data source `078e7c9e-e53e-4c83-a893-af64f82b5123`

### Live properties (before)
`AI LOGS`(relation) · `Agent Type`(select: Notion AI, Cursor, Claude Code, Hybrid, bridge-keepr) · `Blocked by`(relation) · `Blocking`(relation) · `Complexity`(number) · `Context Size`(number) · `Created`(created_time) · `Duration`(number) · `EVENT`(relation) · `Filter`(formula) · `Last Snapshot At`(date) · `Mirror Status`(status: Snapshot Pending, Synced) · `Model`(select) · `Objective`(rich_text) · `PKT-ID`(unique_id) · `PROJECT`(relation) · `Packet Name`(title) · `Packet Output`(rich_text) · `Packet Title`(rich_text) · `SKILLS`(relation) · `Source of Truth`(rich_text) · `Status`(status: **Backlog, QUEUE, FOCUS, REVIEW, Done, Decline**) · `Tokens`(number) · `Trigger`(multi_select 📦 🔃) · `fromStatus`(status: Backlog, QUEUE, FOCUS, REVIEW, Done, Decline)

### Target delta (PRD §8.1)
**ADD (additive, non-destructive — apply live now):**
- `Status` option **`BLOCKED`** (group To-do). [keep all legacy options]
- `fromStatus` option **`BLOCKED`** (mirror).
- `Lifecycle Checked At` — date **with time**.
- `Execution Class` — select: AUTO, REVIEW-FIRST, MANUAL.
- `Priority` — number (0–100; missing = 0).
- `Execution Window` — date (optional end).
- `Last Execution URL` — URL.
- `Last Executed At` — date with time.
- `Cleanup Eligible At` — date with time.
- Verify `Agent Type` has the selected-provider option (Claude Code ✅ present).

**ALSO need (additive options to satisfy target casing without deleting legacy):**
- `Status`/`fromStatus`: target uses **BACKLOG, DONE, CANCELED**; live has **Backlog, Done, Decline**. Migration maps Backlog→BACKLOG, Done→DONE, Decline→CANCELED. Add the target-cased options alongside legacy; **defer** record remap + legacy-option deletion until validation (§8.1 steps 4–7).

**DEFER (destructive — gated on acceptance validation):** remap every record's Status to new casing; stamp `Lifecycle Checked At` after confirming each record's state; set un-audited records' `Execution Class = MANUAL`; delete legacy Status options only after no record/automation references them.

**DO NOT ADD (explicitly forbidden in v1, §8.1):** Ready, Run ID, Worker ID, Claimed By/At, Lease Until, Heartbeat, Attempt, Retry Count, token/cost budget, custom cycle ID.

**Reuse as-is:** PKT-ID (unique_id → deterministic tie-break), Packet Output (rich_text index, ≤1,800 chars), Source of Truth (rich_text locators), PROJECT/SKILLS/Blocked by/Blocking/EVENT/AI LOGS relations.
**Legacy audit-only (retire later):** Complexity, Context Size, Duration, Tokens, Model, Objective, Packet Title, Trigger, Filter, Last Snapshot At, Mirror Status.

## AI LOGS — data source `992fd5ac-d938-4be4-95fb-8ef18bd86bba`

### Live properties (before)
`Anticipation Gaps`(rt) · `Artifacts Created`(rt) · `BOTS`(relation) · `Concise`(select) · `Confidence`(number) · `Created Date`(created_time) · `Duration`(number) · `EVENT`(relation) · `Enhancement Ideas`(rt) · `Faithful`(select) · `Friction Signals`(rt) · `Log Name`(title) · `Log Type`(select: Skill, Aura, Session, Decision, System, Event Intelligence, Evolution Session, Test, Packet) · `Outcome`(select: Success, Partial, Failure, Abandoned) · `PACKET`(relation) · `Platform`(select: Notion, Claude, Cursor) · `Quality`(select) · `Readable`(select) · `Reflexion Used`(checkbox) · `Routing Chain`(rt) · `SKILL`(relation) · `Session Context`(rt) · `User Feedback`(rt)

### Target delta (PRD §8.7)
**ADD (additive — apply live now):**
- `Signal Type` — select: Friction, Anticipation Gap, Enhancement, User Feedback, Incident, Reusable Pattern.
- `Impact` — select: Low, Medium, High.
- `Disposition` — select: Open, Investigating, Mitigated, Resolved, Dismissed, Archived.
- `Summary / Observation` — rich_text.
- `Recommendation` — rich_text.
- `Source URL` — URL.
- `Resolved At` — date with time.
- `Archive Eligible At` — date with time.
- `Promoted To` — rich_text (locator to durable guidance).
- `Log Type` options: add **Incident, Learning** (keep legacy).
- `Platform` options: add **Codex, Other** (keep legacy).

**Reuse:** Log Name(title), Outcome (matches), PACKET/SKILL/EVENT relations, User Feedback, Created Date.
**Legacy audit-only/retire after compat (§8.7):** Confidence, Faithful, Concise, Readable, Quality, Reflexion Used, Duration, Routing Chain, Artifacts Created, Anticipation Gaps, Enhancement Ideas, Friction Signals, Session Context, BOTS.

### Managed body sections (§8.7)
`## Incident Evidence Bundle` · `## Resolution` · `## Learning Promotion`.

## Notes
- Notion **status** properties: options can be added via API; group placement matters (To-do / In progress / Complete). `Status` + `fromStatus` both carry the option set.
- All adds are reversible (property/option removal) → safe to apply live under directive authorization ("preserving legacy compatibility until validation passes").
