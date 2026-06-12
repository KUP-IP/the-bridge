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

    /// Look up the client name for a legacy session, if known. Used by the W2
    /// delivery telemetry so legacy-session audit rows carry the client label.
    public func clientName(sessionID: String) -> String? {
        lock.withLock { clientNames[sessionID] }
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

    /// PKT-800 S2: connector bearer/scope enforcement bundle. **`nil` in
    /// every default configuration** (stdio-only — `BRIDGE_ENABLE_HTTP`
    /// unset / no JWKS configured), which is the additive-isolation
    /// invariant: when `nil`, `handleHTTPRequest` runs exactly as it did
    /// pre-S2, so stdio, legacy SSE, `/health`, the job callback, and the
    /// `/mcp` path itself are byte-for-byte behaviour-identical. Bearer +
    /// scope are enforced ONLY when this is non-nil AND only on the
    /// Streamable-HTTP connector funnel (`handleHTTPRequest`).
    private let connectorAuth: ConnectorAuthContext?

    /// ITEM [session]: durable snapshot of active session ids + minimal
    /// context, persisted across app restart / `make install`. Lets a returning
    /// client carrying its prior `Mcp-Session-Id` be answered with a resumable
    /// re-initialize signal instead of an opaque hard-404. Injected (default
    /// `.shared`) so tests drive it over a temp path. The actor mutates it only
    /// through `await`, so its own actor isolation serializes the disk writes.
    private let sessionStore: SessionPersistenceStore
    private var totalSessionsCreated = 0
    private var totalSessionsExpired = 0
    private var totalSessionsEvicted = 0
    private var totalSessionsClosed = 0
    /// Count of reconnects answered with the resumable re-initialize signal
    /// (a returning client whose id was persisted from a prior run). Surfaced
    /// in health diagnostics so the durability path is observable.
    private var totalSessionsResumeSignaled = 0

    /// Session IDs (Streamable-HTTP + legacy SSE) that have issued a
    /// `resources/subscribe`. Actor-isolated — every mutation/read happens
    /// inside the `SSEServer` actor (the SDK resource handlers, the legacy
    /// RPC switch, session teardown, and `broadcastResourcesUpdated` are all
    /// actor-isolated), so this needs no separate lock; it mirrors the role
    /// of `LegacySSEBridge.clientNames` but stays inside the actor boundary
    /// the way `sessions` does. Cleared per-session on disconnect/eviction.
    private var resourceSubscribers: Set<String> = []

    public nonisolated let endpoint: String = "/mcp"

    /// PKT-336: Thread-safe bridge for legacy SSE connections (no actor boundary for channels).
    public nonisolated let legacy = LegacySSEBridge()

    /// Tear down a disconnected LEGACY SSE session's delivery telemetry.
    ///
    /// BUG FIX (legacy-SSE rows never pruned): the Streamable-HTTP + stdio paths
    /// prune a torn-down session's `DeliveryLog` events via `removeSession`, but
    /// legacy SSE has no such hook — its `LegacySSEBridge.remove` only dropped
    /// the channel, leaving the audit row + debug-timeline events to linger
    /// after disconnect. `channelInactive` now calls this on the NIO event-loop
    /// thread; it hops to the main actor (DeliveryLog is @MainActor), mirroring
    /// `removeSession`'s prune hop. Factored out as a `nonisolated` seam so the
    /// disconnect-prune wiring is exercised by the same code the handler runs.
    public nonisolated static func pruneLegacyDeliveryTelemetry(sessionID: String) {
        Task { @MainActor in DeliveryLog.shared.prune(sessionID: sessionID) }
    }

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
        toolAllowlist: Set<String>? = nil,
        connectorAuth: ConnectorAuthContext? = nil,
        sessionStore: SessionPersistenceStore = .shared
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
        self.connectorAuth = connectorAuth
        self.sessionStore = sessionStore
    }

    // MARK: - Session Durability (ITEM [session])

    /// Custom response header signalling that a 404 on a reconnect is a
    /// RESUMABLE one — the session id was persisted from a prior run and the
    /// host restarted; the client should re-initialize (not treat the id as
    /// corrupt). Distinct from the opaque hard-404 a forged/unknown id gets.
    public static let resumableHeaderName = "Mcp-Session-Resumable"
    /// Echoes the prior session id back so a client can correlate the resume
    /// signal with the id it sent.
    public static let priorSessionHeaderName = "Mcp-Prior-Session-Id"

    /// Stable, machine-readable prefix on the resumable-reconnect error message
    /// so a non-header-aware client can still branch on it.
    public static let resumeSignalReason = "session_expired_resumable"

    /// Build the structured resumable-reconnect response for a returning client
    /// whose `Mcp-Session-Id` was persisted from a prior run but has no live
    /// transport (the host restarted / was reinstalled). Per Streamable-HTTP
    /// resumability guidance this is still a 404 (the session id is no longer
    /// live), but it carries a distinct, recoverable signal:
    ///   • `Mcp-Session-Resumable: true` header,
    ///   • the prior session id echoed back,
    ///   • a stable `[session_expired_resumable]` reason token in the message,
    /// so the client knows to re-initialize rather than surface an opaque
    /// "Session not found or expired" failure. Pure given its inputs — unit
    /// tested without a live server.
    public static func resumableReconnectResponse(
        priorSessionID: String,
        cleanShutdown: Bool
    ) -> HTTPResponse {
        let phase = cleanShutdown ? "host restarted" : "host recovered from an unexpected stop"
        return .error(
            statusCode: 404,
            .invalidRequest(
                "[\(resumeSignalReason)] The MCP host \(phase); this session id is "
                + "no longer live. Re-initialize to resume — your prior session "
                + "state was persisted."
            ),
            extraHeaders: [
                resumableHeaderName: "true",
                priorSessionHeaderName: priorSessionID
            ]
        )
    }

    /// Count of reconnects answered with the resumable signal (test/diagnostic).
    public var resumeSignaledCount: Int { totalSessionsResumeSignaled }

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

        // Install the resources-updated broadcaster so a Standing Orders write
        // fans out `notifications/resources/updated` to subscribed sessions.
        // Decoupled hook (see StandingOrdersDelivery): the pure file store
        // calls `BridgeResources.notifyResourceChanged(uri:)`, which routes
        // here on a detached Task that hops into the actor's broadcast.
        BridgeResources.setResourcesUpdatedBroadcaster { [weak self] uri in
            Task { await self?.broadcastResourcesUpdated(uri: uri) }
        }

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

        let rpcHandler: @Sendable (Data, String?) async -> Data? = { [weak self] data, legacySessionID in
            await self?.processLegacyRPC(data, sessionID: legacySessionID)
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
        // ITEM [session]: a graceful stop (app quit / install) is NOT a
        // per-session teardown — the sessions are being suspended by a host
        // restart, not closed by the client. So we tear down the live
        // transports but PRESERVE the durable snapshot (preservePersistence:
        // true), then write the clean-shutdown marker. On the next launch a
        // returning client's id still resolves to `.resumable` and it gets the
        // re-initialize signal instead of a hard-404.
        let activeAtStop = sessions.count
        for id in Array(sessions.keys) {
            await removeSession(id, reason: "server stop", preservePersistence: true)
        }
        await sessionStore.recordCleanShutdown(reason: "server stop")
        print("[SSE] Clean-shutdown marker written (\(activeAtStop) session(s) preserved for resume)")
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
        // ITEM [session]: durability counters — how many ids are persisted for
        // resume and how many reconnects we've answered with the resume signal.
        let persistedCount = await sessionStore.count
        let priorRunClean = await sessionStore.priorRunEndedCleanly()

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
            "sessionsClosed": diagnostics.totalSessionsClosed,
            "sessionsPersisted": persistedCount,
            "sessionsResumeSignaled": totalSessionsResumeSignaled,
            "priorRunEndedCleanly": priorRunClean
        ]

        return (try? JSONSerialization.data(withJSONObject: health, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - Request Routing (Streamable HTTP — POST /mcp)

    /// PKT-810: a request is "remote" iff Cloudflare stamped a tunnel header on
    /// it. cloudflared adds `Cf-Connecting-Ip` / `Cf-Ray` to every proxied
    /// request reaching the origin; a direct-loopback request (local desktop
    /// stdio-proxy, or any process on 127.0.0.1) carries neither. `header(_:)`
    /// is case-insensitive (MCP SDK), so wire-case variance is a non-issue.
    public static func isRemoteTunnelRequest(_ request: HTTPRequest) -> Bool {
        request.header("Cf-Connecting-Ip") != nil || request.header("Cf-Ray") != nil
    }

    /// PKT-810 coexistence: the loopback (local desktop) static-bearer fallback.
    /// Returns a served response ONLY when the request is direct-loopback (no
    /// Cloudflare tunnel header), a local bearer is configured, and the
    /// presented bearer matches it. Returns `nil` otherwise so the caller falls
    /// back to the OAuth rejection. A remote (tunnel) request never matches —
    /// the static bearer can never be a cloud OAuth bypass.
    private func loopbackStaticBearerFallback(
        _ request: HTTPRequest, authHeader: String?, auth: ConnectorAuthContext
    ) async -> HTTPResponse? {
        guard !Self.isRemoteTunnelRequest(request),
              let expected = auth.localBearer, !expected.isEmpty,
              let presented = authHeader.map({
                  $0.lowercased().hasPrefix("bearer ") ? String($0.dropFirst(7)) : $0
              }),
              presented == expected
        else { return nil }
        await auth.diagnostics.record(outcome: "local.accepted", detail: "loopback")
        return await processStreamableHTTP(request)
    }

    public func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // PKT-800 S2 / PKT-810 — connector auth gate. ADDITIVE ISOLATION: this
        // block is a no-op (falls straight through) whenever
        // `connectorAuth == nil` (every default, stdio-only config). It is
        // reached ONLY on the Streamable-HTTP `/mcp` funnel (the NIO handler
        // routes `/health`, `/sse`, `/messages`, the job callback, and the PRM
        // doc *before* `handleHTTPRequest`), so no other transport hits it.
        //
        // PKT-810 coexistence — OAuth-first, loopback-static-bearer fallback:
        // a valid AuthKit JWT is ALWAYS OAuth-validated (cloud + any origin).
        // If the bearer is NOT a valid JWT, a direct-loopback request may fall
        // back to the local static bearer (so the local desktop path keeps
        // working when cloud OAuth is on). The static bearer is loopback-scoped
        // — a tunnel request never reaches the fallback, so it can never bypass
        // OAuth. `localBearer == nil` ⇒ fallback inert (pure prior behavior).
        if let auth = connectorAuth {
            let authHeader = request.header(HTTPHeaderName.authorization)
            do {
                let token = try await auth.validator.validate(authorizationHeader: authHeader)
                await auth.diagnostics.record(
                    outcome: "bearer.accepted",
                    detail: "method=\(request.method) sub-len=\(token.subject.count)"
                )
                return await dispatchAuthorizedConnectorRequest(request, token: token, auth: auth)
            } catch let err as BearerValidationError {
                if let local = await loopbackStaticBearerFallback(request, authHeader: authHeader, auth: auth) {
                    return local
                }
                await auth.diagnostics.record(
                    outcome: "bearer.rejected",
                    detail: "reason=\(err.wwwAuthenticateError)"
                )
                return Self.unauthorizedResponse(for: err, auth: auth)
            } catch {
                if let local = await loopbackStaticBearerFallback(request, authHeader: authHeader, auth: auth) {
                    return local
                }
                await auth.diagnostics.record(
                    outcome: "bearer.rejected",
                    detail: "reason=opaque"
                )
                return Self.unauthorizedResponse(
                    for: .malformedToken("\(error)"), auth: auth
                )
            }
        }

        return await processStreamableHTTP(request)
    }

    /// The original (pre-S2) Streamable-HTTP session handling, unchanged.
    /// Split out so both the unauthenticated default path and the
    /// post-bearer authorized path funnel through identical session logic.
    private func processStreamableHTTP(_ request: HTTPRequest, connectorAuthed: Bool = false) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            // Durability: refresh the persisted last-accessed timestamp.
            await sessionStore.touch(sessionID: sessionID, at: session.lastAccessedAt)

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
            return await createSession(request, connectorAuthed: connectorAuthed)
        }

        if let sessionID {
            // ITEM [session]: the id is not live in THIS run. Before the opaque
            // hard-404, consult the durable snapshot — if the id was persisted
            // from a prior run, the host restarted / was reinstalled. Answer
            // with the resumable re-initialize signal so the client recovers
            // instead of surfacing "Session not found or expired".
            switch await sessionStore.resumeLookup(sessionID: sessionID) {
            case .resumable(_, let cleanShutdown):
                totalSessionsResumeSignaled += 1
                print("[SSE] Resume signal: \(sessionID.prefix(8))… reconnected after restart "
                    + "(clean=\(cleanShutdown)) — instructing re-initialize")
                return Self.resumableReconnectResponse(
                    priorSessionID: sessionID,
                    cleanShutdown: cleanShutdown
                )
            case .unknown:
                return .error(statusCode: 404, .invalidRequest("Session not found or expired"))
            }
        }
        return .error(statusCode: 400, .invalidRequest("Missing Mcp-Session-Id header"))
    }

    // MARK: - Connector Authorization (PKT-800 S2)

    /// Builds the RFC 6750 `401 Unauthorized` + `WWW-Authenticate: Bearer`
    /// challenge for a failed/missing connector bearer. Pure given its
    /// inputs (static) so it is unit-testable without a live server.
    public static func unauthorizedResponse(
        for error: BearerValidationError,
        auth: ConnectorAuthContext
    ) -> HTTPResponse {
        .error(
            statusCode: 401,
            .invalidRequest("Unauthorized: \(error.challengeDescription)"),
            extraHeaders: [
                HTTPHeaderName.wwwAuthenticate: auth.wwwAuthenticateValue(for: error)
            ]
        )
    }

    /// JSON-RPC method + tool name a Streamable-HTTP body is requesting,
    /// if it is a `tools/call`. Pure — extracted for unit testing the
    /// scope-gate decision without a live transport.
    public static func toolCallTarget(in body: Data?) -> String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (json["method"] as? String) == "tools/call",
              let params = json["params"] as? [String: Any],
              let name = params["name"] as? String
        else { return nil }
        return name
    }

    /// Builds a structured, machine-readable `403`-class connector refusal
    /// (authenticated, but the request is not authorized to proceed). The
    /// `reason` token is stable and distinct from the 401 bearer challenge
    /// so a client can branch on it. Pure given its inputs.
    public static func forbiddenResponse(
        reason: String,
        message: String
    ) -> HTTPResponse {
        .error(
            statusCode: 403,
            .invalidRequest("Forbidden [\(reason)]: \(message)")
        )
    }

    /// Post-bearer connector dispatch. The bearer is already verified.
    ///
    /// Order (all NO-dispatch on failure, distinct machine-readable
    /// reasons):
    ///   1. Confused-deputy isolation — the verified principal is bound to
    ///      the MCP session; a later request on that session with a
    ///      different principal is rejected (token substitution / session
    ///      hijack across connector clients).
    ///   2. Scope gate — the granted scopes must reach the target tool.
    ///   3. Step-up consent — a `destructiveHint: true` connector tool
    ///      additionally requires a verified step-up scope or a per-call
    ///      confirmation token.
    ///
    /// Non-`tools/call` connector traffic (initialize, tools/list, ping,
    /// notifications, DELETE) passes the bearer + confused-deputy gates
    /// only — scope and step-up bind tool *dispatch*.
    private func dispatchAuthorizedConnectorRequest(
        _ request: HTTPRequest,
        token: BridgeAccessToken,
        auth: ConnectorAuthContext
    ) async -> HTTPResponse {
        // 1. Confused-deputy isolation. The principal is derived from the
        //    VERIFIED token only (never request-supplied fields), then
        //    bound to the session id. A mismatch ⇒ a different client's
        //    token is being replayed through this session.
        let sessionID = request.header(HTTPHeaderName.sessionID)
        let admission = await auth.sessionBinding.admit(
            sessionID: sessionID,
            principal: token.connectorPrincipal
        )
        if case .rejected(let refusal) = admission {
            await auth.diagnostics.record(
                outcome: "confused-deputy.rejected",
                detail: "session principal substitution refused"
            )
            return Self.forbiddenResponse(
                reason: refusal.rawValue,
                message: "this session is bound to a different connector "
                    + "principal; cross-client token substitution is refused"
            )
        }

        // Connector tool-authorization policy. DEFAULT = full parity: an
        // authenticated connector token (a verified OAuth JWT from the operator's
        // own WorkOS tenant, or the loopback static bearer) may reach every tool,
        // exactly like a local client — the per-tool SecurityGate (tier +
        // confirmation prompts) is the real guardrail at dispatch, and WorkOS can
        // only ever authenticate the operator. The scope/step-up gates below are
        // an OPTIONAL stricter layer applied ONLY when `strictScopes` is set on
        // the ConnectorAuthContext; otherwise they would 403 every tool, since
        // WorkOS AuthKit issues scope-less tokens (no app-custom scopes).
        if auth.strictScopes, let toolName = Self.toolCallTarget(in: request.body) {
            // 2. Scope gate.
            let decision = await auth.scopeGate.evaluate(
                toolName: toolName,
                grantedScopes: token.connectorScopes
            )
            if case .deny(let reason) = decision {
                await auth.diagnostics.record(
                    outcome: "scope.denied",
                    detail: "tool=\(toolName)"
                )
                // 403 = authenticated but scope-insufficient (distinct
                // from the 401 bearer challenge).
                return Self.forbiddenResponse(
                    reason: "insufficient_scope", message: reason
                )
            }

            // 3. Step-up consent on destructive connector tools.
            let stepUp = auth.stepUpGate.evaluate(
                toolName: toolName,
                grantedScopes: token.connectorScopes,
                body: request.body
            )
            if case .required(let reason, let message) = stepUp {
                await auth.diagnostics.record(
                    outcome: "step-up.required",
                    detail: "tool=\(toolName)"
                )
                // 403-class structured refusal — NO dispatch.
                return Self.forbiddenResponse(
                    reason: reason.rawValue, message: message
                )
            }
            await auth.diagnostics.record(
                outcome: "dispatch.authorized",
                detail: "tool=\(toolName)"
            )
        }
        // Connector-authenticated (OAuth JWT or loopback static bearer, already
        // verified by ConnectorAuthContext upstream). ChatGPT's connector
        // importer expects ordinary JSON-RPC responses on POST; the SDK stateful
        // transport answers with SSE framing (valid Streamable HTTP, but ChatGPT
        // cannot parse it → -32603 "data couldn't be read…"). Serve OAuth
        // connector clients compact JSON here, falling back to the SDK path for
        // anything processConnectorJSONRPC does not handle. The session pipeline
        // still skips the legacy static-bearer re-check (connectorAuthed).
        if let connectorResponse = await processConnectorJSONRPC(request) {
            return connectorResponse
        }
        return await processStreamableHTTP(request, connectorAuthed: true)
    }

    /// Compact JSON-RPC handler for OAuth connector clients (v3.7.10). ChatGPT's
    /// importer rejects the SDK's SSE-framed responses (it expects plain
    /// `application/json` on POST); this answers `initialize` / `tools/list` /
    /// `tools/call` / `ping` / notifications with compact JSON (Content-Type +
    /// Mcp-Session-Id), reusing the SAME `router.dispatchFormatted` execution and
    /// `buildRPCResponse` builders as the legacy and Streamable-HTTP paths.
    /// Returns `nil` for anything it does not handle so the caller falls back to
    /// the SDK transport. claude.ai accepts these plain responses too, so both
    /// cloud connectors share this path.
    private func processConnectorJSONRPC(_ request: HTTPRequest) async -> HTTPResponse? {
        guard request.method.uppercased() == "POST",
              let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else { return nil }

        let requestId = json["id"]
        let sessionID = request.header(HTTPHeaderName.sessionID) ?? UUID().uuidString
        let headers = Self.connectorJSONHeaders(sessionID: sessionID)

        switch method {
        case "initialize":
            if let params = json["params"] as? [String: Any],
               let clientInfo = params["clientInfo"] as? [String: Any],
               let name = clientInfo["name"] as? String {
                let version = clientInfo["version"] as? String ?? "unknown"
                let onClientConnected = self.onClientConnected
                await MainActor.run { onClientConnected(name, version) }
                print("[SSE-Connector] Client identified: \(name) v\(version)")
            }
            let data = buildRPCResponse(id: requestId, result: [
                "protocolVersion": BridgeConstants.mcpProtocolVersion,
                "capabilities": ["tools": [:] as [String: Any]] as [String: Any],
                "serverInfo": [
                    "name": "The Bridge",
                    "version": AppVersion.resolved
                ] as [String: Any],
                "instructions": "Use The Bridge tools for approved local Mac and KEEP OS actions. Prefer read-only tools first, and treat write, send, delete, payment, and calendar actions as confirmation-sensitive."
            ] as [String: Any]) ?? Data()
            return .data(data, headers: headers)

        case "notifications/initialized":
            return .accepted(headers: headers)

        case "tools/list":
            let disabledNames = CredentialsFeature.mergedDisabledToolNames()
            var regs = await router.enabledRegistrations(disabledNames: disabledNames)
            if let allowlist = toolAllowlist {
                regs = regs.filter { allowlist.contains($0.name) }
            }
            let tools: [[String: Any]] = regs.compactMap { reg in
                guard let data = try? JSONEncoder().encode(MCPToolFactory.tool(for: reg)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return object
            }
            let data = buildRPCResponse(id: requestId, result: ["tools": tools]) ?? Data()
            return .data(data, headers: headers)

        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            if let allowlist = toolAllowlist, !allowlist.contains(name) {
                let text = "Error: Tool '\(name)' is not allowed in this session"
                let data = buildRPCResponse(id: requestId, result: [
                    "content": [["type": "text", "text": text] as [String: Any]],
                    "isError": true
                ] as [String: Any]) ?? Data()
                return .data(data, headers: headers)
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
            let data = buildRPCResponse(id: requestId, result: [
                "content": [["type": "text", "text": text] as [String: Any]],
                "isError": isError
            ] as [String: Any]) ?? Data()
            return .data(data, headers: headers)

        case "ping":
            let data = buildRPCResponse(id: requestId, result: [:] as [String: Any]) ?? Data()
            return .data(data, headers: headers)

        default:
            if method.hasPrefix("notifications/") {
                return .accepted(headers: headers)
            }
            let data = buildRPCError(id: requestId, code: -32601, message: "Method not found: \(method)") ?? Data()
            return .data(data, headers: headers)
        }
    }

    private static func connectorJSONHeaders(sessionID: String) -> [String: String] {
        [
            HTTPHeaderName.contentType: "application/json",
            HTTPHeaderName.sessionID: sessionID
        ]
    }

    // MARK: - Session Factory (Streamable HTTP)

    private func createSession(_ request: HTTPRequest, connectorAuthed: Bool = false) async -> HTTPResponse {
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

        let validationPipeline = MCPHTTPValidation.streamableHTTPPipeline(ssePort: port, connectorAuthed: connectorAuthed)

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedIDGenerator(id: sessionID),
            validationPipeline: validationPipeline
        )

        let appVersion = AppVersion.resolved
        // SSOT: the Streamable-HTTP session's `initialize.instructions` now
        // comes from StandingOrdersDelivery — byte-identical to the stdio
        // (ServerManager) path and the legacy SSE path, and the same
        // composition that backs the bridge:// resources.
        let composition = StandingOrdersDelivery.composition(clientName: clientName)
        let composedInstructions = composition.instructionsMarkdown
        // W2 telemetry: record the handshake we composed + shipped (tokens +
        // content hash) for this session. Off-actor-safe via the nonisolated
        // main-actor hop (see DeliveryLog).
        DeliveryLog.shared.recordHandshakeDelivered(
            sessionID: sessionID,
            clientName: clientName,
            tokenCount: composition.tokenCount,
            contentHash: composition.contentHash
        )
        let server = Server(
            name: "NotionBridgeSSE",
            version: appVersion,
            instructions: composedInstructions,
            // Advertise resources (subscribe + listChanged) alongside tools.
            capabilities: .init(
                resources: .init(subscribe: true, listChanged: true),
                tools: .init()
            )
        )

        let router = self.router
        let onToolCall = self.onToolCall
        let toolAllowlist = self.toolAllowlist

        // MCP resource handlers (Streamable-HTTP path). Bytes come from the
        // same StandingOrdersDelivery SSOT the stdio + legacy paths serve.
        // Subscription tracking + `notifications/resources/updated` delivery
        // for this transport is owned by the actor's `resourceSubscribers`
        // set, keyed by sessionID (see `broadcastResourcesUpdated`).
        let resourceClientName = clientName
        let resourceSessionID = sessionID
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: BridgeResources.list)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            let result = try await BridgeResources.read(uri: params.uri, clientName: resourceClientName)
            // W2 telemetry: record the resource read we served + the
            // composition hash at serve time (drives the freshness dot).
            DeliveryLog.shared.recordResourceRead(
                sessionID: resourceSessionID,
                clientName: resourceClientName,
                uri: params.uri,
                contentHash: StandingOrdersDelivery.composition(clientName: resourceClientName).contentHash
            )
            return result
        }
        let subscribeSessionID = sessionID
        await server.withMethodHandler(ResourceSubscribe.self) { [weak self] _ in
            await self?.addResourceSubscriber(sessionID: subscribeSessionID)
            return Empty()
        }
        await server.withMethodHandler(ResourceUnsubscribe.self) { [weak self] _ in
            await self?.removeResourceSubscriber(sessionID: subscribeSessionID)
            return Empty()
        }

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
            // W2 telemetry (AUDIT ONLY — never gates dispatch): record
            // reminders_* tool calls so the Delivery audit can show activity.
            if params.name.hasPrefix("reminders_") {
                DeliveryLog.shared.recordReminderToolCall(
                    sessionID: resourceSessionID,
                    clientName: resourceClientName,
                    toolName: params.name
                )
            }
            // Routing-stability telemetry (AUDIT ONLY): record fetch_skill
            // calls {skill name/path, intent} so the routing surface can be
            // audited for drift / mis-routes.
            if params.name == "fetch_skill" {
                let (skill, intent) = DeliveryLog.skillFetchFields(from: params.arguments.map { Value.object($0) })
                DeliveryLog.shared.recordSkillFetched(
                    sessionID: resourceSessionID,
                    clientName: resourceClientName,
                    skill: skill,
                    intent: intent
                )
            }
            if params.name.hasPrefix("memory_") {
                DeliveryLog.shared.recordMemoryToolCall(
                    sessionID: resourceSessionID,
                    clientName: resourceClientName,
                    toolName: params.name
                )
            }
            var arguments: Value = params.arguments.map { .object($0) } ?? .object([:])
            if params.name == "memory_remember" {
                arguments = MemoryModule.argumentsWithClientSource(arguments, clientName: resourceClientName)
            }
            let (text, isError) = await router.dispatchFormatted(toolName: params.name, arguments: arguments)
            if !isError { await MainActor.run { onToolCall() } }
            return .init(content: [.text(.init(text))], isError: isError)
        }

        do {
            try await server.start(transport: transport)

            let createdAt = Date()
            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: createdAt,
                lastAccessedAt: createdAt,
                clientName: clientName,
                clientVersion: clientVersion
            )
            totalSessionsCreated += 1

            // ITEM [session]: snapshot the new session to disk so it survives an
            // app restart / install and a returning client gets the resumable
            // signal. Minimal context only — never tool args or bearer material.
            await sessionStore.upsert(PersistedSession(
                sessionID: sessionID,
                clientName: clientName,
                clientVersion: clientVersion,
                transport: "streamable-http",
                protocolVersion: BridgeConstants.mcpProtocolVersion,
                createdAt: createdAt,
                lastAccessedAt: createdAt
            ))

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

    func processLegacyRPC(_ body: Data, sessionID: String? = nil) async -> Data? {
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
            // SSOT: legacy initialize instructions come from
            // StandingOrdersDelivery — byte-identical to the stdio
            // (ServerManager) and Streamable-HTTP paths, and the same
            // composition that backs the bridge:// resources. The
            // best-effort store-read fallback lives inside the SSOT.
            let composition = StandingOrdersDelivery.composition()
            let composedInstructions = composition.instructionsMarkdown
            // W2 telemetry: record the handshake we composed + shipped, same as
            // the Streamable-HTTP path (both transports emit identically). The
            // clientName was stored into `legacy` before this handler ran.
            if let sessionID {
                DeliveryLog.shared.recordHandshakeDelivered(
                    sessionID: sessionID,
                    clientName: legacy.clientName(sessionID: sessionID),
                    tokenCount: composition.tokenCount,
                    contentHash: composition.contentHash
                )
            }
            return buildRPCResponse(id: requestId, result: [
                "protocolVersion": BridgeConstants.mcpProtocolVersion,
                // Advertise resources (subscribe + listChanged) alongside tools.
                "capabilities": [
                    "tools": [:] as [String: Any],
                    "resources": ["subscribe": true, "listChanged": true] as [String: Any],
                ] as [String: Any],
                "serverInfo": ["name": "The Bridge", "version": legacyVersion] as [String: Any],  // PKT-1 v3.5: brand rename
                "instructions": composedInstructions
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

            // W2 telemetry (AUDIT ONLY — never gates dispatch): record
            // reminders_* tool calls, identical to the Streamable-HTTP path.
            if name.hasPrefix("reminders_"), let sessionID {
                DeliveryLog.shared.recordReminderToolCall(
                    sessionID: sessionID,
                    clientName: legacy.clientName(sessionID: sessionID),
                    toolName: name
                )
            }

            let args = params["arguments"] as? [String: Any] ?? [:]

            // Routing-stability telemetry (AUDIT ONLY): record fetch_skill
            // calls {skill name/path, intent}, identical to the
            // Streamable-HTTP path.
            if name == "fetch_skill", let sessionID {
                let skill = (args["name"] as? String) ?? ""
                let rawIntent = (args["intent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                DeliveryLog.shared.recordSkillFetched(
                    sessionID: sessionID,
                    clientName: legacy.clientName(sessionID: sessionID),
                    skill: skill,
                    intent: (rawIntent?.isEmpty == false) ? rawIntent : nil
                )
            }

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

        case "resources/list":
            // SSOT: same two entries the Streamable-HTTP / stdio paths advertise.
            return buildRPCResponse(id: requestId, result: [
                "resources": BridgeResources.listAsDictionaries
            ] as [String: Any])

        case "resources/read":
            let params = json["params"] as? [String: Any] ?? [:]
            guard let uri = params["uri"] as? String else {
                return buildRPCError(id: requestId, code: -32602, message: "Missing 'uri' parameter")
            }
            // Bytes resolve from the SAME StandingOrdersDelivery SSOT as every
            // other transport. clientName is not resolvable on the legacy path
            // (it is the future-overlay hook and ignored for content anyway).
            do {
                let markdown = try await BridgeResources.markdown(for: uri, clientName: nil)
                // W2 telemetry: record the resource read we served + the
                // composition hash at serve time (identical to the
                // Streamable-HTTP path; both transports emit the same event).
                if let sessionID {
                    DeliveryLog.shared.recordResourceRead(
                        sessionID: sessionID,
                        clientName: legacy.clientName(sessionID: sessionID),
                        uri: uri,
                        contentHash: StandingOrdersDelivery.composition().contentHash
                    )
                }
                return buildRPCResponse(id: requestId, result: [
                    "contents": [[
                        "uri": uri,
                        "mimeType": "text/markdown",
                        "text": markdown,
                    ] as [String: Any]]
                ] as [String: Any])
            } catch {
                return buildRPCError(id: requestId, code: -32602, message: "Unknown resource URI: \(uri)")
            }

        case "resources/subscribe":
            let params = json["params"] as? [String: Any] ?? [:]
            guard params["uri"] is String else {
                return buildRPCError(id: requestId, code: -32602, message: "Missing 'uri' parameter")
            }
            // Track this legacy session so broadcastResourcesUpdated reaches it.
            if let sessionID { addResourceSubscriber(sessionID: sessionID) }
            return buildRPCResponse(id: requestId, result: [:] as [String: Any])

        case "resources/unsubscribe":
            if let sessionID { removeResourceSubscriber(sessionID: sessionID) }
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

    // MARK: - MCP Resource Subscriptions (resources/subscribe + updated)

    /// Track a session that issued `resources/subscribe`. Idempotent.
    /// Called from the Streamable-HTTP SDK handler and the legacy RPC switch.
    func addResourceSubscriber(sessionID: String) {
        resourceSubscribers.insert(sessionID)
    }

    /// Stop tracking a session (explicit `resources/unsubscribe` or teardown).
    func removeResourceSubscriber(sessionID: String) {
        resourceSubscribers.remove(sessionID)
    }

    /// Whether a session is currently subscribed (test/diagnostic).
    public func isResourceSubscriber(sessionID: String) -> Bool {
        resourceSubscribers.contains(sessionID)
    }

    /// Number of currently-subscribed sessions (test/diagnostic).
    public var resourceSubscriberCount: Int { resourceSubscribers.count }

    /// Send `notifications/resources/updated` for `uri` to every subscribed
    /// session. For Streamable-HTTP sessions the notification is delivered via
    /// the session's SDK `Server.notify` (routed to the standalone GET SSE
    /// stream, or stored for replay if the client has no GET stream open). For
    /// legacy SSE sessions it is written to the session's event stream as a
    /// JSON-RPC notification. Best-effort: a closed/missing channel just drops
    /// the event. Stale subscribers are pruned on session teardown, not here,
    /// so iteration over the set stays read-only.
    public func broadcastResourcesUpdated(uri: String) async {
        guard !resourceSubscribers.isEmpty else { return }

        // Streamable-HTTP subscribers: notify via their per-session SDK Server.
        let httpNotification = ResourceUpdatedNotification.message(.init(uri: uri))
        for sessionID in resourceSubscribers {
            if let session = sessions[sessionID] {
                try? await session.server.notify(httpNotification)
            }
        }

        // Legacy SSE subscribers (any subscriber that is not a known HTTP
        // session): emit a raw JSON-RPC notification on the session's event
        // stream. `sendEvent` drops silently if the channel is gone.
        let legacyNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": ResourceUpdatedNotification.name,
            "params": ["uri": uri],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: legacyNotification),
           let json = String(data: data, encoding: .utf8) {
            for sessionID in resourceSubscribers where sessions[sessionID] == nil {
                legacy.sendEvent(sessionID: sessionID, event: "message", data: json)
            }
        }
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
        incrementEvicted: Bool = false,
        preservePersistence: Bool = false
    ) async {
        guard let session = sessions.removeValue(forKey: id) else { return }

        // Drop any resource subscription this session held so a torn-down
        // session never lingers in the broadcast set.
        resourceSubscribers.remove(id)

        // ITEM [session]: a session torn down WITHIN this run (DELETE / expiry /
        // eviction) is genuinely gone — drop it from the durable snapshot so a
        // later reconnect does NOT get a spurious resume signal. The graceful
        // server-stop path passes `preservePersistence: true` so a host restart
        // keeps the rows AND writes a clean-shutdown marker, letting a returning
        // client resume after the restart.
        if !preservePersistence {
            await sessionStore.remove(sessionID: id)
        }

        // W2 telemetry: prune this session's delivery events so the audit card
        // and debug timeline never show a torn-down session. Hop to the main
        // actor (DeliveryLog is @MainActor); enqueued AFTER any in-flight
        // ingest hops for this session, so it wins the teardown race.
        await MainActor.run { DeliveryLog.shared.prune(sessionID: id) }

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
    private let rpcHandler: @Sendable (Data, String?) async -> Data?
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
        rpcHandler: @escaping @Sendable (Data, String?) async -> Data?,
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
            // W2 telemetry: prune this legacy session's delivery events on
            // disconnect so the audit card + debug timeline never show a
            // torn-down legacy session. The Streamable-HTTP + stdio paths prune
            // via `removeSession`; legacy SSE had no such hook, so it leaked
            // rows. The seam hops to the main actor (DeliveryLog is @MainActor)
            // from this NIO event-loop thread — same posture as `removeSession`.
            SSEServer.pruneLegacyDeliveryTelemetry(sessionID: sessionID)
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

        if let responseData = await rpcHandler(bodyData, sessionID),
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
