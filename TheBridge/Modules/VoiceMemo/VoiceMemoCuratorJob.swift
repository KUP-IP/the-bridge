// VoiceMemoCuratorJob.swift — Morning Voice Memos curator (9:00 daily)
// TheBridge · Modules · VoiceMemo
//
// Seeds a single-step job that calls `voice_memo_process` in batch mode.
// Default: PAUSED — operator runs via Jobs UI / job_run until go-live, then job_resume.
// Idempotent — never clobbers operator edits (mirrors RunningReportJob).

import Foundation
import MCP

public enum VoiceMemoCuratorJob {

    public static let jobId = "voice-memo-curator"
    public static let jobName = "Morning Voice Memos curator"
    public static let defaultSchedule = "0 9 * * *"

    public static func defaultActionChain(dryRun: Bool = false, minConfidence: Double = 0.85) -> [ActionStep] {
        [
            ActionStep(
                tool: "voice_memo_process",
                arguments: [
                    "mode": .string("batch"),
                    "dryRun": .bool(dryRun),
                    "minConfidence": .double(minConfidence),
                ],
                onFail: .stop
            ),
        ]
    }

    public static func defaultJobRecord(now: Date = Date(), dryRun: Bool = false, active: Bool = false) -> JobRecord {
        JobRecord(
            id: jobId,
            name: jobName,
            schedule: defaultSchedule,
            actionChain: defaultActionChain(dryRun: dryRun),
            status: active ? .active : .paused,
            skipOnBattery: false,
            createdAt: now,
            updatedAt: now
        )
    }
}

extension VoiceMemoCuratorJob {
    public typealias LaunchAgentInstaller = RunningReportJob.LaunchAgentInstaller
}

extension JobsManager {

    @discardableResult
    public func seedVoiceMemoCuratorJobIfNeeded(
        dryRun: Bool = false,
        active: Bool = false,
        installLaunchAgent: VoiceMemoCuratorJob.LaunchAgentInstaller = RunningReportJob.realLaunchAgentInstaller
    ) async -> Bool {
        do {
            try await JobStore.shared.open()
            if try await JobStore.shared.fetch(id: VoiceMemoCuratorJob.jobId) != nil {
                return false
            }
            let job = VoiceMemoCuratorJob.defaultJobRecord(dryRun: dryRun, active: active)
            for step in job.actionChain {
                try Self.validateUnattended(tool: step.tool, args: step.arguments)
            }
            try await JobStore.shared.insert(job)
            if job.status == .active {
                let intervals = try CronParser.parse(job.schedule)
                do {
                    try installLaunchAgent(job.id, intervals)
                } catch {
                    try? await JobStore.shared.delete(id: job.id)
                    try? LaunchAgentPlist.remove(jobId: job.id)
                    print("[VoiceMemoCuratorJob] launch-agent install failed, rolled back seed: \(error)")
                    return false
                }
            }
            let mode = job.status == .active ? "active" : "paused (manual job_run until go-live)"
            print("[VoiceMemoCuratorJob] seeded '\(VoiceMemoCuratorJob.jobName)' (\(VoiceMemoCuratorJob.defaultSchedule)) — \(mode)")
            notifyJobsChanged()
            return true
        } catch {
            print("[VoiceMemoCuratorJob] seed failed: \(error)")
            return false
        }
    }
}
