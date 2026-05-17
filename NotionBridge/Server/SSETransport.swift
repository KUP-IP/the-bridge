// SSETransport.swift — SSE Server Transport on :9700
// NotionBridge · Server
//
// Built-in SSE support via MCP Swift SDK v0.11.0 StatefulHTTPServerTransport.
// NIO HTTP server with per-session MCP Server instances sharing one ToolRouter.
// PKT-318: V1-10 SSE Transport Implementation
// PKT-332: Added graceful bind-failure handling — SSE is optional, stdio continues
// PKT-336: Added legacy SSE transport (GET /sse + POST /messages) for Notion compatibility
// PKT-338: V1-SSE-FIX — Fixed NIO ChannelPipeline precondition crash by removing actor
//          reference from SSEHTTPHandler. Handler now stores non-actor references only.
// V1-QUALITY-C2: Added GET /health endpoint returning JSON status. Client identification
//   from MCP initialize request clientInfo. onClientConnected callback to StatusBarController.

import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

// MARK: - Legacy SSE Bridge (PKT-336)

/// Thread-safe storage for legacy SSE channel references.
/// Handles SSE event writing directly to NIO channels on their event loops.
/// V1: supports multiple concurrent connections mapped by session ID.
public final class LegacySSEBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [String: Channel] = [:]
    private var clientNames: [String: String] = [:]  // PKT-366 F13
    
    public init() {}

    /// Register a new SSE stream connection. Returns the assigned session ID.
    public func register(channel: Channel) -> String {
        let id = UUID().uuidString
        let total: Int = lock.withLock {
            channels[id] = channel
            return channels.count
        }
        print("[SSE-Legacy] Client connected — session \(id.prefix(8))… (total: \(total))")
        return id
    }

    /// PKT-366 F13: Associate a client name with a legacy session.
    public func setClientName(sessionID: String, name: String) {
        lock.withLock { clientNames[sessionID] = name }
    }

    /// Remove a disconnected SSE session. Returns client name if known (F13).
    @discardableResult
    public func remove(sessionID: String) -> String? {
        let result: (remaining: Int, clientName: String?) = lock.withLock {
            channels.removeValue(forKey: sessionID)
            let name = clientNames.removeValue(forKey: sessionID)
            return (channels.count, name)
        }
        print("[SSE-Legacy] Client disconnected — session \(sessionID.prefix(8))… (remaining: \(result.remaining))")
        return result.clientName
    }

    /// Send an SSE event to the client's stream.
    /// If sessionID is nil and only one client is connected, sends to that client (V1 fallback).
    public func sendEvent(sessionID: String?, event: String, data: String) {
        let resolved: (channel: Channel?, reason: String, activeCount: Int) = lock.withLock {
            if let id = sessionID, let ch = channels[id] {
                return (ch, "direct:\(id.prefix(8))", channels.count)
            }
            if sessionID != nil {
                return (nil, "missing-session", channels.count)
            }
            if channels.count == 1 {
                return (channels.values.first, "single-client-fallback", channels.count)
            }
            return (nil, "ambiguous-fallback", channels.count)
        }
        guard let channel = resolved.channel else {
            print("[SSE-Legacy] No channel for session — event dropped (\(resolved.reason), active: \(resolved.activeCount))")
            return
        }
        let payload = "event: \(event)\ndata: \(data)\n\n"
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            let part = HTTPServerResponsePart.body(IOData.byteBuffer(buffer))
            channel.writeAndFlush(part, promise: nil)
        }
    }

    /// Number of active legacy SSE connections.
    public var activeCount: Int {
        lock.withLock { channels.count }
    }
}

// MARK: - HTTP Route Classifier (PKT-800 S1)

/// Pure, deterministic classification of an inbound HTTP request on the
/// Bridge NIO listener into exactly one route. Single source of truth for
/// dispatch order so the live handler and tests cannot drift: the new
/// PRM route is provably distinct from `/health`, `/sse`, `/messages`,
/// the job callback, and the Streamable HTTP `/mcp` endpoint.
public enum MCPHTTPRoute: Equatable, Sendable {
    case corsPreflight
    case health
    /// RFC 9728 Protected Resource Metadata (`GET /.well-known/oauth-protected-resource`).
    case protectedResourceMetadata
    case legacySSE
    case legacyMessages
    /// `POST /jobs/{id}/run` — the captured job id.
    case jobsRun(String)
    /// The Streamable HTTP MCP endpoint (`endpoint`, e.g. `/mcp`).
    case mcpEndpoint
    case notFound

