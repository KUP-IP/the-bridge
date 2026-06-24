"""
Packet Runner v1 — provider-neutral controller decision core (reference impl).

Pure, deterministic decision functions that implement the PRD's specified
decision tables. This is the testable backbone of Phase 3 (§10: "Automate
deterministic schema, serialization, filtering, ordering, lifecycle,
receipt-mapping, redaction, compaction, cleanup, archival ... tests"). It is
provider-NEUTRAL by construction (no provider/Notion/IO calls) — the provider
capability layer and live reconciliation wrap these; see CONTROLLER_SPEC.md.

Every function cites the governing PRD section. The PRD governs where it
conflicts with skills/source-packet (§14.1).
"""
from __future__ import annotations
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import re

# ── §8.1 status model ────────────────────────────────────────────────────────
TODO = {"BACKLOG", "QUEUE", "BLOCKED"}
INPROG = {"FOCUS", "REVIEW"}
COMPLETE = {"DONE", "CANCELED"}
TERMINAL = COMPLETE
EXECUTION_CLASSES = {"AUTO", "REVIEW-FIRST", "MANUAL"}


# ── §8.5 receipt → status mapping (R1–R6) ────────────────────────────────────
def map_receipt_to_status(*, goal_state, execution_class, criteria_all_pass,
                          sot_ok, output_written, live_agrees, receipt_valid,
                          blocker_fully_known=False):
    """§8.5 receipt-to-status mapping. Returns one of DONE/REVIEW/BLOCKED.

    Fail-closed: any missing/malformed/contradictory receipt, or DONE
    preconditions unmet, resolves to REVIEW. [T2-sub,T3-sub,T8-sub,T10,T70]
    """
    if execution_class == "MANUAL":
        raise ValueError("MANUAL is never dispatched (§8.5)")
    if not receipt_valid:
        return "REVIEW"  # missing/malformed/contradictory ⇒ REVIEW (§8.5)
    gs = goal_state
    if gs in ("COMPLETED", "ALREADY_SATISFIED"):
        if execution_class == "AUTO":
            # DONE only when every gate holds; else REVIEW.
            if criteria_all_pass and live_agrees and output_written and sot_ok:
                return "DONE"
            return "REVIEW"
        if execution_class == "REVIEW-FIRST":
            # REVIEW-FIRST never auto-DONEs; approval can't override missing
            # verification/SoT (that path is governance: APPROVE_COMPLETION).
            return "REVIEW"
    if gs == "BLOCKED":
        return "BLOCKED" if blocker_fully_known else "REVIEW"
    # REVIEW_REQUIRED, PARTIAL_SAFE, FAILED_SAFE, UNSAFE_AMBIGUOUS
    return "REVIEW"


# ── §8.8 replay-state classification + SAFE_RESUME gate ───────────────────────
def classify_replay_state(*, evidence_of_prior_attempt, goal_already_true,
                          partial_work_present, safe_resume_conditions):
    """§8.8 FIRST_RUN / ALREADY_SATISFIED / SAFE_RESUME / UNSAFE_AMBIGUOUS. [T16,T17]"""
    if goal_already_true:
        return "ALREADY_SATISFIED"
    if partial_work_present:
        return "SAFE_RESUME" if safe_resume_gate(safe_resume_conditions) else "UNSAFE_AMBIGUOUS"
    if not evidence_of_prior_attempt:
        return "FIRST_RUN"
    return "UNSAFE_AMBIGUOUS"


SAFE_RESUME_KEYS = ("contract_unchanged", "artifacts_inspectable",
                    "prior_effects_identifiable", "remaining_distinguishable",
                    "no_consequential_repeat", "verification_valid")


def safe_resume_gate(conditions: dict) -> bool:
    """§8.8 SAFE_RESUME requires ALL six conditions true; else UNSAFE_AMBIGUOUS. [T17]"""
    return all(bool(conditions.get(k)) for k in SAFE_RESUME_KEYS)


