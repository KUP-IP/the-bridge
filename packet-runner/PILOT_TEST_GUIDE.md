# Packet Runner v1 — Pilot Test Guide

**Operator runbook for the Phase 1 pilot → 20-cycle qualification.** Validates the fully-local cycle (an app-local Claude Code scheduled agent, the proven `keep-os-daily-people-report` pattern) end-to-end on **Ship The Bridge v4**, with you hand-picking each packet, before any unattended schedule.

> **Status until Step 10: NOT production-qualified.** Scheduling stays OFF (`schedule: null`) through Phase 1. Everything fails closed — when in doubt the cycle picks **REVIEW**, never guesses; a Bridge-unreachable preflight **aborts with no partial writes**.

**Reference:** [`MASTER_IMPLEMENTATION_SPEC.md`](MASTER_IMPLEMENTATION_SPEC.md) §4–§5 · cycle prompt [`agent/packet-runner-cycle.md`](agent/packet-runner-cycle.md) · [`controller/LATCH_PROTOCOL.md`](controller/LATCH_PROTOCOL.md) · config [`config/routine.config.ship-the-bridge-v4.json`](config/routine.config.ship-the-bridge-v4.json) · [`acceptance/ACCEPTANCE_MATRIX.md`](acceptance/ACCEPTANCE_MATRIX.md) · example brief [`evidence/EXAMPLE_OPERATOR_BRIEF.md`](evidence/EXAMPLE_OPERATOR_BRIEF.md). Decisions: D1′ fully-local · D2 Ship The Bridge v4 · D3 operator hand-picks · D4 §8.6 Bridge-`notify`/Inbox one-hop.

**Canonical IDs:** PACKETS DS `078e7c9e-e53e-4c83-a893-af64f82b5123` · AI LOGS DS `992fd5ac-d938-4be4-95fb-8ef18bd86bba` · brief page `389cbb58-889e-8165-b407-e5e6f0bd45b3` · qualification page `389cbb58-889e-8184-b8da-fb72881782d6`.

---

## Prerequisites

- [ ] **Code live** — The Bridge 3.8.2 installed, `registry_hydrate` available. *(Re-enable cloud Remote Access only if firing from claude.ai; local loopback is unaffected.)*
- [ ] **Claude Code app OPEN** — app-local scheduled tasks run only while it's open (else on next launch). For overnight Phase 2, confirm the app/Mac stay on, or adopt the launchd→headless-`claude` enhancement (spec §4 open-pt #5).
- [ ] **PACKETS schema live** (+7 props: Execution Class / Priority / Lifecycle Checked At / Execution Window / Last Execution URL / Last Executed At / Cleanup Eligible At) and the `BLOCKED` Status option exists. Add `BLOCKED` to `fromStatus` too (only needed to transition *out of* BLOCKED).
- [ ] **PACKETS registered as a registry entity** (so hydration works): `registry_add_entity` (bind DS `078e7c9e…` **by property id**) → `registry_introspect` → note the **entity name**. Smoke-test: `registry_hydrate(entity, <any packet id>)` returns the `packet-registry-v1` envelope (primary + body + one-hop relations + provenance + warnings).
- [ ] **Get `main` locally to edit the config:** stash/commit any in-progress work on your current branch, then `git checkout main && git pull`.

## Step 1 — Fill the config
Edit `config/routine.config.ship-the-bridge-v4.json`; replace **every** `<<OPERATOR: …>>`:
- `version` (semver, e.g. `1.0.0`); `provider.workspace_alias`
- `project_id` = the **Ship The Bridge v4 PROJECT page id** (the PROJECT relation target — **not** the PACKETS DS id)
- `durable_evidence_destination`: `kind` (`notion_page` | `notion_file_area` | `repo_path`), `locator` (a **stable** page/path, never an ephemeral local dir), `latch_location`
- `cycle_timeout_seconds` (must be **<** your future schedule interval) and `packet_timeout_seconds` (must be **<** 14400s / 4h)
- `model.default` + `model.allowlist`
- `connections` aliases (`notion:primary`, `github:primary` — **names only, never secret values**)
- `authorized_identities`: `reviewers`, `operators` (you), `provider_pause_authority` (you)
- **Leave `schedule` null.**
- ✅ *Expected:* zero `<<OPERATOR>>` strings remain; the file is valid JSON.

## Step 2 — Create the control latch
At your chosen `latch_location`, create the record (per `controller/LATCH_PROTOCOL.md`):
```json
{ "holder": null, "acquired_at": null, "expires_at": null, "disabled": false }
```
This single record carries both the **non-overlap holder lease** and the **`disabled` kill-switch**.

## Step 3 — Register the cycle (no schedule yet)
`create_scheduled_task` with `taskId: "packet-runner-ship-the-bridge-v4"`, `prompt` = the **full contents of `agent/packet-runner-cycle.md`**, and **omit `cron`/`fireAt`** (ad-hoc — manual start only). Confirm with `list_scheduled_tasks`.
- ✅ *Expected:* task listed, no schedule attached.

## Step 4 — Queue ONE smoke-test packet
In PACKETS (DS `078e7c9e…`), create one **trivial AUTO** packet: `Status = QUEUE`, `PROJECT = Ship The Bridge v4`, `Execution Class = AUTO`, a tiny verifiable objective (e.g. "append a dated line to `<a scratch Notion doc>`"), with clear **Scope / DoD / QA / Verification Plan**. Keep all other packets for this project **out of** QUEUE so the cycle selects exactly this one.
- *Why trivial:* you're proving the loop (FOCUS → execute → receipt → status → brief → notify), not risking real changes.

