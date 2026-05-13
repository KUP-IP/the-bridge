// CursorModule.swift — PKT-3.4.1 (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Five tool registrations under module = "cursor" exposing the Cursor SDK
// surface via the cursor-sidecar JSON-RPC adapter:
//   - cursor_agent_run        (tier .request — cost gate)
//   - cursor_agent_status     (tier .request)
//   - cursor_agent_list       (tier .request)
//   - cursor_agent_cancel     (tier .request)
//   - cursor_agent_artifacts  (tier .request)
//
// All five are tier .request because Cursor SDK calls bill against the
// user's Pro/Enterprise account. Handlers proxy to CursorRuntime, which owns
// sidecar process lifecycle, JSON-RPC request correlation, prompt redaction,
// and sensitive-repo runtime gating.

import Foundation
import MCP

public enum CursorModule {

    public static let moduleName = "cursor"

    public static func register(
        on router: ToolRouter,
        runtime: CursorRuntime = CursorRuntime.shared
    ) async {

        // MARK: cursor_agent_run
        await router.register(ToolRegistration(
            name: "cursor_agent_run",
            module: moduleName,
            tier: .request,
            description: "Start a Cursor SDK agent run. Runtime 'local' executes against `repoPath` on this machine; 'cloud' provisions a Cursor cloud VM that opens a PR on completion. Returns a run id; follow up via cursor_agent_status / cursor_agent_artifacts. Requires CURSOR_API_KEY in Keychain (service=api_key:cursor, account=cursor) and Node ≥ 20 on PATH.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("Prompt / instructions for the agent. Hashed (sha256) into AI LOGS — raw text never persisted.")
                    ]),
                    "runtime": .object([
                        "type": .string("string"),
                        "description": .string("'local' or 'cloud' (default 'local').")
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("Cursor model id (e.g. 'cursor-default'). Defaults to sidecar-side default.")
                    ]),
                    "repoPath": .object([
                        "type": .string("string"),
                        "description": .string("Required for runtime='local'. Absolute path to the repo to operate against.")
                    ]),
                    "branch": .object([
                        "type": .string("string"),
                        "description": .string("Optional branch to target (cloud runtime).")
                    ]),
                    "maxCostCents": .object([
                        "type": .string("integer"),
                        "description": .string("Optional per-run cost cap in cents. Sidecar trips 10005 COST_CAP_TRIPPED at threshold.")
                    ])
                ]),
                "required": .array([.string("prompt")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let prompt) = args["prompt"], !prompt.isEmpty else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "cursor_agent_run",
                        reason: "missing required 'prompt' parameter"
                    )
                }
                let runtimeKind: CursorRuntimeKind = {
                    if case .string(let s) = args["runtime"],
                       let k = CursorRuntimeKind(rawValue: s) { return k }
                    return .local
                }()
                let model: String? = {
                    if case .string(let s) = args["model"] { return s }
                    return nil
                }()
                let repoPath: String? = {
                    if case .string(let s) = args["repoPath"] { return s }
                    return nil
                }()
                let branch: String? = {
                    if case .string(let s) = args["branch"] { return s }
                    return nil
                }()
                let maxCostCents: Int? = {
                    if case .int(let i) = args["maxCostCents"] { return i }
                    return nil
                }()
                do {
                    let run = try await runtime.agentRun(
                        prompt: prompt,
                        runtime: runtimeKind,
                        model: model,
                        repoPath: repoPath,
                        branch: branch,
                        maxCostCents: maxCostCents
                    )
                    return runToValue(run, includeOK: true)
                } catch let e as CursorError {
                    return errorValue("cursor_agent_run", e)
                }
            }
        ))

        // MARK: cursor_agent_status
        await router.register(ToolRegistration(
            name: "cursor_agent_status",
            module: moduleName,
            tier: .request,
            description: "Return current status (queued / running / succeeded / failed / cancelled) for one run id. Includes cost-cents-to-date and last_event_id for reconnect.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Run id returned by cursor_agent_run.")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let id) = args["id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "cursor_agent_status",
                        reason: "missing required 'id' parameter"
                    )
                }
                do {
                    let run = try await runtime.agentStatus(id: id)
                    return runToValue(run, includeOK: true)
                } catch let e as CursorError {
                    return errorValue("cursor_agent_status", e)
                }
            }
        ))

        // MARK: cursor_agent_list
        await router.register(ToolRegistration(
            name: "cursor_agent_list",
            module: moduleName,
            tier: .request,
            description: "Enumerate runs known to the sidecar. Optional filter by status ('running' / 'succeeded' / etc.) or runtime ('local' / 'cloud'). Used on Bridge restart to re-attach to running cloud agents.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "status": .object([
                        "type": .string("string"),
                        "description": .string("Optional status filter.")
                    ]),
                    "runtime": .object([
                        "type": .string("string"),
                        "description": .string("Optional runtime filter ('local' | 'cloud').")
                    ])
                ])
            ]),
            handler: { arguments in
                var statusFilter: CursorRunStatus? = nil
                var runtimeFilter: CursorRuntimeKind? = nil
                if case .object(let args) = arguments {
                    if case .string(let s) = args["status"]  { statusFilter = CursorRunStatus(rawValue: s) }
                    if case .string(let s) = args["runtime"] { runtimeFilter = CursorRuntimeKind(rawValue: s) }
                }
                do {
                    let runs = try await runtime.agentList(
                        statusFilter: statusFilter,
                        runtimeFilter: runtimeFilter
                    )
                    return .object([
                        "ok": .bool(true),
                        "runs": .array(runs.map { runToValue($0, includeOK: false) })
                    ])
                } catch let e as CursorError {
                    return errorValue("cursor_agent_list", e)
                }
            }
        ))

        // MARK: cursor_agent_cancel
        await router.register(ToolRegistration(
            name: "cursor_agent_cancel",
            module: moduleName,
            tier: .request,
            description: "Cancel a running agent. Local runs: kills the run process. Cloud runs: requests cancellation through the SDK.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Run id to cancel.")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let id) = args["id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "cursor_agent_cancel",
                        reason: "missing required 'id' parameter"
                    )
                }
                do {
                    let run = try await runtime.agentCancel(id: id)
                    return runToValue(run, includeOK: true)
                } catch let e as CursorError {
                    return errorValue("cursor_agent_cancel", e)
                }
            }
        ))

        // MARK: cursor_agent_artifacts
        await router.register(ToolRegistration(
            name: "cursor_agent_artifacts",
            module: moduleName,
            tier: .request,
            description: "Fetch artifacts (PR URL, diffs, logs, session transcript) produced by a completed run.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Run id whose artifacts to fetch.")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let id) = args["id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "cursor_agent_artifacts",
                        reason: "missing required 'id' parameter"
                    )
                }
                do {
                    let artifacts = try await runtime.agentArtifacts(id: id)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(id),
                        "artifacts": .array(artifacts.map { artifactToValue($0) })
                    ])
                } catch let e as CursorError {
                    return errorValue("cursor_agent_artifacts", e)
                }
            }
        ))
    }

    // MARK: - Value mappers

    static func runToValue(_ run: CursorRun, includeOK: Bool) -> Value {
        let iso = ISO8601DateFormatter()
        var dict: [String: Value] = [
            "id": .string(run.id),
            "runtime": .string(run.runtime.rawValue),
            "model": .string(run.model),
            "status": .string(run.status.rawValue),
            "startedAt": .string(iso.string(from: run.startedAt))
        ]
        if let ts = run.endedAt    { dict["endedAt"]      = .string(iso.string(from: ts)) }
        if let c  = run.costCents  { dict["costCents"]    = .int(c) }
        if let p  = run.repoPath   { dict["repoPath"]     = .string(p) }
        if let p  = run.prURL      { dict["prURL"]        = .string(p) }
        if let e  = run.lastEventId{ dict["lastEventId"]  = .string(e) }
        if includeOK { dict["ok"] = .bool(true) }
        return .object(dict)
    }

    static func artifactToValue(_ a: CursorArtifact) -> Value {
        var dict: [String: Value] = ["kind": .string(a.kind)]
        if let u = a.url       { dict["url"]       = .string(u) }
        if let l = a.label     { dict["label"]     = .string(l) }
        if let m = a.mediaType { dict["mediaType"] = .string(m) }
        return .object(dict)
    }

    static func errorValue(_ tool: String, _ err: CursorError) -> Value {
        .object([
            "ok": .bool(false),
            "tool": .string(tool),
            "error": .string(err.localizedDescription),
            "code": .int(err.sidecarCode)
        ])
    }
}
