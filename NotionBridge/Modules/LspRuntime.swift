// LspRuntime.swift – PKT-745 W2: per-workspace LSP session supervision (Option C)
// NotionBridge · Modules · dev/
//
// Per PM Decision Log #29 (2026-05-11, Reflow #13): Option C — LspRuntime owns
// supervision internally + LspModule exposes lsp_session_list for observability.
// DoD #3 reframed: "Long-running LSP sessions supervised + visible via
// `lsp_session_list`" (substitute for `bg_process_list`).
//
// Architecture:
//   - One LspSession actor per (language, workspaceRoot) pair, registered in LspRuntime.
//   - Lazy spawn on first textDocument/* request; reused across subsequent calls.
//   - Idle dispose after `idleTimeoutSeconds` (default 900s); reset on every request.
//   - JSON-RPC over stdio with `Content-Length: N\r\n\r\n<JSON>` framing.
//   - textDocument/didOpen sent on first touch per file (content read from disk).
//
// Concurrency:
//   - LspRuntime is an actor; serializes session registry mutations.
//   - Each LspSession is its own actor; serializes per-session stdin writes,
//     pendingRequests continuations, and open-file tracking.
//   - Background read loop runs as a detached Task on FileHandle.bytes.
//   - Responses cross the actor boundary as `Data?` (Sendable JSON bytes) so callers
//     can decode in their own context without violating actor isolation rules.
//
// Scope limits (per packet Hard Limits & ## Scope OUT clauses):
//   - Single-root workspaces only.
//   - No textDocument/didChange (read-only ops; rename reads from disk on apply).
//   - No code actions / quickfixes (rename only).
//   - Best-effort terminate: SIGTERM via Process.terminate(), no shutdown handshake.

import Foundation

public actor LspRuntime {
    public static let shared = LspRuntime()

    public struct SessionInfo: Sendable {
        public let language: String
        public let workspaceRoot: String
        public let pid: Int32
        public let serverPath: String
        public let serverName: String?
        public let serverVersion: String?
        public let spawnedAt: Date
        public let lastUsedAt: Date
        public let idleSeconds: TimeInterval
        public let requestCount: Int
        public let openFileCount: Int
    }

    public enum LspError: Error, Sendable, CustomStringConvertible {
        case spawnFailed(String)
        case initializeFailed(String)
        case rpcError(code: Int, message: String)
        case streamClosed
        case decodingFailed(String)
        case fileReadFailed(String)
        case unsupportedLanguage(String)
        case timeout(method: String, seconds: Int)

        public var description: String {
            switch self {
            case .spawnFailed(let m):            return "LSP spawn failed: \(m)"
            case .initializeFailed(let m):       return "LSP initialize failed: \(m)"
            case .rpcError(let c, let m):        return "LSP RPC error \(c): \(m)"
            case .streamClosed:                  return "LSP stdout closed unexpectedly"
            case .decodingFailed(let m):         return "LSP JSON decoding failed: \(m)"
            case .fileReadFailed(let m):         return "file read failed: \(m)"
            case .unsupportedLanguage(let l):    return "unsupported LSP language: \(l)"
            case .timeout(let m, let s):         return "LSP request \(m) timed out after \(s)s"
            }
        }
    }

    private var sessions: [String: LspSession] = [:]
    private var idleTimeoutSeconds: TimeInterval = 15 * 60

    private init() {}

    /// Override default 15-minute idle dispose. Affects newly created sessions only.
    public func setIdleTimeout(_ seconds: TimeInterval) { idleTimeoutSeconds = seconds }
    public func currentIdleTimeout() -> TimeInterval { idleTimeoutSeconds }

    private func sessionKey(language: String, workspaceRoot: String) -> String {
        "\(language)::\(workspaceRoot)"
    }

    /// Ensure an initialized session exists for (language, workspaceRoot).
    /// Lazy-spawns on first call; reuses on subsequent calls.
    public func ensureSession(
        language: String,
        workspaceRoot: String,
        serverPath: String
    ) async throws -> LspSession {
        let key = sessionKey(language: language, workspaceRoot: workspaceRoot)
        if let existing = sessions[key] { return existing }
        let timeout = idleTimeoutSeconds
        let session = try await LspSession.spawn(
            language: language,
            workspaceRoot: workspaceRoot,
            serverPath: serverPath,
            idleTimeoutSeconds: timeout,
            onIdle: { [weak self] in
                await self?.dispose(language: language, workspaceRoot: workspaceRoot)
            }
        )
        sessions[key] = session
        return session
    }

    /// Tear down one session (drops registry entry + terminates process).
    public func dispose(language: String, workspaceRoot: String) async {
        let key = sessionKey(language: language, workspaceRoot: workspaceRoot)
        guard let session = sessions.removeValue(forKey: key) else { return }
        await session.terminate()
    }

    /// Tear down all sessions. Best-effort.
    public func disposeAll() async {
        let snapshot = sessions
        sessions.removeAll()
        for (_, s) in snapshot { await s.terminate() }
    }

    /// Snapshot every live session for the lsp_session_list tool.
    public func listSessions() async -> [SessionInfo] {
        var out: [SessionInfo] = []
        for (_, s) in sessions { out.append(await s.snapshot()) }
        return out.sorted { ($0.language, $0.workspaceRoot) < ($1.language, $1.workspaceRoot) }
    }
}

