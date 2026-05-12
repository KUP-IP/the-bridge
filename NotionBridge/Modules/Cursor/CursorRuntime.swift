// CursorRuntime.swift — PKT-3.4.1 (Bridge v2.2) + PKT-3.4.3 Wave 1 hardening
// NotionBridge · Modules · Cursor
//
// Owns the Node `cursor-sidecar` lifecycle and the (eventual) JSON-RPC 2.0
// IPC over stdio. Wave 1 (PKT-3.4.1) shipped the capability surface, the
// Keychain → env wire-through, and the public API contract; full bidirectional
// IPC + sidecar runtime impl lands in Wave 2 (PKT-3.4.1.W2) once the published
// `@cursor/sdk@1.0.12` npm tarball ships its `.d.ts` declarations (currently
// absent — verified via `find @cursor/sdk/dist -name '*.d.ts'` returning zero
// results), or until we vendor minimal type declarations from the SDK's
// upstream source.
//
// PKT-3.4.3 Wave 1 (this packet) layers a pre-dispatch hardening pass on top
// of the Wave 1 contract: `agentRun(...)` now runs sensitive-repo allowlist
// evaluation + prompt redaction BEFORE `requireCapability()`. The scrubbed
// prompt + effective runtime + audit entry are what W2's live IPC will
// dispatch once @cursor/sdk types ship. Pure (never throws); the Wave 1
// `notImplemented` contract after the capability gate is preserved.
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

    /// PKT-3.4.3 Wave 1: queued redaction audit entries waiting for W2's
    /// AI LOGS DS writer to drain. See `RedactionAuditEntry`.
    private var pendingAudits: [RedactionAuditEntry] = []

    // MARK: - Init

    public init(
        sidecarRoot: URL = CursorRuntime.defaultSidecarRoot(),
        nodePath: String? = nil
    ) {
        self.sidecarRoot = sidecarRoot
        if let p = nodePath, FileManager.default.isExecutableFile(atPath: p) {
            self.configuredNodePath = p
        } else {
            self.configuredNodePath = nil
        }
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
        process = nil
        spawnedAt = nil
        cachedCapability = nil
    }

    // MARK: - Public API (Wave 2 wires real IPC; Wave 1 returns notImplemented after capability gate)

    public func ping() async throws -> [String: String] {
        try requireCapability()
        throw CursorError.notImplemented("ping: sidecar IPC wiring deferred to PKT-3.4.1.W2")
    }

    public func capabilityProbe() async throws -> [String: String] {
        try requireCapability()
        throw CursorError.notImplemented("capability_probe (live): sidecar IPC wiring deferred to PKT-3.4.1.W2")
    }

    public func agentRun(prompt: String, runtime: CursorRuntimeKind, model: String?, repoPath: String?, branch: String?, maxCostCents: Int?) async throws -> CursorRun {
        // PKT-3.4.3 Wave 1: pre-dispatch hardening pass (redaction + sensitive-repo allowlist).
        // Audit entry queued for PKT-3.4.1.W2 AI LOGS writer; the scrubbed prompt + effective
        // runtime are what W2's live IPC will dispatch.
        let verdict = evaluateGates(prompt: prompt, runtime: runtime, repoPath: repoPath)
        _ = (verdict, model, branch, maxCostCents)
        try requireCapability()
        throw CursorError.notImplemented("agent_run: sidecar @cursor/sdk wiring deferred to PKT-3.4.1.W2 (SDK .d.ts not shipped in npm tarball)")
    }

    public func agentStatus(id: String) async throws -> CursorRun {
        _ = id
        try requireCapability()
        throw CursorError.notImplemented("agent_status: sidecar @cursor/sdk wiring deferred to PKT-3.4.1.W2")
    }

    public func agentList(statusFilter: CursorRunStatus?, runtimeFilter: CursorRuntimeKind?) async throws -> [CursorRun] {
        _ = (statusFilter, runtimeFilter)
        try requireCapability()
        throw CursorError.notImplemented("agent_list: sidecar @cursor/sdk wiring deferred to PKT-3.4.1.W2")
    }

    public func agentCancel(id: String) async throws -> CursorRun {
        _ = id
        try requireCapability()
        throw CursorError.notImplemented("agent_cancel: sidecar @cursor/sdk wiring deferred to PKT-3.4.1.W2")
    }

    public func agentArtifacts(id: String) async throws -> [CursorArtifact] {
        _ = id
        try requireCapability()
        throw CursorError.notImplemented("agent_artifacts: sidecar @cursor/sdk wiring deferred to PKT-3.4.1.W2")
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