## Step 5 — Fire one cycle
`update_scheduled_task(taskId, fireAt = ~2 minutes from now)` for a single one-shot run (or start the ad-hoc task manually). Keep the app open. The cycle runs as **ONE** autonomous agent run: preflight → latch → hydrate → QUEUE→FOCUS → execute inline → receipt → reconcile + bounded maintenance → brief → Inbox + `notify` → release latch.

## Step 6 — Verify the outcome
- [ ] **Packet:** `QUEUE → FOCUS → {DONE | REVIEW}`; `Lifecycle Checked At` updated; `## Packet Runner Output` holds the receipt (`Current Canonical Result` + `Artifact Manifest`); `Source of Truth` set iff a durable authoritative result exists (else "not applicable").
- [ ] **Brief:** the canonical page `389cbb58-889e-8165-…` was overwritten attention-first (Decisions needed → Completed → Blocked → Failures → Skipped/stale → Learning → Cycle metadata + health). Compare to `evidence/EXAMPLE_OPERATOR_BRIEF.md`.
- [ ] **Notification:** native macOS notification received; tap opens the **Bridge Inbox**; the Notion brief URL is in the Inbox entry **and** the notification body (one hop).
- [ ] **Latch released** (`holder` cleared; `disabled` still `false`).
- [ ] **No AI LOG** for a clean cycle (AI LOG only for actionable incidents / reusable learnings).

## Step 7 — Gating capability tests (must all pass)
- [ ] **#1 non-overlap** — fire a 2nd cycle while one is mid-run → the 2nd returns `NOT_STARTED_OVERLAP`: no packet started, the active brief **NOT overwritten**.
- [ ] **#7 pause / kill-switch** — set the latch `disabled = true` (and/or `update_scheduled_task(taskId, enabled:false)`) → the next fire **aborts at PAUSED**, writes nothing, re-reads to confirm. Verify the routine does **not** self-re-enable; **you** clear `disabled` to resume.
- [ ] **#8 completion notification** — confirm you (the operator) actually receive the notification and reach the brief in one hop.
- [ ] **Evidence paths (§8.20):**
  - **BLOCKED** — a packet with an unmet `Blocked by` (concrete owner + exact unblock condition) → ends **BLOCKED** with owner + unblock condition.
  - **REVIEW-FIRST** — an `Execution Class = REVIEW-FIRST` packet → stops at **REVIEW** (never auto-DONE) with a structured review request.
  - **Permission denial** — a packet needing access you haven't granted → fail-closed (REVIEW/BLOCKED), no partial writes.
  - **Schema failure** — temporarily rename/remove a required PACKETS prop → preflight **FAILS closed**, no mutation. *(Restore the prop after.)*
  - **Archival** — an AI LOG with `Disposition ∈ {Resolved, Dismissed}` past `Archive Eligible At` → **archived (not deleted)**, learning promoted first.
  - **Session-export fallback (§8.18)** — confirm a compact durable evidence bundle is retained when a full provider session export isn't available.

## Step 8 — Gate
Proceed **only if every box in Steps 6–7 is checked.** Any failure or ambiguity → fix and re-run Step 5. **Do not schedule.**

## Step 9 — Phase 2: scheduled 20-cycle qualification
- [ ] Confirm the Mac + Claude Code app are reliably **on at the chosen window** (or adopt the launchd→headless-`claude` enhancement first).
- [ ] `update_scheduled_task(taskId, cronExpression = <your reviewed nightly expression, America/Chicago>)` **and** set `schedule` in the config. Keep `max_packets_per_cycle = 1`.
- [ ] Keep hand-picking packets into QUEUE (D3) so each cycle has work; aim for variety.
- [ ] Run **20 consecutive clean cycles.** Required coverage across the streak (§8.20): **≥10 executed packets, ≥1 real BLOCKED, ≥1 real REVIEW, ≥1 delayed cleanup** observed.
- [ ] Each cycle appends a compact qualification-evidence row to page `389cbb58-889e-8184-…` **after** brief + notification results are known. A missing/unverifiable row makes the cycle **non-qualifying** and **breaks the streak** (even if health is HEALTHY).
- [ ] Any FAILED / DEGRADED cycle or safety incident **resets** the streak — investigate, remediate, restart the count.

## Step 10 — Sign-off
After 20 consecutive clean qualifying cycles **and** your review of the evidence, **you (authorized operator) record `PRODUCTION_QUALIFIED`** (§8.20). Only then is the routine production-qualified.

---

## Kill-switch (any time)
`update_scheduled_task(taskId, enabled:false)` **+** set the latch `disabled = true`. *(If you wrapped the cycle in a Bridge launchd job as the optional hardening, `job_pause all:true` is the panic button.)* Nothing re-enables itself — to resume, clear `disabled` **and** `enabled:true` (operator-only, `may_reenable`).

## Fail-closed expectations ("good" looks like)
- When in doubt → **REVIEW**, never guess.
- Bridge unreachable at preflight → **abort, no partial writes.**
- **No** claim / lease / heartbeat / Run-ID / Worker-ID fields are ever written (best-effort FOCUS + re-read verify only).
- **REVIEW-FIRST never auto-DONEs;** DONE requires a valid **Source of Truth** when a durable result exists.
- Empty queue → a healthy no-op brief is still written.