    /// Classifies `method` + `path` against `endpoint`. `path` must be the
    /// query-stripped request path. Order mirrors the live handler exactly.
    public static func classify(method: String, path: String, endpoint: String) -> MCPHTTPRoute {
        let m = method.uppercased()
        if m == "OPTIONS" { return .corsPreflight }
        if m == "GET" && path == "/health" { return .health }
        if m == "GET" && path == "/.well-known/oauth-protected-resource" {
            return .protectedResourceMetadata
        }
        if m == "GET" && path == "/sse" { return .legacySSE }
        if m == "POST" && path == "/messages" { return .legacyMessages }
        if m == "POST" && path.hasPrefix("/jobs/") && path.hasSuffix("/run") {
            let jobId = String(path.dropFirst("/jobs/".count).dropLast("/run".count))
            return .jobsRun(jobId)
        }
        if path == endpoint { return .mcpEndpoint }
        return .notFound
    }
}

// MARK: - SSE Server

/// Manages an SSE-based MCP server on a configurable port.
/// Each connecting client gets its own MCP session backed by StatefulHTTPServerTransport.
/// All sessions share the same ToolRouter for tool dispatch.
///
/// PKT-336: Also serves legacy SSE transport (GET /sse + POST /messages) for clients
/// like Notion that use the standard split SSE spec instead of Streamable HTTP.
///
/// V1-QUALITY-C2: Serves GET /health endpoint. Extracts clientInfo from initialize requests.
public actor SSEServer {
    private let host: String
    private let port: Int
    private let router: ToolRouter
    private let onToolCall: @MainActor @Sendable () -> Void
    private let onClientConnected: @MainActor @Sendable (String, String) -> Void
    private let onClientDisconnected: @MainActor @Sendable (String) -> Void  // PKT-366 F13
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    private let sessionTimeout: TimeInterval
    private let sessionCleanupInterval: TimeInterval
    private let maxHTTPSessions: Int
    private let toolAllowlist: Set<String>?
    private var totalSessionsCreated = 0
    private var totalSessionsExpired = 0
    private var totalSessionsEvicted = 0
    private var totalSessionsClosed = 0

    public nonisolated let endpoint: String = "/mcp"

    /// PKT-336: Thread-safe bridge for legacy SSE connections (no actor boundary for channels).
    public nonisolated let legacy = LegacySSEBridge()

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
        var clientName: String?
        var clientVersion: String?
    }

    public struct SessionRuntimeDiagnostics: Sendable {
        public let activeHTTPClients: Int
        public let activeLegacyClients: Int
        public let totalSessionsCreated: Int
        public let totalSessionsExpired: Int
        public let totalSessionsEvicted: Int
        public let totalSessionsClosed: Int
        public let maxHTTPSessions: Int
        public let sessionTimeoutSeconds: Int
        public let sessionCleanupIntervalSeconds: Int

        public var activeClients: Int { activeHTTPClients + activeLegacyClients }
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = BridgeConstants.defaultSSEPort,
        router: ToolRouter,
        onToolCall: @escaping @MainActor @Sendable () -> Void,
        onClientConnected: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in },
        onClientDisconnected: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        sessionTimeout: TimeInterval = 300,
        sessionCleanupInterval: TimeInterval = 30,
        maxHTTPSessions: Int = 48,
        toolAllowlist: Set<String>? = nil
    ) {
        let normalizedSessionTimeout = sessionTimeout.isInfinite ? .infinity : max(30, sessionTimeout)
        self.host = host
        self.port = port
        self.router = router
        self.onToolCall = onToolCall
        self.onClientConnected = onClientConnected
        self.onClientDisconnected = onClientDisconnected
        self.sessionTimeout = normalizedSessionTimeout
        self.sessionCleanupInterval = normalizedSessionTimeout.isInfinite
            ? max(5, sessionCleanupInterval)
            : max(5, min(normalizedSessionTimeout, sessionCleanupInterval))
        self.maxHTTPSessions = max(8, maxHTTPSessions)
        self.toolAllowlist = toolAllowlist
    }

    /// PKT-366 F13: Bridge NIO thread to MainActor disconnect UI callback without redundant `await` on stored closure.
    private func notifyClientDisconnected(_ name: String) async {
        let callback = onClientDisconnected
        await MainActor.run { callback(name) }
    }

    // MARK: - Lifecycle

    /// Start accepting SSE connections. Blocks until the channel is closed.
    /// PKT-332: Graceful bind-failure handling — if the port is in use or bind fails,
    /// logs a clear message and returns without crashing. stdio transport continues.
    public func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        // PKT-338 V1-SSE-FIX: Capture non-actor references BEFORE the bootstrap closure.
        let bridge = self.legacy
        let endpointPath = self.endpoint

        // PKT-366 F13: Capture disconnect callback for NIO handler
        let onDisconnect: @Sendable (String) async -> Void = { [weak self] name in
            await self?.notifyClientDisconnected(name)
        }

        // PKT-340 V2-SCHEDULER: Jobs callback handler -- looks up job in sqlite
        // and runs its action chain through the ToolRouter.
        let routerForJobs = self.router
        let jobsCallback: @Sendable (String) async -> Data = { jobId in
            do {
                let result = try await JobsManager.shared.runCallback(jobId: jobId, router: routerForJobs)
                // Encode as minimal JSON so launchd's curl sees 200 OK.
                if case .object = result {
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.sortedKeys]
                    if let data = try? enc.encode(result) { return data }
                }
                return Data("{\"ok\":true}".utf8)
            } catch {
                let msg = error.localizedDescription.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'")
                return Data("{\"ok\":false,\"error\":\"\(msg)\"}".utf8)
            }
        }

        let rpcHandler: @Sendable (Data) async -> Data? = { [weak self] data in
            await self?.processLegacyRPC(data)
        }

        let httpRequestHandler: @Sendable (HTTPRequest) async -> HTTPResponse = { [weak self] request in
            guard let self else {
                return .error(statusCode: 503, .internalError("Server unavailable"))
            }
            return await self.handleHTTPRequest(request)
        }

        // V1-QUALITY-C2: Health endpoint handler — returns JSON status
        let healthHandler: @Sendable () async -> Data = { [weak self] in
            await self?.buildHealthResponse() ?? Data()
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(SSEHTTPHandler(
                        legacyBridge: bridge,
                        endpoint: endpointPath,
                        rpcHandler: rpcHandler,
                        httpRequestHandler: httpRequestHandler,
                        healthHandler: healthHandler,
                        jobsCallbackHandler: jobsCallback,
                        onClientDisconnected: onDisconnect
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            self.channel = channel
            print("[SSE] Listening on \(host):\(port)")
            print("[SSE] Streamable HTTP: POST \(endpoint)")
            print("[SSE] Legacy SSE:      GET /sse + POST /messages")
            print("[SSE] Health:          GET /health")

            Task { await sessionCleanupLoop() }

            try await channel.closeFuture.get()
        } catch {
            print("[SSE] Port \(port) in use — SSE transport disabled, stdio still active")
            print("[SSE] Bind error detail: \(error) (\(error.localizedDescription))")
        }
    }

    /// Stop the SSE server gracefully.
    public func stop() async {
        for id in Array(sessions.keys) {
            await removeSession(id, reason: "server stop")
        }
        try? await channel?.close()
        channel = nil
        print("[SSE] Server stopped")
    }

    /// Invalidate all active HTTP sessions (e.g. after remote access config change).
    /// Existing clients must reconnect and re-authenticate with the current config.
    public func invalidateAllSessions(reason: String) async {
        guard !sessions.isEmpty else { return }
        let count = sessions.count
        for id in Array(sessions.keys) {
            await removeSession(id, reason: reason)
        }
        print("[SSE] Invalidated \(count) session(s): \(reason)")
    }

    /// Number of active sessions (Streamable HTTP + legacy SSE).
    public var activeSessionCount: Int { sessions.count + legacy.activeCount }

    public func sessionRuntimeDiagnostics() -> SessionRuntimeDiagnostics {
        SessionRuntimeDiagnostics(
            activeHTTPClients: sessions.count,
            activeLegacyClients: legacy.activeCount,
            totalSessionsCreated: totalSessionsCreated,
            totalSessionsExpired: totalSessionsExpired,
            totalSessionsEvicted: totalSessionsEvicted,
            totalSessionsClosed: totalSessionsClosed,
            maxHTTPSessions: maxHTTPSessions,
            sessionTimeoutSeconds: sessionTimeout.isFinite ? Int(sessionTimeout) : 0,
            sessionCleanupIntervalSeconds: sessionCleanupInterval.isFinite ? Int(sessionCleanupInterval) : 0
        )
    }

    // MARK: - Health Endpoint (V1-QUALITY-C2)

    /// Build the JSON health response.
    /// Returns: {"status": "running", "tools": N, "uptime": N, "version": "X.Y.Z", "clients": N}
    private func buildHealthResponse() async -> Data {
        let appVersion = AppVersion.resolved
        let toolCount = await router.allRegistrations().count
        let uptime: Int = {
            guard let earliest = sessions.values.map(\.createdAt).min() else { return 0 }
            return Int(Date().timeIntervalSince(earliest))
        }()
        let diagnostics = sessionRuntimeDiagnostics()

        let health: [String: Any] = [
            "status": "running",
            "tools": toolCount,
            "uptime": uptime,
            "version": appVersion,
            "clients": diagnostics.activeClients,
            "httpClients": diagnostics.activeHTTPClients,
            "legacyClients": diagnostics.activeLegacyClients,
            "maxHTTPClients": diagnostics.maxHTTPSessions,
            "sessionTimeoutSeconds": diagnostics.sessionTimeoutSeconds,
            "sessionCleanupIntervalSeconds": diagnostics.sessionCleanupIntervalSeconds,
            "sessionsCreated": diagnostics.totalSessionsCreated,
            "sessionsExpired": diagnostics.totalSessionsExpired,
            "sessionsEvicted": diagnostics.totalSessionsEvicted,
            "sessionsClosed": diagnostics.totalSessionsClosed
        ]

        return (try? JSONSerialization.data(withJSONObject: health, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - Request Routing (Streamable HTTP — POST /mcp)

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                await removeSession(sessionID, reason: "closed via DELETE", incrementClosed: true)
            }

            return response
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequest(body)
        {
            return await createSession(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Missing Mcp-Session-Id header"))
    }

    // MARK: - Session Factory (Streamable HTTP)

    private func createSession(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        // V1-QUALITY-C2: Extract clientInfo from initialize request
        var clientName: String?
        var clientVersion: String?
        if let body = request.body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let params = json["params"] as? [String: Any],
           let clientInfo = params["clientInfo"] as? [String: Any] {
            clientName = clientInfo["name"] as? String
            clientVersion = clientInfo["version"] as? String
        }

        await cleanupExpiredSessions()
        await pruneDuplicateClientSessions(clientName: clientName, clientVersion: clientVersion)
        await evictSessionsIfNeeded(reservingSlots: 1)

        let validationPipeline = MCPHTTPValidation.streamableHTTPPipeline(ssePort: port)

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedIDGenerator(id: sessionID),
            validationPipeline: validationPipeline
        )

        let appVersion = AppVersion.resolved
        let routingInstructions = SkillsModule.buildRoutingInstructions()
        let server = Server(
            name: "NotionBridgeSSE",
            version: appVersion,
            instructions: routingInstructions,
            capabilities: .init(tools: .init())
        )

        let router = self.router
        let onToolCall = self.onToolCall
        let toolAllowlist = self.toolAllowlist
        
        await server.withMethodHandler(ListTools.self) { _ in
            let disabledNames = CredentialsFeature.mergedDisabledToolNames()
            var registrations = await router.enabledRegistrations(disabledNames: disabledNames)
            if let allowlist = toolAllowlist {
                registrations = registrations.filter { allowlist.contains($0.name) }
            }
            // v3.0·0.5: single source of truth — same factory as ServerManager.
            return .init(tools: registrations.map { MCPToolFactory.tool(for: $0) })
        }

        await server.withMethodHandler(CallTool.self) { params in
            if let allowlist = toolAllowlist, !allowlist.contains(params.name) {
                return .init(content: [.text(.init("Error: Tool '\(params.name)' is not allowed in this session"))], isError: true)
            }
            let arguments: Value = params.arguments.map { .object($0) } ?? .object([:])
            let (text, isError) = await router.dispatchFormatted(toolName: params.name, arguments: arguments)
            if !isError { await MainActor.run { onToolCall() } }
            return .init(content: [.text(.init(text))], isError: isError)
        }

        do {
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date(),
                clientName: clientName,
                clientVersion: clientVersion
            )
            totalSessionsCreated += 1

            print("[SSE] Session created: \(sessionID.prefix(8))… (active HTTP: \(sessions.count)/\(maxHTTPSessions))")

            // V1-QUALITY-C2: Notify UI of new client connection
            if let name = clientName {
                let version = clientVersion ?? "unknown"
                let onClientConnected = self.onClientConnected
                await MainActor.run { onClientConnected(name, version) }
                print("[SSE] Client identified: \(name) v\(version)")
            }

            let response = await transport.handleRequest(request)

            if case .error = response {
                await removeSession(sessionID, reason: "initialize failed")
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    // MARK: - Legacy SSE JSON-RPC Processing (PKT-336)

    func processLegacyRPC(_ body: Data) async -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String else {
            return buildRPCError(id: nil, code: -32700, message: "Parse error")
        }

        let requestId = json["id"]

        switch method {
        case "initialize":
            // V1-QUALITY-C2: Extract clientInfo from legacy initialize request
            if let params = json["params"] as? [String: Any],
               let clientInfo = params["clientInfo"] as? [String: Any],
               let name = clientInfo["name"] as? String {
                let version = clientInfo["version"] as? String ?? "unknown"
                let onClientConnected = self.onClientConnected
                await MainActor.run { onClientConnected(name, version) }
                print("[SSE-Legacy] Client identified: \(name) v\(version)")
            }

            let legacyVersion = AppVersion.resolved
            let routingInstructions = SkillsModule.buildRoutingInstructions()
            return buildRPCResponse(id: requestId, result: [
                "protocolVersion": BridgeConstants.mcpProtocolVersion,
                "capabilities": ["tools": [:] as [String: Any]] as [String: Any],
                "serverInfo": ["name": "NotionBridge", "version": legacyVersion] as [String: Any],
                "instructions": routingInstructions
            ] as [String: Any])

        case "notifications/initialized":
            return nil

        case "tools/list":
            let disabledNames = CredentialsFeature.mergedDisabledToolNames()
            var regs = await router.enabledRegistrations(disabledNames: disabledNames)
            if let allowlist = toolAllowlist {
                regs = regs.filter { allowlist.contains($0.name) }
            }
            let tools: [[String: Any]] = regs.map { reg in
                var t: [String: Any] = [
                    "name": reg.name,
                    "description": reg.description
                ]
                if let data = try? JSONEncoder().encode(reg.inputSchema),
                   let schema = try? JSONSerialization.jsonObject(with: data) {
                    t["inputSchema"] = schema
                }
                return t
            }
            return buildRPCResponse(id: requestId, result: ["tools": tools])

        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            
            if let allowlist = toolAllowlist, !allowlist.contains(name) {
                let text = "Error: Tool '\(name)' is not allowed in this session"
                return buildRPCResponse(id: requestId, result: [
                    "content": [["type": "text", "text": text] as [String: Any]],
                    "isError": true
                ] as [String: Any])
            }
            
            let args = params["arguments"] as? [String: Any] ?? [:]

            let argsValue: Value
            if let d = try? JSONSerialization.data(withJSONObject: args),
               let v = try? JSONDecoder().decode(Value.self, from: d) {
                argsValue = v
            } else {
                argsValue = .object([:])
            }

            let (text, isError) = await router.dispatchFormatted(toolName: name, arguments: argsValue)
            if !isError { await MainActor.run { onToolCall() } }
            return buildRPCResponse(id: requestId, result: [
                "content": [["type": "text", "text": text] as [String: Any]],
                "isError": isError
            ] as [String: Any])

        case "ping":
            return buildRPCResponse(id: requestId, result: [:] as [String: Any])

        default:
            return buildRPCError(id: requestId, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func buildRPCResponse(id: Any?, result: Any) -> Data? {
        var resp: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { resp["id"] = id }
        return try? JSONSerialization.data(withJSONObject: resp)
    }

    private func buildRPCError(id: Any?, code: Int, message: String) -> Data? {
        var resp: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message] as [String: Any]
        ]
        if let id = id { resp["id"] = id }
        return try? JSONSerialization.data(withJSONObject: resp)
    }

    // MARK: - Session Cleanup

    private func sessionCleanupLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(sessionCleanupInterval))
            await cleanupExpiredSessions()
        }
    }

    private func cleanupExpiredSessions(now: Date = Date()) async {
        guard !sessionTimeout.isInfinite else { return }
        let expiredIDs = sessions
            .filter { _, ctx in now.timeIntervalSince(ctx.lastAccessedAt) > sessionTimeout }
            .sorted { lhs, rhs in
                if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt {
                    return lhs.value.createdAt < rhs.value.createdAt
                }
                return lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
            }
            .map(\.key)

        for id in expiredIDs {
            await removeSession(id, reason: "expired", incrementExpired: true)
        }
    }

    private func evictSessionsIfNeeded(reservingSlots: Int = 0) async {
        let overflow = max(0, sessions.count + reservingSlots - maxHTTPSessions)
        guard overflow > 0 else { return }

        let evictionOrder = sessions
            .sorted { lhs, rhs in
                if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt {
                    return lhs.value.createdAt < rhs.value.createdAt
                }
                return lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
            }
            .prefix(overflow)
            .map(\.key)

        for id in evictionOrder {
            await removeSession(id, reason: "evicted to enforce cap", incrementEvicted: true)
        }
    }

    /// UEP-005 W3: Soft-cap duplicate session pruning.
    /// Keeps the newest `maxPerClient` sessions per client name.
    /// Sessions accessed within `gracePeriod` seconds are never evicted.
    private func pruneDuplicateClientSessions(clientName: String?, clientVersion: String?) async {
        guard let rawName = clientName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            return
        }

        let maxPerClient = 2
        let gracePeriod: TimeInterval = 5.0
        let now = Date()

        let matching = sessions
            .filter { _, ctx in
                guard ctx.clientName == rawName else { return false }
                if let clientVersion {
                    return ctx.clientVersion == clientVersion
                }
                return true
            }
            .sorted { lhs, rhs in
                // Newest first (by lastAccessedAt, then createdAt)
                if lhs.value.lastAccessedAt == rhs.value.lastAccessedAt {
                    return lhs.value.createdAt > rhs.value.createdAt
                }
                return lhs.value.lastAccessedAt > rhs.value.lastAccessedAt
            }

        // Keep the newest maxPerClient sessions; evict the rest (respecting grace period)
        let candidates = matching.dropFirst(maxPerClient)
        for (id, ctx) in candidates {
            let age = now.timeIntervalSince(ctx.lastAccessedAt)
            if age < gracePeriod {
                print("[SSE] Skipping eviction of \(id.prefix(8))… — accessed \(String(format: "%.1f", age))s ago (grace period)")
                continue
            }
            await removeSession(id, reason: "soft-cap eviction for \(rawName) (keeping newest \(maxPerClient))", incrementEvicted: true)
        }
    }

    private func removeSession(
        _ id: String,
        reason: String,
        incrementClosed: Bool = false,
        incrementExpired: Bool = false,
        incrementEvicted: Bool = false
    ) async {
        guard let session = sessions.removeValue(forKey: id) else { return }

        if incrementClosed { totalSessionsClosed += 1 }
        if incrementExpired { totalSessionsExpired += 1 }
        if incrementEvicted { totalSessionsEvicted += 1 }

        if let name = session.clientName {
            let callback = self.onClientDisconnected
            await MainActor.run { callback(name) }
        }

        await session.transport.disconnect()
        print("[SSE] Session \(reason): \(id.prefix(8))… (active HTTP: \(sessions.count)/\(maxHTTPSessions))")
    }

    // MARK: - Helpers

    private func isInitializeRequest(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String else { return false }
        return method == "initialize"
    }

    private struct FixedIDGenerator: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }
}

