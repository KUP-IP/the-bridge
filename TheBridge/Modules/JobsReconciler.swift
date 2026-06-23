// JobsReconciler.swift — PKT-381 (Scheduler Resilience)
// TheBridge · Modules
//
// The durability layer that turns the dead bootstrap() "missed-execution scan"
// into a real reconciler + serial drain on top of the job_backlog table.
//
// Provides:
//   • JobOccurrenceEnumerator — DST-correct enumeration of the PAST scheduled
//     occurrences of a cron expression in a (lowerBound, upperBound] window.
//   • CatchUpPolicy — per-job replay policy (replay-all default + optional cap).
//   • JobsManager.reconcileMissedOccurrences() — for every active job, enumerate
//     missed occurrences since its last success, dedup against job_executions
//     (incl. a launchd wake-run), and enqueue into job_backlog (idempotent).
//   • JobsManager.drainBacklog() — serial single-flight worker: oldest pending
//     occurrence → claim → runCallback → record → next; resumes after a relaunch;
//     honors skip_on_battery; never double-fires (compare-and-set claim + the
//     job_backlog UNIQUE key + execution-window dedup).
//
// launchd only coalesces missed calendar times into AT MOST ONE wake-run, and
// only if the agent is loaded AND the SSE server is alive. The reconciler — not
// launchd — is therefore the real durability guarantee, especially when the Mac
// was fully OFF. Idempotency (UNIQUE(job_id, occurrence_ts) + the dedup window)
// is what makes the two coexist safely.

import Foundation
import MCP

// MARK: - Catch-up policy

/// Per-job catch-up policy. Default is REPLAY-ALL: every missed occurrence is
/// enqueued. An optional per-job cap bounds a pathological gap × frequent cron:
///   • .replayAll            — enqueue every missed occurrence (default).
///   • .maxLookback(seconds) — only occurrences newer than now-seconds.
///   • .coalesceToLatest     — collapse the whole missed set to its single most
///                             recent occurrence (one catch-up run).
public enum CatchUpPolicy: Sendable, Equatable {
    case replayAll
    case maxLookback(TimeInterval)
    case coalesceToLatest
}

// MARK: - Occurrence enumeration

/// Enumerates the concrete wall-clock instants at which a cron expression was
/// scheduled to fire within a half-open-then-closed window `(lowerBound, upperBound]`.
///
/// Correctness notes:
///   • DST/timezone: candidate instants are resolved from wall-clock
///     `DateComponents` through a `Calendar` pinned to a time zone (system by
///     default). `Calendar.date(from:)` maps a local wall-clock time to the
///     correct absolute instant, so a 02:30 slot that does not exist on a
///     spring-forward day resolves the way the OS scheduler would, and a 01:30
///     slot on a fall-back day is produced once (we de-dup identical instants).
///   • We iterate DAY BY DAY (not minute by minute) so a multi-month gap is
///     cheap, then within each matching day expand the interval's concrete
///     minute/hour set. A global `safetyCeiling` bounds the output so a
///     misconfigured schedule can never enumerate unbounded instants.
public enum JobOccurrenceEnumerator {

    /// Hard cap on enumerated occurrences for a single job in one reconcile pass.
    /// A daily job over ~5.5 years is ~2000 fires; 5000 covers extreme gaps while
    /// still bounding a runaway (e.g. an every-15-min job left off for months).
    public static let defaultSafetyCeiling = 5000

    public struct Result: Sendable, Equatable {
        public var occurrences: [Date]
        /// True if the safety ceiling clipped the set (caller should log).
        public var ceilingHit: Bool
    }

