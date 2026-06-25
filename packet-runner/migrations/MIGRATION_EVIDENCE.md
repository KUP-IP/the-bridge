# Migration Evidence — additive schema migration APPLIED LIVE

**Applied:** 2026-06-23 · **Tool:** Bridge `notion_datasource_update` (PATCH `/v1/data_sources/{id}`)
**Authorization:** directive ("Apply the PACKETS and AI LOGS migrations … preserving legacy compatibility until validation passes") + PRD §8.1/§8.7. Additive-only; reversible.
**Before snapshots:** [`SNAPSHOT_PACKETS_before.json`](./SNAPSHOT_PACKETS_before.json), [`SNAPSHOT_AILOGS_before.json`](./SNAPSHOT_AILOGS_before.json).
**After snapshots:** [`SNAPSHOT_PACKETS_after.json`](./SNAPSHOT_PACKETS_after.json), [`SNAPSHOT_AILOGS_after.json`](./SNAPSHOT_AILOGS_after.json).
**Rollback:** [`MIGRATION_PLAN.md`](./MIGRATION_PLAN.md) §4 (resend smaller option list to drop an option; set property → `null` to delete a column).

## PATCH 1 — PACKETS `078e7c9e-e53e-4c83-a893-af64f82b5123` → `success: true`
Inner properties applied:
```json
{"Lifecycle Checked At":{"date":{}},"Execution Class":{"select":{"options":[{"name":"AUTO"},{"name":"REVIEW-FIRST"},{"name":"MANUAL"}]}},"Priority":{"number":{}},"Execution Window":{"date":{}},"Last Execution URL":{"url":{}},"Last Executed At":{"date":{}},"Cleanup Eligible At":{"date":{}}}
```
Verified present (with assigned property ids): `Lifecycle Checked At`(nrEw,date) · `Execution Class`(WHc%7D,select{AUTO,REVIEW-FIRST,MANUAL}) · `Priority`(fvlG,number) · `Execution Window`(M%5ERi,date) · `Last Execution URL`(iTpe,url) · `Last Executed At`(hhpb,date) · `Cleanup Eligible At`(pq~Y,date). Legacy properties + `Status`/`fromStatus` options unchanged (additive proof). `Agent Type` has `Claude Code` ✅.

## PATCH 2 — AI LOGS `992fd5ac-d938-4be4-95fb-8ef18bd86bba` → `success: true`
9 new properties added: `Signal Type`(Cl%5BX,select{6}) · `Impact`(RE%7CF,select{Low,Medium,High}) · `Disposition`(~x%3AH,select{Open,Investigating,Mitigated,Resolved,Dismissed,Archived}) · `Summary / Observation`(iYjl,rich_text) · `Recommendation`({Dv_,rich_text) · `Source URL`(?b<r,url) · `Resolved At`(wmBe,date) · `Archive Eligible At`(@`fw,date) · `Promoted To`(=qvS,rich_text).

## PATCH 3 — AI LOGS select-option merges → `success: true`
`Log Type` → 11 options: Skill, Aura, Session, Decision, System, Event Intelligence, Evolution Session, Test, Packet, **Incident**, **Learning** (legacy 9 preserved). `Platform` → 5 options: Notion, Claude, Cursor, **Codex**, **Other** (legacy 3 preserved).

## Forbidden-field assertion (§8.1) — PASS
Neither data source contains: Ready, Run ID, Worker ID, Claimed By/At, Lease Until, Heartbeat, Attempt, Retry Count, token/cost budget, cycle ID. Confirmed by after-snapshot.

## ⛔ OPERATOR BLOCKER — PACKETS `Status` / `fromStatus` options (UI-only)
Notion `status`-type options are **not API-mutable**. The following must be added by the operator in the Notion UI before the controller's lifecycle can be exercised:
- `Status` → **To-do** group: `BLOCKED` (required for the controller now); `BACKLOG` (deferred-remap target).
- `Status` → **Complete** group: `DONE`, `CANCELED` (deferred-remap targets).
- `fromStatus` → mirror the same four options (§8.1 step 5).
The controller's BLOCKED transitions (FR-4, §6) cannot run until at least `BLOCKED` exists on `Status`. BACKLOG/DONE/CANCELED are needed for the deferred record-remap (Section 5 of the plan), which is gated on acceptance validation regardless.

## DEFERRED (not run) — destructive remap
Per [`MIGRATION_PLAN.md`](./MIGRATION_PLAN.md) §5 (D-1…D-6): record Status remap (Backlog→BACKLOG / Done→DONE / Decline→CANCELED), `Lifecycle Checked At` stamping, un-audited `Execution Class=MANUAL`, legacy-option deletion, AI LOGS legacy remap — all gated on §8.1 steps 4–7 (acceptance validation + operator confirm). **Not executed.**