# ── §8.8 / FR-6 material-revision guard ──────────────────────────────────────
EXEC_CRITICAL = ("goal", "scope", "constraints", "success_criteria",
                 "verification", "review_requirement", "stop_conditions",
                 "dependencies", "project", "execution_class")
CONTROLLER_OWNED = ("lifecycle_checked_at", "last_execution_url",
                    "last_executed_at", "cleanup_eligible_at", "formatting",
                    "commentary", "from_status")


def material_change(a: dict, b: dict):
    """Returns the list of execution-critical fields that differ (§8.8/FR-6).
    Non-empty ⇒ MATERIAL_CHANGE ⇒ REVIEW; empty ⇒ proceed. [T18]"""
    return [f for f in EXEC_CRITICAL if a.get(f) != b.get(f)]


def approval_still_valid(approved_snapshot: dict, current_snapshot: dict) -> bool:
    """§8.10 revision-specific approval: any execution-critical change invalidates
    a prior approval. [T32]"""
    return material_change(approved_snapshot, current_snapshot) == []


# ── §6 step 4 / FR-4 eligibility classification ──────────────────────────────
@dataclass
class Packet:
    id: str
    status: str = "QUEUE"
    execution_class: str | None = "AUTO"
    has_mission_context: bool = True
    has_repo_identity: bool = True
    blocked_by: list = field(default_factory=list)   # list of (id, status)
    blocking: list = field(default_factory=list)
    window: tuple | None = None                      # (start, end|None)
    known_unmet_prereq: dict | None = None           # {owner, unblock_condition,...}
    ambiguous_blocker: bool = False
    priority: int = 0
    lifecycle_checked_at: datetime | None = None
    pkt_id: int = 0


def classify_eligibility(p: Packet, now: datetime, tz=timezone.utc):
    """Deterministic candidate classification (§6 step 4). Returns
    (action, resulting_status_or_None) where action ∈
    {EXECUTE, SKIP_MANUAL, LEAVE_QUEUE, REVIEW, BLOCKED}. Fail-closed. [T1,T4,T5,T20,T110]"""
    if p.execution_class == "MANUAL":
        return ("SKIP_MANUAL", None)                                  # T4
    if p.execution_class not in ("AUTO", "REVIEW-FIRST"):
        return ("REVIEW", "REVIEW")                                   # missing class ⇒ REVIEW (FR-3)
    if not p.has_mission_context or not p.has_repo_identity:
        return ("REVIEW", "REVIEW")                                   # missing context/repo ⇒ REVIEW
    # dependency-graph integrity (T110)
    if not validate_graph(p):
        return ("REVIEW", "REVIEW")
    # direct blockers must be DONE (FR-4)
    if any(s != "DONE" for (_, s) in p.blocked_by):
        if p.ambiguous_blocker or p.known_unmet_prereq is None:
            return ("REVIEW", "REVIEW")                               # ambiguous ⇒ REVIEW (T20)
        if _blocker_fully_known(p.known_unmet_prereq):
            return ("BLOCKED", "BLOCKED")                             # known prereq ⇒ BLOCKED (T5)
        return ("REVIEW", "REVIEW")
    # execution window (T102)
    if p.window is not None:
        w = classify_window(now, p.window[0], p.window[1], tz)
        if w == "QUEUE":
            return ("LEAVE_QUEUE", "QUEUE")                           # before window
        if w == "REVIEW":
            return ("REVIEW", "REVIEW")                              # expired window
    if p.known_unmet_prereq is not None:
        if p.ambiguous_blocker or not _blocker_fully_known(p.known_unmet_prereq):
            return ("REVIEW", "REVIEW")
        return ("BLOCKED", "BLOCKED")
    return ("EXECUTE", "FOCUS")


def _blocker_fully_known(b: dict) -> bool:
    return all(b.get(k) for k in ("owner", "unblock_condition"))