    /// Enumerate missed occurrences in `(lowerBound, upperBound]`.
    /// - Parameters:
    ///   - schedule: a 5-field cron expression (validated via CronParser).
    ///   - lowerBound: exclusive floor (typically last-success or job.createdAt).
    ///   - upperBound: inclusive ceiling (typically `now`).
    ///   - timeZone: the calendar time zone (defaults to the system zone; tests
    ///     pin an explicit zone to exercise a DST boundary deterministically).
    ///   - safetyCeiling: max occurrences returned.
    public static func enumerate(schedule: String,
                                 after lowerBound: Date,
                                 through upperBound: Date,
                                 timeZone: TimeZone = .current,
                                 safetyCeiling: Int = defaultSafetyCeiling) throws -> Result {
        guard upperBound > lowerBound else { return Result(occurrences: [], ceilingHit: false) }
        let intervals = try CronParser.parse(schedule)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        // Walk from the start-of-day of the lower bound to the upper bound.
        guard let startDay = cal.dateInterval(of: .day, for: lowerBound)?.start else {
            return Result(occurrences: [], ceilingHit: false)
        }

        var out: [Date] = []
        var seen = Set<Date>()
        var ceilingHit = false

        var day = startDay
        // Safety on the day loop itself: never iterate more than ~20 years of days.
        var dayGuard = 0
        let maxDays = 366 * 20

        while day <= upperBound && dayGuard < maxDays {
            dayGuard += 1
            let comps = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let year = comps.year, let month = comps.month,
                  let dom = comps.day, let weekdayApple = comps.weekday else {
                break
            }
            // Apple weekday: 1=Sunday…7=Saturday. Cron weekday: 0=Sunday…6=Saturday.
            let cronWeekday = weekdayApple - 1

            for iv in intervals {
                // Month filter (wildcard month matches every month).
                if let m = iv.month, m != month { continue }
                // Day-of-month vs weekday: cron semantics — if BOTH day and
                // weekday are constrained, a match on EITHER fires. If only one is
                // constrained, that one must match. (We mirror launchd/vixie-cron
                // behaviour for the common single-constraint schedules used here;
                // both-constrained is an OR.)
                let domConstrained = iv.day != nil
                let dowConstrained = iv.weekday != nil
                if domConstrained && dowConstrained {
                    if iv.day != dom && iv.weekday != cronWeekday { continue }
                } else if domConstrained {
                    if iv.day != dom { continue }
                } else if dowConstrained {
                    if iv.weekday != cronWeekday { continue }
                }

                // Expand the concrete hour/minute. nil = wildcard over the full range.
                let hours: [Int] = iv.hour.map { [$0] } ?? Array(0...23)
                let minutes: [Int] = iv.minute.map { [$0] } ?? Array(0...59)

                for h in hours {
                    for mnt in minutes {
                        var dc = DateComponents()
                        dc.year = year; dc.month = month; dc.day = dom
                        dc.hour = h; dc.minute = mnt; dc.second = 0
                        // Calendar.date(from:) is DST-correct: a non-existent
                        // spring-forward wall time yields the adjusted instant;
                        // a fall-back ambiguous time resolves deterministically.
                        guard let instant = cal.date(from: dc) else { continue }
                        if instant > lowerBound && instant <= upperBound {
                            if seen.insert(instant).inserted {
                                out.append(instant)
                                if out.count >= safetyCeiling {
                                    ceilingHit = true
                                }
                            }
                        }
                        if ceilingHit { break }
                    }
                    if ceilingHit { break }
                }
                if ceilingHit { break }
            }
            if ceilingHit { break }
            guard let nextDay = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }

        out.sort()
        if out.count > safetyCeiling {
            out = Array(out.prefix(safetyCeiling))
            ceilingHit = true
        }
        return Result(occurrences: out, ceilingHit: ceilingHit)
    }

    /// Apply a per-job catch-up policy to a sorted (ascending) occurrence list.
    public static func applyPolicy(_ policy: CatchUpPolicy,
                                   to occurrences: [Date],
                                   now: Date) -> [Date] {
        switch policy {
        case .replayAll:
            return occurrences
        case .maxLookback(let seconds):
            let floor = now.addingTimeInterval(-seconds)
            return occurrences.filter { $0 > floor }
        case .coalesceToLatest:
            return occurrences.last.map { [$0] } ?? []
        }
    }
}

// MARK: - Reconciler + serial drain (JobsManager)

extension JobsManager {