// MARK: - NIO HTTP Handler

/// PKT-338 V1-SSE-FIX: SSEHTTPHandler no longer stores a reference to SSEServer (actor).
/// V1-QUALITY-C2: Added healthHandler closure for GET /health endpoint.
private final class SSEHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let legacyBridge: LegacySSEBridge
    private let endpoint: String
    private let rpcHandler: @Sendable (Data) async -> Data?
    private let httpRequestHandler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let healthHandler: @Sendable () async -> Data
    private let jobsCallbackHandler: @Sendable (String) async -> Data  // PKT-340: POST /jobs/{id}/run
    private let onClientDisconnected: @Sendable (String) async -> Void  // PKT-366 F13

    private struct PendingRequest {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var pending: PendingRequest?
    private var legacySessionID: String?

    init(
        legacyBridge: LegacySSEBridge,
        endpoint: String,
        rpcHandler: @escaping @Sendable (Data) async -> Data?,
        httpRequestHandler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
        healthHandler: @escaping @Sendable () async -> Data,
        jobsCallbackHandler: @escaping @Sendable (String) async -> Data = { _ in Data() },
        onClientDisconnected: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.legacyBridge = legacyBridge
        self.endpoint = endpoint
        self.rpcHandler = rpcHandler
        self.httpRequestHandler = httpRequestHandler
        self.healthHandler = healthHandler
        self.jobsCallbackHandler = jobsCallbackHandler
        self.onClientDisconnected = onClientDisconnected
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            pending = PendingRequest(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            pending?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let req = pending else { return }
            pending = nil
            
            let head = req.head
            let bodyData: Data? = req.bodyBuffer.readableBytes > 0 
                ? req.bodyBuffer.getBytes(at: 0, length: req.bodyBuffer.readableBytes).map { Data($0) }
                : nil
            
            nonisolated(unsafe) let ctx = context
            Task {
                await self.processRequest(head: head, body: bodyData, context: ctx)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let sessionID = legacySessionID {
            // PKT-366 F13: Get client name and notify UI of disconnect
            let clientName = legacyBridge.remove(sessionID: sessionID)
            if let name = clientName {
                let callback = self.onClientDisconnected
                Task { await callback(name) }
            }
        }
        context.fireChannelInactive()
    }

    private func processRequest(head: HTTPRequestHead, body: Data?, context: ChannelHandlerContext) async {
        let fullURI = head.uri
        let path = fullURI.split(separator: "?").first.map(String.init) ?? fullURI
        let startTime = CFAbsoluteTimeGetCurrent()

        // PKT-800 S1: single-source route classification (same order /
        // outcomes as before). The new PRM route is provably distinct
        // from /health, /sse, /messages, the job callback, and /mcp.
        let route = MCPHTTPRoute.classify(
            method: head.method.rawValue,
            path: path,
            endpoint: endpoint
        )

        switch route {
        case .corsPreflight:
            await writeCORSPreflight(version: head.version, context: context)
            return  // skip access log for CORS preflight

        case .health:
            // V1-QUALITY-C2: Health endpoint (GET /health) — no authentication required
            let healthData = await healthHandler()
            await writeJSONResponse(data: healthData, version: head.version, context: context)
            return  // skip access log for health (too noisy)

        case .protectedResourceMetadata:
            // PKT-800 S1: RFC 9728 Protected Resource Metadata — no
            // authentication (it advertises *where* to authenticate;
            // carries no secret). The issuer is env-configurable
            // (BRIDGE_OAUTH_ISSUER) and defaults to a documented
            // placeholder — there is no live authorization server in
            // this slice.
            let prmData = ProtectedResourceMetadataProvider.jsonBody()
            logAccess(method: "GET", path: path, sessionID: nil, status: 200, start: startTime)
            await writeJSONResponse(data: prmData, version: head.version, context: context)
            return

        case .legacySSE:
            logAccess(method: "GET", path: path, sessionID: nil, status: 200, start: startTime)
            await handleLegacySSE(head: head, context: context)
            return

        case .legacyMessages:
            logAccess(method: "POST", path: path, sessionID: nil, status: 200, start: startTime)
            await handleLegacyMessage(head: head, body: body, uri: fullURI, context: context)
            return

        case .jobsRun(let jobId):
            // PKT-340 V2-SCHEDULER: POST /jobs/{id}/run -- invoked by launchd via curl
            let data = await jobsCallbackHandler(jobId)
            logAccess(method: "POST", path: path, sessionID: nil, status: 200, start: startTime)
            await writeJSONResponse(data: data, version: head.version, context: context)
            return

        case .notFound:
            logAccess(method: head.method.rawValue, path: path, sessionID: nil, status: 404, start: startTime)
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version,
                context: context
            )
            return

        case .mcpEndpoint:
            break  // fall through to Streamable HTTP handling below
        }

        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let sessionID = headers["mcp-session-id"]
        let httpRequest = HTTPRequest(method: head.method.rawValue, headers: headers, body: body)
        let response = await httpRequestHandler(httpRequest)
        logAccess(method: head.method.rawValue, path: path, sessionID: sessionID, status: response.statusCode, start: startTime)
        await writeResponse(response, version: head.version, context: context)
    }

    /// UEP-005 W4: Structured access log for MCP request diagnostics.
    private func logAccess(method: String, path: String, sessionID: String?, status: Int, start: CFAbsoluteTime) {
        let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let sid = sessionID.map { String($0.prefix(8)) + "…" } ?? "-"
        print("[MCP-ACCESS] \(method) \(path) sid=\(sid) status=\(status) \(durationMs)ms")
    }

    // MARK: - Health Response Writer (V1-QUALITY-C2)

    private func writeJSONResponse(data: Data, version: HTTPVersion, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = context
        let responseData = data
        ctx.eventLoop.execute {
            var head = HTTPResponseHead(version: version, status: .ok)
            head.headers.add(name: "Content-Type", value: "application/json")
            // PKT-373 P1-4: CORS wildcard removed
            head.headers.add(name: "Cache-Control", value: "no-cache")
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

            var buffer = ctx.channel.allocator.buffer(capacity: responseData.count)
            buffer.writeBytes(responseData)
            ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    // MARK: - Legacy SSE Handlers (PKT-336)

    private func handleLegacySSE(head: HTTPRequestHead, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = context
        ctx.eventLoop.execute {
            let sessionID = self.legacyBridge.register(channel: ctx.channel)
            self.legacySessionID = sessionID

            var responseHead = HTTPResponseHead(version: head.version, status: .ok)
            responseHead.headers.add(name: "Content-Type", value: "text/event-stream")
            responseHead.headers.add(name: "Cache-Control", value: "no-cache")
            responseHead.headers.add(name: "Connection", value: "keep-alive")
            // SEC-02: CORS wildcard removed — localhost-only server needs no cross-origin access (PKT-373 P1-4)
            ctx.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

            let endpointData = "event: endpoint\ndata: /messages?sessionId=\(sessionID)\n\n"
            var buffer = ctx.channel.allocator.buffer(capacity: endpointData.utf8.count)
            buffer.writeString(endpointData)
            ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
    }

    private func handleLegacyMessage(
        head: HTTPRequestHead,
        body: Data?,
        uri: String,
        context: ChannelHandlerContext
    ) async {
        let sessionID: String? = {
            guard let qIdx = uri.firstIndex(of: "?") else { return nil }
            let query = uri[uri.index(after: qIdx)...]
            for param in query.split(separator: "&") {
                let parts = param.split(separator: "=", maxSplits: 1)
                if parts.count == 2 && parts[0] == "sessionId" {
                    return String(parts[1])
                }
            }
            return nil
        }()

        guard let bodyData = body else {
            await writeSimpleResponse(statusCode: 400, version: head.version, context: context)
            return
        }

        // PKT-366 F13: Store client name in bridge for disconnect tracking
        if let sid = sessionID,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let method = json["method"] as? String, method == "initialize",
           let params = json["params"] as? [String: Any],
           let clientInfo = params["clientInfo"] as? [String: Any],
           let clientName = clientInfo["name"] as? String {
            legacyBridge.setClientName(sessionID: sid, name: clientName)
        }

        if let responseData = await rpcHandler(bodyData),
           let responseString = String(data: responseData, encoding: .utf8) {
            legacyBridge.sendEvent(sessionID: sessionID, event: "message", data: responseString)
        }

        await writeSimpleResponse(statusCode: 202, version: head.version, context: context)
    }

    private func writeSimpleResponse(
        statusCode: Int,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        ctx.eventLoop.execute {
            let head = HTTPResponseHead(
                version: version,
                status: HTTPResponseStatus(statusCode: statusCode)
            )
            // PKT-373 P1-4: CORS wildcard removed -- localhost-only server needs no cross-origin access
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    private func writeCORSPreflight(version: HTTPVersion, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = context
        ctx.eventLoop.execute {
            var head = HTTPResponseHead(version: version, status: .noContent)
            // PKT-373 P1-4: CORS wildcard removed -- localhost-only server needs no cross-origin access
            head.headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
            head.headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization, Mcp-Session-Id")
            head.headers.add(name: "Access-Control-Max-Age", value: "86400")
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    // MARK: - Response Writing (Streamable HTTP)

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in response.headers {
                    head.headers.add(name: name, value: value)
                }
                head.headers.replaceOrAdd(name: "Connection", value: "keep-alive")
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // Stream ended with error — close connection
            }

            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in response.headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

                head.headers.replaceOrAdd(name: "Connection", value: "keep-alive")

                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }

                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
