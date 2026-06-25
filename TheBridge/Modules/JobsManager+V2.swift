// JobsManager+V2.swift — Jobs Surface v1.10.0 high-level tool handlers
// TheBridge · Modules
//
// Adds: runNow, updateJob, duplicateJob, exportJobs, importJobs, pauseAll, resumeAll.
// The low-level `JobStore.update(id:mutate:)` and `JobsManager.router_()` accessors
// live in JobsManager.swift (patched inline).
//
// Scope: Packet SEQ 14. No behavioral changes to pre-existing tool handlers.

import Foundation
import MCP

// MARK: - Portable JSON envelope for export/import

public struct JobExportEnvelope: Codable, Sendable {
    public let version: Int
    public let exportedAt: Date
    public let jobs: [JobRecord]

    public init(jobs: [JobRecord], version: Int = 1, exportedAt: Date = Date()) {
        self.version = version
        self.exportedAt = exportedAt
        self.jobs = jobs
    }
}

// MARK: - JobsManager v1.10.0 tool handlers

extension JobsManager {

    // MARK: job_run

    public func runNowTool(args: Value) async throws -> Value {
        guard case .object(let o) = args, case .string(let id)? = o["id"] else {
            throw JobsModuleError.invalidActionChain("missing required arg 'id'")
        }
        guard let router = self.router_() else {
            throw JobsModuleError.launchAgentFailure("router unavailable — JobsManager.bootstrap(router:) must be called at app startup before job_run")
        }
        return try await runCallback(jobId: id, router: router, allowPaused: true)
    }

    // MARK: job_update

    public func updateJobTool(args: Value) async throws -> Value {
        guard case .object(let obj) = args, case .string(let id)? = obj["id"] else {
            throw JobsModuleError.invalidActionChain("missing required arg 'id'")
        }
        guard let current = try await JobStore.shared.fetch(id: id) else {
            throw JobsModuleError.jobNotFound(id)
        }

        var newName = current.name
        if case .string(let s)? = obj["name"] { newName = s }

        var newSchedule = current.schedule
        var scheduleChanged = false
        if case .string(let s)? = obj["schedule"] {
            newSchedule = s
            scheduleChanged = (s != current.schedule)
        }

        var newChain = current.actionChain
        if case .array(let arr)? = obj["actions"] {
            guard !arr.isEmpty, arr.count <= 10 else {
                throw JobsModuleError.invalidActionChain("actions must contain 1–10 steps")
            }
            newChain = try arr.map { v -> ActionStep in
                guard case .object(let step) = v else {
                    throw JobsModuleError.invalidActionChain("each action must be an object")
                }
                guard case .string(let rawTool)? = step["tool"] else {
                    throw JobsModuleError.invalidActionChain("action missing 'tool'")
                }
                let tool = JobsManager.canonicalActionToolName(rawTool)
                var argsMap: [String: JSONValue] = [:]
                if case .object(let a)? = step["arguments"] {
                    for (k, vv) in a { argsMap[k] = JSONValue.fromMCP(vv) }
                }
                let onFail: ActionStep.OnFail = {
                    if case .string(let s)? = step["onFail"],
                       let p = ActionStep.OnFail(rawValue: s) { return p }
                    return .stop
                }()
                try JobsManager.validateUnattended(tool: tool, args: argsMap)
                return ActionStep(tool: tool, arguments: argsMap, onFail: onFail)
            }
        }

        var newSkipBattery = current.skipOnBattery
        if case .bool(let b)? = obj["skipOnBattery"] { newSkipBattery = b }

        // Validate new schedule up front if it changed — cheap, pre-persist.
        var newIntervals: [CronParser.CalendarInterval]? = nil
        if scheduleChanged {
            newIntervals = try CronParser.parse(newSchedule)
        }

        // Persist DB change.
        let updated = try await JobStore.shared.update(id: id) { rec in
            var next = rec
            next.name = newName
            next.schedule = newSchedule
            next.actionChain = newChain
            next.skipOnBattery = newSkipBattery
            return next
        }

        // Re-register LaunchAgent if schedule changed and job is active.
        if scheduleChanged, let intervals = newIntervals, current.status == .active {
            try? LaunchAgentLifecycle.unregister(jobId: id)
            let plist = LaunchAgentPlist.build(jobId: id, intervals: intervals, ssePort: JobsManager.sseServerPort)
            do {
                try LaunchAgentPlist.write(jobId: id, plist: plist)
                try LaunchAgentLifecycle.register(jobId: id)
            } catch {
                // Roll back DB to previous schedule, attempt to restore old LaunchAgent.
                _ = try? await JobStore.shared.update(id: id) { rec in
                    var r = rec; r.schedule = current.schedule; return r
                }
                if let oldIntervals = try? CronParser.parse(current.schedule) {
                    let oldPlist = LaunchAgentPlist.build(jobId: id, intervals: oldIntervals, ssePort: JobsManager.sseServerPort)
                    try? LaunchAgentPlist.write(jobId: id, plist: oldPlist)
                    try? LaunchAgentLifecycle.register(jobId: id)
                }
                throw JobsModuleError.launchAgentFailure("schedule update rolled back: \(error)")
            }
        }

        notifyJobsChanged()
        return .object([
            "updated": .string(updated.id),
            "name": .string(updated.name),
            "schedule": .string(updated.schedule),
            "skipOnBattery": .bool(updated.skipOnBattery),
            "steps": .int(updated.actionChain.count),
            "scheduleChanged": .bool(scheduleChanged)
        ])
    }

    // MARK: job_duplicate