    /// Outcome of one reconcile pass — surfaced for logging/telemetry + tests.
    public struct ReconcileReport: Sendable, Equatable {
        public var enqueued: Int
        public var scannedJobs: Int
        public var ceilingHits: [String]   // job ids whose enumeration was clipped
        public init(enqueued: Int = 0, scannedJobs: Int = 0, ceilingHits: [String] = []) {
            self.enqueued = enqueued; self.scannedJobs = scannedJobs; self.ceilingHits = ceilingHits
        }
    }

    /// Global ceiling on total pending backlog rows across ALL jobs. Prevents a
    /// pathological set of schedules from collectively flooding the queue even if
    /// each individual job stays under its own per-job ceiling.
    public static let globalBacklogCeiling = 20000

    /// THE reconciler. For each active job:
    ///   1. floor = last successful execution, else job.createdAt.
    ///   2. enumerate missed occurrences in (floor, now], DST-correct.
    ///   3. apply the per-job catch-up policy (default replay-all).
    ///   4. for each occurrence, dedup against job_executions in a ±halfWindow
    ///      around the slot (covers a launchd wake-run for that slot), then
    ///      INSERT OR IGNORE into job_backlog (the UNIQUE key dedups re-runs).
    /// Idempotent: safe to call on launch AND on wake/heartbeat-online.
    @discardableResult
    public func reconcileMissedOccurrences(now: Date = Date(),
                                           policy: CatchUpPolicy = .replayAll,
                                           dedupHalfWindow: TimeInterval = 30 * 60,
                                           timeZone: TimeZone = .current) async -> ReconcileReport {
        var report = ReconcileReport()
        do {
            try await JobStore.shared.open()
            // Resume any rows a prior run left mid-flight before enqueuing more.
            _ = try await JobStore.shared.requeueStuckRunning()

            let jobs = try await JobStore.shared.listAll(statusFilter: .active)
            report.scannedJobs = jobs.count

            for job in jobs {
                // Respect the global ceiling — stop enqueuing once we hit it.
                let totalPending = try await JobStore.shared.pendingBacklogTotal()
                if totalPending >= Self.globalBacklogCeiling {
                    print("[JobsReconciler] global backlog ceiling \(Self.globalBacklogCeiling) reached — skipping remaining jobs")
                    break
                }

                let floor: Date = (try? await JobStore.shared.lastSuccessfulExecution(jobId: job.id))?.startedAt ?? job.createdAt

                let enumResult: JobOccurrenceEnumerator.Result
                do {
                    enumResult = try JobOccurrenceEnumerator.enumerate(schedule: job.schedule, after: floor, through: now, timeZone: timeZone)
                } catch {
                    // An unparseable / over-cap schedule should not abort the whole
                    // reconcile — log and skip just this job.
                    print("[JobsReconciler] skip job \(job.id): schedule enumeration failed: \(error)")
                    continue
                }
                if enumResult.ceilingHit { report.ceilingHits.append(job.id) }

                let occurrences = JobOccurrenceEnumerator.applyPolicy(policy, to: enumResult.occurrences, now: now)

                for occ in occurrences {
                    // Global ceiling guard inside the loop too.
                    if try await JobStore.shared.pendingBacklogTotal() >= Self.globalBacklogCeiling {
                        report.ceilingHits.append(job.id)
                        print("[JobsReconciler] global backlog ceiling reached mid-job \(job.id)")
                        break
                    }
                    // Dedup vs an execution launchd may already have produced for
                    // this slot (the single coalesced wake-run).
                    let lo = occ.addingTimeInterval(-dedupHalfWindow)
                    let hi = occ.addingTimeInterval(dedupHalfWindow)
                    if try await JobStore.shared.hasExecution(jobId: job.id, in: lo, hi) {
                        continue
                    }
                    let inserted = try await JobStore.shared.enqueueBacklog(jobId: job.id, occurrenceTs: occ, enqueuedAt: now)
                    if inserted { report.enqueued += 1 }
                }
            }
        } catch {
            print("[JobsReconciler] reconcile failed: \(error)")
        }
        if report.enqueued > 0 {
            print("[JobsReconciler] enqueued \(report.enqueued) missed occurrence(s) across \(report.scannedJobs) active job(s)")
            notifyJobsChanged()
        }
        return report
    }

