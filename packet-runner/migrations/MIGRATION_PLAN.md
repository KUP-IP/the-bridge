# PACKETS + AI LOGS — Migration Plan (Lane A)

**Status:** Plan only. No live Notion mutation performed by this lane (read-only directive).
**Captured:** 2026-06-23. **Authority:** PRD-v1.0 §8.1, §8.2, §8.2A, §8.7, §8.15 (PRD governs — §14.1).
**Inputs verified live (read-only):** `notion_datasource_get` on both data sources (2026-06-23); wire
contract verified in source (`TheBridge/Notion/NotionClient.swift:855`, `Modules/NotionModule.swift:1420`).

Data sources:
- **PACKETS** — `078e7c9e-e53e-4c83-a893-af64f82b5123`
- **AI LOGS** — `992fd5ac-d938-4be4-95fb-8ef18bd86bba`

Migration philosophy (PRD §8.1 migration sequence, §8.7 migration): **additive-first, legacy-preserving.**
Only the ADDITIVE adds in Section 1 are applied live now. All destructive remap/stamping/deletion is
deferred (Section 5) until acceptance validation passes (§8.1 steps 4–7).

---

## 0. Bridge tool + Notion API wire contract (how every add below is executed)

All schema adds use the Bridge tool **`notion_datasource_update`** (tier `.notify`).

Verified behavior (source-confirmed, do not re-derive):
- Tool params: `{ dataSourceId, properties, workspace? }`. `properties` is a **JSON string of the INNER
  properties object only** — the tool wraps it as `{ "properties": <obj> }` itself
  (`NotionModule.swift:1420`) and PATCHes `/v1/data_sources/{id}` (`NotionClient.swift:855`).
- Therefore every `properties` payload in this plan is the **inner** map: `{ "<Prop Name>": { <spec> } }`.
  Do **not** add an outer `properties` wrapper — that double-wraps and fails.
- Keying: a property is **added** when the key (property name) does not exist; **modified** when it does.
  For `select`, sending `options` is **merge/replace of the option set** — to add an option you must send
  the **full desired option list** (existing + new), or Notion drops omitted options. Each verification
  read in Section 3 supplies the exact existing list to merge against immediately before the call.

### 0.1 HARD CONSTRAINT — Notion `status` properties are NOT API-mutable
The Notion data-source PATCH endpoint **rejects adding/removing/renaming options or groups on
`status`-type properties**; status options are editable only in the Notion UI. `select`/`multi_select`
options *are* API-mutable. Consequence for this plan:

| Target add | Property type | API-applicable via `notion_datasource_update`? |
|---|---|---|
| `Status` options BACKLOG / BLOCKED / DONE / CANCELED | **status** | ❌ NO — UI-only |
| `fromStatus` options BACKLOG / BLOCKED / DONE / CANCELED | **status** | ❌ NO — UI-only |
| `Execution Class`, `Priority`, `Execution Window`, URLs, dates (PACKETS) | select/number/date/url | ✅ yes |
| AI LOGS new select props + `Log Type`/`Platform` option adds | select | ✅ yes |
| AI LOGS new rich_text / url / date props | rich_text/url/date | ✅ yes |

> **BLOCKED: operator action required for all PACKETS `Status` + `fromStatus` option adds (Steps 1.1, 1.2).**
> They cannot be applied by this routine. Operator must add them in the Notion UI (Section 1 gives exact
> option name + group). This is a determinism boundary, not a design gap — recorded honestly per directive.

---

## 1. ADDITIVE adds — the ONLY steps applied live now

Ordered. PACKETS first (§8.1), then AI LOGS (§8.7). Steps marked **[UI-ONLY]** are the status-option adds
that the operator applies in the Notion UI; all others are `notion_datasource_update` calls (Section 2).

### PACKETS (`078e7c9e-e53e-4c83-a893-af64f82b5123`)

Live `Status`/`fromStatus` options today: `Backlog, QUEUE, FOCUS, REVIEW, Done, Decline` (groups: To-do /
In progress / Complete). QUEUE, FOCUS, REVIEW already match target casing and group — **no change**.

