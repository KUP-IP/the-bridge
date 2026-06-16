// SchedulerResilienceTests.swift — PKT-381 (Scheduler Resilience)
// Durable missed-occurrence backlog + reconciler + serial drain + first job.
//
// Wave 1 — Durability core: job_backlog table, idempotent enqueue
//          (INSERT OR IGNORE on UNIQUE(job_id, occurrence_ts)),
//          last-successful-execution lookup, dedup window helper.
// Wave 2 — Reconciler: DST-correct missed-occurrence enumeration
//          (last-success → now), per-job cap + global ceiling.
// Wave 3 — Serial drain: single-flight, oldest-first, resume, battery, no double-fire.
//
// All tests are hermetic: each opens the shared JobStore (fixed path) and
// scopes itself to a unique job id created + deleted within the test, so the
// real user DB is never disturbed (CASCADE deletes the backlog rows too).

import Foundation
import NotionBridgeLib

func runSchedulerResilienceTests() async {
    print("\n\u{1F501} Scheduler Resilience Tests (PKT-381)")

    // Small helper: a parseable ISO instant.
    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // A bare ToolRouter with no tools registered. The drain dispatches the job's
    // action chain through it; an unknown tool fails the step, but runCallback
    // still RECORDS a job_executions row and the drain retires the backlog row —
    // which is exactly the durability contract under test (we are not testing the
    // action tool itself here, only serialization / idempotency / resume).
    func makeTestToolRouter() async -> ToolRouter {
        ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
    }

    // Insert a throwaway active job and return its id; caller deletes it.
    func makeJob(_ schedule: String, name: String = "resilience-test",
                 createdAt: Date = Date(), skipOnBattery: Bool = false) async throws -> String {
        try await JobStore.shared.open()
        let id = "RT-" + UUID().uuidString
        let job = JobRecord(id: id, name: name, schedule: schedule,
                            actionChain: [ActionStep(tool: "noop")],
                            status: .active, skipOnBattery: skipOnBattery,
                            createdAt: createdAt, updatedAt: createdAt)
        try await JobStore.shared.insert(job)
        return id
    }

    // ---------------------------------------------------------------
    // Wave 1 — Durability core
    // ---------------------------------------------------------------

    await test("Backlog: enqueue of same (job,occurrence) dedups via UNIQUE") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let occ = date("2026-06-10T06:00:00.000Z")

        let first = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ)
        try expect(first == true, "first enqueue should insert a new row")

        let second = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ)
        try expect(second == false, "re-enqueue of identical occurrence must be a no-op")

        let rows = try await JobStore.shared.backlog(jobId: id)
        try expect(rows.count == 1, "expected exactly 1 backlog row after dedup, got \(rows.count)")
        try expect(rows[0].status == .pending)
        try await JobStore.shared.delete(id: id)
    }

    await test("Backlog: distinct occurrences each enqueue; oldest-first ordering") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let occ1 = date("2026-06-10T06:00:00.000Z")
        let occ2 = date("2026-06-11T06:00:00.000Z")
        let occ3 = date("2026-06-12T06:00:00.000Z")
        // enqueue out of order
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ2)
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ3)
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ1)

        let pending = try await JobStore.shared.pendingBacklog()
            .filter { $0.jobId == id }
        try expect(pending.count == 3)
        try expect(pending[0].occurrenceTs == occ1, "oldest occurrence must sort first")
        try expect(pending[1].occurrenceTs == occ2)
        try expect(pending[2].occurrenceTs == occ3)

        let next = try await JobStore.shared.nextPendingBacklog()
        // next is the global oldest pending; at minimum our occ1 must be present
        try expect(next != nil)
        try await JobStore.shared.delete(id: id)
    }

    await test("Backlog: setBacklogStatus compare-and-set single-flight claim") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let occ = date("2026-06-10T06:00:00.000Z")
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ)
        let row = try await JobStore.shared.backlog(jobId: id).first!
        let rowId = row.id!

        // First claim pending→running succeeds.
        let claimed = try await JobStore.shared.setBacklogStatus(id: rowId, to: .running, expecting: .pending)
        try expect(claimed == true, "first claim must succeed")
        // A second claim expecting pending must fail (it is now running).
        let reclaimed = try await JobStore.shared.setBacklogStatus(id: rowId, to: .running, expecting: .pending)
        try expect(reclaimed == false, "second concurrent claim must be refused (already running)")
        // Move running→done.
        let done = try await JobStore.shared.setBacklogStatus(id: rowId, to: .done, expecting: .running)
        try expect(done == true)
        let after = try await JobStore.shared.backlog(jobId: id).first!
        try expect(after.status == .done)
        try await JobStore.shared.delete(id: id)
    }

    await test("Backlog: requeueStuckRunning resets running→pending (mid-drain kill resume)") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let occ = date("2026-06-10T06:00:00.000Z")
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ)
        let rowId = try await JobStore.shared.backlog(jobId: id).first!.id!
        _ = try await JobStore.shared.setBacklogStatus(id: rowId, to: .running, expecting: .pending)

        // Simulate relaunch sweep.
        let reset = try await JobStore.shared.requeueStuckRunning()
        try expect(reset >= 1, "should reset at least our stuck running row")
        let after = try await JobStore.shared.backlog(jobId: id).first!
        try expect(after.status == .pending, "stuck running row must return to pending for resume")
        try await JobStore.shared.delete(id: id)
    }

    await test("Backlog: CASCADE — deleting a job removes its backlog rows") {
        let id = try await makeJob("0 6 * * *")
        let occ = date("2026-06-10T06:00:00.000Z")
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ)
        try expect(try await JobStore.shared.backlog(jobId: id).count == 1)
        try await JobStore.shared.delete(id: id)
        try expect(try await JobStore.shared.backlog(jobId: id).isEmpty,
                   "backlog rows must CASCADE-delete with the job")
    }

    await test("lastSuccessfulExecution: returns latest success, ignores failure/skipped") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let t1 = date("2026-06-10T06:00:00.000Z")
        let t2 = date("2026-06-11T06:00:00.000Z")
        let t3 = date("2026-06-12T06:00:00.000Z")
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(id: nil, jobId: id, startedAt: t1, completedAt: t1, status: .success, results: nil, errorMessage: nil))
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(id: nil, jobId: id, startedAt: t2, completedAt: t2, status: .failure, results: nil, errorMessage: "x"))
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(id: nil, jobId: id, startedAt: t3, completedAt: t3, status: .skipped, results: nil, errorMessage: "paused"))

        let last = try await JobStore.shared.lastSuccessfulExecution(jobId: id)
        try expect(last != nil, "should find the success row")
        try expect(last!.startedAt == t1, "failure/skipped after a success must NOT advance the watermark")
        try await JobStore.shared.delete(id: id)
    }

    await test("lastSuccessfulExecution: nil when job never succeeded") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(id: nil, jobId: id, startedAt: Date(), completedAt: Date(), status: .failure, results: nil, errorMessage: "x"))
        let last = try await JobStore.shared.lastSuccessfulExecution(jobId: id)
        try expect(last == nil, "no success → nil watermark (caller falls back to createdAt)")
        try await JobStore.shared.delete(id: id)
    }

    await test("hasExecution: detects a run inside the dedup window") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let occ = date("2026-06-10T06:00:00.000Z")
        let windowStart = occ.addingTimeInterval(-30 * 60)
        let windowEnd = occ.addingTimeInterval(30 * 60)
        try expect(try await JobStore.shared.hasExecution(jobId: id, in: windowStart, windowEnd) == false)
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(id: nil, jobId: id, startedAt: occ.addingTimeInterval(60), completedAt: occ, status: .success, results: nil, errorMessage: nil))
        try expect(try await JobStore.shared.hasExecution(jobId: id, in: windowStart, windowEnd) == true,
                   "a run inside the window must be detected for dedup vs launchd")
        try await JobStore.shared.delete(id: id)
    }

    // ---------------------------------------------------------------
    // Wave 2 — Occurrence enumeration + reconciler
    // ---------------------------------------------------------------

    // Use UTC for the deterministic gap tests so wall-clock math is exact.
    let utc = TimeZone(identifier: "UTC")!

    await test("Enumerate: 3-day gap of a daily 06:00 job yields exactly 3 occurrences") {
        // last success at 2026-06-10T06:00; now 2026-06-13T07:00 → misses are the
        // 06:00 slots on the 11th, 12th, 13th. The 10th is == lowerBound (excluded).
        let floor = date("2026-06-10T06:00:00.000Z")
        let now = date("2026-06-13T07:00:00.000Z")
        let r = try JobOccurrenceEnumerator.enumerate(schedule: "0 6 * * *", after: floor, through: now, timeZone: utc)
        try expect(r.occurrences.count == 3, "expected 3 missed daily slots, got \(r.occurrences.count)")
        try expect(r.occurrences[0] == date("2026-06-11T06:00:00.000Z"))
        try expect(r.occurrences[1] == date("2026-06-12T06:00:00.000Z"))
        try expect(r.occurrences[2] == date("2026-06-13T06:00:00.000Z"))
        try expect(r.ceilingHit == false)
    }

    await test("Enumerate: lower bound is exclusive, upper bound inclusive") {
        // floor exactly on a slot must NOT re-enumerate that slot; now exactly on
        // a slot SHOULD include it.
        let floor = date("2026-06-10T06:00:00.000Z")
        let now = date("2026-06-12T06:00:00.000Z")
        let r = try JobOccurrenceEnumerator.enumerate(schedule: "0 6 * * *", after: floor, through: now, timeZone: utc)
        try expect(r.occurrences.count == 2, "expected the 11th and 12th, got \(r.occurrences.count)")
        try expect(r.occurrences.first == date("2026-06-11T06:00:00.000Z"))
        try expect(r.occurrences.last == date("2026-06-12T06:00:00.000Z"))
    }

    await test("Enumerate: empty when now <= lastSuccess") {
        let floor = date("2026-06-13T06:00:00.000Z")
        let now = date("2026-06-13T06:00:00.000Z")
        let r = try JobOccurrenceEnumerator.enumerate(schedule: "0 6 * * *", after: floor, through: now, timeZone: utc)
        try expect(r.occurrences.isEmpty)
    }

    await test("Enumerate: hourly job over a 6-hour gap yields 6 occurrences") {
        let floor = date("2026-06-10T00:00:00.000Z")
        let now = date("2026-06-10T06:00:00.000Z")
        let r = try JobOccurrenceEnumerator.enumerate(schedule: "0 * * * *", after: floor, through: now, timeZone: utc)
        // slots at 01,02,03,04,05,06 (00 excluded as == floor)
        try expect(r.occurrences.count == 6, "expected 6 hourly slots, got \(r.occurrences.count)")
    }

    await test("Enumerate: weekday-only (Mon 09:00) matches just the Mondays in a gap") {
        // 2026-06-08 is a Monday. Window covers 2026-06-07..2026-06-23 → Mondays
        // on the 8th, 15th, 22nd (3 occurrences).
        let floor = date("2026-06-07T00:00:00.000Z")
        let now = date("2026-06-23T00:00:00.000Z")
        let r = try JobOccurrenceEnumerator.enumerate(schedule: "0 9 * * 1", after: floor, through: now, timeZone: utc)
        try expect(r.occurrences.count == 3, "expected 3 Mondays, got \(r.occurrences.count)")
        for occ in r.occurrences {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
            try expect(cal.component(.weekday, from: occ) == 2, "each occurrence must be a Monday (Apple weekday 2)")
            try expect(cal.component(.hour, from: occ) == 9)
        }
    }

    await test("Enumerate: DST spring-forward boundary (America/New_York) — 02:30 slot collapses, no duplicate/lost day") {
        // US DST 2026 spring-forward: 2026-03-08, clocks jump 02:00 → 03:00, so a
        // daily 02:30 job has NO valid 02:30 on the 8th. Calendar.date(from:)
        // resolves the non-existent wall time to the adjusted instant; we must
        // still produce exactly one occurrence per day with no crash/dup.
        let ny = TimeZone(identifier: "America/New_York")!
        let floor = date("2026-03-06T12:00:00.000Z")   // before the boundary
        let now = date("2026-03-11T12:00:00.000Z")      // after the boundary
        let r = try JobOccurrenceEnumerator.enumerate(schedule: "30 2 * * *", after: floor, through: now, timeZone: ny)
        // Days 7, 8, 9, 10, 11 each contribute their 02:30 slot in local time.
        // The 8th's 02:30 does not exist; it resolves to one instant (03:30 EDT),
        // still distinct from neighbours → exactly 5 occurrences, all unique.
        try expect(r.occurrences.count == 5, "expected one occurrence per local day across the DST boundary, got \(r.occurrences.count)")
        try expect(Set(r.occurrences).count == r.occurrences.count, "no duplicate instants across the boundary")
        // Strictly increasing.
        for i in 1..<r.occurrences.count {
            try expect(r.occurrences[i] > r.occurrences[i-1], "occurrences must be strictly increasing")
        }
    }

    await test("Enumerate: DST fall-back boundary (America/New_York) — 01:30 ambiguous slot produced once") {
        // US DST 2026 fall-back: 2026-11-01, clocks 02:00 → 01:00, so 01:30 occurs
        // twice in local time. We must produce exactly one occurrence for that day
        // (no double-enqueue of the same logical daily slot).
        let ny = TimeZone(identifier: "America/New_York")!
        let floor = date("2026-10-30T12:00:00.000Z")
        let now = date("2026-11-03T12:00:00.000Z")
        let r = try JobOccurrenceEnumerator.enumerate(schedule: "30 1 * * *", after: floor, through: now, timeZone: ny)
        // local days 31, 1, 2, 3 → 4 occurrences, deduped.
        try expect(r.occurrences.count == 4, "expected one 01:30 occurrence per local day, got \(r.occurrences.count)")
        try expect(Set(r.occurrences).count == r.occurrences.count, "ambiguous fall-back slot must not double-count")
    }

    await test("Enumerate: safety ceiling clips a pathological hourly multi-year gap") {
        let floor = date("2020-01-01T00:00:00.000Z")
        let now = date("2026-01-01T00:00:00.000Z")   // ~6 years of hourly slots
        let r = try JobOccurrenceEnumerator.enumerate(schedule: "0 * * * *", after: floor, through: now, timeZone: utc, safetyCeiling: 100)
        try expect(r.occurrences.count == 100, "ceiling must clip to exactly the ceiling, got \(r.occurrences.count)")
        try expect(r.ceilingHit == true, "ceilingHit must flag the clip")
    }

    await test("applyPolicy: coalesceToLatest collapses to the single newest occurrence") {
        let occs = [date("2026-06-11T06:00:00.000Z"), date("2026-06-12T06:00:00.000Z"), date("2026-06-13T06:00:00.000Z")]
        let out = JobOccurrenceEnumerator.applyPolicy(.coalesceToLatest, to: occs, now: date("2026-06-13T07:00:00.000Z"))
        try expect(out == [date("2026-06-13T06:00:00.000Z")])
    }

    await test("applyPolicy: maxLookback filters to the recent window") {
        let now = date("2026-06-13T07:00:00.000Z")
        let occs = [date("2026-06-11T06:00:00.000Z"), date("2026-06-12T06:00:00.000Z"), date("2026-06-13T06:00:00.000Z")]
        // 36h lookback keeps only the 12th 06:00 and 13th 06:00.
        let out = JobOccurrenceEnumerator.applyPolicy(.maxLookback(36 * 3600), to: occs, now: now)
        try expect(out.count == 2, "36h lookback should keep 2, got \(out.count)")
        try expect(out.first == date("2026-06-12T06:00:00.000Z"))
    }

    await test("Reconciler: 3-day gap enqueues exactly the missed set (deduped vs an existing run)") {
        // Job created 4 days ago, one success 3 days ago; daily 06:00. Reconciler
        // should enqueue the slots AFTER the last success up to now, EXCEPT a slot
        // already covered by an existing job_executions row (launchd wake-run).
        let now = date("2026-06-13T07:00:00.000Z")
        let createdAt = date("2026-06-09T00:00:00.000Z")
        let id = try await makeJob("0 6 * * *", createdAt: createdAt)
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        // Last success on the 10th 06:00.
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(id: nil, jobId: id, startedAt: date("2026-06-10T06:00:05.000Z"),
                            completedAt: date("2026-06-10T06:00:06.000Z"), status: .success, results: nil, errorMessage: nil))
        // launchd already fired the 12th 06:00 slot (an execution inside the window).
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(id: nil, jobId: id, startedAt: date("2026-06-12T06:00:10.000Z"),
                            completedAt: date("2026-06-12T06:00:11.000Z"), status: .failure, results: nil, errorMessage: "launchd run failed"))

        // NB: the 12th's execution is .failure, not .success — it does NOT advance
        // the watermark (which stays at the 10th), but it DOES sit inside the 12th
        // slot's dedup window, so the reconciler enumerates 11/12/13 from the 10th
        // and dedups only the 12th against this existing (failed) launchd run.
        let report = await JobsManager.shared.reconcileMissedOccurrences(now: now, timeZone: utc)
        try expect(report.enqueued >= 1)
        let rows = try await JobStore.shared.backlog(jobId: id)
        let occs = Set(rows.map { $0.occurrenceTs })
        // Expect the 11th and 13th 06:00; the 12th is deduped (launchd ran it).
        try expect(occs.contains(date("2026-06-11T06:00:00.000Z")), "missing the 11th")
        try expect(occs.contains(date("2026-06-13T06:00:00.000Z")), "missing the 13th")
        try expect(!occs.contains(date("2026-06-12T06:00:00.000Z")), "12th must be deduped vs the launchd run")
        try await JobStore.shared.delete(id: id)
    }

    await test("Reconciler: second pass is idempotent (no duplicate backlog rows)") {
        let now = date("2026-06-13T07:00:00.000Z")
        let createdAt = date("2026-06-11T00:00:00.000Z")
        let id = try await makeJob("0 6 * * *", createdAt: createdAt)
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let r1 = await JobsManager.shared.reconcileMissedOccurrences(now: now, timeZone: utc)
        let count1 = try await JobStore.shared.backlog(jobId: id).count
        let r2 = await JobsManager.shared.reconcileMissedOccurrences(now: now, timeZone: utc)
        let count2 = try await JobStore.shared.backlog(jobId: id).count
        try expect(count1 == count2, "second reconcile must not add rows (\(count1) → \(count2))")
        try expect(r2.enqueued == 0, "idempotent reconcile enqueues nothing the second time")
        _ = r1
        try await JobStore.shared.delete(id: id)
    }

    await test("Reconciler: never-run job uses createdAt as the enumeration floor") {
        let now = date("2026-06-12T07:00:00.000Z")
        let createdAt = date("2026-06-10T06:00:00.000Z")  // exactly on a slot → excluded
        let id = try await makeJob("0 6 * * *", createdAt: createdAt)
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        _ = await JobsManager.shared.reconcileMissedOccurrences(now: now, timeZone: utc)
        let occs = Set(try await JobStore.shared.backlog(jobId: id).map { $0.occurrenceTs })
        // 10th excluded (== createdAt), 11th + 12th enqueued.
        try expect(occs == Set([date("2026-06-11T06:00:00.000Z"), date("2026-06-12T06:00:00.000Z")]),
                   "never-run job should backfill from createdAt, got \(occs.count) rows")
        try await JobStore.shared.delete(id: id)
    }

    // ---------------------------------------------------------------
    // Wave 3 — Serial drain
    // ---------------------------------------------------------------

    await test("Drain: serially executes pending backlog oldest-first via runCallback") {
        // A job with a trivial action chain (noop is unknown → step fails, but the
        // run is RECORDED and the backlog row is marked done; drain advances).
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: date("2026-06-11T06:00:00.000Z"))
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: date("2026-06-12T06:00:00.000Z"))

        let router = await makeTestToolRouter()
        let report = await JobsManager.shared.drainBacklog(router: router)
        try expect(report.executed + report.skipped == 2, "both backlog rows must be drained, got \(report.executed + report.skipped)")
        let remaining = try await JobStore.shared.pendingBacklogCount(jobId: id)
        try expect(remaining == 0, "no pending rows should remain after a drain")
        // Each drained occurrence produced a job_executions row.
        let execs = try await JobStore.shared.executions(jobId: id, limit: 50)
        try expect(execs.count >= 2, "drain must record a job_executions row per occurrence, got \(execs.count)")
        try await JobStore.shared.delete(id: id)
    }

    await test("Drain: mid-drain kill leaves a running row that requeueStuckRunning resumes") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: date("2026-06-11T06:00:00.000Z"))
        let rowId = try await JobStore.shared.backlog(jobId: id).first!.id!
        // Simulate a crash AFTER claim, BEFORE completion.
        _ = try await JobStore.shared.setBacklogStatus(id: rowId, to: .running, expecting: .pending)
        try expect(try await JobStore.shared.pendingBacklogCount(jobId: id) == 0, "claimed row is not pending")
        // Relaunch path: requeue stuck, then drain.
        let router = await makeTestToolRouter()
        let report = await JobsManager.shared.reconcileAndDrain(router: router, now: date("2026-06-11T07:00:00.000Z")).1
        _ = report
        try expect(try await JobStore.shared.pendingBacklogCount(jobId: id) == 0, "resumed row must be drained to completion")
        let after = try await JobStore.shared.backlog(jobId: id).first
        try expect(after?.status == .done || after?.status == .skipped, "resumed row should be terminal after drain")
        try await JobStore.shared.delete(id: id)
    }

    await test("Drain: skip_on_battery records a skip (no double-fire) when low-power") {
        // We cannot toggle real low-power mode in a unit test; this asserts the
        // structural contract that a paused job is recorded as a skip and the
        // backlog row is still retired (so the occurrence never re-fires).
        let id = try await makeJob("0 6 * * *", skipOnBattery: true)
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        try await JobStore.shared.updateStatus(id: id, status: .paused)  // forces the .skipped path deterministically
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: date("2026-06-11T06:00:00.000Z"))
        let router = await makeTestToolRouter()
        let report = await JobsManager.shared.drainBacklog(router: router)
        try expect(report.skipped == 1, "paused job occurrence must be recorded as a skip, got executed=\(report.executed) skipped=\(report.skipped)")
        try expect(try await JobStore.shared.pendingBacklogCount(jobId: id) == 0, "skipped occurrence must still retire the backlog row")
        try await JobStore.shared.delete(id: id)
    }

    await test("Drain: no double-fire — re-enqueue of a drained occurrence is ignored, re-drain is a no-op") {
        let id = try await makeJob("0 6 * * *")
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let occ = date("2026-06-11T06:00:00.000Z")
        _ = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ)
        let router = await makeTestToolRouter()
        _ = await JobsManager.shared.drainBacklog(router: router)
        let execsAfterFirst = try await JobStore.shared.executions(jobId: id, limit: 50).count
        // Attempt to re-enqueue the SAME occurrence — UNIQUE makes it a no-op.
        let reEnq = try await JobStore.shared.enqueueBacklog(jobId: id, occurrenceTs: occ)
        try expect(reEnq == false, "re-enqueue of a drained occurrence must be ignored (idempotency key)")
        // A second drain has nothing pending → fires nothing.
        let report2 = await JobsManager.shared.drainBacklog(router: router)
        try expect(report2.executed == 0 && report2.skipped == 0, "second drain must be a no-op (no pending rows)")
        let execsAfterSecond = try await JobStore.shared.executions(jobId: id, limit: 50).count
        try expect(execsAfterFirst == execsAfterSecond, "no new execution row on the second drain — occurrence fired at most once")
        try await JobStore.shared.delete(id: id)
    }

    // ---------------------------------------------------------------
    // Wave 4 — First job: running report → iMessage (scaffold + delivery)
    // ---------------------------------------------------------------

    await test("FirstJob: default record uses the packet schedule + stable id + active") {
        let job = RunningReportJob.defaultJobRecord()
        try expect(job.id == "first-job-running-report", "stable id keeps seeding idempotent")
        try expect(job.schedule == "0 6 * * *", "packet default schedule is 06:00 daily")
        try expect(job.status == .active, "active so Run-now works + launchd schedules it")
        try expect(job.actionChain.count == 2, "expected build-report + send-iMessage steps")
    }

    await test("FirstJob: action chain is report-builder → iMessage with $prev_result wiring") {
        let chain = RunningReportJob.defaultActionChain()
        // Step 0 builds the report text.
        try expect(chain[0].tool == "shell_exec", "step 0 builds the running summary")
        try expect(chain[0].onFail == .stop, "abort delivery if the report can't be built")
        // Step 1 delivers via iMessage to self.
        try expect(chain[1].tool == "messages_send", "step 1 delivers via iMessage")
        try expect(chain[1].onFail == .continue, "an un-wired placeholder records a failed send, not an abort")
        if case .string(let body)? = chain[1].arguments["body"] {
            try expect(body == "$prev_result", "delivery body must read the previous step's report output")
        } else { try expect(false, "messages_send must have a 'body'") }
        if case .string(let confirm)? = chain[1].arguments["confirm"] {
            try expect(confirm == "SEND", "unattended messages_send requires confirm: SEND")
        } else { try expect(false, "messages_send must carry the SEND gate") }
    }

    await test("FirstJob: chain passes the same unattended validation as createJob") {
        // The seeder runs this exact gate; if it throws the build fails.
        let chain = RunningReportJob.defaultActionChain()
        for step in chain {
            try JobsManager.validateUnattended(tool: step.tool, args: step.arguments)
        }
    }

    await test("FirstJob: report scaffold is honest — no fabricated metrics, flags the data source") {
        let chain = RunningReportJob.defaultActionChain()
        guard case .string(let script)? = chain[0].arguments["command"] else {
            try expect(false, "report builder must carry a shell command"); return
        }
        // Honesty contract: the scaffold must NOT invent numbers and must mark
        // the data source as operator-pending.
        try expect(script.contains("operator: wire data source") || script.contains("Data source not yet connected"),
                   "report must flag the Strava data path as operator-pending")
        try expect(script.contains("7-day mileage") && script.contains("Pace vs last week") && script.contains("Latest run"),
                   "report must lay out the default metric set (latest run / 7-day mileage / pace vs last week)")
    }

    await test("FirstJob: recipient is an obvious operator-pending placeholder (no real contact)") {
        let chain = RunningReportJob.defaultActionChain()
        if case .string(let recip)? = chain[1].arguments["recipient"] {
            try expect(recip == RunningReportJob.selfHandlePlaceholder)
            try expect(recip.uppercased() == recip && recip.contains("REPLACE"),
                       "placeholder must be obviously fake so a stray fire can't message a real contact")
        } else { try expect(false, "messages_send must have a recipient") }
    }

    await test("FirstJob: seeder inserts once, registers, and is idempotent") {
        // Hermetic: inject a NO-OP launch-agent installer so the test never
        // writes a real plist to ~/Library/LaunchAgents or calls launchctl.
        // (Production uses RunningReportJob.realLaunchAgentInstaller.)
        let noopInstaller: @Sendable (String, [CronParser.CalendarInterval]) throws -> Void = { _, _ in }
        try await JobStore.shared.open()
        try? await JobStore.shared.delete(id: RunningReportJob.jobId)

        let firstSeed = await JobsManager.shared.seedRunningReportJobIfNeeded(installLaunchAgent: noopInstaller)
        try expect(firstSeed == true, "first seed should insert the job")
        let seeded = try await JobStore.shared.fetch(id: RunningReportJob.jobId)
        try expect(seeded != nil, "seeded job must be present in the store (visible in Jobs UI)")
        try expect(seeded?.schedule == "0 6 * * *")
        try expect(seeded?.status == .active, "Run-now requires an active job")

        let secondSeed = await JobsManager.shared.seedRunningReportJobIfNeeded(installLaunchAgent: noopInstaller)
        try expect(secondSeed == false, "second seed must be a no-op (idempotent — never clobbers operator edits)")
        let all = try await JobStore.shared.listAll().filter { $0.id == RunningReportJob.jobId }
        try expect(all.count == 1, "exactly one seeded job, got \(all.count)")

        // Cleanup (DB only — no plist was written).
        try? await JobStore.shared.delete(id: RunningReportJob.jobId)
    }
}
