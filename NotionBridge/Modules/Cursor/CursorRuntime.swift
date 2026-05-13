// CursorRuntime.swift — PKT-3.4.1 (Bridge v2.2) + PKT-3.4.3 Wave 1 hardening
// NotionBridge · Modules · Cursor
//
// Owns the Node `cursor-sidecar` lifecycle and JSON-RPC 2.0 IPC over stdio.
// Wave 1 (PKT-3.4.1) shipped the capability surface. Wave 2 replaces the
// notImplemented stubs with live request/response correlation against the
// sidecar process.
//
// PKT-3.4.3 Wave 1 (this packet) layers a pre-dispatch hardening pass on top
// of the Wave 1 contract: `agentRun(...)` now runs sensitive-repo allowlist
// evaluation + prompt redaction BEFORE `requireCapability()`. The scrubbed
// prompt + effective runtime + audit entry are what W2's live IPC will
// dispatch through the JSON-RPC sidecar.
//
// Architecture notes:
//   - Sidecar is a long-lived Node process speaking JSON-RPC 2.0 line-delimited
//     over stdin/stdout per SPEC.md §2. Because we need bidirectional IPC with
//     structured request/response correlation, we own the Process directly with
//     pipes (mirroring the GhRuntime / DevServerRuntime pattern), not
//     BgProcessRuntime (which captures stdio to files).
//   - Lifecycle observability still mirrors the bg_process_* conventions:
//     status snapshot, restart, graceful kill.
//   - Keychain `service=api_key:cursor / account=cursor` is read at spawn time
//     and injected as env `CURSOR_API_KEY` per SPEC §6. The sidecar never
//     reads Keychain directly.

import Foundation

