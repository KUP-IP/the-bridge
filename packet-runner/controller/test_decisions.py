"""
Deterministic acceptance tests for the Packet Runner controller decision core.

Each test names the PRD acceptance ID(s) (T-n) it exercises. These are the
AUTOMATABLE-NOW subset of T1–T114 (per acceptance/ACCEPTANCE_MATRIX.md) — pure
decisions over controlled inputs, no live provider and no human. Run:
    python3 test_decisions.py
Exits non-zero on any failure (so the captured evidence is trustworthy).
"""
import sys
from datetime import datetime, timedelta, timezone
import decisions as d

UTC = timezone.utc
NOW = datetime(2026, 6, 23, 12, 0, tzinfo=UTC)
TESTS = []


def t(ids):
    def deco(fn):
        TESTS.append((ids, fn.__name__, fn))
        return fn
    return deco


# ── receipt → status (§8.5) ──────────────────────────────────────────────────
@t("T2,T16")
def auto_completed_all_green_done():
    assert d.map_receipt_to_status(goal_state="COMPLETED", execution_class="AUTO",
        criteria_all_pass=True, sot_ok=True, output_written=True, live_agrees=True,
        receipt_valid=True) == "DONE"
    assert d.map_receipt_to_status(goal_state="ALREADY_SATISFIED", execution_class="AUTO",
        criteria_all_pass=True, sot_ok=True, output_written=True, live_agrees=True,
        receipt_valid=True) == "DONE"


@t("T2,T71")
def auto_completed_missing_sot_review():
    assert d.map_receipt_to_status(goal_state="COMPLETED", execution_class="AUTO",
        criteria_all_pass=True, sot_ok=False, output_written=True, live_agrees=True,
        receipt_valid=True) == "REVIEW"


@t("T3")
def review_first_never_auto_done():
    assert d.map_receipt_to_status(goal_state="COMPLETED", execution_class="REVIEW-FIRST",
        criteria_all_pass=True, sot_ok=True, output_written=True, live_agrees=True,
        receipt_valid=True) == "REVIEW"


@t("T5")
def blocked_only_when_fully_known():
    assert d.map_receipt_to_status(goal_state="BLOCKED", execution_class="AUTO",
        criteria_all_pass=False, sot_ok=False, output_written=False, live_agrees=False,
        receipt_valid=True, blocker_fully_known=True) == "BLOCKED"
    assert d.map_receipt_to_status(goal_state="BLOCKED", execution_class="AUTO",
        criteria_all_pass=False, sot_ok=False, output_written=False, live_agrees=False,
        receipt_valid=True, blocker_fully_known=False) == "REVIEW"


@t("T10,T70")
def invalid_receipt_review():
    assert d.map_receipt_to_status(goal_state="COMPLETED", execution_class="AUTO",
        criteria_all_pass=True, sot_ok=True, output_written=True, live_agrees=True,
        receipt_valid=False) == "REVIEW"


@t("T8,T19")
def unsafe_and_partial_review():
    for gs in ("REVIEW_REQUIRED", "PARTIAL_SAFE", "FAILED_SAFE", "UNSAFE_AMBIGUOUS"):
        assert d.map_receipt_to_status(goal_state=gs, execution_class="AUTO",
            criteria_all_pass=True, sot_ok=True, output_written=True, live_agrees=True,
            receipt_valid=True) == "REVIEW"


# ── replay (§8.8) ─────────────────────────────────────────────────────────────
@t("T16")
def already_satisfied():
    assert d.classify_replay_state(evidence_of_prior_attempt=False, goal_already_true=True,
        partial_work_present=False, safe_resume_conditions={}) == "ALREADY_SATISFIED"


@t("T17")
def safe_resume_gate_all_or_nothing():
    full = {k: True for k in d.SAFE_RESUME_KEYS}
    assert d.classify_replay_state(evidence_of_prior_attempt=True, goal_already_true=False,
        partial_work_present=True, safe_resume_conditions=full) == "SAFE_RESUME"
    partial = dict(full); partial["no_consequential_repeat"] = False
    assert d.classify_replay_state(evidence_of_prior_attempt=True, goal_already_true=False,
        partial_work_present=True, safe_resume_conditions=partial) == "UNSAFE_AMBIGUOUS"


# ── material change / approval (§8.8 / §8.10) ─────────────────────────────────
@t("T18")
def material_change_detects_exec_critical():
    a = {f: "x" for f in d.EXEC_CRITICAL}
    b = dict(a); b["scope"] = "y"
    assert d.material_change(a, b) == ["scope"]
    c = dict(a); c["lifecycle_checked_at"] = "later"
    assert d.material_change(a, c) == []   # controller-owned change ⇒ proceed


