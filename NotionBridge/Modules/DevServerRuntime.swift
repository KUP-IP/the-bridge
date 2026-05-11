// DevServerRuntime.swift — PKT-741 (Bridge v2.2 · 1.3)
// NotionBridge · Modules · dev/
//
// Port inspection + dev-server lifecycle on top of BgProcessRuntime (PKT-744).
//
// Public surface (frozen):
//   - portInspect(port:)                     -> PortInspectResult
//   - devserverStart(cmd:cwd:port:...)       -> DevServerStartResult
//   - devserverStop(id:port:force:)          -> DevServerStopResult
//   - devserverHealth(port:httpPath:...)     -> DevServerHealthResult
//   - capabilityCheck()                      -> (ok, reason?)
//
// Implementation notes:
//   - Port inspection wraps `lsof -nP -iTCP:<port>` (TCP only — dev-server use case).
//     Empty stdout (or exit==1 with empty stderr) means the port is free.
//   - devserver_start pre-checks the port (LISTENers reject as `port_in_use`),
//     spawns under BgProcessRuntime, then polls port + job-status until either
//     a LISTENer appears (success), the supervised job becomes terminal
//     (`spawn_failed` with the supervised exitCode), or the timeout elapses
//     (`timeout` — supervised job is killed before throw).
//   - devserver_stop calls `supervisor.kill(id, force:)` and (when port given)
//     re-probes after a short grace window to confirm the port is released.
//   - devserver_health is read-only: lsof + optional URLSession HTTP GET.
//
// Boundary: this runtime does NOT manage ports it didn't supervise — it only
// inspects them. devserver_stop requires a bg_process job id (the canonical
// identity for a supervised server). Restart-resilience is inherited from
// BgProcessRuntime's orphan-reconcile + atomic meta.json on disk.

import Foundation
import Darwin

// MARK: - Public Types

public struct PortOccupant: Codable, Sendable, Equatable {
    public let pid: Int32
    public let command: String
    public let user: String?
    public let listenState: String?  // "LISTEN", "ESTABLISHED", etc., or nil
    public let nameField: String     // raw NAME column from lsof

    public init(pid: Int32, command: String, user: String?, listenState: String?, nameField: String) {
        self.pid = pid
        self.command = command
        self.user = user
        self.listenState = listenState
        self.nameField = nameField
    }
}

public struct PortInspectResult: Codable, Sendable {
    public let port: Int
    public let occupants: [PortOccupant]
    public let listening: [PortOccupant]   // subset where listenState == "LISTEN"
    public let lsofExitCode: Int32

    public init(port: Int, occupants: [PortOccupant], lsofExitCode: Int32) {
        self.port = port
        self.occupants = occupants
        self.listening = occupants.filter { ($0.listenState ?? "") == "LISTEN" }
        self.lsofExitCode = lsofExitCode
    }
}

public struct DevServerStartResult: Sendable {
    public let job: BgProcessJobMeta
    public let port: Int
    public let occupant: PortOccupant
    public let waitedMs: Int
}

public struct DevServerStopResult: Sendable {
    public let job: BgProcessJobMeta
    public let port: Int?
    public let portFree: Bool
    public let occupants: [PortOccupant]
}

public struct DevServerHealthResult: Sendable {
    public let port: Int
    public let listening: Bool
    public let occupant: PortOccupant?
    public let httpStatus: Int?
    public let httpExpected: Int?
    public let httpOK: Bool?
    public let httpLatencyMs: Int?
    public let httpError: String?
    public let ok: Bool
}

public enum DevServerError: Error, LocalizedError {
    case capabilityMissing(String)
    case portInUse(port: Int, occupants: [PortOccupant])
    case timeout(seconds: Double, port: Int)
    case spawnFailed(reason: String, exitCode: Int32?)
    case invalidArgument(String)
    case bgProcess(BgProcessError)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .capabilityMissing(let m):
            return "capability_missing: \(m)"
        case .portInUse(let p, let occ):
            let names = occ.map { "\($0.command)(pid=\($0.pid))" }.joined(separator: ", ")
            return "port \(p) already in use by \(names)"
        case .timeout(let s, let p):
            return "devserver_start timed out after \(s)s waiting for port \(p) to LISTEN"
        case .spawnFailed(let r, let ec):
            if let ec { return "spawn failed (exit \(ec)): \(r)" }
            return "spawn failed: \(r)"
        case .invalidArgument(let m):
            return "invalid argument: \(m)"
        case .bgProcess(let e):
            return e.localizedDescription
        case .ioError(let m):
            return "io error: \(m)"
        }
    }
}

// MARK: - Runtime Actor