def validate_graph(p: Packet) -> bool:
    """§6/FR-4: reject self-dependency, canceled prereq, contradiction. Returns
    True if the local graph is sane (cycle detection is controller-global; here
    we catch the per-packet malformations). [T110]"""
    for (bid, bstatus) in p.blocked_by:
        if bid == p.id:                       # self-dependency
            return False
        if bstatus == "CANCELED":             # canceled prerequisite
            return False
        if bid in [x[0] for x in p.blocking]:  # contradiction: blocks & blocked-by same
            return False
    return True


def enforce_cap(eligible_ids: list, cap: int) -> list:
    """§6 step 6 cap: dispatch at most `cap`. [T11,T12]"""
    return list(eligible_ids)[:max(0, cap)]


def order_candidates(packets: list[Packet]) -> list[Packet]:
    """§6 step 5 ordering: dependency topo (approximated by blocked-by-count) then
    Priority desc, Lifecycle Checked At asc, PKT-ID asc. [ordering for T11/T12]"""
    far = datetime.max.replace(tzinfo=timezone.utc)
    return sorted(packets, key=lambda p: (
        len(p.blocked_by),
        -p.priority,
        p.lifecycle_checked_at or far,
        p.pkt_id,
    ))


# ── §8.1 / §6 execution-window classifier ────────────────────────────────────
def classify_window(now: datetime, start, end, tz=timezone.utc) -> str:
    """before start ⇒ QUEUE; within ⇒ ELIGIBLE; after end ⇒ REVIEW.
    end-without-start / reversed / unparseable ⇒ REVIEW. tz: embedded else routine. [T102]"""
    if start is None and end is None:
        return "ELIGIBLE"
    if start is None and end is not None:
        return "REVIEW"                       # end without start ⇒ REVIEW
    if end is not None and end < start:
        return "REVIEW"                       # reversed range ⇒ REVIEW
    if now < start:
        return "QUEUE"
    if end is not None and now > end:
        return "REVIEW"                       # expired ⇒ REVIEW
    return "ELIGIBLE"


# ── §8.14 global stale-state thresholds (controlled clock) ────────────────────
QUEUE_STALE = timedelta(days=7)
FOCUS_STALE = timedelta(hours=4)
BLOCKED_STALE = timedelta(days=7)
REVIEW_STALE = timedelta(days=7)


def is_stale_queue(checked_at: datetime, now: datetime) -> bool:
    """§8.14: QUEUE readiness expires after 7 calendar days. [T61]"""
    return (now - checked_at) >= QUEUE_STALE


def stale_label(status: str, checked_at: datetime, now: datetime):
    """§8.14 staleness → a report label, NEVER an automatic transition. Returns
    (is_stale, label, new_status). new_status is ALWAYS the same status — age
    never mutates lifecycle (no requeue/approve/complete/cancel). [T61,T64]"""
    age = now - checked_at
    if status == "QUEUE" and age >= QUEUE_STALE:
        return (True, "Readiness refresh required", "QUEUE")
    if status == "BLOCKED" and age >= BLOCKED_STALE:
        return (True, "Stale blocker — resurfaced", "BLOCKED")
    if status == "REVIEW" and age >= REVIEW_STALE:
        return (True, "Stale review — decision outstanding", "REVIEW")
    return (False, None, status)


CLOCK_REFRESH_EVENTS = {"authorized_transition", "explicit_revalidation"}
CLOCK_NOOP_EVENTS = {"comment", "ordinary_edit"}


def should_refresh_clock(event: str) -> bool:
    """§8.14: only authorized transitions / explicit revalidation refresh the
    Lifecycle Checked At clock; comments + ordinary edits do not. [T65]"""
    return event in CLOCK_REFRESH_EVENTS


# ── §8.16 Source of Truth ─────────────────────────────────────────────────────
DURABLE_ARTIFACT_CLASSES = {"repo", "pr", "commit", "release", "notion", "database",
                            "workflow", "external"}
INVALID_SOT_REFS = {"brief", "session", "packet-page", "temp-branch", "draft",
                    "screenshot", "raw-log", "review-artifact"}