    /// Outcome of a drain pass.
    public struct DrainReport: Sendable, Equatable {
        public var executed: Int
        public var skipped: Int
        public init(executed: Int = 0, skipped: Int = 0) {
            self.executed = executed; self.skipped = skipped
        }
    }

    /// SERIAL single-flight backlog drain. Processes the OLDEST pending occurrence
    /// to completion, then immediately picks the next — strictly one at a time,
    /// oldest-first. Because `JobsManager` is an actor, only one drain body runs
    /// at a time; the `draining` guard additionally prevents a re-entrant drain
    /// (e.g. a wake firing while a launch drain is mid-flight). Each row is claimed
    /// pending→running with a compare-and-set so a second caller can never grab the
    /// same row, and the actual run goes through `runCallback` which writes a
    /// job_executions row — that is the same path launchd uses, so the
    /// reconciler's execution-window dedup keeps them from double-firing.
    @discardableResult
    public func drainBacklog(router: ToolRouter? = nil, maxItems: Int = 10000) async -> DrainReport {
        var report = DrainReport()
        if draining { return report }   // re-entrancy guard (single-flight)
        draining = true
        defer { draining = false }

        if let router { self.router = router }
        guard let activeRouter = self.router else {
            print("[JobsReconciler] drain skipped: no router (bootstrap(router:) not called)")
            return report
        }

        do {
            try await JobStore.shared.open()
            var processed = 0
            while processed < maxItems {
                guard let item = try await JobStore.shared.nextPendingBacklog(), let rowId = item.id else {
                    break   // backlog drained
                }
                // Claim it (pending→running). If the CAS fails, another path took
                // it; skip and continue.
                let claimed = try await JobStore.shared.setBacklogStatus(id: rowId, to: .running, expecting: .pending)
                if !claimed { continue }
                processed += 1

                do {
                    let result = try await runCallback(jobId: item.jobId, router: activeRouter)
                    // runCallback already recorded a job_executions row (incl. a
                    // .skipped row for paused / low-power). Mark the backlog row
                    // done either way — the occurrence has been accounted for.
                    if case .object(let o) = result, case .string? = o["skipped"] {
                        report.skipped += 1
                    } else {
                        report.executed += 1
                    }
                    _ = try await JobStore.shared.setBacklogStatus(id: rowId, to: .done, expecting: .running)
                } catch JobsModuleError.jobNotFound {
                    // Job was deleted out from under us — drop the orphan row.
                    _ = try await JobStore.shared.setBacklogStatus(id: rowId, to: .skipped, expecting: .running)
                    report.skipped += 1
                } catch {
                    // Execution error: the failure is recorded by runCallback's
                    // own ledger write where it reached it; mark the backlog row
                    // done so the serial drain advances (no infinite retry loop).
                    print("[JobsReconciler] drain item \(item.jobId)@\(item.occurrenceTs) failed: \(error)")
                    _ = try await JobStore.shared.setBacklogStatus(id: rowId, to: .done, expecting: .running)
                }
            }
        } catch {
            print("[JobsReconciler] drain failed: \(error)")
        }
        if report.executed > 0 || report.skipped > 0 {
            notifyJobsChanged()
        }
        return report
    }

    /// Convenience: reconcile then drain. This is the single entry point the app
    /// calls on launch and on wake/heartbeat-online.
    @discardableResult
    public func reconcileAndDrain(router: ToolRouter? = nil,
                                  now: Date = Date(),
                                  policy: CatchUpPolicy = .replayAll,
                                  timeZone: TimeZone = .current) async -> (ReconcileReport, DrainReport) {
        if let router { self.router = router }
        let r = await reconcileMissedOccurrences(now: now, policy: policy, timeZone: timeZone)
        let d = await drainBacklog(router: self.router)
        return (r, d)
    }
}