@t("T32")
def approval_invalidated_by_material_change():
    a = {f: "x" for f in d.EXEC_CRITICAL}
    assert d.approval_still_valid(a, a) is True
    b = dict(a); b["success_criteria"] = "changed"
    assert d.approval_still_valid(a, b) is False


# ── eligibility (§6 step 4) ───────────────────────────────────────────────────
@t("T4")
def manual_never_dispatched():
    p = d.Packet(id="p", execution_class="MANUAL")
    assert d.classify_eligibility(p, NOW) == ("SKIP_MANUAL", None)


@t("T5")
def known_blocker_to_blocked():
    p = d.Packet(id="p", blocked_by=[("dep", "BLOCKED")],
                 known_unmet_prereq={"owner": "Isaiah", "unblock_condition": "grant scope"})
    assert d.classify_eligibility(p, NOW) == ("BLOCKED", "BLOCKED")


@t("T20")
def ambiguous_blocker_to_review():
    p = d.Packet(id="p", blocked_by=[("dep", "REVIEW")], ambiguous_blocker=True)
    assert d.classify_eligibility(p, NOW) == ("REVIEW", "REVIEW")


@t("T110")
def invalid_graph_to_review():
    assert d.classify_eligibility(d.Packet(id="p", blocked_by=[("p", "QUEUE")]), NOW)[1] == "REVIEW"
    assert d.classify_eligibility(d.Packet(id="p", blocked_by=[("x", "CANCELED")]), NOW)[1] == "REVIEW"


@t("T4,T1")
def clean_auto_executes():
    p = d.Packet(id="p", blocked_by=[("dep", "DONE")])
    assert d.classify_eligibility(p, NOW) == ("EXECUTE", "FOCUS")


# ── cap / ordering (§6 steps 5–6) ─────────────────────────────────────────────
@t("T11,T12")
def cap_one():
    assert d.enforce_cap(["a", "b", "c"], 1) == ["a"]
    assert d.enforce_cap(["a", "b"], 0) == []


@t("T11")
def ordering_priority_then_clock_then_pktid():
    a = d.Packet(id="a", priority=5, pkt_id=2)
    b = d.Packet(id="b", priority=9, pkt_id=3)
    c = d.Packet(id="c", priority=5, pkt_id=1)
    assert [p.id for p in d.order_candidates([a, b, c])] == ["b", "c", "a"]


# ── window (§8.1) ─────────────────────────────────────────────────────────────
@t("T102")
def window_semantics():
    before = NOW + timedelta(days=1)
    after = NOW - timedelta(days=1)
    assert d.classify_window(NOW, before, None) == "QUEUE"
    assert d.classify_window(NOW, after, None) == "ELIGIBLE"
    assert d.classify_window(NOW, after, NOW - timedelta(hours=1)) == "REVIEW"   # expired
    assert d.classify_window(NOW, None, after) == "REVIEW"                       # end w/o start
    assert d.classify_window(NOW, NOW, NOW - timedelta(days=1)) == "REVIEW"      # reversed


# ── stale-state (§8.14) ───────────────────────────────────────────────────────
@t("T61")
def stale_queue_7d():
    old = NOW - timedelta(days=7, minutes=1)
    assert d.is_stale_queue(old, NOW) is True
    assert d.is_stale_queue(NOW - timedelta(days=6), NOW) is False
    is_stale, label, new = d.stale_label("QUEUE", old, NOW)
    assert is_stale and label == "Readiness refresh required" and new == "QUEUE"


@t("T64")
def stale_blocked_review_no_mutation():
    old = NOW - timedelta(days=8)
    for st in ("BLOCKED", "REVIEW"):
        is_stale, label, new = d.stale_label(st, old, NOW)
        assert is_stale and new == st   # status unchanged — age never mutates


@t("T65")
def clock_refresh_predicate():
    assert d.should_refresh_clock("authorized_transition") is True
    assert d.should_refresh_clock("explicit_revalidation") is True
    assert d.should_refresh_clock("comment") is False
    assert d.should_refresh_clock("ordinary_edit") is False


# ── Source of Truth (§8.16) ───────────────────────────────────────────────────
@t("T71")
def durable_requires_sot_and_gates_done():
    req = d.requires_sot(created_or_changed_durable=True, already_satisfied_durable=False, ephemeral_only=False)
    assert req is True
    assert d.gate_done(requires_sot_=req, sot_ref_kind=None) == "REVIEW"
    assert d.gate_done(requires_sot_=req, sot_ref_kind="pr") == "DONE_ELIGIBLE"


