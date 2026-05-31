// BgProcessModule.swift – PKT-744 W1: bg_process_* tool registrations
// NotionBridge · Modules · dev/
//
// Five tools that wrap BgProcessRuntime as the public MCP surface:
//   - bg_process_start  : spawn detached child in its own process group
//   - bg_process_status : read meta.json for one job
//   - bg_process_logs   : paginated tail of stdout/stderr (cursor + n)
//   - bg_process_kill   : SIGTERM → 5s grace → SIGKILL on the process group
//   - bg_process_list   : enumerate jobs with optional status filter
//
// All five are tier .request (require user approval) because spawning
// detached processes is a privileged operation. Capability detection emits
// `capability_missing` if the runtime cannot prepare its base directory.

import Foundation
import MCP

public enum BgProcessModule {

    public static let moduleName = "dev"

    /// Register all 5 dev/bg_process_* tools on the given router. Pass a
    /// custom runtime (e.g., for tests with a temp baseDir); defaults to the
    /// shared singleton used by the production app.
    public static func register(
        on router: ToolRouter,
        runtime: BgProcessRuntime = BgProcessRuntime.shared
    ) async {

        // MARK: bg_process_start
        await router.register(ToolRegistration(
            name: "bg_process_start",
            module: moduleName,
            tier: .request,
            description: "Spawn a long-running shell command as a detached child process in its own POSIX process group. Returns a job id immediately; use bg_process_status / bg_process_logs / bg_process_list to monitor and bg_process_kill to terminate. Stdout/stderr are streamed to per-job log files at ~/Library/Application Support/NotionBridge/jobs/<id>/. Use this instead of `shell_exec` for builds/migrations/dev servers/test runners that exceed shell_exec's request timeout, or any work where the agent should keep iterating while the process runs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("Shell command to run via /bin/bash -c.")
                    ]),
                    "workingDir": .object([
                        "type": .string("string"),
                        "description": .string("Optional working directory (tilde-expanded).")
                    ]),
                    "env": .object([
                        "type": .string("object"),
                        "description": .string("Optional env vars (string values) merged onto the bridge process environment.")
                    ]),
                    "label": .object([
                        "type": .string("string"),
                        "description": .string("Optional human label (e.g. 'devserver', 'lsp', 'cursor-sidecar') for filtering bg_process_list.")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let command) = args["command"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "bg_process_start",
                        reason: "missing required 'command' parameter"
                    )
                }
                let workingDir: String? = {
                    if case .string(let s) = args["workingDir"] { return s }
                    return nil
                }()
                var envDict: [String: String] = [:]
                if case .object(let envArgs) = args["env"] {
                    for (k, v) in envArgs {
                        if case .string(let s) = v { envDict[k] = s }
                    }
                }
                let label: String? = {
                    if case .string(let s) = args["label"] { return s }
                    return nil
                }()

                do {
                    let meta = try await runtime.start(
                        command: command, workingDir: workingDir,
                        env: envDict, label: label
                    )
                    return jobMetaToValue(meta, includeOK: true)
                } catch let e as BgProcessError {
                    return errorValue("bg_process_start", e)
                }
            }
        ))

        // MARK: bg_process_status
        await router.register(ToolRegistration(
            name: "bg_process_status",
            module: moduleName,
            tier: .request,
            description: "Return the current meta (status, pid, pgid, exitCode, killSignal, timestamps) for one job by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Job id returned by bg_process_start.")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let id) = args["id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "bg_process_status",
                        reason: "missing required 'id' parameter"
                    )
                }
                do {
                    let meta = try await runtime.status(id: id)
                    return jobMetaToValue(meta, includeOK: true)
                } catch let e as BgProcessError {
                    return errorValue("bg_process_status", e)
                }
            }
        ))

        // MARK: bg_process_logs
        await router.register(ToolRegistration(
            name: "bg_process_logs",
            module: moduleName,
            tier: .request,
            description: "Read a paginated chunk of stdout or stderr for one job. Pass cursor=0 (or omit) for the start; pass nextCursor from the previous page to continue. eof=true when the job is terminal AND the cursor reached totalBytes.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Job id returned by bg_process_start.")
                    ]),
                    "stream": .object([
                        "type": .string("string"),
                        "description": .string("'stdout' or 'stderr' (default 'stdout').")
                    ]),
                    "cursor": .object([
                        "type": .string("integer"),
                        "description": .string("Byte offset to read from (default 0).")
                    ]),
                    "n": .object([
                        "type": .string("integer"),
                        "description": .string("Max bytes to return (default 8192).")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let id) = args["id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "bg_process_logs",
                        reason: "missing required 'id' parameter"
                    )
                }
                let stream: String = {
                    if case .string(let s) = args["stream"] { return s }
                    return "stdout"
                }()
                let cursor: Int? = {
                    if case .int(let i) = args["cursor"] { return i }
                    return nil
                }()
                let n: Int? = {
                    if case .int(let i) = args["n"] { return i }
                    return nil
                }()
                do {
                    let page = try await runtime.logs(id: id, stream: stream, cursor: cursor, n: n)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(page.id),
                        "stream": .string(page.stream),
                        "cursor": .int(page.cursor),
                        "nextCursor": .int(page.nextCursor),
                        "bytes": .int(page.bytes),
                        "totalBytes": .int(page.totalBytes),
                        "eof": .bool(page.eof),
                        "text": .string(page.text)
                    ])
                } catch let e as BgProcessError {
                    return errorValue("bg_process_logs", e)
                }
            }
        ))

        // MARK: bg_process_kill
        await router.register(ToolRegistration(
            name: "bg_process_kill",
            module: moduleName,
            tier: .request,
            description: "Send SIGTERM to the entire process group of a running job, then SIGKILL after 5s if still alive. Pass force=true to skip the grace period and SIGKILL immediately. Idempotent on already-terminal jobs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Job id returned by bg_process_start.")
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, send SIGKILL immediately (no SIGTERM grace). Default false.")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let id) = args["id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "bg_process_kill",
                        reason: "missing required 'id' parameter"
                    )
                }
                let force: Bool = {
                    if case .bool(let b) = args["force"] { return b }
                    return false
                }()
                do {
                    let meta = try await runtime.kill(id: id, force: force)
                    return jobMetaToValue(meta, includeOK: true)
                } catch let e as BgProcessError {
                    return errorValue("bg_process_kill", e)
                }
            }
        ))

        // MARK: bg_process_list
        await router.register(ToolRegistration(
            name: "bg_process_list",
            module: moduleName,
            tier: .open,
            description: "List all known jobs (newest started first). Optional status filter: 'running'|'done'|'failed'|'killed'|'unknown'. Optional label filter (substring match on the start-time label). Reconciles orphaned jobs first if reconcile=true (defaults true on first call after Bridge launch via the bootstrap, but agents may pass true to force a re-scan).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "status": .object([
                        "type": .string("string"),
                        "description": .string("Optional status filter: running | done | failed | killed | unknown.")
                    ]),
                    "label": .object([
                        "type": .string("string"),
                        "description": .string("Optional exact-match label filter.")
                    ]),
                    "reconcile": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, run orphan reconciliation (kill(pid,0) liveness probe) before listing. Default false.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                var statusFilter: BgProcessStatus? = nil
                var labelFilter: String? = nil
                var reconcile = false
                if case .object(let args) = arguments {
                    if case .string(let s) = args["status"], let st = BgProcessStatus(rawValue: s) {
                        statusFilter = st
                    }
                    if case .string(let s) = args["label"] { labelFilter = s }
                    if case .bool(let b) = args["reconcile"] { reconcile = b }
                }
                var reconcileSummary: Value? = nil
                if reconcile {
                    let r = await runtime.reconcileOrphans()
                    reconcileSummary = .object([
                        "reconciled": .int(r.reconciled),
                        "stillRunning": .int(r.stillRunning),
                        "cleaned": .int(r.cleaned)
                    ])
                }
                let jobs = await runtime.list(filter: statusFilter, label: labelFilter)
                let arr: [Value] = jobs.map { jobMetaToValue($0, includeOK: false) }
                var out: [String: Value] = [
                    "ok": .bool(true),
                    "count": .int(arr.count),
                    "jobs": .array(arr)
                ]
                if let s = reconcileSummary { out["reconcile"] = s }
                if let s = statusFilter { out["statusFilter"] = .string(s.rawValue) }
                if let l = labelFilter { out["labelFilter"] = .string(l) }
                return .object(out)
            }
        ))
    }

    // MARK: - Helpers

    static func jobMetaToValue(_ m: BgProcessJobMeta, includeOK: Bool) -> Value {
        let iso = ISO8601DateFormatter()
        var dict: [String: Value] = [
            "id": .string(m.id),
            "pid": .int(Int(m.pid)),
            "pgid": .int(Int(m.pgid)),
            "command": .string(m.command),
            "status": .string(m.status.rawValue),
            "startedAt": .string(iso.string(from: m.startedAt))
        ]
        if includeOK { dict["ok"] = .bool(true) }
        if let wd = m.workingDir { dict["workingDir"] = .string(wd) }
        if let label = m.label { dict["label"] = .string(label) }
        if let ended = m.endedAt { dict["endedAt"] = .string(iso.string(from: ended)) }
        if let ec = m.exitCode { dict["exitCode"] = .int(Int(ec)) }
        if let ks = m.killSignal { dict["killSignal"] = .int(Int(ks)) }
        if let r = m.lastReconcileAt { dict["lastReconcileAt"] = .string(iso.string(from: r)) }
        if let n = m.note { dict["note"] = .string(n) }
        return .object(dict)
    }

    static func errorValue(_ tool: String, _ error: BgProcessError) -> Value {
        // Distinguish capability_missing for clean agent UX (per packet scope).
        switch error {
        case .capabilityMissing(let reason):
            return .object([
                "ok": .bool(false),
                "status": .string("capability_missing"),
                "tool": .string(tool),
                "error": .string(reason)
            ])
        case .notFound(let id):
            return .object([
                "ok": .bool(false),
                "status": .string("not_found"),
                "tool": .string(tool),
                "id": .string(id),
                "error": .string(error.localizedDescription)
            ])
        case .invalidArgument, .spawnFailed, .ioError:
            return .object([
                "ok": .bool(false),
                "status": .string("failed"),
                "tool": .string(tool),
                "error": .string(error.localizedDescription)
            ])
        }
    }
}