    public func duplicateJobTool(args: Value) async throws -> Value {
        guard case .object(let obj) = args, case .string(let id)? = obj["id"] else {
            throw JobsModuleError.invalidActionChain("missing required arg 'id'")
        }
        guard let source = try await JobStore.shared.fetch(id: id) else {
            throw JobsModuleError.jobNotFound(id)
        }
        var nameSuffix = " (copy)"
        if case .string(let s)? = obj["nameSuffix"] { nameSuffix = s }

        let clone = JobRecord(
            name: source.name + nameSuffix,
            schedule: source.schedule,
            actionChain: source.actionChain,
            status: .active,
            skipOnBattery: source.skipOnBattery
        )
        let intervals = try CronParser.parse(clone.schedule)
        try await JobStore.shared.insert(clone)
        let plist = LaunchAgentPlist.build(jobId: clone.id, intervals: intervals, ssePort: JobsManager.sseServerPort)
        do {
            try LaunchAgentPlist.write(jobId: clone.id, plist: plist)
            try LaunchAgentLifecycle.register(jobId: clone.id)
        } catch {
            try? await JobStore.shared.delete(id: clone.id)
            try? LaunchAgentPlist.remove(jobId: clone.id)
            throw JobsModuleError.launchAgentFailure("\(error)")
        }
        notifyJobsChanged()
        return .object([
            "id": .string(clone.id),
            "name": .string(clone.name),
            "sourceId": .string(source.id)
        ])
    }

    // MARK: job_export

    public func exportJobsTool(args: Value) async throws -> Value {
        var ids: [String]? = nil
        if case .object(let o) = args, case .array(let arr)? = o["ids"] {
            ids = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        let all = try await JobStore.shared.listAll(statusFilter: nil)
        let subset: [JobRecord]
        if let ids, !ids.isEmpty {
            let set = Set(ids)
            subset = all.filter { set.contains($0.id) }
        } else {
            subset = all
        }
        let envelope = JobExportEnvelope(jobs: subset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return .object([
            "count": .int(subset.count),
            "json": .string(json)
        ])
    }

    // MARK: job_import

    public func importJobsTool(args: Value) async throws -> Value {
        guard case .object(let obj) = args, case .string(let json)? = obj["json"] else {
            throw JobsModuleError.invalidActionChain("missing required arg 'json'")
        }
        guard let data = json.data(using: .utf8) else {
            throw JobsModuleError.invalidActionChain("invalid UTF-8 in json")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: JobExportEnvelope
        do {
            envelope = try decoder.decode(JobExportEnvelope.self, from: data)
        } catch {
            throw JobsModuleError.invalidActionChain("decode failed: \(error)")
        }

        var imported = 0
        var skipped: [String] = []
        var createdIds: [String] = []

        for job in envelope.jobs {
            let fresh = JobRecord(
                name: job.name,
                schedule: job.schedule,
                actionChain: job.actionChain,
                status: .active,
                skipOnBattery: job.skipOnBattery
            )
            do {
                let intervals = try CronParser.parse(fresh.schedule)
                try await JobStore.shared.insert(fresh)
                let plist = LaunchAgentPlist.build(jobId: fresh.id, intervals: intervals, ssePort: JobsManager.sseServerPort)
                try LaunchAgentPlist.write(jobId: fresh.id, plist: plist)
                try LaunchAgentLifecycle.register(jobId: fresh.id)
                imported += 1
                createdIds.append(fresh.id)
            } catch {
                try? await JobStore.shared.delete(id: fresh.id)
                try? LaunchAgentPlist.remove(jobId: fresh.id)
                skipped.append("\(job.name): \(error)")
            }
        }

        if imported > 0 { notifyJobsChanged() }
        return .object([
            "imported": .int(imported),
            "skipped": .int(skipped.count),
            "skippedReasons": .array(skipped.map { .string($0) }),
            "newIds": .array(createdIds.map { .string($0) })
        ])
    }

    // MARK: jobs_pause_all / jobs_resume_all

    public func pauseAllTool(args: Value) async throws -> Value {
        let all = try await JobStore.shared.listAll(statusFilter: .active)
        var paused = 0
        var failedIds: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for job in all {
                group.addTask {
                    do {
                        try LaunchAgentLifecycle.unregister(jobId: job.id)
                        try await JobStore.shared.updateStatus(id: job.id, status: .paused)
                        return (job.id, true)
                    } catch {
                        return (job.id, false)
                    }
                }
            }
            for await (id, ok) in group {
                if ok { paused += 1 } else { failedIds.append(id) }
            }
        }
        if paused > 0 { notifyJobsChanged() }
        return .object([
            "paused": .int(paused),
            "failed": .int(failedIds.count),
            "failedIds": .array(failedIds.map { .string($0) })
        ])
    }

    public func resumeAllTool(args: Value) async throws -> Value {
        let all = try await JobStore.shared.listAll(statusFilter: .paused)
        var resumed = 0
        var failedIds: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for job in all {
                group.addTask {
                    do {
                        try LaunchAgentLifecycle.register(jobId: job.id)
                        try await JobStore.shared.updateStatus(id: job.id, status: .active)
                        return (job.id, true)
                    } catch {
                        return (job.id, false)
                    }
                }
            }
            for await (id, ok) in group {
                if ok { resumed += 1 } else { failedIds.append(id) }
            }
        }
        if resumed > 0 { notifyJobsChanged() }
        return .object([
            "resumed": .int(resumed),
            "failed": .int(failedIds.count),
            "failedIds": .array(failedIds.map { .string($0) })
        ])
    }
}