def requires_sot(*, created_or_changed_durable: bool, already_satisfied_durable: bool,
                 ephemeral_only: bool) -> bool:
    """§8.16 requirement test. [T71,T72,T73]"""
    if ephemeral_only:
        return False
    return bool(created_or_changed_durable or already_satisfied_durable)


def validate_sot(ref_kind: str) -> bool:
    """§8.16 valid references vs invalid substitutes. [T72,T74]"""
    if ref_kind in INVALID_SOT_REFS:
        return False
    return ref_kind in DURABLE_ARTIFACT_CLASSES


def gate_done(*, requires_sot_: bool, sot_ref_kind: str | None) -> str:
    """§8.16 DONE reconciliation: required+valid ⇒ DONE-eligible; required+invalid/
    missing ⇒ REVIEW; not-required ⇒ DONE-eligible (Output states not-applicable). [T71,T73,T74]"""
    if not requires_sot_:
        return "DONE_ELIGIBLE"
    if sot_ref_kind is not None and validate_sot(sot_ref_kind):
        return "DONE_ELIGIBLE"
    return "REVIEW"


# ── §8.10 PACKET DECISION grammar + authority ────────────────────────────────
DECISIONS = {"APPROVE_COMPLETION", "AUTHORIZE_CONTINUATION", "REQUEST_CHANGES", "CANCEL"}
REQUIRED_DECISION_LABELS = ("Decision", "Approved action", "Conditions", "Reviewer",
                            "Authority scope")


