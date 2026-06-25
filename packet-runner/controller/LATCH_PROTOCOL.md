# Packet Runner — Latch Store Design + Agent Latch Protocol

**WU-3 deliverable** (MASTER_IMPLEMENTATION_SPEC v1.1 §3). Documents the **single-writer latch store** + the **agent-side acquire → verify → release** protocol that wrap the decision logic already implemented in [`decisions.py`](decisions.py). This file is **design + protocol only** — it neither reimplements nor supersedes the pure functions; it specifies the durable record they read/write and the exact sequence the scheduled agent (WU-1) follows around them.

> **Authority.** Lifecycle/safety semantics: PRD v1.0 ([`../_refs/PRD-v1.0.md`](../_refs/PRD-v1.0.md)) — §6 (cycle), §6.1 (non-overlap), §8.5A (provider-native fail-closed latch), §8.13 (self-modification/pause), §8.14 (stale FOCUS), §8.18 (preservation), FR-18. Deployment topology: MASTER_IMPLEMENTATION_SPEC v1.1 (D1′ fully-local app-local Claude Code scheduled agent). The decision functions are the single source of truth for *outcomes*; this document is the source of truth for the *record* and *call sequence*. **Where this doc and `decisions.py` appear to disagree, `decisions.py` governs the decision and this doc is wrong** — file a fix.

---

## 0. Why a controller latch exists (the integration findings)

Two `decisions.py` header findings (cited verbatim in the module) force the latch:

1. **Non-overlap (§6.1).** The Claude Code Routines / scheduled-task surface documents **no** routine-level non-overlap guard, no single-flight config, and no skip-on-overlap signal (`evidence/INTEGRATION_NON_OVERLAP.md`). §8.5A permits a *"deterministic provider-native fail-closed latch."* The controller therefore enforces non-overlap **itself** with a single-writer latch checked **before any FOCUS write**.
2. **Kill-switch (§8.13).** Routines pause/disable is **UI-only** — no API (the only documented Routines endpoint is `POST .../fire`). §8.13's autonomous-pause exception requires a *machine-callable* reversible control with confirmation; a UI toggle alone does not satisfy it. §8.5A again permits a fail-closed latch, so the **same** store carries a `disabled` flag.

Both guards are **provider-neutral** (they live in our durable store, not the provider) so they survive a later surface swap (e.g. the deferred launchd → headless `claude` enhancement, which would add native single-flight + `job_pause` as belt-and-suspenders).

**Hard limitation — no compare-and-swap.** Notion offers no atomic CAS; a repo-file destination offers none across processes either. Acquisition is therefore **best-effort single-writer**, made safe by *write-then-re-read-verify*, **not** by a lock (PRD §6 "best-effort acquisition limitation"). Any evidence of a competing writer is an **ownership conflict → fail closed**, never permission to continue.

---

## 1. Latch record schema

One latch record per routine (the pilot routine = `packet-runner-ship-the-bridge-v4`). It carries **two orthogonal concerns** in one place: the non-overlap holder lease, and the kill-switch flag.