@t("T73")
def ephemeral_no_sot():
    req = d.requires_sot(created_or_changed_durable=False, already_satisfied_durable=False, ephemeral_only=True)
    assert req is False
    assert d.gate_done(requires_sot_=req, sot_ref_kind=None) == "DONE_ELIGIBLE"


@t("T72,T74")
def sot_valid_vs_invalid_refs():
    for ok in ("repo", "pr", "commit", "release", "notion", "database", "workflow", "external"):
        assert d.validate_sot(ok) is True
    for bad in ("brief", "session", "packet-page", "temp-branch", "draft", "screenshot", "raw-log"):
        assert d.validate_sot(bad) is False
        assert d.gate_done(requires_sot_=True, sot_ref_kind=bad) == "REVIEW"


# ── PACKET DECISION (§8.10) ───────────────────────────────────────────────────
GOOD_DECISION = ("PACKET DECISION\nDecision: APPROVE_COMPLETION\n"
                 "Approved action: merge PR #51\nConditions: none\n"
                 "Reviewer: Isaiah\nAuthority scope: repo merge")


@t("T113")
def packet_decision_parser_accepts_valid():
    parsed = d.parse_packet_decision(GOOD_DECISION, commenter="Isaiah", authority_scope_ok=True)
    assert parsed and parsed["decision"] == "APPROVE_COMPLETION"


@t("T33,T113")
def packet_decision_parser_rejects_invalid():
    assert d.parse_packet_decision("looks good!", commenter="Isaiah", authority_scope_ok=True) is None
    no_first = GOOD_DECISION.replace("PACKET DECISION\n", "")
    assert d.parse_packet_decision(no_first, commenter="Isaiah", authority_scope_ok=True) is None
    missing = "PACKET DECISION\nDecision: CANCEL\nReviewer: Isaiah"   # missing labels
    assert d.parse_packet_decision(missing, commenter="Isaiah", authority_scope_ok=True) is None
    # valid grammar but reviewer outside authority scope ⇒ rejected
    assert d.parse_packet_decision(GOOD_DECISION, commenter="Random", authority_scope_ok=False) is None


@t("T29,T30,T31")
def decision_transitions():
    assert d.apply_decision_transition("APPROVE_COMPLETION", verification_valid=True, sot_ok=True) == "DONE"
    assert d.apply_decision_transition("APPROVE_COMPLETION", verification_valid=False, sot_ok=True) == "REVIEW"
    assert d.apply_decision_transition("AUTHORIZE_CONTINUATION", verification_valid=True, sot_ok=True) == "QUEUE"
    assert d.apply_decision_transition("REQUEST_CHANGES", verification_valid=True, sot_ok=True) == "REVIEW"


# ── AI LOG threshold (§8.11) ──────────────────────────────────────────────────
@t("T13,T46")
def ai_log_threshold():
    for ev in d.AI_LOG_INCIDENT_EVENTS:
        assert d.should_create_ai_log(ev) is True
    for ev in d.AI_LOG_NOOP_EVENTS:
        assert d.should_create_ai_log(ev) is False


# ── cleanup (§8.17) ───────────────────────────────────────────────────────────
@t("T76")
def cleanup_window_7d():
    term = NOW
    assert d.cleanup_eligible_at(term) == term + timedelta(days=7)


@t("T78")
def cleanup_protection_gate():
    for cls in d.PROTECTION_CLASSES:
        assert d.is_protected({cls}) is True
    assert d.is_protected({"plain_temp"}) is False


@t("T79")
def reopen_clears_cleanup():
    assert d.reopen_clears_cleanup("DONE", "REVIEW", NOW) is None
    assert d.reopen_clears_cleanup("DONE", "DONE", NOW) == NOW


# ── archival (§8.19) ──────────────────────────────────────────────────────────
@t("T88")
def archive_date_90d():
    assert d.archive_eligible_at(NOW) == NOW + timedelta(days=90)


@t("T89")
def open_record_never_archives():
    old_created = NOW - timedelta(days=100)
    # Disposition Open ⇒ never archive regardless of age
    assert d.archive_due("Open", old_created, NOW) is False
    assert d.archive_due("Resolved", NOW - timedelta(days=1), NOW) is True
    assert d.archive_due("Resolved", NOW + timedelta(days=1), NOW) is False  # not yet due