| # | Property | Action | Type | Detail / options | Group placement |
|---|---|---|---|---|---|
| 1.1 **[UI-ONLY]** | `Status` | add options | status | **BACKLOG**, **BLOCKED** | both → **To-do** |
| 1.2 **[UI-ONLY]** | `Status` | add options | status | **DONE**, **CANCELED** | both → **Complete** |
| 1.3 **[UI-ONLY]** | `fromStatus` | add options | status | **BACKLOG**, **BLOCKED**, **DONE**, **CANCELED** | mirror Status groups (§8.1 step 5) |
| 1.4 | `Lifecycle Checked At` | add property | date (with time) | — | — |
| 1.5 | `Execution Class` | add property | select | **AUTO**, **REVIEW-FIRST**, **MANUAL** | — |
| 1.6 | `Priority` | add property | number | 0–100; missing = 0 (§8.1) | — |
| 1.7 | `Execution Window` | add property | date (optional end) | — | — |
| 1.8 | `Last Execution URL` | add property | url | — | — |
| 1.9 | `Last Executed At` | add property | date (with time) | — | — |
| 1.10 | `Cleanup Eligible At` | add property | date (with time) | Packet-Runner-derived; never worker-supplied (§8.1) | — |
| 1.11 | `Agent Type` | **verify only** | select | Confirm selected provider option exists. **Claude Code present** ✅ (live read). No add unless provider differs (§8.1). | — |

Notes:
- Notion `date` is a single property type; "with time" and "optional end" are **value-level**, not
  schema-level — the schema spec is identical `{"date": {}}` for 1.4/1.7/1.9/1.10. The with-time / range
  semantics are enforced by writers (§8.1 Coupled lifecycle write; §8.8), not the column definition.
- `Priority`: PRD §8.1 says "missing equals 0" — this is reader semantics; Notion cannot set a numeric
  default, so no `format`/default is specified. Leave bare `{"number": {}}` (no `format` ⇒ plain number).
- BACKLOG and BLOCKED are **distinct** target options even though legacy `Backlog` exists — the remap
  Backlog→BACKLOG is deferred (Section 5). Adding `BACKLOG` alongside `Backlog` is intentional (§8.1 step 2:
  "without removing legacy values").

### AI LOGS (`992fd5ac-d938-4be4-95fb-8ef18bd86bba`)

Live `Log Type`: `Skill, Aura, Session, Decision, System, Event Intelligence, Evolution Session, Test,
Packet`. Live `Platform`: `Notion, Claude, Cursor`. Live `Outcome` already matches target ✅. All AI LOGS
adds are **select / rich_text / url / date** ⇒ **fully API-applicable** (no status type here).

| # | Property | Action | Type | Detail / options |
|---|---|---|---|---|
| 1.12 | `Signal Type` | add property | select | **Friction**, **Anticipation Gap**, **Enhancement**, **User Feedback**, **Incident**, **Reusable Pattern** |
| 1.13 | `Impact` | add property | select | **Low**, **Medium**, **High** |
| 1.14 | `Disposition` | add property | select | **Open**, **Investigating**, **Mitigated**, **Resolved**, **Dismissed**, **Archived** |
| 1.15 | `Summary / Observation` | add property | rich_text | — |
| 1.16 | `Recommendation` | add property | rich_text | — |
| 1.17 | `Source URL` | add property | url | — |
| 1.18 | `Resolved At` | add property | date (with time) | — |
| 1.19 | `Archive Eligible At` | add property | date (with time) | — |
| 1.20 | `Promoted To` | add property | rich_text | stable locator to durable guidance (§8.7) |
| 1.21 | `Log Type` | add options (merge) | select | add **Incident**, **Learning** — keep all 9 legacy |
| 1.22 | `Platform` | add options (merge) | select | add **Codex**, **Other** — keep all 3 legacy |

Notes:
- `Summary / Observation` contains a slash and spaces — that is the literal property **name** (§8.7); it is
  valid as a Notion property name and as a JSON key. Send it verbatim.