| Field | Type | Written by | Meaning |
|---|---|---|---|
| `holder` | string (the run's native execution reference / cycle id) | the acquiring cycle | Who owns the active cycle. The MASTER spec sets this to the **scheduled-task run id** (D1′ exec-ref #5 = the run record / `lastRunAt` + output) — local, not a cloud session URL. Empty/absent ⇒ no holder. Maps to `OverlapLatch.holder`. |
| `acquired_at` | datetime (ISO-8601, routine tz America/Chicago) | the acquiring cycle | When the holder acquired the latch. Maps to `OverlapLatch.acquired_at`. |
| `expires_at` | datetime (ISO-8601) | the acquiring cycle | `acquired_at + cycle_timeout`. `cycle_timeout` **must be < the schedule interval** (§8.5A; preflight P14) so a crashed cycle's latch is provably stale by the next fire. Maps to `OverlapLatch.expires_at`. |
| `disabled` | boolean | Packet Runner (set only) **or** operator (set/clear) | The fail-closed kill-switch. `true` ⇒ every cycle aborts at start. The **controller may set it but may NEVER clear it** (§8.13; `may_reenable`). |

> The `OverlapLatch` dataclass in `decisions.py` models the **overlap triple** (`holder`, `acquired_at`, `expires_at`). The `disabled` flag is stored alongside it in the same record but is consumed by a **separate** function (`pause_gate`), because non-overlap and pause are independent gates evaluated in sequence (pause first — see §4).

**Forbidden fields (§8.1 / Cross-cutting invariants).** The latch is **not** a claims/lease database. Do **not** add Run ID, Worker ID, Claimed By/At, Lease Until, Heartbeat, Attempt, Retry Count, token/cost budget, or a custom cycle ID to PACKETS. The latch holder reference reuses the **native execution reference** (§8.11) as the cycle correlation id; it lives in the latch record, never on packet rows.

**Serialization note.** Whether the destination is a Notion property/row or a repo file (operator's choice, §2), the four fields above are the whole contract. A run reading a record with a present non-empty `holder` but a missing/unparseable `acquired_at`/`expires_at` MUST treat it as **ambiguous (a malformed live latch) → fail closed**, exactly as a stale-other latch (`STALE`/`FAILED`) — never as "absent".

---

## 2. Where the latch lives

```
durable_evidence_destination = "<<OPERATOR: stable Notion property/row or repo file path>>"
  └── latch record { holder, acquired_at, expires_at, disabled }   (one per routine)
```

The latch is persisted in **`durable_evidence_destination`** — the same stable area used for redacted incident exports and the §8.18 compact-bundle fallback. The destination MUST be a **stable Notion page/file area or repository evidence path, never an ephemeral local directory** (§8.5A; PRD §8.5A config contract). Preflight **P6** fails the cycle before any packet mutation if it cannot be resolved (MASTER spec / CONTROLLER_SPEC §2).

The concrete latch location is an **operator input** and is left as a placeholder — do **not** fabricate it:

- `durable_evidence_destination` + the latch's exact location within it: `<<OPERATOR: stable Notion property/row or repo file path>>`

Everything downstream (the agent steps in §3–§5) is written against the four-field schema and is independent of which backing store the operator picks.

---

## 3. Acquire → re-read-verify → release sequence (maps to `overlap_gate` / `overlap_verify`)

This is the MASTER spec §1 step-1 sequence ("read control latch → overlap_gate + pause_gate … acquire latch (holder = run id), re-read verify → FAILED if not ours"), expanded and tied to the exact function names. The **pause gate (§4) runs first**; this section assumes `pause_gate` returned `PROCEED`.

### 3.1 Read + classify — `overlap_gate(latch, now, our_id)`

The agent reads the current latch record from `durable_evidence_destination` and calls `overlap_gate`. `our_id` = this run's native execution reference (holder value). The function returns `(action, classification)`:

| Live latch state | `overlap_gate` returns | Agent action |
|---|---|---|
| **absent** (no holder) | `('ACQUIRE', 'PROCEED')` | Write the latch (§3.2), then verify (§3.3). |
| **held by us** (`holder == our_id`) | `('HELD', 'PROCEED')` | Idempotent re-entry (same run re-reading its own latch) — proceed without re-writing. |
| **fresh, other holder** (`now < expires_at`) | `('REFUSE', 'NOT_STARTED_OVERLAP')` | **Start no packet. Do NOT overwrite the active cycle's brief.** Record `NOT_STARTED_OVERLAP` and exit. This is the clean overlap case — it is *not* a FAILED emission; the other cycle owns the brief (PRD §6.1; NOT_STARTED_OVERLAP definition §3). It also **breaks the qualification streak** (§8.20). |
| **stale, other holder** (`now ≥ expires_at`) | `('STALE', 'FAILED')` | A prior cycle left a latch past `cycle_timeout` — overlap **cannot be ruled out**. Start no packet; set `cycle.health = FAILED`; go to minimal closeout (PRD §6.1 "started but overlap cannot be ruled out … classify FAILED"). See §6 (staleness). |

> **`malformed live latch` ⇒ treat as the `STALE`/`FAILED` branch** (ambiguous, fail closed) — §1 serialization note.

### 3.2 Write (only on `ACQUIRE`)

On `('ACQUIRE','PROCEED')`, write the record with `holder = our_id`, `acquired_at = now`, `expires_at = now + cycle_timeout`, preserving `disabled` (the kill-switch must not be cleared by acquisition). This is **best-effort, not atomic** — a concurrent cycle may also be writing. The verify step (§3.3) is what makes it safe.

### 3.3 Re-read-verify — `overlap_verify(reread_latch, our_id)`

Immediately re-read the latch and call `overlap_verify`. It returns:

- `'PROCEED'` — only when the re-read shows **our** holder (`reread_latch is not None and reread_latch.holder == our_id`). Acquisition confirmed; continue to the QUEUE→FOCUS coupled write (MASTER spec §1 steps 2–3).
- `'FAILED'` — the re-read shows a different holder, or the write didn't stick. A concurrent writer won (or our write was lost) ⇒ **overlap cannot be ruled out** ⇒ no packet started; `cycle.health = FAILED`; minimal closeout. Treat competing acquisition as an **ownership conflict** (PRD §6).

This mirrors the same *write → immediate re-read → stop-if-not-ours* pattern the controller uses for the QUEUE→FOCUS acquisition itself (PRD §8.8 protection 3) — the latch is one layer up.

### 3.4 Hold

While `overlap_verify == 'PROCEED'`, the run owns the latch for the rest of the cycle (steps 2–8 of MASTER spec §1). No heartbeat, no renewal — the single synchronous run holds it for its whole, bounded (`cycle_timeout`) duration. There is **no** mid-cycle re-acquire and **no** FOCUS reclaim of another holder (PRD §6 / §8.14 "no FOCUS reclaim").

### 3.5 Release

On normal completion the agent releases the latch as **MASTER spec §1 step 8** ("release latch; call Bridge notify"), i.e. **after** reconciliation + brief write and **before/with** the completion notification, by clearing `holder`/`acquired_at`/`expires_at` (set the holder empty) while **leaving `disabled` untouched**.

- **There is no `release_latch` function in `decisions.py` by design** — release is a plain store write (clear the overlap triple), not a decision. Its correctness is guaranteed by §6: if the agent crashes before releasing, the leftover latch becomes **stale** at `expires_at` and the *next* cycle classifies it `STALE → FAILED` via `overlap_gate` (which is the intended fail-closed behavior, not a leak).
- Release **never** touches `disabled`: a cycle that paused itself (§5) must leave the routine paused for the operator.
- A failed/ambiguous cycle that reached `FAILED` may still release the overlap triple if it can prove it still owns it; if ownership is unprovable, leave the latch to expire (it is already `FAILED` + pause-required under §8.18). Do not force-clear a latch you cannot prove is yours.

### 3.6 Sequence diagram (one cycle, happy path)

```
read latch ─▶ pause_gate(disabled)            # §4 — kill-switch FIRST
                │ PROCEED
                ▼
            overlap_gate(latch, now, our_id)   # §3.1
                │ ('ACQUIRE','PROCEED')
                ▼
            write { holder=our_id, acquired_at, expires_at, disabled unchanged }   # §3.2
                ▼
            re-read ─▶ overlap_verify(reread, our_id)   # §3.3
                │ 'PROCEED'
                ▼
   ┌── HOLD ──────────────────────────────────────────────────┐
   │  QUEUE→FOCUS coupled write · execute inline · receipt ·   │   # MASTER §1 steps 2–6
   │  reconcile · bounded maintenance · write brief           │   # steps 6–7
   └──────────────────────────────────────────────────────────┘
                ▼
            release latch (clear overlap triple, keep `disabled`)   # §3.5 / MASTER §1 step 8
                ▼
            Bridge notify + Inbox mirror
```

---

## 4. Kill-switch read at cycle start — `pause_gate` (#7)

The `disabled` flag is the **#7 kill-switch**. Per MASTER spec §1 ("Pause/kill-switch: `update_scheduled_task enabled:false` (machine-callable) + latch `disabled` flag") it has **two layers**, which are complementary:

1. **`update_scheduled_task enabled:false`** — the machine-callable provider control (WU-2). Stops *future automatic fires* of the scheduled task. This is the "reversible control with confirmation" surface that the §8.13 autonomous-pause exception wants. It does **not** stop an already-running cycle and is not, by itself, read by the neutral core.
2. **The latch `disabled` flag** — the provider-neutral fail-closed guard read **at the start of every cycle**, *before any packet work*, by `pause_gate(disabled)`:
   - `disabled == true` ⇒ `'PAUSED'` ⇒ **abort before any packet work** (no QUEUE→FOCUS, no execute). The cycle goes straight to minimal closeout; QUEUE is left untouched.
   - `disabled == false` ⇒ `'PROCEED'` ⇒ continue to `overlap_gate` (§3.1).

**Ordering: pause gate first, then overlap.** A paused routine must abort even if it could otherwise acquire the latch, so `pause_gate` is evaluated on the freshly-read record **before** `overlap_gate` (MASTER spec §1 step 1 order; CONTROLLER_SPEC §1 step 1a/1b sequencing puts the safety abort ahead of work). Belt-and-suspenders: even if `enabled:false` failed to stop a fire, the `disabled` flag still aborts the run.

---

## 5. Setting the kill-switch autonomously — `request_pause` (the §8.13 pause exception)

Packet Runner **may set `disabled = true` itself** only inside a critical-incident boundary (§8.13 autonomous-pause exception; FR-18; self-recovery boundary §8.12). The protocol:

1. The agent decides a critical incident requires containment of **this routine** (and only routines inside the established incident boundary — §8.13 / §8.12 boundaries).
2. Write `disabled = true` to the latch record (and, when WU-2's control is reachable, also call `update_scheduled_task enabled:false` as the provider-confirmed layer).
3. **Re-read and confirm** — call `request_pause(reread_disabled)`:
   - `'CONFIRMED'` — the re-read shows `disabled == true`. The autonomous pause is honored; record the pause receipt (routine, prior state, new state, incident boundary, reason, timestamp, provider confirmation, affected packets, resume requirements — §8.13).
   - `'UNCONFIRMED'` — the flag write could not be confirmed by re-read. Per FR-18 / §8.18: *"Failure to confirm the pause is itself surfaced as a critical unresolved control issue."* The cycle stays `FAILED`, the boundary stays **pause-required**, and the brief names the unconfirmed-pause control gap.

This is the **only** autonomous persistent control Packet Runner has (PRD §8.13 / FR-18): *reduce or stop* future activity, with confirmation. It may **never** enable, re-enable, broaden, accelerate, or expand scope.

---

## 6. Staleness, expiry, and the FOCUS-stale relationship

Three distinct "stale" concepts intersect here; keep them separate:

| Concept | Threshold source | Effect on the latch | Function |
|---|---|---|---|
| **Latch expiry** (overlap lease) | `expires_at = acquired_at + cycle_timeout`; `cycle_timeout < schedule interval` (§8.5A, P14) | A leftover latch from a crashed/over-running cycle becomes **stale → `('STALE','FAILED')`** at the next `overlap_gate`. This is the **fail-closed** recovery path: an unreleased latch never silently lets a new cycle run as if uncontested; it forces `FAILED` because overlap can't be ruled out. | `overlap_gate` (§3.1) |
| **Stale FOCUS** (a packet stuck in FOCUS) | `packet_timeout < 4h` stale-FOCUS threshold (§8.14; P14) — `FOCUS_STALE = timedelta(hours=4)` in `decisions.py` | **Not a latch concern.** Discovering a stale FOCUS packet moves *that packet* to REVIEW (never reclaim/redispatch) and classifies the cycle DEGRADED or FAILED by state trustworthiness (§8.14 / CONTROLLER_SPEC §8). Handled by the eligibility/health layer, **not** the latch. | `stale_label` / health derivation (separate) |
| **Disabled flag** (kill-switch) | n/a — never ages out | `disabled` has **no expiry**. It persists across cycles until an **operator** clears it (§7). Age never clears a pause (§8.14 "no age-based lifecycle mutation"; §8.13 re-enablement is operator-only). | `pause_gate` / `may_reenable` |

**Key invariant:** the latch's `cycle_timeout` is sized **below** the schedule interval precisely so that "a previous cycle's latch is still present" is *provably* a crash/overrun (→ `STALE`/`FAILED`), not a legitimately-concurrent run. Preflight (P14) fails closed if `cycle_timeout ≥ schedule interval` or `packet_timeout ≥ 4h`, so this sizing is enforced before any cycle starts.

---

## 7. Operator-only re-enable — `may_reenable` (#7 resume)

Clearing `disabled` (re-enabling the routine) is an **explicit operator governance decision**, never a controller/self-recovery step (PRD §8.13 "Re-enablement"; FR-18 "may never re-enable itself").

`may_reenable(actor_is_authorized_operator)` is the gate:

- `actor_is_authorized_operator == true` ⇒ `True` — only an authorized operator (Isaiah or another explicitly authorized operator per the §8.5A "authorized reviewer/operator identities") may set `disabled = false`, and only **after the incident-resume checklist is satisfied** (reconciliation of affected state, identified cause, remediation, manual validation, acceptance evidence, documented residual risk, explicit authorization — §8.12 / §8.13).
- any non-operator (including **the routine itself** / the scheduled run) ⇒ `False`. `decisions.py` returns `False` for any non-operator, which is the fail-closed default the controller relies on.

The authorized operator / pause-authority identity is an operator input:

- pause-authority / authorized re-enable identity: `<<OPERATOR: reviewer/operator identity with pause authority>>`

Re-enable in this local topology means: the operator (a) clears `disabled` in the latch record **and** (b) restores the provider control (`update_scheduled_task enabled:true`). Both layers from §4 must be lifted; the controller participates in neither.

---

## 8. Function → protocol-step cross-reference

Every protocol step ties to exactly one `decisions.py` function. The functions are pure and unchanged; this doc only wraps them with the store + sequence.

| `decisions.py` function | PRD anchor | Protocol step (this doc) |
|---|---|---|
| `pause_gate(disabled)` | §8.13 / §8.5A | §4 — kill-switch read at cycle start (FIRST). `PAUSED` ⇒ abort before any packet work. |
| `overlap_gate(latch, now, our_id)` | §6 step 1 / §6.1 | §3.1 — read + classify: `ACQUIRE`/`HELD`→PROCEED, `REFUSE`→NOT_STARTED_OVERLAP, `STALE`→FAILED. |
| `overlap_verify(reread_latch, our_id)` | §6 best-effort single-writer | §3.3 — re-read-verify after write; `PROCEED` only when re-read holder is ours, else `FAILED`. |
| `request_pause(reread_disabled)` | §8.13 + FR-18 + §8.18 | §5 — autonomous pause: confirm the `disabled` write by re-read; `UNCONFIRMED` ⇒ critical unresolved control issue. |
| `may_reenable(actor_is_authorized_operator)` | §8.13 / FR-18 | §7 — operator-only re-enable; controller (and the routine) always `False`. |
| *(none — plain store writes)* | §6.1 / §6 / §8.18 | §3.2 acquire-write, §3.5 release. Release is deliberately not a decision function; crash-safety is the stale-latch path (§6). |
| `OverlapLatch` dataclass | §6 step 1 | §1 — the `{holder, acquired_at, expires_at}` triple of the record (the `disabled` flag is stored alongside, consumed by `pause_gate`). |

---

## 9. Invariants (quick reference)

- **No CAS / no lock (§6).** Acquisition is best-effort single-writer; safety comes from write→re-read→`overlap_verify`, and from sequential dispatch + the operating rule that humans/agents don't start the same QUEUE packet mid-cycle.
- **Fail closed everywhere.** Absent → acquire+verify; fresh-other → NOT_STARTED_OVERLAP (brief untouched); stale-other / verify-mismatch / malformed → FAILED; `disabled` → PAUSED. When in doubt, do not start a packet.
- **NOT_STARTED_OVERLAP is not FAILED.** It writes no packet, **does not overwrite the active brief**, breaks the qualification streak — but it is the *clean* overlap outcome owned by the running cycle (§6.1).
- **Controller may set `disabled`, never clear it.** Re-enable is operator-only (`may_reenable`).
- **`disabled` never ages out; the overlap lease always does.** `cycle_timeout < schedule interval` (P14) makes a leftover latch provably stale.
- **The latch is not a claims DB.** No Run/Worker ID, lease, heartbeat, attempt, or budget on PACKETS; holder = the native execution reference (§8.11).
- **Latch lives in `durable_evidence_destination`** (`<<OPERATOR: …>>`), a stable Notion/repo area, never an ephemeral local dir; preflight P6 fails closed otherwise.
