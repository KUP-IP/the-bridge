// JobsModule.swift — Job Scheduling MCP Tools
// NotionBridge · Modules
//
// History:
//   PKT-340 (v1.9.0) — Initial 8 tools (create/get/list/delete/pause/resume/history/templates).
//   Jobs UI v1.10.0 — +7 tools (run/update/duplicate/export/import/pause_all/resume_all).
//                      Total: 15 scheduler tools.
//
// Tier assignments:
//   job_create, job_delete, job_update, job_duplicate, job_run, job_import → .notify (mutating)
//   job_get, job_list, job_pause, job_resume, job_history, job_templates,
//   job_export → .open (read)

import Foundation
import MCP

public enum JobsModule {
    public static let moduleName = "scheduler"

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        // v1.9.0 tools
        await router.register(makeJobCreate())
        await router.register(makeJobGet())
        await router.register(makeJobList())
        await router.register(makeJobDelete())

        await router.register(makeJobPause())
        await router.register(makeJobResume())

        await router.register(makeJobHistory())
        await router.register(makeJobTemplates())
        // v1.10.0 tools
        await router.register(makeJobRun())
        await router.register(makeJobUpdate())
        await router.register(makeJobDuplicate())
        await router.register(makeJobExport())
        await router.register(makeJobImport())
    }

    // MARK: - v1.9.0 tool factories

    private static func makeJobCreate() -> ToolRegistration {
        ToolRegistration(
            name: "job_create",
            module: moduleName,
            tier: .notify,
            description: "Create a scheduled job: 5-field cron + action chain (≤10 steps) with $prev_result templating between steps. Registers a LaunchAgent.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("schedule"), .string("actions")]),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                    "schedule": .object(["type": .string("string")]),
                    "actions": .object([
                        "type": .string("array"),
                        "maxItems": .int(10),
                        "items": .object(["type": .string("object")])
                    ]),
                    "skipOnBattery": .object(["type": .string("boolean"), "default": .bool(false)])
                ])
            ]),
            handler: { args in try await JobsManager.shared.createJob(args: args) }
        )
    }

    private static func makeJobGet() -> ToolRegistration {
        ToolRegistration(
            name: "job_get", module: moduleName, tier: .open,
            description: "Fetch one job by ID, including its last 10 executions.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object(["id": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.getJob(args: args) }
        )
    }

    private static func makeJobList() -> ToolRegistration {
        ToolRegistration(
            name: "job_list", module: moduleName, tier: .open,
            description: "List every scheduled job (active + paused) with summary metadata.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { args in try await JobsManager.shared.listJobs(args: args) }
        )
    }

    private static func makeJobDelete() -> ToolRegistration {
        ToolRegistration(
            name: "job_delete", module: moduleName, tier: .notify,
            description: "Permanently delete a job: unregister LaunchAgent, remove plist, drop DB record (cascades execution history). Irreversible.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object(["id": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.deleteJob(args: args) }
        )
    }

    private static func makeJobPause() -> ToolRegistration {
        ToolRegistration(
            name: "job_pause", module: moduleName, tier: .open,
            description: "Pause one job: unregister its LaunchAgent but keep DB record + plist. Reversible via job_resume. Sprint A · mcp-builder #3: pass all:true to pause every active job in parallel (kill-switch — replaces deprecated jobs_pause_all). id and all:true are mutually exclusive.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id":  .object(["type": .string("string"),  "description": .string("Job id to pause (mutually exclusive with all:true).")]),
                    "all": .object(["type": .string("boolean"), "description": .string("Pause every active job (kill-switch). Default false.")])
                ])
            ]),
            handler: { args in
                if case .object(let dict) = args, case .bool(true) = dict["all"] {
                    return try await JobsManager.shared.pauseAllTool(args: args)
                }
                return try await JobsManager.shared.pauseJob(args: args)
            }
        )
    }

    private static func makeJobResume() -> ToolRegistration {
        ToolRegistration(
            name: "job_resume", module: moduleName, tier: .open,
            description: "Resume one paused job by re-registering its LaunchAgent. Sprint A · mcp-builder #3: pass all:true to resume every paused job (replaces deprecated jobs_resume_all). id and all:true are mutually exclusive.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id":  .object(["type": .string("string"),  "description": .string("Job id to resume (mutually exclusive with all:true).")]),
                    "all": .object(["type": .string("boolean"), "description": .string("Resume every paused job. Default false.")])
                ])
            ]),
            handler: { args in
                if case .object(let dict) = args, case .bool(true) = dict["all"] {
                    return try await JobsManager.shared.resumeAllTool(args: args)
                }
                return try await JobsManager.shared.resumeJob(args: args)
            }
        )
    }

    private static func makeJobHistory() -> ToolRegistration {
        ToolRegistration(
            name: "job_history", module: moduleName, tier: .open,
            description: "Return the last N execution records for one job (default 20, max 200).",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer"), "default": .int(20), "maximum": .int(200)])
                ])
            ]),
            handler: { args in try await JobsManager.shared.jobHistory(args: args) }
        )
    }

    private static func makeJobTemplates() -> ToolRegistration {
        ToolRegistration(
            name: "job_templates", module: moduleName, tier: .open,
            description: "List built-in job presets (cron + action-chain starters) for common workflows.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { args in try await JobsManager.shared.listTemplates(args: args) }
        )
    }

    // MARK: - v1.10.0 tool factories

    private static func makeJobRun() -> ToolRegistration {
        ToolRegistration(
            name: "job_run", module: moduleName, tier: .notify,
            description: "Fire a job now, bypassing its cron schedule. Does not modify the schedule itself.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object(["id": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.runNowTool(args: args) }
        )
    }

    private static func makeJobUpdate() -> ToolRegistration {
        ToolRegistration(
            name: "job_update", module: moduleName, tier: .notify,
            description: "Patch a job's name, cron schedule, action chain, or skipOnBattery. Schedule changes re-register the LaunchAgent atomically (rollback on failure).",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "schedule": .object(["type": .string("string")]),
                    "actions": .object(["type": .string("array"), "maxItems": .int(10), "items": .object(["type": .string("object")])]),
                    "skipOnBattery": .object(["type": .string("boolean")])
                ])
            ]),
            handler: { args in try await JobsManager.shared.updateJobTool(args: args) }
        )
    }

    private static func makeJobDuplicate() -> ToolRegistration {
        ToolRegistration(
            name: "job_duplicate", module: moduleName, tier: .notify,
            description: "Clone a job with a fresh ID and its own LaunchAgent. Optional nameSuffix (default ' (copy)').",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "nameSuffix": .object(["type": .string("string")])
                ])
            ]),
            handler: { args in try await JobsManager.shared.duplicateJobTool(args: args) }
        )
    }

    private static func makeJobExport() -> ToolRegistration {
        ToolRegistration(
            name: "job_export", module: moduleName, tier: .open,
            description: "Export all jobs (or a subset by ids) as a portable JSON envelope {version, exportedAt, jobs[]}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "ids": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
                ])
            ]),
            handler: { args in try await JobsManager.shared.exportJobsTool(args: args) }
        )
    }

    private static func makeJobImport() -> ToolRegistration {
        ToolRegistration(
            name: "job_import", module: moduleName, tier: .notify,
            description: "Import jobs from a JSON envelope produced by job_export. IDs are regenerated to avoid collisions; returns imported vs. skipped counts.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("json")]),
                "properties": .object(["json": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.importJobsTool(args: args) }
        )
    }

}

// MARK: - Errors

public enum JobsModuleError: Error, CustomStringConvertible {
    case notImplemented(String)
    case invalidSchedule(String)
    case invalidActionChain(String)
    case jobNotFound(String)
    case storageFailure(String)
    case launchAgentFailure(String)

    public var description: String {
        switch self {
        case .notImplemented(let what): return "Not yet implemented: \(what)"
        case .invalidSchedule(let s): return "Invalid cron schedule: \(s)"
        case .invalidActionChain(let s): return "Invalid action chain: \(s)"
        case .jobNotFound(let id): return "Job not found: \(id)"
        case .storageFailure(let s): return "Job storage error: \(s)"
        case .launchAgentFailure(let s): return "LaunchAgent error: \(s)"
        }
    }
}