@t("T92,T93")
def reopen_and_protection_block_archive():
    assert d.reopen_clears_archive("Resolved", "Investigating", NOW) is None
    assert d.archive_due("Resolved", NOW - timedelta(days=1), NOW, active_dependency=True) is False


# ── two-layer Output (§8.2A) ──────────────────────────────────────────────────
@t("T103")
def two_layer_output_budget():
    idx, body, fits = d.split_output("FULL" * 1000, "compact index")
    assert fits and len(idx) <= 1800 and body == "FULL" * 1000
    _, _, fits2 = d.split_output("x", "y" * 1801)
    assert fits2 is False


# ── compaction (§8.15) ────────────────────────────────────────────────────────
@t("T66,T67,T68")
def compose_output_rewrite_and_retain():
    prior = {"current_canonical_result": "old", "artifact_manifest": "oldM",
             "exceptional_history": ["incident-1"]}
    new = {"current_canonical_result": "new", "artifact_manifest": "newM",
           "exceptional_history": []}
    r = d.compose_output(prior, new, new_valid=True)
    assert r["ok"] and r["result"]["current_canonical_result"] == "new"
    assert r["result"]["exceptional_history"] == ["incident-1"]   # retained (T67/T68)


@t("T70")
def failed_compaction_preserves_prior():
    prior = {"current_canonical_result": "trustworthy"}
    r = d.compose_output(prior, {"current_canonical_result": "junk"}, new_valid=False)
    assert not r["ok"] and r["result"] == prior and r["status_hint"] == "REVIEW"


# ── health (§8.11) ────────────────────────────────────────────────────────────
@t("T37,T42,T43")
def health_precedence():
    assert d.derive_health(safety_or_authz_or_untrusted_incident=True, recoverable_anomaly=True, controller_clean=True) == "FAILED"
    assert d.derive_health(safety_or_authz_or_untrusted_incident=False, recoverable_anomaly=True, controller_clean=True) == "DEGRADED"
    assert d.derive_health(safety_or_authz_or_untrusted_incident=False, recoverable_anomaly=False, controller_clean=True) == "HEALTHY"


# ── schema preflight (§8.1) ───────────────────────────────────────────────────
@t("T100")
def preflight_schema_gate():
    live = {"Execution Class": {"type": "select", "options": ["AUTO", "REVIEW-FIRST", "MANUAL"]},
            "Lifecycle Checked At": {"type": "date"}}
    req = {"Execution Class": {"type": "select", "options": ["AUTO", "MANUAL"]},
           "Lifecycle Checked At": {"type": "date"}}
    ok, missing = d.preflight_schema(live, req)
    assert ok and missing == []
    bad = dict(req); bad["Priority"] = {"type": "number"}
    ok2, missing2 = d.preflight_schema(live, bad)
    assert not ok2 and any("Priority" in m for m in missing2)


# ── brief (§8.6) ──────────────────────────────────────────────────────────────
@t("T36")
def brief_ordering():
    present = {"Cycle metadata", "Decisions needed", "Completed", "Blocked"}
    assert d.order_brief_sections(present) == ["Decisions needed", "Completed", "Blocked", "Cycle metadata"]


@t("T40")
def brief_redaction():
    assert d.validate_brief_content("PKT-1 done; see PR #51") is True
    assert d.validate_brief_content("error: Authorization: Bearer sk_live_abc123") is False


# ── review/cancel completeness (§8.10) ────────────────────────────────────────
@t("T28")
def review_request_completeness():
    full = {f: "x" for f in d.REVIEW_REQUEST_FIELDS}
    assert d.validate_review_request(full) is True
    short = dict(full); short["reviewer"] = ""
    assert d.validate_review_request(short) is False


@t("T105")
def cancellation_receipt_completeness():
    full = {f: "x" for f in d.CANCEL_RECEIPT_FIELDS}
    assert d.validate_cancellation_receipt(full) is True
    assert d.validate_cancellation_receipt({}) is False


# ── adaptation guards (§8.13) ─────────────────────────────────────────────────
@t("T54")
def model_selection_within_allowlist():
    chosen, default_unchanged = d.select_model("opus", available={"sonnet", "haiku"},
        allowlist={"opus", "sonnet"}, default="opus")
    assert chosen == "sonnet" and default_unchanged is True


@t("T49")
def fallback_only_authorized():
    assert d.select_fallback("verify", "toolA", {"toolB"}, {"toolA", "toolB"}) == "toolB"
    assert d.select_fallback("verify", "toolA", {"toolC"}, {"toolA", "toolB"}) is None