public actor CursorRuntime {

    // MARK: - Singleton

    public static let shared = CursorRuntime()

    // MARK: - Config

    /// Sidecar install root (default: `~/Library/Application Support/NotionBridge/cursor-sidecar/`).
    public nonisolated let sidecarRoot: URL

    /// Resolved entrypoint (default: `<root>/dist/index.js`).
    public nonisolated var sidecarEntrypoint: URL {
        sidecarRoot.appendingPathComponent("dist/index.js")
    }

    /// Keychain coordinates per Reflow #14 finding (PKT-772 page).
    public static let keychainService = "api_key:cursor"
    public static let keychainAccount = "cursor"
    public static let envVarName = "CURSOR_API_KEY"

    /// Optional override for the node binary path (set in init).
    public nonisolated let configuredNodePath: String?

    // MARK: - State (Wave 2 will populate)

    private var process: Process?
    private var spawnedAt: Date?
    private var cachedCapability: CursorCapability?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestId = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]

    /// PKT-3.4.3 Wave 1: queued redaction audit entries waiting for W2's
    /// AI LOGS DS writer to drain. See `RedactionAuditEntry`.
    private var pendingAudits: [RedactionAuditEntry] = []
    private let apiKeyOverride: String?

    // MARK: - Init

    public init(
        sidecarRoot: URL = CursorRuntime.defaultSidecarRoot(),
        nodePath: String? = nil,
        apiKeyOverride: String? = nil
    ) {
        self.sidecarRoot = sidecarRoot
        if let p = nodePath, FileManager.default.isExecutableFile(atPath: p) {
            self.configuredNodePath = p
        } else {
            self.configuredNodePath = nil
        }
        self.apiKeyOverride = apiKeyOverride
    }

    /// Default sidecar root: `~/Library/Application Support/NotionBridge/cursor-sidecar/`.
    public nonisolated static func defaultSidecarRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Application Support/NotionBridge/cursor-sidecar",
            isDirectory: true
        )
    }

    // MARK: - Capability

    /// Synchronous capability check — does NOT spawn the sidecar. Combines:
    ///   - node binary present on PATH (≥ 20 expected; version reported)
    ///   - sidecar entrypoint exists on disk
    ///   - CURSOR_API_KEY present in Keychain
    public nonisolated func capabilityCheck() -> CursorCapability {
        let node = configuredNodePath ?? CursorRuntime.locateNode()
        let entry = sidecarEntrypoint
        let hasSidecar = FileManager.default.fileExists(atPath: entry.path)
        let hasKey: Bool = {
            if let override = apiKeyOverride, !override.isEmpty {
                return true
            }
            do {
                _ = try CredentialManager.shared.read(
                    service: CursorRuntime.keychainService,
                    account: CursorRuntime.keychainAccount
                )
                return true
            } catch {
                return false
            }
        }()

        var reasons: [String] = []
        if node == nil {
            reasons.append("node binary not found on PATH (need Node ≥ 20)")
        }
        if !hasSidecar {
            reasons.append("sidecar entrypoint missing at \(entry.path)")
        }
        if !hasKey {
            reasons.append(
                "CURSOR_API_KEY missing from Keychain (service=\(CursorRuntime.keychainService), account=\(CursorRuntime.keychainAccount))"
            )
        }

        let nodeVersion: String? = node.flatMap { CursorRuntime.detectNodeVersion(at: $0) }
        let sidecarVersion: String? = hasSidecar ? CursorRuntime.readSidecarVersion(root: sidecarRoot) : nil

        return CursorCapability(
            ok: reasons.isEmpty,
            reason: reasons.isEmpty ? nil : reasons.joined(separator: "; "),
            nodePath: node,
            nodeVersion: nodeVersion,
            sidecarPath: hasSidecar ? entry.path : nil,
            sidecarVersion: sidecarVersion,
            hasApiKey: hasKey
        )
    }

    // MARK: - Process observability (mirrors bg_process_* snapshot shape)

    public func processSnapshot() -> (running: Bool, pid: Int32?, spawnedAt: Date?) {
        if let p = process, p.isRunning {
            return (true, p.processIdentifier, spawnedAt)
        }
        return (false, nil, spawnedAt)
    }

    /// Tear down the sidecar process. Idempotent.
    public func shutdown() {
        if let p = process, p.isRunning {
            p.terminate()
        }
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        for (_, cont) in pendingRequests {
            cont.resume(throwing: CursorError.ipcError("cursor sidecar stopped"))
        }
        pendingRequests.removeAll()
        process = nil
        spawnedAt = nil
        cachedCapability = nil
        stdin = nil
        stdout = nil
        stderr = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Public API

    public func ping() async throws -> [String: String] {
        try requireCapability()
        return try await request(method: "ping", params: [String: String]())
    }

    public func capabilityProbe() async throws -> [String: String] {
        try requireCapability()
        return try await request(method: "capability_probe", params: [String: String]())
    }

    public func agentRun(prompt: String, runtime: CursorRuntimeKind, model: String?, repoPath: String?, branch: String?, maxCostCents: Int?) async throws -> CursorRun {
        // PKT-3.4.3 Wave 1: pre-dispatch hardening pass (redaction + sensitive-repo allowlist).
        // Audit entry queued for PKT-3.4.1.W2 AI LOGS writer; the scrubbed prompt + effective
        // runtime are what W2's live IPC will dispatch.
        let verdict = evaluateGates(prompt: prompt, runtime: runtime, repoPath: repoPath)
        try requireCapability()
        return try await request(method: "agent_run", params: CursorAgentRunRequest(
            prompt: verdict.scrubbedPrompt,
            runtime: verdict.effectiveRuntime,
            model: model,
            repoPath: repoPath,
            branch: branch,
            maxCostCents: maxCostCents
        ))
    }

    public func agentStatus(id: String) async throws -> CursorRun {
        try requireCapability()
        return try await request(method: "agent_status", params: CursorIdRequest(id: id))
    }

    public func agentList(statusFilter: CursorRunStatus?, runtimeFilter: CursorRuntimeKind?) async throws -> [CursorRun] {
        try requireCapability()
        let response: CursorRunListResponse = try await request(
            method: "agent_list",
            params: CursorAgentListRequest(status: statusFilter, runtime: runtimeFilter)
        )
        return response.runs
    }

    public func agentCancel(id: String) async throws -> CursorRun {
        try requireCapability()
        return try await request(method: "agent_cancel", params: CursorIdRequest(id: id))
    }

    public func agentArtifacts(id: String) async throws -> [CursorArtifact] {
        try requireCapability()
        let response: CursorArtifactListResponse = try await request(
            method: "agent_artifacts",
            params: CursorIdRequest(id: id)
        )
        return response.artifacts
    }

    // MARK: - PKT-3.4.3 Wave 1: Hardening surface (sensitive-repo allowlist + prompt redaction)

    /// Read-only snapshot of pending redaction audit entries.
    /// PKT-3.4.1.W2's AI LOGS DS writer drains via `drainPendingRedactionAudits()`.
    public func pendingRedactionAudits() -> [RedactionAuditEntry] {
        pendingAudits
    }

    /// Drain and return all pending audit entries (PKT-3.4.1.W2 calls this
    /// after the AI LOGS DS write succeeds).
    public func drainPendingRedactionAudits() -> [RedactionAuditEntry] {
        let drain = pendingAudits
        pendingAudits = []
        return drain
    }

    /// Pre-dispatch hardening: sensitive-repo allowlist + prompt redaction.
    /// Returns the scrubbed prompt, effective runtime (cloud→local override on
    /// sensitive repo), and the verdict that produced them. Always enqueues an
    /// audit entry for W2's AI LOGS writer.
    ///
    /// Pure (never throws); safe to call from tests without triggering IPC.
    /// Wave 1 of PKT-3.4.3 (this packet): `agentRun(...)` calls this before
    /// `requireCapability()`.
    public func evaluateGates(
        prompt: String,
        runtime: CursorRuntimeKind,
        repoPath: String?
    ) -> CursorGateVerdict {
        let sensitivity = SensitiveRepoMatcher.evaluate(repoPath: repoPath)
        let effectiveRuntime: CursorRuntimeKind = sensitivity.forceLocal ? .local : runtime
        let redaction = PromptRedactor.redact(prompt)
        let audit = RedactionAuditEntry(
            runId: nil,
            count: redaction.count,
            ruleIds: redaction.ruleIds,
            promptHash: redaction.promptHash,
            repoPath: repoPath,
            sensitiveRepoMatched: sensitivity.matchedPattern,
            forcedLocal: sensitivity.forceLocal && runtime == .cloud,
            redactedAt: Date()
        )
        pendingAudits.append(audit)
        return CursorGateVerdict(
            scrubbedPrompt: redaction.scrubbed,
            effectiveRuntime: effectiveRuntime,
            sensitivity: sensitivity,
            redaction: redaction,
            auditQueued: audit
        )
    }

    // MARK: - Private capability gate

    /// Throw `capabilityMissing` if pre-flight fails. Sets `cachedCapability`.
    private func requireCapability() throws {
        let cap = capabilityCheck()
        self.cachedCapability = cap
        if !cap.ok {
            throw CursorError.capabilityMissing(cap.reason ?? "unknown")
        }
    }

    private func ensureSidecarProcess() throws {
        if let p = process, p.isRunning, stdin != nil {
            return
        }
        guard let node = configuredNodePath ?? CursorRuntime.locateNode() else {
            throw CursorError.capabilityMissing("node binary not found on PATH")
        }
        guard FileManager.default.fileExists(atPath: sidecarEntrypoint.path) else {
            throw CursorError.capabilityMissing("sidecar entrypoint missing at \(sidecarEntrypoint.path)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = [sidecarEntrypoint.path]
        proc.currentDirectoryURL = sidecarRoot

        var env = ProcessInfo.processInfo.environment
        env[CursorRuntime.envVarName] = try apiKeyOverride ?? CursorRuntime.readApiKey()
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw CursorError.spawnFailed("\(node): \(error.localizedDescription)")
        }

        process = proc
        spawnedAt = Date()
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        stderr = errPipe.fileHandleForReading
        stdoutBuffer.removeAll(keepingCapacity: true)

        stdout?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                if data.isEmpty {
                    await self?.handleSidecarClosed()
                } else {
                    await self?.ingestStdout(data)
                }
            }
        }
        stderr?.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    private func request<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params,
        timeout: TimeInterval = 120
    ) async throws -> Result {
        try ensureSidecarProcess()
        let id = nextRequestId
        nextRequestId += 1
        let envelope = CursorJSONRPCRequest(id: id, method: method, params: params)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(envelope)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pendingRequests[id] = cont
            do {
                var line = body
                line.append(0x0A)
                try stdin?.write(contentsOf: line)
            } catch {
                pendingRequests.removeValue(forKey: id)
                cont.resume(throwing: CursorError.ipcError("sidecar stdin write failed: \(error.localizedDescription)"))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutRequest(id: id, method: method, seconds: Int(timeout))
            }
        }.decoded(as: Result.self)
    }

    private func ingestStdout(_ data: Data) {
        stdoutBuffer.append(data)
        let newline = Data([0x0A])
        while let range = stdoutBuffer.firstRange(of: newline) {
            let line = stdoutBuffer.subdata(in: 0..<range.lowerBound)
            stdoutBuffer.removeSubrange(0..<range.upperBound)
            handleJSONRPCLine(line)
        }
    }

    private func handleJSONRPCLine(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = Self.numericRequestId(from: obj["id"]),
              let cont = pendingRequests.removeValue(forKey: id) else {
            return
        }
        if let error = obj["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            let message = error["message"] as? String ?? "unknown sidecar error"
            let data = error["data"].map { "\($0)" }
            cont.resume(throwing: CursorError.sidecarError(code: code, message: message, data: data))
            return
        }
        if let result = obj["result"],
           let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
            cont.resume(returning: resultData)
        } else {
            cont.resume(returning: Data("{}".utf8))
        }
    }

    private func handleSidecarClosed() {
        for (_, cont) in pendingRequests {
            cont.resume(throwing: CursorError.ipcError("cursor sidecar stdout closed"))
        }
        pendingRequests.removeAll()
        process = nil
        spawnedAt = nil
    }

    private func timeoutRequest(id: Int, method: String, seconds: Int) {
        if let cont = pendingRequests.removeValue(forKey: id) {
            cont.resume(throwing: CursorError.timeout("\(method) timed out after \(seconds)s"))
        }
    }

    private nonisolated static func numericRequestId(from raw: Any?) -> Int? {
        switch raw {
        case let id as Int: return id
        case let id as NSNumber: return id.intValue
        default: return nil
        }
    }

    // MARK: - Static helpers (nonisolated)

    /// Locate `node` on PATH. Checks common Homebrew/system paths, then falls back to `/usr/bin/which`.
    public nonisolated static func locateNode() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/opt/homebrew/opt/node@22/bin/node",
            "/opt/homebrew/opt/node@20/bin/node",
            "/usr/bin/node",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["node"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) {
                    return s
                }
            }
        } catch {
            // ignore; treat as missing
        }
        return nil
    }

    public nonisolated static func detectNodeVersion(at path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
        } catch {
            // ignore
        }
        return nil
    }

    public nonisolated static func readSidecarVersion(root: URL) -> String? {
        let pkg = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkg) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    /// Read the Cursor API key from Keychain. Throws `CursorError.authFailed` on miss.
    /// Surface intended for Wave 2 spawn path; exposed publicly so unit tests can
    /// verify the lookup path without needing the full spawn machinery.
    public nonisolated static func readApiKey() throws -> String {
        do {
            let entry = try CredentialManager.shared.read(
                service: keychainService,
                account: keychainAccount
            )
            guard let pw = entry.password, !pw.isEmpty else {
                throw CursorError.authFailed("Keychain entry exists but password field is empty")
            }
            return pw
        } catch let e as CursorError {
            throw e
        } catch {
            throw CursorError.authFailed("Keychain read failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cost emission (Wave 5b offline stub-emit surface)
    //
    // Sidecar will call into this once PKT-3.4.1.W2 ships its event stream.
    // Today this is exercised by tests + manual cost-replay paths so the
    // CursorCostLedger → CursorAutoPauseController feedback loop is
    // already wired end-to-end before the runtime side is finished.

    /// Record a cost delta for a run into the shared `CursorCostLedger`.
    /// Returns the post-record snapshot (total/tier/crossed-threshold).
    @discardableResult
    public nonisolated static func emitCost(
        runId: String,
        cents: Int,
        runtime: CursorRuntimeKind? = nil,
        model: String? = nil
    ) async -> CursorCostRecordResult {
        await CursorCostLedger.shared.record(
            runId: runId,
            cents: cents,
            runtime: runtime?.rawValue,
            model: model
        )
    }
}

private struct CursorJSONRPCRequest<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

private struct CursorAgentRunRequest: Encodable {
    let prompt: String
    let runtime: CursorRuntimeKind
    let model: String?
    let repoPath: String?
    let branch: String?
    let maxCostCents: Int?
}

private struct CursorAgentListRequest: Encodable {
    let status: CursorRunStatus?
    let runtime: CursorRuntimeKind?
}

private struct CursorIdRequest: Encodable {
    let id: String
}

private struct CursorRunListResponse: Decodable {
    let runs: [CursorRun]
}

private struct CursorArtifactListResponse: Decodable {
    let artifacts: [CursorArtifact]
}

private extension Data {
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: self)
    }
}