- §8.7 target `Log Type` is `Incident, Learning, Decision, System, Packet`. Decision/System/Packet already
  exist; Skill/Aura/Session/Event Intelligence/Evolution Session/Test are **legacy kept** (§8.7: "Preserve
  legacy fields during migration until compatibility is verified"). Only Incident + Learning are added now.

### NOT ADDED — forbidden-field confirmation (§8.1 final paragraph)
The following are **explicitly NOT added** to either data source, now or in the deferred plan:
**Ready, Run ID, Worker ID, Claimed By, Claimed At, Lease Until, Heartbeat, Attempt, Retry Count, token
budget, cost budget, custom cycle ID** — and by extension any claim/lease/heartbeat/budget field. Confirmed
absent from Section 1 and Section 5. (CONTRACT_CONFLICTS executor §0.SA.4/§3.PF.2/§3.R, orchestrator
Execution-Class row — all resolved by exclusion.)

---

## 2. Per-property Notion API shape (deterministic execution)

Each block: `dataSourceId` + the **inner** `properties` JSON string for one `notion_datasource_update`
call. Apply one property per call for clean rollback/attribution (batching is allowed but loses per-add
isolation). **Select option adds (2.10, 2.11) MUST first read the live option list (Section 3) and resend
the full merged list** — the placeholder lists below already include the verified-live options as of
2026-06-23; re-verify immediately before the call in case of UI drift.

### 2.1–2.7 PACKETS additive properties (API-applicable)

```text
TOOL: notion_datasource_update
dataSourceId: 078e7c9e-e53e-4c83-a893-af64f82b5123
properties (one call each — inner object only):

# 1.4 Lifecycle Checked At
{ "Lifecycle Checked At": { "date": {} } }

# 1.5 Execution Class
{ "Execution Class": { "select": { "options": [
  { "name": "AUTO" }, { "name": "REVIEW-FIRST" }, { "name": "MANUAL" } ] } } }

# 1.6 Priority
{ "Priority": { "number": {} } }

# 1.7 Execution Window
{ "Execution Window": { "date": {} } }

# 1.8 Last Execution URL
{ "Last Execution URL": { "url": {} } }

# 1.9 Last Executed At
{ "Last Executed At": { "date": {} } }

# 1.10 Cleanup Eligible At
{ "Cleanup Eligible At": { "date": {} } }
```

> **1.1/1.2/1.3 (`Status`/`fromStatus` status options): NO API SHAPE — UI-ONLY (§0.1).** Operator adds
> in Notion UI: `Status` → To-do group: BACKLOG, BLOCKED; Complete group: DONE, CANCELED. Then mirror the
> same four into `fromStatus` (§8.1 step 5). Color is operator discretion; option **name** is load-bearing
> (writers bind by name). If the API ever accepts status edits in a future Notion version, the shape would
> be `{ "Status": { "status": { "options": [...], "groups": [...] } } }` — but today this returns a
> validation error; do not attempt it programmatically.

### 2.8 PACKETS `Agent Type` — verify only (no write)
Read confirms options include **Claude Code** ✅ (live 2026-06-23). No `notion_datasource_update` call.
Only if the selected pilot provider is NOT in `[Notion AI, Cursor, Claude Code, Hybrid, bridge-keepr]` do
you merge-add it (then use the same full-list merge pattern as 2.10).

### 2.9 AI LOGS additive properties (API-applicable)

```text
TOOL: notion_datasource_update
dataSourceId: 992fd5ac-d938-4be4-95fb-8ef18bd86bba
properties (one call each — inner object only):

# 1.12 Signal Type
{ "Signal Type": { "select": { "options": [
  { "name": "Friction" }, { "name": "Anticipation Gap" }, { "name": "Enhancement" },
  { "name": "User Feedback" }, { "name": "Incident" }, { "name": "Reusable Pattern" } ] } } }

# 1.13 Impact
{ "Impact": { "select": { "options": [
  { "name": "Low" }, { "name": "Medium" }, { "name": "High" } ] } } }

# 1.14 Disposition
{ "Disposition": { "select": { "options": [
  { "name": "Open" }, { "name": "Investigating" }, { "name": "Mitigated" },
  { "name": "Resolved" }, { "name": "Dismissed" }, { "name": "Archived" } ] } } }

# 1.15 Summary / Observation
{ "Summary / Observation": { "rich_text": {} } }

# 1.16 Recommendation
{ "Recommendation": { "rich_text": {} } }

# 1.17 Source URL
{ "Source URL": { "url": {} } }

# 1.18 Resolved At
{ "Resolved At": { "date": {} } }

# 1.19 Archive Eligible At
{ "Archive Eligible At": { "date": {} } }

# 1.20 Promoted To
{ "Promoted To": { "rich_text": {} } }
```

### 2.10 AI LOGS `Log Type` — merge-add Incident + Learning (full list resend)

```text
TOOL: notion_datasource_update
dataSourceId: 992fd5ac-d938-4be4-95fb-8ef18bd86bba
properties:
{ "Log Type": { "select": { "options": [
  { "name": "Skill" }, { "name": "Aura" }, { "name": "Session" }, { "name": "Decision" },
  { "name": "System" }, { "name": "Event Intelligence" }, { "name": "Evolution Session" },
  { "name": "Test" }, { "name": "Packet" },
  { "name": "Incident" }, { "name": "Learning" } ] } } }
```
> Re-read live `Log Type` options first (Section 3.2) and reproduce them exactly before appending Incident +
> Learning. Omitting any existing option **deletes** it. To preserve existing colors, include each option's
> live `id` alongside `name` (read it from the verification get; Notion keys options by id when present).

### 2.11 AI LOGS `Platform` — merge-add Codex + Other (full list resend)

```text
TOOL: notion_datasource_update
dataSourceId: 992fd5ac-d938-4be4-95fb-8ef18bd86bba
properties:
{ "Platform": { "select": { "options": [
  { "name": "Notion" }, { "name": "Claude" }, { "name": "Cursor" },
  { "name": "Codex" }, { "name": "Other" } ] } } }
```
> Same full-list-resend caution as 2.10; include live option `id`s to preserve colors.

---

## 3. Post-add verification reads (after Section 1/2 applied)

All read-only (`notion_datasource_get`). Run after the adds; compare against the expected sets below.
A mismatch ⇒ do not proceed to deferred work; investigate.

### 3.1 PACKETS verification
```text
notion_datasource_get  dataSourceId: 078e7c9e-e53e-4c83-a893-af64f82b5123
```
Assert the schema now contains, with correct types:
- `Lifecycle Checked At`:date · `Execution Class`:select{AUTO,REVIEW-FIRST,MANUAL} · `Priority`:number ·
  `Execution Window`:date · `Last Execution URL`:url · `Last Executed At`:date · `Cleanup Eligible At`:date.
- `Status` (status): options ⊇ {Backlog, QUEUE, FOCUS, REVIEW, Done, Decline, **BACKLOG, BLOCKED, DONE,
  CANCELED**}; BACKLOG+BLOCKED in **To-do**, DONE+CANCELED in **Complete** — **only after the UI step**.
- `fromStatus` (status): same option superset as `Status`.
- `Agent Type`: contains the selected provider option.
- Legacy properties (Complexity, Tokens, Model, …) **still present** (additive proof).

### 3.2 AI LOGS verification
```text
notion_datasource_get  dataSourceId: 992fd5ac-d938-4be4-95fb-8ef18bd86bba
```
Assert:
- New props present with correct types: `Signal Type`:select(6) · `Impact`:select(3) ·
  `Disposition`:select(6) · `Summary / Observation`:rich_text · `Recommendation`:rich_text ·
  `Source URL`:url · `Resolved At`:date · `Archive Eligible At`:date · `Promoted To`:rich_text.
- `Log Type` options ⊇ legacy 9 **+ Incident, Learning** (legacy not dropped).
- `Platform` options ⊇ {Notion, Claude, Cursor, **Codex, Other**}.
- `Outcome` unchanged {Success, Partial, Failure, Abandoned}; legacy audit props still present.

### 3.3 Forbidden-field assertion (both)
Confirm **none** of Ready / Run ID / Worker ID / Claimed By / Claimed At / Lease Until / Heartbeat /
Attempt / Retry Count / token budget / cost budget / custom cycle ID exists on either data source.

---

## 4. ROLLBACK procedure (reverse each additive add)

All Section 1 adds are reversible. Reverse order. **A removed select option's cell values become empty on
affected records** — accept this for never-populated new options (rollback is for a bad add before
adoption). Removing a whole property deletes its column and any values written to it.

### 4.1 Remove an added select OPTION (without deleting the property)
Resend `notion_datasource_update` with the **prior** (smaller) option list — i.e. omit the added option.
- `Log Type` rollback → resend the **legacy-9** list (drop Incident, Learning).
- `Platform` rollback → resend `{Notion, Claude, Cursor}` (drop Codex, Other).
(Notion treats option set as declarative; omitting = remove.)

### 4.2 Remove an added PROPERTY entirely
Set the property to `null` in the inner object — this deletes the column:
```text
# PACKETS — remove each added property (one call or batched)
dataSourceId: 078e7c9e-e53e-4c83-a893-af64f82b5123
{ "Lifecycle Checked At": null, "Execution Class": null, "Priority": null,
  "Execution Window": null, "Last Execution URL": null, "Last Executed At": null,
  "Cleanup Eligible At": null }

# AI LOGS — remove each added property
dataSourceId: 992fd5ac-d938-4be4-95fb-8ef18bd86bba
{ "Signal Type": null, "Impact": null, "Disposition": null, "Summary / Observation": null,
  "Recommendation": null, "Source URL": null, "Resolved At": null,
  "Archive Eligible At": null, "Promoted To": null }
```
> Verify in source that the Bridge passes `null` values through to the PATCH body — `NotionModule.swift`
> parses `properties` via `JSONSerialization` into `[String:Any]` and forwards as-is, so JSON `null`
> survives. Notion's data-source PATCH interprets a property set to `null` as **delete** (same as the
> public databases API). **BLOCKED: if a future Bridge build strips nulls, fall back to UI deletion.**