public actor DevServerRuntime {

    public static let shared = DevServerRuntime()

    public let supervisor: BgProcessRuntime
    public let lsofPath: String?

    public init(supervisor: BgProcessRuntime = .shared, lsofPath: String? = nil) {
        self.supervisor = supervisor
        self.lsofPath = lsofPath ?? DevServerRuntime.resolveLsof()
    }

    private static func resolveLsof() -> String? {
        let candidates = [
            "/usr/sbin/lsof",
            "/usr/bin/lsof",
            "/opt/homebrew/bin/lsof",
            "/usr/local/bin/lsof"
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        // Fallback: `which lsof` honoring inherited PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["lsof"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if let s = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !s.isEmpty,
                   FileManager.default.isExecutableFile(atPath: s) {
                    return s
                }
            }
        } catch {
            // Ignore — fall through to nil.
        }
        return nil
    }

    /// Cheap synchronous capability check — `lsof` discoverable on the host?
    public nonisolated func capabilityCheck() -> (ok: Bool, reason: String?) {
        if let p = lsofPath, FileManager.default.isExecutableFile(atPath: p) {
            return (true, nil)
        }
        return (false, "lsof binary not found (looked in /usr/sbin, /usr/bin, /opt/homebrew/bin, /usr/local/bin, and `which lsof`)")
    }

    // MARK: - port_inspect

    public func portInspect(port: Int) throws -> PortInspectResult {
        guard port > 0 && port <= 65535 else {
            throw DevServerError.invalidArgument("port must be 1..65535, got \(port)")
        }
        guard let lsof = lsofPath, FileManager.default.isExecutableFile(atPath: lsof) else {
            throw DevServerError.capabilityMissing("lsof binary not available")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lsof)
        p.arguments = ["-nP", "-iTCP:\(port)"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            throw DevServerError.ioError("failed to launch lsof: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        let exit = p.terminationStatus
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        // lsof exit semantics:
        //   0  = matches found
        //   1  = no matches OR error (we disambiguate via stderr / stdout shape)
        //   >1 = hard error
        if exit != 0 && exit != 1 {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw DevServerError.ioError("lsof exit \(exit): \(errText)")
        }
        let outText = String(data: outData, encoding: .utf8) ?? ""
        if outText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing on the port — exit 1 here is expected.
            return PortInspectResult(port: port, occupants: [], lsofExitCode: exit)
        }
        let occupants = Self.parseLsof(outText)
        return PortInspectResult(port: port, occupants: occupants, lsofExitCode: exit)
    }

    /// Parse `lsof -nP -iTCP:<port>` stdout into PortOccupant rows.
    /// Tolerant of header presence and whitespace runs. Skips malformed lines.
    static func parseLsof(_ text: String) -> [PortOccupant] {
        var out: [PortOccupant] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(raw)
            if s.hasPrefix("COMMAND") { continue }
            let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }
            let command = parts[0]
            guard let pid = Int32(parts[1]) else { continue }
            let user = parts[2]
            let nameField = parts[8...].joined(separator: " ")
            // Trailing "(STATE)" — extract if present.
            var listenState: String? = nil
            if let openIdx = nameField.lastIndex(of: "("),
               let last = nameField.last, last == ")" {
                let stateStart = nameField.index(after: openIdx)
                let stateEnd = nameField.index(before: nameField.endIndex)
                if stateStart < stateEnd {
                    listenState = String(nameField[stateStart..<stateEnd])
                }
            }
            out.append(PortOccupant(
                pid: pid, command: command, user: user,
                listenState: listenState, nameField: nameField
            ))
        }
        return out
    }

    // MARK: - devserver_start

    public func devserverStart(
        cmd: String,
        cwd: String? = nil,
        port: Int,
        label: String? = nil,
        env: [String: String] = [:],
        timeoutSec: Double = 60,
        pollIntervalMs: Int = 500
    ) async throws -> DevServerStartResult {
        guard !cmd.isEmpty else {
            throw DevServerError.invalidArgument("cmd must not be empty")
        }
        guard port > 0 && port <= 65535 else {
            throw DevServerError.invalidArgument("port must be 1..65535, got \(port)")
        }
        guard timeoutSec > 0 else {
            throw DevServerError.invalidArgument("timeoutSec must be > 0")
        }

        // Pre-check: port must have no LISTENers.
        let pre = try portInspect(port: port)
        if !pre.listening.isEmpty {
            throw DevServerError.portInUse(port: port, occupants: pre.listening)
        }

        let resolvedLabel = label ?? "devserver:\(port)"
        let job: BgProcessJobMeta
        do {
            job = try await supervisor.start(
                command: cmd, workingDir: cwd, env: env, label: resolvedLabel
            )
        } catch let e as BgProcessError {
            throw DevServerError.bgProcess(e)
        }

        let started = Date()
        let pollNs = UInt64(max(50, pollIntervalMs)) * 1_000_000
        while Date().timeIntervalSince(started) < timeoutSec {
            // 1. Did the supervised process die before opening the port?
            let meta: BgProcessJobMeta
            do {
                meta = try await supervisor.status(id: job.id)
            } catch {
                _ = try? await supervisor.kill(id: job.id, force: true)
                throw DevServerError.spawnFailed(
                    reason: "job \(job.id) status unreadable: \(error.localizedDescription)",
                    exitCode: nil
                )
            }
            if meta.status != .running {
                throw DevServerError.spawnFailed(
                    reason: "process exited (status=\(meta.status.rawValue)) before opening port \(port). cmd: \(cmd)",
                    exitCode: meta.exitCode
                )
            }
            // 2. Is something LISTENing on the port? Prefer matching pid.
            let probe = try portInspect(port: port)
            if let occ = probe.listening.first(where: { $0.pid == meta.pid })
                ?? probe.listening.first {
                let waited = Int(Date().timeIntervalSince(started) * 1000)
                let updated = (try? await supervisor.status(id: job.id)) ?? meta
                return DevServerStartResult(
                    job: updated, port: port, occupant: occ, waitedMs: waited
                )
            }
            try? await Task.sleep(nanoseconds: pollNs)
        }
        // Timeout — terminate the supervised child before surfacing.
        _ = try? await supervisor.kill(id: job.id, force: false)
        throw DevServerError.timeout(seconds: timeoutSec, port: port)
    }

    // MARK: - devserver_stop

    public func devserverStop(
        id: String,
        port: Int? = nil,
        force: Bool = false
    ) async throws -> DevServerStopResult {
        let killed: BgProcessJobMeta
        do {
            killed = try await supervisor.kill(id: id, force: force)
        } catch let e as BgProcessError {
            throw DevServerError.bgProcess(e)
        }
        var portFree = true
        var occupants: [PortOccupant] = []
        if let port {
            // Poll for port release. SIGTERM-graceful servers (e.g. python3 -m
            // http.server, vite) can take 1-2s to close their listening socket
            // even after the supervisor returns. Retry up to ~3s; on the final
            // probe we report whatever is still there honestly via portFree.
            let deadline = Date().addingTimeInterval(3.0)
            var probe: PortInspectResult
            repeat {
                try? await Task.sleep(nanoseconds: 200_000_000)
                probe = try portInspect(port: port)
                if probe.listening.isEmpty { break }
            } while Date() < deadline
            occupants = probe.occupants
            portFree = probe.listening.isEmpty
        }
        return DevServerStopResult(
            job: killed, port: port, portFree: portFree, occupants: occupants
        )
    }

    // MARK: - devserver_health

    public func devserverHealth(
        port: Int,
        httpPath: String? = nil,
        expectedStatus: Int = 200,
        timeoutSec: Double = 5
    ) async -> DevServerHealthResult {
        let probe: PortInspectResult
        do {
            probe = try portInspect(port: port)
        } catch {
            return DevServerHealthResult(
                port: port, listening: false, occupant: nil,
                httpStatus: nil,
                httpExpected: httpPath != nil ? expectedStatus : nil,
                httpOK: nil, httpLatencyMs: nil,
                httpError: error.localizedDescription, ok: false
            )
        }
        guard let occ = probe.listening.first else {
            return DevServerHealthResult(
                port: port, listening: false, occupant: nil,
                httpStatus: nil,
                httpExpected: httpPath != nil ? expectedStatus : nil,
                httpOK: nil, httpLatencyMs: nil, httpError: nil, ok: false
            )
        }
        guard let httpPath else {
            return DevServerHealthResult(
                port: port, listening: true, occupant: occ,
                httpStatus: nil, httpExpected: nil, httpOK: nil,
                httpLatencyMs: nil, httpError: nil, ok: true
            )
        }
        let path = httpPath.hasPrefix("/") ? httpPath : "/" + httpPath
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            return DevServerHealthResult(
                port: port, listening: true, occupant: occ,
                httpStatus: nil, httpExpected: expectedStatus, httpOK: false,
                httpLatencyMs: nil,
                httpError: "invalid URL: 127.0.0.1:\(port)\(path)", ok: false
            )
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = max(1, timeoutSec)
        cfg.timeoutIntervalForResource = max(1, timeoutSec)
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let started = Date()
        do {
            let (_, response) = try await session.data(for: req)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let ok = (status == expectedStatus)
            return DevServerHealthResult(
                port: port, listening: true, occupant: occ,
                httpStatus: status, httpExpected: expectedStatus, httpOK: ok,
                httpLatencyMs: latency, httpError: nil, ok: ok
            )
        } catch {
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return DevServerHealthResult(
                port: port, listening: true, occupant: occ,
                httpStatus: nil, httpExpected: expectedStatus, httpOK: false,
                httpLatencyMs: latency, httpError: error.localizedDescription,
                ok: false
            )
        }
    }
}