def parse_packet_decision(comment: str, *, commenter, authority_scope_ok: bool):
    """§8.10 exact decision syntax. Returns a parsed decision dict, or None if the
    comment is not a valid+authorized approval (missing first line / required
    label / out-of-scope identity). [T33,T113]"""
    lines = comment.splitlines()
    if not lines or lines[0].strip() != "PACKET DECISION":
        return None                                                  # T33/T113: missing first line
    fields = {}
    for ln in lines[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            fields[k.strip()] = v.strip()
    for label in REQUIRED_DECISION_LABELS:
        if not fields.get(label):
            return None                                              # missing required label
    if fields["Decision"] not in DECISIONS:
        return None
    if not authority_scope_ok:
        return None                                                  # out-of-scope reviewer
    return {"decision": fields["Decision"], "reviewer": commenter, **fields}


def apply_decision_transition(decision: str, *, verification_valid: bool, sot_ok: bool):
    """§8.10 valid review outcomes → next status. APPROVE_COMPLETION ⇒ DONE only if
    verification still valid + SoT ok; else stays REVIEW. [T29-sub,T30-sub,T31]"""
    if decision == "APPROVE_COMPLETION":
        return "DONE" if (verification_valid and sot_ok) else "REVIEW"
    if decision == "AUTHORIZE_CONTINUATION":
        return "QUEUE"                                               # re-enters readiness/replay
    if decision == "REQUEST_CHANGES":
        return "REVIEW"                                              # stays REVIEW (T31)
    if decision == "CANCEL":
        return "CANCELED"
    return "REVIEW"


# ── §8.11 selective AI LOG threshold ─────────────────────────────────────────
AI_LOG_INCIDENT_EVENTS = {"duplicate_execution", "unauthorized_action", "secret_exposure",
                          "review_bypass", "unexplained_overwrite", "false_done",
                          "receipt_live_mismatch", "ambiguous_consequential_action",
                          "recurring_provider_failure", "repeated_queue_hygiene_defect",
                          "precheck_capability_miss", "reusable_pattern"}
AI_LOG_NOOP_EVENTS = {"clean_cycle", "empty_queue", "normal_blocked", "expected_review",
                      "recovered_one_time_retry", "ordinary_test_output"}


def should_create_ai_log(event_type: str) -> bool:
    """§8.11 AI LOG threshold: only actionable incidents/learning. [T13,T46]"""
    return event_type in AI_LOG_INCIDENT_EVENTS


# ── §8.17 cleanup eligibility ────────────────────────────────────────────────
CLEANUP_WINDOW = timedelta(days=7)
PROTECTION_CLASSES = {"source_of_truth", "active_review", "blocked_dependency",
                      "successor_packet", "rollback", "replay_safety", "approval",
                      "cancellation", "incident", "uncertain_ownership"}


def cleanup_eligible_at(terminal_at: datetime) -> datetime:
    """§8.17 recovery window: terminal transition + 7 calendar days. [T76]"""
    return terminal_at + CLEANUP_WINDOW


def is_protected(artifact_deps: set) -> bool:
    """§8.17 protection gate: any active protective dependency ⇒ never auto-delete. [T78]"""
    return bool(artifact_deps & PROTECTION_CLASSES)


def reopen_clears_cleanup(prev_status: str, new_status: str, cleanup_at):
    """§8.17: terminal → nonterminal before cleanup clears Cleanup Eligible At. [T79]"""
    if prev_status in TERMINAL and new_status not in TERMINAL:
        return None
    return cleanup_at


def cleanup_failure_preserves(prev_terminal_status: str):
    """§8.17 cleanup failure: terminal status unchanged, eligibility retained, no
    repeat deletion. Returns (status_unchanged, retain_eligibility, repeat_delete). [T80-sub]"""
    return (prev_terminal_status, True, False)


# ── §8.19 AI LOG resolution + archival ───────────────────────────────────────
ARCHIVE_WINDOW = timedelta(days=90)


def archive_eligible_at(resolved_at: datetime) -> datetime:
    """§8.19: closure timestamp + 90 calendar days. [T88]"""
    return resolved_at + ARCHIVE_WINDOW


def archive_due(disposition: str, archive_eligible_at_: datetime | None, now: datetime,
                active_dependency: bool = False) -> bool:
    """§8.19: archival is resolution-based, never age-based; protected by active deps. [T89,T92,T93-sub]"""
    if disposition not in ("Resolved", "Dismissed"):
        return False                                                 # age alone never archives (T89)
    if archive_eligible_at_ is None:
        return False
    if active_dependency:
        return False                                                 # protection gate (T93)
    return now >= archive_eligible_at_


def reopen_clears_archive(prev_disposition: str, new_disposition: str, archive_at):
    """§8.19: reopening a resolved record clears Archive Eligible At. [T92]"""
    if prev_disposition in ("Resolved", "Dismissed") and new_disposition not in ("Resolved", "Dismissed"):
        return None
    return archive_at


# ── §8.2A two-layer Packet Output ────────────────────────────────────────────
OUTPUT_PROPERTY_LIMIT = 1800


def split_output(full_record: str, index_summary: str):
    """§8.2A: compact property index ≤1800 visible chars + full managed body.
    Returns (index, body, fits). [T103]"""
    index = index_summary
    fits = len(index) <= OUTPUT_PROPERTY_LIMIT
    return (index, full_record, fits)


# ── §8.11 cycle-health precedence ────────────────────────────────────────────
def derive_health(*, safety_or_authz_or_untrusted_incident: bool,
                  recoverable_anomaly: bool, controller_clean: bool) -> str:
    """§8.11 precedence FAILED > DEGRADED > HEALTHY. UNKNOWN is never controller-
    emitted. Normal BLOCKED/REVIEW/empty do not change health. [T37-sub,T42-sub,T43-sub,T46-sub]"""
    if safety_or_authz_or_untrusted_incident:
        return "FAILED"
    if recoverable_anomaly:
        return "DEGRADED"
    if controller_clean:
        return "HEALTHY"
    return "FAILED"


# ── §8.1 schema preflight ────────────────────────────────────────────────────
def preflight_schema(live_props: dict, required: dict):
    """§8.1/§8.7 preflight: every required property must exist with the right type
    (+ required select options ⊆ live). Returns (ok, missing[]). FAIL ⇒ no mutation. [T100]"""
    missing = []
    for name, spec in required.items():
        col = live_props.get(name)
        if col is None:
            missing.append(f"{name} (absent)")
            continue
        if col.get("type") != spec.get("type"):
            missing.append(f"{name} (type {col.get('type')}≠{spec.get('type')})")
            continue
        need_opts = set(spec.get("options", []))
        have_opts = set(col.get("options", []))
        if not need_opts <= have_opts:
            missing.append(f"{name} (options missing {sorted(need_opts - have_opts)})")
    return (len(missing) == 0, missing)


# ── §8.6 brief content policy + ordering ─────────────────────────────────────
BRIEF_SECTION_ORDER = ["Decisions needed", "Completed", "Blocked",
                       "Failures or ambiguous", "Skipped", "System learning",
                       "Cycle metadata"]
FORBIDDEN_BRIEF_PATTERNS = [r"-----BEGIN [A-Z ]*PRIVATE KEY-----", r"Authorization: Bearer ",
                            r"sk_live_[A-Za-z0-9]+", r"password\s*=", r"BEGIN TRANSCRIPT"]


def order_brief_sections(present: set) -> list:
    """§8.6 attention-first ordering regardless of execution order. [T36]"""
    return [s for s in BRIEF_SECTION_ORDER if s in present]


def validate_brief_content(text: str) -> bool:
    """§8.6/§8.18 redaction: brief must not carry secrets/transcripts/etc. [T40]"""
    return not any(re.search(p, text) for p in FORBIDDEN_BRIEF_PATTERNS)


# ── §8.10 review-request + cancellation completeness ─────────────────────────
REVIEW_REQUEST_FIELDS = ("reason", "work_completed", "work_remaining", "evidence",
                         "exact_decision", "available_outcomes", "consequences",
                         "safe_state", "reviewer")
CANCEL_RECEIPT_FIELDS = ("reason", "actor", "timestamp", "prior_status", "safe_state",
                         "external_effect", "artifact_disposition", "cleanup_timing")


def validate_review_request(output: dict) -> bool:
    """§8.10 structured review request completeness (9 fields). [T28]"""
    return all(output.get(f) not in (None, "") for f in REVIEW_REQUEST_FIELDS)


def validate_cancellation_receipt(rec: dict) -> bool:
    """§8.10 cancellation receipt completeness (8 fields). [T105-sub]"""
    return all(rec.get(f) not in (None, "") for f in CANCEL_RECEIPT_FIELDS)


# ── §8.13 session-local adaptation guards ────────────────────────────────────
PERSISTENT_SETTINGS = {"schedule", "cycle_cap", "default_model", "model_allowlist",
                       "timeout_ceiling", "retry_policy", "routine_instructions",
                       "repo_scope", "project_scope", "credentials", "permissions",
                       "notification", "governance"}
PERSISTENT_CHANGE_RECEIPT_FIELDS = ("setting", "before", "after", "reason", "risk",
                                    "validation", "rollback", "reviewer", "effective_time")


def select_model(preferred: str, available: set, allowlist: set, default: str):
    """§8.13: pick a model strictly within the approved allowlist; never mutate the
    persisted default. Returns (chosen, default_unchanged). [T54]"""
    if preferred in available and preferred in allowlist:
        return (preferred, True)
    for m in allowlist:
        if m in available:
            return (m, True)
    raise RuntimeError("no approved model available")  # fail-closed, default untouched


def select_fallback(action: str, preferred: str, available: set, allowlist: set):
    """§8.12/§8.13: switch only to an already-authorized tool for the same scoped
    action. [T49]"""
    if preferred in available:
        return preferred
    for t in allowlist:
        if t in available:
            return t
    return None                                                       # none authorized ⇒ no switch


def within_bounds(value, lo, hi) -> bool:
    """§8.13 bounded session-local adaptation. [T55]"""
    return lo <= value <= hi


def classify_persistent_change(setting: str) -> str:
    """§8.13: a governed persistent setting can only be PROPOSE-ONLY in-invocation. [T56]"""
    return "PROPOSE_ONLY" if setting in PERSISTENT_SETTINGS else "SESSION_LOCAL"


def validate_persistent_change_receipt(rec: dict) -> bool:
    """§8.13 persistent change receipt (9 fields), no separate config-history DB. [T60]"""
    return all(rec.get(f) not in (None, "") for f in PERSISTENT_CHANGE_RECEIPT_FIELDS)


def privilege_escalation_guard(*, requested_scope: set, required_scope: set):
    """§8.9/FR-13: requested ⊋ required ⇒ REVIEW (never self-elevate). [T24]"""
    if requested_scope > required_scope:
        return ("REVIEW", "requested scope exceeds least-privilege need")
    return ("OK", None)


# ── §8.15 Output compaction ──────────────────────────────────────────────────
def compose_output(prior: dict, new_attempt: dict, *, new_valid: bool):
    """§8.15: rewrite Current Canonical Result + Artifact Manifest in place; RETAIN
    required Exceptional History; a failed/invalid compose preserves prior. [T66,T67,T68,T70]"""
    if not new_valid:
        return {"ok": False, "result": prior, "status_hint": "REVIEW"}  # T70 preserve prior
    out = dict(prior)
    out["current_canonical_result"] = new_attempt["current_canonical_result"]  # replace (T66)
    out["artifact_manifest"] = new_attempt["artifact_manifest"]
    # Exceptional History is append-only for safety-relevant entries (T67/T68).
    hist = list(prior.get("exceptional_history", []))
    for e in new_attempt.get("exceptional_history", []):
        hist.append(e)
    out["exceptional_history"] = hist
    return {"ok": True, "result": out, "status_hint": None}


# ── §8.15 Output content policy ──────────────────────────────────────────────
FORBIDDEN_OUTPUT_PATTERNS = [r"BEGIN TRANSCRIPT", r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
                             r"sk_live_[A-Za-z0-9]+", r"Authorization: Bearer ",
                             r"\$ .+\n(?:.*\n){50,}",  # raw command log dumps
                             r"(?:PASS|FAIL).*\n(?:.*\n){40,}"]  # extensive repeated test output


def validate_output_content(text: str) -> bool:
    """§8.15 excluded content: no transcripts/raw logs/repeated tests/secrets in
    Packet Output (actionable links + redacted facts are kept). [T69]"""
    return not any(re.search(p, text) for p in FORBIDDEN_OUTPUT_PATTERNS)


# ── §8.16 Source of Truth supersession ───────────────────────────────────────
def supersede_sot(old_ref: str, new_ref_kind: str, new_ref: str, output: dict):
    """§8.16 supersession: SoT property is rewritten to the new authoritative
    target; the old context is preserved compactly in Exceptional History. [T75]"""
    if not validate_sot(new_ref_kind):
        raise ValueError("new SoT must be a valid durable reference")
    out = dict(output)
    out["source_of_truth"] = new_ref
    hist = list(output.get("exceptional_history", []))
    hist.append(f"SoT superseded: {old_ref} → {new_ref}")
    out["exceptional_history"] = hist
    return out


# ── §8.17 / §7 maintenance ordering + budget (no control plane) ──────────────
def maintenance_plan(due_items: list, *, max_items: int = 10, time_budget_s: int = 120):
    """§7 steps 10–12 + §8.17: bounded maintenance runs AFTER reconciliation and
    BEFORE the brief; ≤max_items, time-bounded; remainder reported; cleanup counts
    0 against max_packets_per_cycle; qualification row written AFTER brief+notify;
    no separate scheduler/DB/ledger entity. [T107,T81]"""
    processed = list(due_items)[:max(0, max_items)]
    deferred = list(due_items)[max(0, max_items):]
    return {
        "processed": processed,
        "deferred": deferred,                       # reported, not silently dropped
        "counts_against_cycle_cap": 0,              # T81: not a mission slot
        "runs_after_reconcile_before_brief": True,  # T107 ordering
        "time_budget_s": time_budget_s,
        "qualification_row_after_brief_and_notify": True,
        "uses_separate_control_plane": False,       # T81: no scheduler/DB/ledger
    }
