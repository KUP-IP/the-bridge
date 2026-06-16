// RunningReportJob.swift — PKT-1004 Wave 4 (Scheduler Resilience · first job)
// NotionBridge · Modules
//
// The "first live job": a daily morning running-performance report delivered to
// the operator via iMessage-to-self. This is the proof-of-life for the durable
// scheduler — once the on-device sleep/wake + force-quit verification (Wave 5,
// operator-gated) confirms a missed 06:00 slot is recovered on reconnect, this
// job is the visible payload that gets replayed.
//
// SCOPE / HONESTY CONTRACT (per the packet's hard guardrail "do NOT fabricate
// Strava metrics or invent a data path"):
//   • The Bridge has NO server-side Strava / HealthKit data path today (verified
//     reconnaissance — there is no in-process fitness connector, no Strava
//     credential store). This job therefore SCAFFOLDS the report + the delivery
//     and marks the data-source wiring as OPERATOR-PENDING. It does not invent
//     mileage or pace numbers.
//   • The DEFAULT metric set is the sensible one the packet specified — latest
//     run + trailing-7-day mileage + pace vs the prior week — laid out as a
//     template the report-builder step prints. The selection is intentionally
//     easy to change (edit the one builder step) and is FLAGGED for operator
//     confirmation, not blocking.
//   • Delivery is iMessage-to-self (the ratified decision). Because there is no
//     "self" handle alias in the Messages tool, the recipient is seeded as a
//     clearly-marked placeholder the operator replaces with their own handle.
//     The send step uses onFail:.continue so an un-wired placeholder produces a
//     recorded (failed) send rather than aborting — the report itself always
//     builds. The job is ACTIVE so Run-now works and launchd schedules it;
//     until the operator wires the handle + Strava source it is a safe no-harm
//     fire (a notification-style report that says "operator: wire your data").
//
// The seeder is idempotent: it inserts the job at a STABLE id exactly once and
// never clobbers later operator edits (schedule, recipient, metric set).

import Foundation
import MCP

/// Builds + seeds the first running-report job. Pure builders are `static` so
/// they are unit-testable without touching the store or launchd.
public enum RunningReportJob {

    /// Stable id so the seeder is idempotent — re-running bootstrap never creates
    /// a duplicate, and an operator who edits the job keeps their changes.
    public static let jobId = "first-job-running-report"
    public static let jobName = "Morning running report"
    /// Packet default schedule: 06:00 daily, local time (matches launchd firing).
    public static let defaultSchedule = "0 6 * * *"

    /// The recipient placeholder the operator must replace with their own handle
    /// (phone or Apple ID email) to enable iMessage-to-self delivery. Kept
    /// obviously-fake so a stray fire can never message a real contact and so the
    /// Jobs UI surfaces it as clearly needing attention.
    public static let selfHandlePlaceholder = "REPLACE_WITH_YOUR_IMESSAGE_HANDLE"

    /// The default metric set, surfaced for operator confirmation. Changing the
    /// report = editing the single `reportBuilderScript` below.
    public static let defaultMetricSet = "latest run · trailing-7-day mileage · pace vs prior week"

    /// The report-builder step's shell script. It prints an HONEST scaffold: the
    /// intended metric layout with placeholder values and an explicit
    /// operator-pending banner for the Strava data source. NO fabricated numbers.
    /// When the operator wires a data source, they replace this one step (e.g.
    /// with an `http_fetch` of their Strava activities + a formatter) — the
    /// delivery step downstream is unchanged because it reads `$prev_result`.
    static let reportBuilderScript = """
    cat <<'REPORT'
    🏃 Morning Running Report — $(date '+%a %b %-d')

    Latest run:        (operator: wire data source)
    7-day mileage:     (operator: wire data source)
    Pace vs last week: (operator: wire data source)

    ⚠️ Data source not yet connected. This is the Bridge's first scheduled job
    (scheduler-resilience proof-of-life). To turn it into a real report:
      1. Replace this step with a fetch of your running data
         (e.g. http_fetch of the Strava activities API), and
      2. Set the messages_send recipient to your own iMessage handle.
    Metric set (default): latest run · trailing-7-day mileage · pace vs prior week
    REPORT
    """