// MARK: - LspSession

public actor LspSession {
    public nonisolated let language: String
    public nonisolated let workspaceRoot: String
    public nonisolated let serverPath: String
    public nonisolated let spawnedAt: Date
    public private(set) var lastUsedAt: Date
    public private(set) var requestCount: Int = 0
    public private(set) var serverName: String?
    public private(set) var serverVersion: String?

    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Data?, Error>] = [:]
    private var openFiles: Set<String> = []
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private let idleTimeoutSeconds: TimeInterval
    private let onIdle: @Sendable () async -> Void
    private var terminated = false

    fileprivate init(
        language: String,
        workspaceRoot: String,
        serverPath: String,
        process: Process,
        stdin: FileHandle,
        stdout: FileHandle,
        stderr: FileHandle,
        idleTimeoutSeconds: TimeInterval,
        onIdle: @Sendable @escaping () async -> Void
    ) {
        self.language = language
        self.workspaceRoot = workspaceRoot
        self.serverPath = serverPath
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.spawnedAt = Date()
        self.lastUsedAt = Date()
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.onIdle = onIdle
    }

    /// Spawn an LSP server process and complete its `initialize` handshake.
    fileprivate static func spawn(
        language: String,
        workspaceRoot: String,
        serverPath: String,
        idleTimeoutSeconds: TimeInterval,
        onIdle: @Sendable @escaping () async -> Void
    ) async throws -> LspSession {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: serverPath)
        switch language {
        case "typescript": proc.arguments = ["--stdio"]
        case "swift":      proc.arguments = []
        default:           throw LspRuntime.LspError.unsupportedLanguage(language)
        }
        proc.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw LspRuntime.LspError.spawnFailed("\(serverPath): \(error.localizedDescription)")
        }
        let session = LspSession(
            language: language,
            workspaceRoot: workspaceRoot,
            serverPath: serverPath,
            process: proc,
            stdin: inPipe.fileHandleForWriting,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading,
            idleTimeoutSeconds: idleTimeoutSeconds,
            onIdle: onIdle
        )
        await session.startBackgroundTasks()
        try await session.performInitialize()
        return session
    }

    public func currentPid() -> Int32 { process.processIdentifier }

    public func snapshot() -> LspRuntime.SessionInfo {
        LspRuntime.SessionInfo(
            language: language,
            workspaceRoot: workspaceRoot,
            pid: process.processIdentifier,
            serverPath: serverPath,
            serverName: serverName,
            serverVersion: serverVersion,
            spawnedAt: spawnedAt,
            lastUsedAt: lastUsedAt,
            idleSeconds: Date().timeIntervalSince(lastUsedAt),
            requestCount: requestCount,
            openFileCount: openFiles.count
        )
    }

    // MARK: - Public RPC API

    /// Ensure `textDocument/didOpen` has been sent for this file (idempotent per session).
    public func ensureFileOpen(_ filePath: String) async throws {
        if openFiles.contains(filePath) { return }
        let content: String
        do {
            content = try String(contentsOf: URL(fileURLWithPath: filePath), encoding: .utf8)
        } catch {
            throw LspRuntime.LspError.fileReadFailed("\(filePath): \(error.localizedDescription)")
        }
        let languageId = Self.lspLanguageId(forLanguage: language, filePath: filePath)
        try await sendNotification(method: "textDocument/didOpen", params: [
            "textDocument": [
                "uri":        URL(fileURLWithPath: filePath).absoluteString,
                "languageId": languageId,
                "version":    1,
                "text":       content
            ]
        ])
        openFiles.insert(filePath)
    }

    /// Send a JSON-RPC request and await its response.
    /// Returns the `result` field re-encoded as JSON bytes (Sendable). The empty case is `nil`.
    /// Throws `LspError.rpcError` on protocol errors, `LspError.timeout` after `timeout` seconds.
    public func sendRequest(method: String, params: Any, timeout: TimeInterval = 30) async throws -> Data? {
        try requireAlive()
        lastUsedAt = Date()
        requestCount += 1
        resetIdleTimer()
        let id = nextRequestId
        nextRequestId += 1
        let body: Data
        do {
            let message: [String: Any] = [
                "jsonrpc": "2.0",
                "id":      id,
                "method":  method,
                "params":  params
            ]
            body = try JSONSerialization.data(withJSONObject: message)
        } catch {
            throw LspRuntime.LspError.decodingFailed(error.localizedDescription)
        }
        let header = "Content-Length: \(body.count)\r\n\r\n".data(using: .ascii) ?? Data()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            pendingRequests[id] = cont
            do {
                try stdin.write(contentsOf: header + body)
            } catch {
                pendingRequests.removeValue(forKey: id)
                cont.resume(throwing: LspRuntime.LspError.streamClosed)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutRequest(id: id, method: method, seconds: Int(timeout))
            }
        }
    }

    /// Send a JSON-RPC notification (no response expected).
    public func sendNotification(method: String, params: Any) async throws {
        try requireAlive()
        lastUsedAt = Date()
        resetIdleTimer()
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method":  method,
            "params":  params
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: message)
        } catch {
            throw LspRuntime.LspError.decodingFailed(error.localizedDescription)
        }
        let header = "Content-Length: \(body.count)\r\n\r\n".data(using: .ascii) ?? Data()
        do {
            try stdin.write(contentsOf: header + body)
        } catch {
            throw LspRuntime.LspError.streamClosed
        }
    }

    /// Best-effort teardown: cancel tasks, fail pending RPCs, SIGTERM the process.
    public func terminate() async {
        if terminated { return }
        terminated = true
        idleTask?.cancel(); idleTask = nil
        readTask?.cancel()
        stderrTask?.cancel()
        failAllPendingRequests(LspRuntime.LspError.streamClosed)
        try? stdin.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: - Background tasks

    private func startBackgroundTasks() {
        readTask = Task { [weak self] in await self?.runReadLoop() }
        stderrTask = Task { [weak self] in await self?.runStderrDrainLoop() }
        resetIdleTimer()
    }

    private func runReadLoop() async {
        var buffer = Data()
        do {
            for try await byte in stdout.bytes {
                buffer.append(byte)
                while let message = try Self.extractFramedMessage(from: &buffer) {
                    await handleIncomingMessage(message)
                }
            }
        } catch {
            // stream closed or framing error — fall through to fail pending
        }
        failAllPendingRequests(LspRuntime.LspError.streamClosed)
    }

    private func runStderrDrainLoop() async {
        do {
            for try await _ in stderr.bytes {
                // drain; per-line capture deferred to W3 (diagnostics surface)
            }
        } catch {}
    }

    private nonisolated static func extractFramedMessage(from buffer: inout Data) throws -> Data? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerRange = buffer.firstRange(of: sep) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let header = String(data: headerData, encoding: .ascii) else {
            throw LspRuntime.LspError.decodingFailed("non-ASCII header")
        }
        var contentLength = 0
        for line in header.components(separatedBy: "\r\n") where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1]) ?? 0
            }
        }
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard buffer.count >= bodyEnd else { return nil }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(0..<bodyEnd)
        return body
    }

    private func handleIncomingMessage(_ data: Data) async {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // (1) Response to one of our outgoing requests: integer id, no `method` field.
        if let id = obj["id"] as? Int, obj["method"] == nil {
            if let cont = pendingRequests.removeValue(forKey: id) {
                if let error = obj["error"] as? [String: Any] {
                    let code = error["code"] as? Int ?? -32000
                    let msg = error["message"] as? String ?? "(no message)"
                    cont.resume(throwing: LspRuntime.LspError.rpcError(code: code, message: msg))
                } else if let r = obj["result"] {
                    let resultData = try? JSONSerialization.data(withJSONObject: r, options: [.fragmentsAllowed])
                    cont.resume(returning: resultData)
                } else {
                    cont.resume(returning: nil)
                }
            }
            return
        }

        // (2) Server-initiated request: has both `id` and `method`. We must reply, or the server hangs.
        if let method = obj["method"] as? String, let id = obj["id"] {
            await handleServerRequest(id: id, method: method, params: obj["params"])
            return
        }

        // (3) Server-initiated notification: has `method`, no `id`. Drain quietly.
        if let method = obj["method"] as? String {
            await handleServerNotification(method: method, params: obj["params"])
            return
        }
    }

    // MARK: - Server-initiated request/notification handling (PKT-777 W1)

    /// Respond to server-initiated requests so the server does not hang.
    /// - `workspace/configuration`: reply with an array of `null` matching the requested item count.
    /// - Any other method: reply with JSON-RPC MethodNotFound (-32601).
    private func handleServerRequest(id: Any, method: String, params: Any?) async {
        switch method {
        case "workspace/configuration":
            // Per LSP spec, `result` is an array with one entry per `ConfigurationItem` requested.
            // NotionBridge tracks no client-side LSP configuration, so reply all-null. Servers
            // (notably sourcekit-lsp) treat null entries as "use defaults".
            let itemCount: Int
            if let p = params as? [String: Any], let items = p["items"] as? [Any] {
                itemCount = max(1, items.count)
            } else {
                itemCount = 1
            }
            let nulls: [Any] = Array(repeating: NSNull(), count: itemCount)
            await sendResponse(id: id, result: nulls)
        default:
            await sendResponseError(
                id: id,
                code: -32601,
                message: "method '\(method)' not supported by NotionBridge LSP client"
            )
        }
    }

    /// Drain server-initiated notifications. `window/showMessage` + `window/logMessage` are
    /// silently consumed (no client UI surface). `textDocument/publishDiagnostics` is reserved
    /// for the W2 push-diagnostics cache; for now it is also drained.
    private func handleServerNotification(method: String, params: Any?) async {
        switch method {
        case "window/showMessage", "window/logMessage":
            return
        case "textDocument/publishDiagnostics":
            // W2 (push-diagnostics cache) will store params["diagnostics"] keyed by params["uri"].
            return
        default:
            return
        }
    }

    /// Write a JSON-RPC success response with `result` to the server.
    private func sendResponse(id: Any, result: Any) async {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id":      id,
            "result":  result
        ]
        await writeFramedMessage(message)
    }

    /// Write a JSON-RPC error response.
    private func sendResponseError(id: Any, code: Int, message: String) async {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id":      id,
            "error":   ["code": code, "message": message]
        ]
        await writeFramedMessage(payload)
    }

    /// Best-effort framed write. Failures are swallowed because the read-loop will surface
    /// stream closure to pending requests via the existing `failAllPendingRequests` path.
    private func writeFramedMessage(_ message: [String: Any]) async {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        let header = "Content-Length: \(body.count)\r\n\r\n".data(using: .ascii) ?? Data()
        try? stdin.write(contentsOf: header + body)
    }

    // MARK: - Internal helpers

    private func requireAlive() throws {
        if terminated || !process.isRunning {
            throw LspRuntime.LspError.streamClosed
        }
    }

    private func failAllPendingRequests(_ error: Error) {
        let snapshot = pendingRequests
        pendingRequests.removeAll()
        for (_, cont) in snapshot { cont.resume(throwing: error) }
    }

    private func timeoutRequest(id: Int, method: String, seconds: Int) {
        if let cont = pendingRequests.removeValue(forKey: id) {
            cont.resume(throwing: LspRuntime.LspError.timeout(method: method, seconds: seconds))
        }
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        let timeout = idleTimeoutSeconds
        let cb = onIdle
        idleTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await cb()
        }
    }

    private func performInitialize() async throws {
        let workspaceURI = URL(fileURLWithPath: workspaceRoot).absoluteString
        let workspaceName = (workspaceRoot as NSString).lastPathComponent
        let params: [String: Any] = [
            "processId":        NSNumber(value: ProcessInfo.processInfo.processIdentifier),
            "clientInfo":       ["name": "NotionBridge", "version": AppVersion.marketing],
            "locale":           "en",
            "rootUri":          workspaceURI,
            "rootPath":         workspaceRoot,
            "workspaceFolders": [["uri": workspaceURI, "name": workspaceName]],
            "capabilities": [
                "textDocument": [
                    "synchronization":    ["didSave": true, "willSave": false],
                    "hover":              ["contentFormat": ["markdown", "plaintext"]],
                    "publishDiagnostics": ["relatedInformation": true],
                    "references":         ["dynamicRegistration": false],
                    "definition":         ["dynamicRegistration": false, "linkSupport": true],
                    "rename":             ["prepareSupport": false]
                ],
                "workspace": [
                    "workspaceFolders": true,
                    "configuration":    true,
                    "applyEdit":        true
                ]
            ]
        ]
        let result: Data?
        do {
            result = try await sendRequest(method: "initialize", params: params, timeout: 30)
        } catch {
            throw LspRuntime.LspError.initializeFailed("\(error)")
        }
        if let data = result,
           let dict = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
           let info = dict["serverInfo"] as? [String: Any] {
            self.serverName = info["name"] as? String
            self.serverVersion = info["version"] as? String
        }
        try await sendNotification(method: "initialized", params: [String: Any]())
    }

    /// Map (LspModule language family, file extension) to the LSP-spec `languageId`.
    private static func lspLanguageId(forLanguage language: String, filePath: String) -> String {
        switch language {
        case "typescript":
            let ext = (filePath as NSString).pathExtension.lowercased()
            switch ext {
            case "ts":                return "typescript"
            case "tsx":               return "typescriptreact"
            case "js", "mjs", "cjs":  return "javascript"
            case "jsx":               return "javascriptreact"
            default:                  return "typescript"
            }
        case "swift":
            return "swift"
        default:
            return language
        }
    }
}