### 4.3 Rollback of UI-only status options (1.1–1.3)
**Operator action in Notion UI** — delete the added options BACKLOG / BLOCKED / DONE / CANCELED from
`Status` and `fromStatus`. Not API-reversible (status props are UI-only). Only safe before any record uses
the new option.

### 4.4 `Agent Type`
No rollback unless an option was added in 2.8 — then resend the prior list (Section 4.1 pattern).

---

## 5. DEFERRED destructive plan — **DO NOT RUN until acceptance validation passes (§8.1 steps 4–7)**

> **GATE:** Execute Section 5 **only after** schema + lifecycle acceptance tests pass (§8.1 step 6) and the
> operator confirms validation. Each item below is **irreversible** (record mutation / option deletion).
> This section is documentation of the eventual path, **not** an instruction to act now. (PROGRAM_PLAN
> "Honest gate map": destructive remap = ⛔ Deferred.)

**D-1 — Record Status remap (§8.1 step 4).** For every PACKETS record, audit live state, then remap the
`Status` (and `fromStatus` where it carries the old value): **Backlog→BACKLOG, Done→DONE, Decline→CANCELED**
(QUEUE/FOCUS/REVIEW unchanged). Per §8.1 step 4, remap **only after confirming the record's actual state**.
Tooling: per-record `notion_page_update` (write) — out of scope until gate; **READ-ONLY now**.