@t("T55")
def adaptation_bounds():
    assert d.within_bounds(120, 60, 300) is True
    assert d.within_bounds(500, 60, 300) is False


@t("T56")
def persistent_change_propose_only():
    assert d.classify_persistent_change("schedule") == "PROPOSE_ONLY"
    assert d.classify_persistent_change("timeout") == "SESSION_LOCAL"


@t("T60")
def persistent_change_receipt():
    full = {f: "x" for f in d.PERSISTENT_CHANGE_RECEIPT_FIELDS}
    assert d.validate_persistent_change_receipt(full) is True
    assert d.validate_persistent_change_receipt({"setting": "x"}) is False


@t("T24")
def privilege_escalation_guard():
    assert d.privilege_escalation_guard(requested_scope={"admin", "read"}, required_scope={"read"})[0] == "REVIEW"
    assert d.privilege_escalation_guard(requested_scope={"read"}, required_scope={"read"})[0] == "OK"


# ── output content / supersession / maintenance (§8.15/§8.16/§8.17) ───────────
@t("T69")
def output_content_policy():
    assert d.validate_output_content("Result: merged; SoT=PR#51; evidence link") is True
    assert d.validate_output_content("BEGIN TRANSCRIPT\n...lots...") is False
    assert d.validate_output_content("token sk_live_abc123XYZ leaked") is False


@t("T75")
def sot_supersession():
    out = d.supersede_sot("commit:old", "pr", "https://github.com/x/pull/9",
                          {"source_of_truth": "commit:old", "exceptional_history": []})
    assert out["source_of_truth"] == "https://github.com/x/pull/9"
    assert any("superseded" in e for e in out["exceptional_history"])


@t("T107")
def maintenance_ordering_and_budget():
    plan = d.maintenance_plan(list(range(25)))
    assert len(plan["processed"]) == 10 and len(plan["deferred"]) == 15
    assert plan["runs_after_reconcile_before_brief"] is True
    assert plan["qualification_row_after_brief_and_notify"] is True


@t("T81")
def no_cleanup_control_plane():
    plan = d.maintenance_plan([1, 2])
    assert plan["counts_against_cycle_cap"] == 0
    assert plan["uses_separate_control_plane"] is False


# ── non-overlap latch (§6 step 1) ─────────────────────────────────────────────
@t("T99")
def overlap_gate_cases():
    now = NOW
    assert d.overlap_gate(None, now, "cycleA") == ('ACQUIRE', 'PROCEED')
    mine = d.OverlapLatch("cycleA", now, now + timedelta(minutes=10))
    assert d.overlap_gate(mine, now, "cycleA") == ('HELD', 'PROCEED')   # idempotent
    fresh_other = d.OverlapLatch("cycleB", now - timedelta(minutes=1), now + timedelta(minutes=9))
    assert d.overlap_gate(fresh_other, now, "cycleA") == ('REFUSE', 'NOT_STARTED_OVERLAP')
    stale_other = d.OverlapLatch("cycleB", now - timedelta(hours=1), now - timedelta(minutes=1))
    assert d.overlap_gate(stale_other, now, "cycleA") == ('STALE', 'FAILED')   # ambiguous → fail-closed


@t("T99")
def overlap_verify_best_effort():
    now = NOW
    assert d.overlap_verify(d.OverlapLatch("cycleA", now, now + timedelta(minutes=10)), "cycleA") == 'PROCEED'
    assert d.overlap_verify(d.OverlapLatch("cycleB", now, now + timedelta(minutes=10)), "cycleA") == 'FAILED'  # lost the race
    assert d.overlap_verify(None, "cycleA") == 'FAILED'   # write didn't stick


def main():
    covered = set()
    passed = failed = 0
    fails = []
    for ids, name, fn in TESTS:
        for x in ids.split(","):
            covered.add(x.strip())
        try:
            fn()
            passed += 1
            print(f"  ✅ [{ids}] {name}")
        except Exception as e:  # noqa
            failed += 1
            fails.append((ids, name, repr(e)))
            print(f"  ❌ [{ids}] {name} — {e!r}")
    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed, {len(TESTS)} total")
    print(f"Distinct acceptance IDs exercised: {len(covered)} → {','.join(sorted(covered, key=lambda s:int(s[1:])))}")
    if failed:
        print("FAILURES:")
        for ids, name, err in fails:
            print(f"  [{ids}] {name}: {err}")
        sys.exit(1)
    print("✅ ALL DETERMINISTIC CONTROLLER TESTS PASSED")


if __name__ == "__main__":
    main()
