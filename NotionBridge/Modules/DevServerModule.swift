// DevServerModule.swift — PKT-741 (Bridge v2.2 · 1.3)
// NotionBridge · Modules · dev/
//
// Four MCP tools wrapping DevServerRuntime as the public dev/ surface for
// port inspection and supervised dev-server lifecycle:
//
//   - port_inspect      : structured `lsof -nP -iTCP:<port>` results
//   - devserver_start   : spawn under bg_process + wait for port LISTEN
//   - devserver_stop    : kill the supervised job + verify port released
//   - devserver_health  : liveness probe (port + optional HTTP GET)
//
// All four are tier .request (privileged: side effects on processes / network).
// Capability detection emits `capability_missing` if `lsof` is not on PATH.
//
// Builds on PKT-744 (BgProcessRuntime) — every devserver_start spawns through
// the bg_process supervisor, inheriting orphan reconciliation, atomic meta,
// SIGCHLD reaping, and 7-day terminal-job cleanup.

import Foundation
import MCP

public enum DevServerModule {

    public static let moduleName = "dev"

    /// Register all 4 dev/ port + devserver tools on the given router.
    /// Pass a custom runtime (e.g. with a hermetic BgProcessRuntime baseDir)
    /// for tests; defaults to the shared singleton used by the production app.
    public static func register(
        on router: ToolRouter,
        runtime: DevServerRuntime = DevServerRuntime.shared
    ) async {

        // MARK: port_inspect
        await router.register(ToolRegistration(
            name: "port_inspect",
            module: moduleName,
            tier: .request,
            description: "Inspect what (if anything) is listening on a TCP port. Wraps `lsof -nP -iTCP:<port>` and returns structured occupants ({pid, command, user, listenState, name}). The `listening` array is the LISTEN subset — empty means the port is free. Returns `capability_missing` if lsof is not on PATH.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "port": .object([
                        "type": .string("integer"),
                        "description": .string("TCP port to inspect (1..65535).")
                    ])
                ]),
                "required": .array([.string("port")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .int(let port) = args["port"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "port_inspect",
                        reason: "missing required integer 'port' parameter"
                    )
                }
                do {
                    let r = try await runtime.portInspect(port: port)
                    return portInspectResultToValue(r, ok: true)
                } catch let e as DevServerError {
                    return errorValue("port_inspect", e)
                }
            }
        ))

        // MARK: devserver_start
        await router.register(ToolRegistration(
            name: "devserver_start",
            module: moduleName,
            tier: .request,
            description: "Spawn a dev server (Vite, Wrangler, Next, npm run dev, python3 -m http.server, etc.) under bg_process supervision and wait for the given TCP port to LISTEN. Pre-checks the port — if a LISTENer is already present, fails with `port_in_use` + occupying pid(s). If the supervised child terminates before opening the port, fails with `spawn_failed` + supervised exitCode. If the timeout elapses, the supervised child is terminated and the call fails with `timeout`. On success returns the bg_process job id (use with devserver_stop / bg_process_logs / bg_process_status). cmd is passed verbatim to /bin/bash -c — no framework auto-detect. timeoutSec default 60.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "cmd": .object([
                        "type": .string("string"),
                        "description": .string("Shell command to run (e.g. 'npm run dev', 'wrangler dev', 'python3 -m http.server 8080').")
                    ]),
                    "cwd": .object([
                        "type": .string("string"),
                        "description": .string("Optional working directory (tilde-expanded by bg_process).")
                    ]),
                    "port": .object([
                        "type": .string("integer"),
                        "description": .string("TCP port the server is expected to bind. Pre-checked with port_inspect.")
                    ]),
                    "label": .object([
                        "type": .string("string"),
                        "description": .string("Optional bg_process label (default 'devserver:<port>').")
                    ]),
                    "env": .object([
                        "type": .string("object"),
                        "description": .string("Optional env vars (string values) merged onto the bridge process environment.")
                    ]),
                    "timeoutSec": .object([
                        "type": .string("number"),
                        "description": .string("Max seconds to wait for the port to LISTEN (default 60).")
                    ])
                ]),
                "required": .array([.string("cmd"), .string("port")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let cmd) = args["cmd"],
                      case .int(let port) = args["port"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "devserver_start",
                        reason: "missing required 'cmd' (string) and/or 'port' (integer) parameters"
                    )
                }
                let cwd: String? = {
                    if case .string(let s) = args["cwd"] { return s }
                    return nil
                }()
                let label: String? = {
                    if case .string(let s) = args["label"] { return s }
                    return nil
                }()
                var envDict: [String: String] = [:]
                if case .object(let envArgs) = args["env"] {
                    for (k, v) in envArgs {
                        if case .string(let s) = v { envDict[k] = s }
                    }
                }
                let timeoutSec: Double = {
                    if case .double(let d) = args["timeoutSec"] { return d }
                    if case .int(let i) = args["timeoutSec"] { return Double(i) }
                    return 60
                }()
                do {
                    let r = try await runtime.devserverStart(
                        cmd: cmd, cwd: cwd, port: port,
                        label: label, env: envDict, timeoutSec: timeoutSec
                    )
                    return devserverStartResultToValue(r)
                } catch let e as DevServerError {
                    return errorValue("devserver_start", e)
                }
            }
        ))

        // MARK: devserver_stop
        await router.register(ToolRegistration(
            name: "devserver_stop",
            module: moduleName,
            tier: .request,
            description: "Stop a previously-started dev server by bg_process job id. Sends SIGTERM (or SIGKILL when force=true) via the bg_process supervisor and — when `port` is provided — re-probes via port_inspect to verify the port has been released. Idempotent on already-terminal jobs (returns the final meta). Use this after Bridge restart too: bg_process orphan reconcile + atomic meta on disk make stop reliable across runs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("bg_process job id (returned by devserver_start).")
                    ]),
                    "port": .object([
                        "type": .string("integer"),
                        "description": .string("Optional port to verify is released after the kill (recommended).")
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, send SIGKILL immediately (skip SIGTERM grace). Default false.")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let id) = args["id"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "devserver_stop",
                        reason: "missing required 'id' parameter"
                    )
                }
                let port: Int? = {
                    if case .int(let i) = args["port"] { return i }
                    return nil
                }()
                let force: Bool = {
                    if case .bool(let b) = args["force"] { return b }
                    return false
                }()
                do {
                    let r = try await runtime.devserverStop(id: id, port: port, force: force)
                    return devserverStopResultToValue(r)
                } catch let e as DevServerError {
                    return errorValue("devserver_stop", e)
                }
            }
        ))

        // MARK: devserver_health
        await router.register(ToolRegistration(
            name: "devserver_health",
            module: moduleName,
            tier: .request,
            description: "Liveness probe for a dev server: confirms a LISTENer on the port and (optionally) issues an HTTP GET to verify a status code. Returns ok=true when the port has a LISTENer AND (if httpPath is set) the response status equals expectedStatus (default 200). HTTP probe runs against http://127.0.0.1:<port><httpPath> with timeoutSec (default 5).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "port": .object([
                        "type": .string("integer"),
                        "description": .string("TCP port to probe.")
                    ]),
                    "httpPath": .object([
                        "type": .string("string"),
                        "description": .string("Optional URL path (e.g. '/' or '/healthz'). When present, HTTP GET is performed against http://127.0.0.1:<port><path>.")
                    ]),
                    "expectedStatus": .object([
                        "type": .string("integer"),
                        "description": .string("HTTP status code expected for the httpPath probe (default 200).")
                    ]),
                    "timeoutSec": .object([
                        "type": .string("number"),
                        "description": .string("HTTP probe timeout in seconds (default 5).")
                    ])
                ]),
                "required": .array([.string("port")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .int(let port) = args["port"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "devserver_health",
                        reason: "missing required integer 'port' parameter"
                    )
                }
                let httpPath: String? = {
                    if case .string(let s) = args["httpPath"] { return s }
                    return nil
                }()
                let expected: Int = {
                    if case .int(let i) = args["expectedStatus"] { return i }
                    return 200
                }()
                let timeoutSec: Double = {
                    if case .double(let d) = args["timeoutSec"] { return d }
                    if case .int(let i) = args["timeoutSec"] { return Double(i) }
                    return 5
                }()
                let r = await runtime.devserverHealth(
                    port: port, httpPath: httpPath,
                    expectedStatus: expected, timeoutSec: timeoutSec
                )
                return devserverHealthResultToValue(r)
            }
        ))
    }

    // MARK: - Value encoders

    static func portOccupantToValue(_ o: PortOccupant) -> Value {
        var dict: [String: Value] = [
            "pid": .int(Int(o.pid)),
            "command": .string(o.command),
            "name": .string(o.nameField)
        ]
        if let u = o.user { dict["user"] = .string(u) }
        if let s = o.listenState { dict["listenState"] = .string(s) }
        return .object(dict)
    }

    static func portInspectResultToValue(_ r: PortInspectResult, ok: Bool) -> Value {
        return .object([
            "ok": .bool(ok),
            "port": .int(r.port),
            "occupants": .array(r.occupants.map { portOccupantToValue($0) }),
            "listening": .array(r.listening.map { portOccupantToValue($0) }),
            "lsofExitCode": .int(Int(r.lsofExitCode))
        ])
    }

    static func devserverStartResultToValue(_ r: DevServerStartResult) -> Value {
        var dict: [String: Value] = [
            "ok": .bool(true),
            "id": .string(r.job.id),
            "pid": .int(Int(r.job.pid)),
            "port": .int(r.port),
            "occupant": portOccupantToValue(r.occupant),
            "waitedMs": .int(r.waitedMs),
            "command": .string(r.job.command),
            "status": .string(r.job.status.rawValue)
        ]
        if let l = r.job.label { dict["label"] = .string(l) }
        if let wd = r.job.workingDir { dict["workingDir"] = .string(wd) }
        return .object(dict)
    }

    static func devserverStopResultToValue(_ r: DevServerStopResult) -> Value {
        var dict: [String: Value] = [
            "ok": .bool(true),
            "id": .string(r.job.id),
            "status": .string(r.job.status.rawValue),
            "portFree": .bool(r.portFree),
            "occupants": .array(r.occupants.map { portOccupantToValue($0) })
        ]
        if let p = r.port { dict["port"] = .int(p) }
        if let ec = r.job.exitCode { dict["exitCode"] = .int(Int(ec)) }
        if let ks = r.job.killSignal { dict["killSignal"] = .int(Int(ks)) }
        return .object(dict)
    }

    static func devserverHealthResultToValue(_ r: DevServerHealthResult) -> Value {
        var dict: [String: Value] = [
            "ok": .bool(r.ok),
            "port": .int(r.port),
            "listening": .bool(r.listening)
        ]
        if let occ = r.occupant { dict["occupant"] = portOccupantToValue(occ) }
        if let s = r.httpStatus { dict["httpStatus"] = .int(s) }
        if let e = r.httpExpected { dict["httpExpected"] = .int(e) }
        if let h = r.httpOK { dict["httpOK"] = .bool(h) }
        if let l = r.httpLatencyMs { dict["httpLatencyMs"] = .int(l) }
        if let err = r.httpError { dict["httpError"] = .string(err) }
        return .object(dict)
    }

    static func errorValue(_ tool: String, _ error: DevServerError) -> Value {
        switch error {
        case .capabilityMissing(let m):
            return .object([
                "ok": .bool(false),
                "status": .string("capability_missing"),
                "tool": .string(tool),
                "error": .string(m)
            ])
        case .portInUse(let p, let occ):
            return .object([
                "ok": .bool(false),
                "status": .string("port_in_use"),
                "tool": .string(tool),
                "port": .int(p),
                "occupants": .array(occ.map { portOccupantToValue($0) }),
                "error": .string(error.localizedDescription)
            ])
        case .timeout(let s, let p):
            return .object([
                "ok": .bool(false),
                "status": .string("timeout"),
                "tool": .string(tool),
                "timeoutSec": .double(s),
                "port": .int(p),
                "error": .string(error.localizedDescription)
            ])
        case .spawnFailed(let reason, let ec):
            var dict: [String: Value] = [
                "ok": .bool(false),
                "status": .string("spawn_failed"),
                "tool": .string(tool),
                "error": .string(reason)
            ]
            if let ec { dict["exitCode"] = .int(Int(ec)) }
            return .object(dict)
        case .invalidArgument(let m):
            return .object([
                "ok": .bool(false),
                "status": .string("invalid_argument"),
                "tool": .string(tool),
                "error": .string(m)
            ])
        case .bgProcess(let e):
            return .object([
                "ok": .bool(false),
                "status": .string("bg_process_error"),
                "tool": .string(tool),
                "error": .string(e.localizedDescription)
            ])
        case .ioError(let m):
            return .object([
                "ok": .bool(false),
                "status": .string("io_error"),
                "tool": .string(tool),
                "error": .string(m)
            ])
        }
    }
}