**D-2 — `Lifecycle Checked At` stamping (§8.1 step 4).** Stamp `Lifecycle Checked At` on each record **only
after** confirming its state (coupled lifecycle write, §8.1). Not retroactively guessed.

**D-3 — Un-audited `Execution Class = MANUAL` (§8.1 step 4).** Every legacy packet without an audited
Execution Class → set **MANUAL** (fail-closed). Promotion to AUTO / REVIEW-FIRST only via explicit
recertification. (MANUAL is never dispatched — §8.5.)

**D-4 — `fromStatus` retirement (§8.1 step 5).** Keep `fromStatus` mirrored while dependent automations
exist; retire **only after** compatibility evidence proves it unnecessary.

**D-5 — Legacy Status option deletion (§8.1 step 7).** Delete legacy `Backlog`, `Done`, `Decline` from
`Status` and `fromStatus` **only after** no record or automation references them (i.e. after D-1 completes
and references are swept). **UI-only** (status props) — operator action; irreversible.

**D-6 — AI LOGS legacy remap + retirement (§8.7 migration).** Map legacy `Accepted`-style records to
`Disposition` Investigating/Resolved **only after record-level review**. Retire audit-only fields
(Confidence, Faithful, Concise, Readable, Quality, Reflexion Used, manual Duration, Routing Chain,
Artifacts Created, …) **after** compatibility evidence confirms they are unused.
> Note: live AI LOGS has no `Accepted` *option* today (no Disposition/Accepted field existed pre-migration);
> "legacy Accepted records" refers to historical disposition semantics carried in audit fields — resolve at
> record-review time, not by blind mapping. **BLOCKED: record-level review is human-gated.**

---

## 6. Managed `## Packet Runner Output` body structure (add to nonterminal packets)

Per §8.2 + §8.2A + §8.15. **Orchestrator authors the empty managed heading**; it places **no mission
instructions** beneath it. Executor *proposes* only inside this section; **Packet Runner writes the final
form** after reconciliation. Mission sections above it are never overwritten (§8.2).