    /// The default action chain: build the report text, then deliver it as an
    /// iMessage. Step 2 reads `$prev_result` (the report builder's stdout).
    public static func defaultActionChain(recipient: String = selfHandlePlaceholder) -> [ActionStep] {
        [
            // Step 0 — build the running summary text (honest scaffold).
            ActionStep(
                tool: "shell_exec",
                arguments: ["command": .string(reportBuilderScript)],
                onFail: .stop
            ),
            // Step 1 — deliver via iMessage to self. confirm:"SEND" is the
            // unattended gate; recipient is the operator-pending placeholder.
            // onFail:.continue so an un-wired handle records a failed send
            // instead of aborting the (already-built) report.
            ActionStep(
                tool: "messages_send",
                arguments: [
                    "recipient": .string(recipient),
                    "body": .string("$prev_result"),
                    "confirm": .string("SEND")
                ],
                onFail: .continue
            )
        ]
    }

    /// The seeded JobRecord (active, default schedule, default chain).
    public static func defaultJobRecord(now: Date = Date()) -> JobRecord {
        JobRecord(
            id: jobId,
            name: jobName,
            schedule: defaultSchedule,
            actionChain: defaultActionChain(),
            status: .active,
            skipOnBattery: false,
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - Idempotent seeding (JobsManager)

extension RunningReportJob {
    /// Install (write plist + register the LaunchAgent) for a seeded job. The
    /// default is the real launchd path; tests inject a no-op so seeding stays
    /// hermetic (no real plist written to ~/Library/LaunchAgents, no launchctl).
    /// `Sendable` so it can cross the actor boundary cleanly.
    public typealias LaunchAgentInstaller = @Sendable (_ jobId: String, _ intervals: [CronParser.CalendarInterval]) throws -> Void

    /// The production installer: build → write → register the LaunchAgent.
    public static let realLaunchAgentInstaller: LaunchAgentInstaller = { jobId, intervals in
        let plist = LaunchAgentPlist.build(jobId: jobId, intervals: intervals, ssePort: JobsManager.ssePort)
        try LaunchAgentPlist.write(jobId: jobId, plist: plist)
        try LaunchAgentLifecycle.register(jobId: jobId)
    }
}

extension JobsManager {

    /// Seed the first running-report job exactly once. Idempotent: if a job with
    /// the stable id already exists (including one the operator has edited), this
    /// is a no-op. Inserts the JobRecord AND installs its launchd LaunchAgent so
    /// it appears in the Jobs UI, supports Run-now, and fires on schedule.
    ///
    /// Failure to install the launch agent is non-fatal: the DB row is rolled
    /// back and the seed is simply retried on the next bootstrap (so a transient
    /// launchd hiccup never leaves a half-seeded job).
    ///
    /// - Parameter installLaunchAgent: dependency seam — defaults to the real
    ///   launchd installer; tests pass a no-op (and skip launchd) via
    ///   `installLaunchAgent: { _, _ in }`.
    @discardableResult
    public func seedRunningReportJobIfNeeded(
        installLaunchAgent: RunningReportJob.LaunchAgentInstaller = RunningReportJob.realLaunchAgentInstaller
    ) async -> Bool {
        do {
            try await JobStore.shared.open()
            if try await JobStore.shared.fetch(id: RunningReportJob.jobId) != nil {
                return false   // already seeded (or operator-edited) — never clobber
            }
            let job = RunningReportJob.defaultJobRecord()

            // Validate the chain through the same unattended gate the public
            // createJob path uses, so the seed can never ship a chain the runtime
            // would reject.
            for step in job.actionChain {
                try JobsManager.validateUnattended(tool: step.tool, args: step.arguments)
            }
            let intervals = try CronParser.parse(job.schedule)

            try await JobStore.shared.insert(job)
            do {
                try installLaunchAgent(job.id, intervals)
            } catch {
                // Roll back so the next bootstrap retries cleanly.
                try? await JobStore.shared.delete(id: job.id)
                try? LaunchAgentPlist.remove(jobId: job.id)
                print("[RunningReportJob] launch-agent install failed, rolled back seed: \(error)")
                return false
            }
            print("[RunningReportJob] seeded first job '\(RunningReportJob.jobName)' (\(RunningReportJob.defaultSchedule)) — recipient + Strava source are operator-pending")
            notifyJobsChanged()
            return true
        } catch {
            print("[RunningReportJob] seed failed: \(error)")
            return false
        }
    }
}