**Applies to:** nonterminal packets — i.e. any packet not already DONE/CANCELED that is (or will be) queued
as Standard or Strategic (§8.2). Add via surgical body insert (read-modify-write; do not clobber mission
sections). Authoring the empty heading is non-destructive but is a **body write** ⇒ deferred to the
authoring/orchestrator lane, not applied by this read-only lane.

Exact structure to insert at the **end** of the packet body:

```markdown
## Packet Runner Output

### Current Canonical Result
<!-- One fenced YAML block, rewritten in place each cycle (§8.2A, §8.15).
     Reflects latest authoritative state: status + receipt classification, concise outcome +
     success-criteria result, verification evidence + artifact links, native execution reference +
     last execution time (when a worker started), safe state / rollback position / already-satisfied
     evidence, exact review decision or unblock condition, controlling approval/cancellation receipt. -->

### Artifact Manifest
<!-- One fenced YAML list, rewritten in place each cycle. One entry per artifact:
     target, change, retention_class (canonical|evidence|temporary), ownership
     (routine|repository|external|unknown), authoritative_locator, current existence. -->

### Exceptional History
<!-- Append-only ONLY for events whose omission would make current state unsafe/misleading (§8.15):
     critical incident / authorization violation; ambiguous irreversible or external effect; duplicate
     execution / ownership conflict; approval/continuation/request-changes/cancellation receipts when
     historically relevant; significant rollback/recovery/safe-resume; material packet revision that
     invalidated prior approval; secret/credential incident (redacted only); false-DONE correction or
     receipt/live mismatch. Each entry = compact timestamped Markdown with the labeled fields:
     event type · time · concise facts · affected artifact/action · resulting safe state ·
     source execution/reference · resolution status. -->
```

Invariants (from §8.2A / §8.15):
- Exactly **one** managed section; if missing, duplicated, malformed, or too large to update safely →
  do **not** improvise another location; move packet to **REVIEW** and preserve the prior trustworthy record.
- `Current Canonical Result` + `Artifact Manifest` are **replaced in place**; `Exceptional History` is
  **append-only** (compaction may drop redundant detail only — never safety-relevant evidence).
- The compact `Packet Output` **property** (≤1,800 visible chars, §8.2A labeled fields) is the index; this
  body section is the full machine-readable record. The property is written by Packet Runner, not here.

---

## Summary of what is / isn't done

- **Applied live now (Section 1/2):** NONE by this lane (read-only directive). Section 1/2 are the exact,
  ready-to-run additive steps for the executing lane. API-applicable adds = PACKETS 7 props +
  AI LOGS 9 props + 2 select-option merges. **Status-option adds (PACKETS 1.1–1.3) are UI-ONLY** (§0.1).
- **Deferred (Section 5):** all record remap / stamping / MANUAL backfill / legacy-option deletion / AI LOGS
  legacy remap — gated on §8.1 steps 4–7 validation. **DO NOT RUN now.**
- **Forbidden fields:** confirmed **NOT added** (Ready/Run ID/Worker ID/claims/leases/heartbeat/budgets/
  cycle ID) — Section 1, 3.3, 5.
- **Managed body (Section 6):** structure specified for nonterminal packets; the empty-heading write is an
  orchestrator-lane body edit (deferred from this read-only lane).

### BLOCKED / open items
- **BLOCKED:** PACKETS `Status` + `fromStatus` option adds (BACKLOG/BLOCKED/DONE/CANCELED) require **operator
  Notion-UI action** — not API-applicable (Notion status properties are UI-only). Section 1.1–1.3 give exact
  option + group.
- **BLOCKED:** select-option merge adds (Log Type, Platform, and any Agent Type provider add) must **re-read
  the live option list immediately before the call** and resend the full merged list (with option `id`s to
  preserve colors); stale lists silently delete options.
- **BLOCKED:** rollback-by-`null` (4.2) assumes the Bridge forwards JSON `null` to the PATCH body (consistent
  with current `NotionModule.swift` pass-through); if a future build strips nulls, fall back to UI deletion.
- **BLOCKED (deferred gate):** all Section 5 destructive steps + D-6 record-level review are human/validation
  gated (§8.1 steps 4–7, §8.7).
