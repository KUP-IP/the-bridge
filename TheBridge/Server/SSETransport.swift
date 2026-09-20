// SSETransport.swift — SSE Server Transport on :9700
// TheBridge · Server
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
/// and the Streamable HTTP `/mcp` endpoint.
public enum MCPHTTPRoute: Equatable, Sendable {
    case corsPreflight
    case health
    /// RFC 9728 Protected Resource Metadata (`GET /.well-known/oauth-protected-resource`).
    case protectedResourceMetadata
    case legacySSE
    case legacyMessages
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
    private let worktreeOwnershipEnabled: Bool

    /// PKT-800 S2: connector bearer/scope enforcement bundle. **`nil` in
    /// every default configuration** (stdio-only — `BRIDGE_ENABLE_HTTP`
    /// unset / no JWKS configured), which is the additive-isolation
    /// invariant: when `nil`, `handleHTTPRequest` runs exactly as it did
    /// pre-S2, so stdio, legacy SSE, `/health`, the job callback, and the
    /// `/mcp` path itself are byte-for-byte behaviour-identical. Bearer +
    /// scope are enforced ONLY when this is non-nil AND only on the
    /// Streamable-HTTP connector funnel (`handleHTTPRequest`).
    private let connectorAuth: ConnectorAuthContext?
    /// Local-only correlation ledger for every tunnel authentication failure.
    /// Detailed reasons never cross the tunnel response boundary.
    private let authFailureAudit: TunnelAuthFailureAudit

    /// ITEM [session]: durable snapshot of active session ids + minimal
    /// context, persisted across app restart / `make install`. Lets a returning
    /// client carrying its prior `Mcp-Session-Id` be answered with a resumable
    /// re-initialize signal instead of an opaque hard-404. Injected (default
    /// `.shared`) so tests drive it over a temp path. The actor mutates it only
    /// through `await`, so its own actor isolation serializes the disk writes.
    private let sessionStore: SessionPersistenceStore
    /// Redacted accept/reconnect telemetry shared with connections_list and Settings.
    private let connectionObservability: ConnectionRuntimeObservability
    /// Canonical governed-session rebind used by the local tool and Settings.
    private let connectionResetService: ConnectionSessionResetService
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
        var origin: ToolDispatchOrigin
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
        worktreeOwnershipEnabled: Bool = false,
        connectorAuth: ConnectorAuthContext? = nil,
        authFailureAudit: TunnelAuthFailureAudit = .shared,
        sessionStore: SessionPersistenceStore = .shared,
        connectionObservability: ConnectionRuntimeObservability = .shared,
        connectionResetService: ConnectionSessionResetService = .shared
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
        self.worktreeOwnershipEnabled = worktreeOwnershipEnabled
        self.connectorAuth = connectorAuth
        self.authFailureAudit = authFailureAudit
        self.sessionStore = sessionStore
        self.connectionObservability = connectionObservability
        self.connectionResetService = connectionResetService
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

            // Packet E Wave 3 (fail-loud): the connector OAuth gate is live
            // ONLY when streamableHTTP is active — and `connectorAuth` is
            // built iff `transportRouter.isActive(.streamableHTTP)` (see
            // ServerManager.setup), so `connectorAuth != nil` is that signal
            // here without reaching into ServerManager. If the build is also
            // misconfigured (resolved issuer is still the fail-closed
            // placeholder), the PRM route now refuses (503) instead of
            // advertising `auth.example.invalid`; emit ONE loud line so an
            // operator sees why remote sign-in will not work.
            if connectorAuth != nil, ProtectedResourceMetadataProvider.isMisconfigured() {
                print("[SSE] ⚠️ remote access misconfigured: serving no authorization server "
                    + "until BRIDGE_OAUTH_ISSUER / config / baked identity is set")
            }

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

    /// Rotate canonical governance receipts for every live local HTTP session.
    /// The response-capable transport remains active; remote sessions are never
    /// touched. This is the Settings counterpart to `connections_reset`.
    @discardableResult
    public func resetLocalSessions() async -> Int {
        let localSessions = sessions.filter { $0.value.origin == .local }
        var resetCount = 0
        for (id, session) in localSessions {
            let context = ToolDispatchContext(
                transportSessionId: id,
                origin: .local,
                client: session.clientName
            )
            if (try? await connectionResetService.reset(context: context)) != nil {
                resetCount += 1
            }
        }
        return resetCount
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

    /// Remote OAuth readiness for operator-facing health/status surfaces.
    public struct RemoteOAuthReadiness: Sendable, Equatable {
        public let ready: Bool
        public let status: String
    }

    public static func remoteOAuthReadiness(
        connectorAuth: ConnectorAuthContext?,
        isMisconfigured: Bool = ProtectedResourceMetadataProvider.isMisconfigured()
    ) -> RemoteOAuthReadiness {
        guard let connectorAuth else {
            return RemoteOAuthReadiness(ready: false, status: "inactive")
        }
        if isMisconfigured {
            return RemoteOAuthReadiness(ready: false, status: "misconfigured_issuer")
        }
        if !connectorAuth.validator.hasConfiguredKeys {
            return RemoteOAuthReadiness(ready: false, status: "missing_verification_keys")
        }
        return RemoteOAuthReadiness(ready: true, status: "ready")
    }

    /// Operator-facing auth-mode diagnosis. This is served only on the local
    /// health/settings surface; tunnel rejection bodies stay coarse.
    public static func remoteAuthMode(connectorAuth: ConnectorAuthContext?) -> String {
        if connectorAuth != nil { return "oauth" }
        if MCPHTTPValidation.isRemoteTunnelActive(),
           !MCPHTTPValidation.resolveMCPBearerToken().isEmpty {
            return "static_bearer"
        }
        return "inactive"
    }

    /// Build the JSON health response.
    /// Returns server-local health plus remote OAuth readiness. `status=running`
    /// only means the local HTTP process is alive; `remoteOAuthReady` states
    /// whether tunnel-origin connector calls can actually authenticate.
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
        let oauthReadiness = Self.remoteOAuthReadiness(connectorAuth: connectorAuth)

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
            "priorRunEndedCleanly": priorRunClean,
            "remoteAuthMode": Self.remoteAuthMode(connectorAuth: connectorAuth),
            "remoteOAuthReady": oauthReadiness.ready,
            "remoteOAuthStatus": oauthReadiness.status,
            "worktreeOwnershipEnabled": worktreeOwnershipEnabled,
            "worktreeOwnershipMode": worktreeOwnershipEnabled ? "enforced" : "disabled"
        ]
        // Issue #189: counts `/mcp` replies that reached this process. No
        // Cf-Ray or path — public /health is tunnel-reachable without auth.
        let inbound = MCPInboundAudit.shared.snapshot()
        var healthWithInbound = health
        healthWithInbound["mcpInboundCount"] = inbound.count
        if let status = inbound.lastStatus {
            healthWithInbound["mcpInboundLastStatus"] = status
        }
        if let lastAt = inbound.lastAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            healthWithInbound["mcpInboundLastAt"] = formatter.string(from: lastAt)
        }

        return (try? JSONSerialization.data(withJSONObject: healthWithInbound, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - Request Routing (Streamable HTTP — POST /mcp)

    /// PKT-810: a request is "remote" iff Cloudflare stamped a tunnel header on
    /// it. cloudflared adds `Cf-Connecting-Ip` / `Cf-Ray` to every proxied
    /// request reaching the origin AND overwrites any client-supplied copy, so a
    /// remote caller can neither suppress nor spoof "looks local." A direct-
    /// loopback request (local desktop stdio-proxy, or any process on 127.0.0.1)
    /// carries neither. `header(_:)` is case-insensitive (MCP SDK), so wire-case
    /// variance is a non-issue.
    ///
    /// SECURITY — trust boundary: the loopback token-exemption rests ENTIRELY on
    /// this origin signal, which is sound ONLY because (a) the listener binds
    /// 127.0.0.1 (off-box clients can't reach it directly) and (b) cloudflared
    /// is the ONLY fronting proxy and always stamps Cf-*. If `:9700` is ever
    /// fronted by a different proxy (nginx/Caddy/Tailscale Funnel) that does NOT
    /// inject a Cf-* header, every remote request would read as local and become
    /// token-free. Any such proxy MUST inject `Cf-Ray` (or the loopback exemption
    /// must be revisited). A peer-address check does NOT help here: cloudflared
    /// runs on-box, so tunneled traffic also has a loopback peer address.
    public static func isRemoteTunnelRequest(_ request: HTTPRequest) -> Bool {
        request.header("Cf-Connecting-Ip") != nil || request.header("Cf-Ray") != nil
    }

    /// Same tunnel-origin test for the NIO dispatch layer, which holds raw
    /// `HTTPHeaders` (legacy `/sse` + `/messages`) rather than an `HTTPRequest`.
    /// MUST mirror `isRemoteTunnelRequest(_:)` above — keep the two in lockstep
    /// so the loopback exemption can never diverge between the `/mcp` funnel and
    /// the legacy routes. `HTTPHeaders.first(name:)` is case-insensitive (RFC).
    public static func isRemoteTunnelRequest(headers: HTTPHeaders) -> Bool {
        headers.first(name: "Cf-Connecting-Ip") != nil || headers.first(name: "Cf-Ray") != nil
    }

    public func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let requestOrigin: ToolDispatchOrigin = Self.isRemoteTunnelRequest(request) ? .remote : .local
        // PKT-800 S2 / PKT-810 — connector auth gate. ADDITIVE ISOLATION: this
        // block is a no-op (falls straight through) whenever
        // `connectorAuth == nil` (every default, stdio-only config). It is
        // reached ONLY on the Streamable-HTTP `/mcp` funnel (the NIO handler
        // routes `/health`, `/sse`, `/messages`, the job callback, and the PRM
        // doc *before* `handleHTTPRequest`), so no other transport hits it.
        //
        // PKT-810 R5 — origin split: a DIRECT-LOOPBACK request (no Cloudflare
        // tunnel header) is local and token-exempt by contract; only a REMOTE
        // (tunnel) request is OAuth-gated. The prior PKT-810 "loopback static
        // bearer" fallback is removed — it gated loopback behind a bearer the
        // OAuth desktop client never sends, contradicting the documented
        // token-free-loopback contract and dead-ending local clients in a cloud
        // OAuth discovery.
        if let auth = connectorAuth {
            // PKT-810 R5 — restore the documented loopback contract. The UI
            // (ConnectionsSection) promises: "Local clients on this Mac connect
            // with no token — the bearer applies only off-loopback." Cloud OAuth
            // exists ONLY for REMOTE (Cloudflare-tunnel) callers; a request with
            // no tunnel header is a local process on 127.0.0.1 and must NEVER be
            // OAuth-gated. Gating it could only dead-end a local client in an
            // OAuth discovery it should never have been sent to (the WorkOS
            // Dynamic-Client-Registration failure this fixes — the WWW-Authenticate
            // points a loopback client at a cloud sign-in service). Serve the
            // loopback request as a LOCAL session (`connectorAuthed: false`) so it
            // keeps the full local tool surface; `createSession` additionally
            // skips the legacy static-bearer / remote-tunnel-missing phase for a
            // loopback request, so loopback is token-free end-to-end — exactly as
            // documented and as the stdio-only build behaves. Tunnel requests
            // (Cf header present) fall through to the full OAuth gate below:
            // remote enforcement is entirely unchanged, and no bearer over the
            // tunnel can ever be bypassed.
            if !Self.isRemoteTunnelRequest(request) {
                await auth.diagnostics.record(
                    outcome: "local.exempt",
                    detail: "loopback"
                )
                return await processStreamableHTTP(request, origin: .local)
            }
            let authHeader = request.header(HTTPHeaderName.authorization)
            do {
                let token = try await auth.validator.validate(authorizationHeader: authHeader)
                await auth.diagnostics.record(
                    outcome: "bearer.accepted",
                    detail: "method=\(request.method) sub-len=\(token.subject.count)"
                )
                return await dispatchAuthorizedConnectorRequest(
                    request,
                    token: token,
                    auth: auth,
                    origin: .remote
                )
            } catch let err as BearerValidationError {
                let reason = Self.tunnelAuthFailureReason(
                    for: err,
                    authorizationHeader: authHeader
                )
                let correlationID = authFailureAudit.record(reason)
                await auth.diagnostics.record(
                    outcome: "auth.failed",
                    detail: "correlation_id=\(correlationID) reason=\(reason.rawValue)"
                )
                return Self.unauthorizedResponse(correlationID: correlationID, auth: auth)
            } catch {
                let correlationID = authFailureAudit.record(.oauthRevoked)
                await auth.diagnostics.record(
                    outcome: "auth.failed",
                    detail: "correlation_id=\(correlationID) reason=oauth_revoked"
                )
                return Self.unauthorizedResponse(
                    correlationID: correlationID, auth: auth
                )
            }
        } else if Self.isRemoteTunnelRequest(request) {
            let correlationID = authFailureAudit.record(.oauthInactive)
            return Self.remoteOAuthInactiveResponse(correlationID: correlationID)
        }

        return await processStreamableHTTP(request, origin: requestOrigin)
    }

    /// Keep opaque legacy bearer failures distinct in the local audit while
    /// preserving OAuth precedence. Once connector auth is active, an opaque
    /// bearer is never accepted as the legacy static token; it is diagnosed
    /// locally as a static-bearer mismatch and receives the same coarse tunnel
    /// response as every OAuth failure.
    public nonisolated static func tunnelAuthFailureReason(
        for error: BearerValidationError,
        authorizationHeader: String?
    ) -> TunnelAuthFailureReason {
        if case .malformedToken = error,
           !MCPHTTPValidation.resolveMCPBearerToken().isEmpty,
           let token = ConnectorBearerValidator.bearerToken(
               fromAuthorizationHeader: authorizationHeader
           ),
           token.split(separator: ".", omittingEmptySubsequences: false).count != 3 {
            return .staticBearerMismatch
        }
        return TunnelAuthFailureReason(error)
    }

    /// The original (pre-S2) Streamable-HTTP session handling, unchanged.
    /// Split out so both the unauthenticated default path and the
    /// post-bearer authorized path funnel through identical session logic.
    private func processStreamableHTTP(
        _ request: HTTPRequest,
        connectorAuthed: Bool = false,
        origin: ToolDispatchOrigin = .local,
        governancePrincipal: String? = nil
    ) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            // Durability: refresh the persisted last-accessed timestamp.
            await sessionStore.touch(sessionID: sessionID, at: session.lastAccessedAt)

            let response = await ToolDispatchContext.$current.withValue(
                ToolDispatchContext(
                    transportSessionId: sessionID,
                    origin: origin,
                    client: session.clientName,
                    clientVersion: session.clientVersion,
                    governancePrincipal: governancePrincipal
                )
            ) {
                await session.transport.handleRequest(request)
            }

            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                await removeSession(sessionID, reason: "closed via DELETE", incrementClosed: true)
            }

            return response
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequest(body)
        {
            return await createSession(
                request,
                connectorAuthed: connectorAuthed,
                origin: origin,
                governancePrincipal: governancePrincipal
            )
        }

        if let sessionID {
            // ITEM [session]: the id is not live in THIS run. Before the opaque
            // hard-404, consult the durable snapshot — if the id was persisted
            // from a prior run, the host restarted / was reinstalled. Answer
            // with the resumable re-initialize signal so the client recovers
            // instead of surfacing "Session not found or expired".
            switch await sessionStore.resumeLookup(sessionID: sessionID) {
            case .resumable(let persisted, let cleanShutdown):
                totalSessionsResumeSignaled += 1
                await connectionObservability.recordReconnect(
                    transportSessionId: sessionID,
                    origin: origin,
                    clientName: persisted.clientName
                )
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
        correlationID: String,
        auth: ConnectorAuthContext
    ) -> HTTPResponse {
        MCPHTTPValidation.coarseAuthFailureResponse(
            statusCode: 401,
            correlationID: correlationID,
            extraHeaders: [
                HTTPHeaderName.wwwAuthenticate: auth.wwwAuthenticateValue(correlationID: correlationID)
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

    /// Remote tunnel traffic reached `/mcp`, but this Bridge process did not
    /// build a connector auth context. That is not a local-client case; it means
    /// the cloud/OAuth startup invariant failed (for example missing
    /// BRIDGE_ENABLE_HTTP / config at process launch). Fail loudly so remote
    /// clients never see a green local session backed by the wrong auth model.
    public static func remoteOAuthInactiveResponse(correlationID: String) -> HTTPResponse {
        MCPHTTPValidation.coarseAuthFailureResponse(
            statusCode: 503,
            correlationID: correlationID
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
        auth: ConnectorAuthContext,
        origin: ToolDispatchOrigin
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

        // Connector tool-authorization policy. Production defaults to strict:
        // remote tokens may reach only the connector allowlist, with destructive
        // tool calls requiring step-up. WorkOS/AuthKit tokens that carry only
        // standard OpenID scopes are treated as authenticated directory tokens by
        // ConnectorScopeGate, while tokens carrying Bridge custom scopes still
        // use strict per-scope intersection.
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
        let governancePrincipal = SessionRegistry.principalKey(subject: token.subject)
        if let connectorResponse = await processConnectorJSONRPC(
            request,
            token: token,
            auth: auth,
            origin: origin,
            governancePrincipal: governancePrincipal
        ) {
            return connectorResponse
        }
        return await processStreamableHTTP(
            request,
            connectorAuthed: true,
            origin: origin,
            governancePrincipal: governancePrincipal
        )
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
    private func processConnectorJSONRPC(
        _ request: HTTPRequest,
        token: BridgeAccessToken,
        auth: ConnectorAuthContext,
        origin: ToolDispatchOrigin,
        governancePrincipal: String? = nil
    ) async -> HTTPResponse? {
        guard request.method.uppercased() == "POST",
              let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else { return nil }

        let requestId = json["id"]
        let requestSessionID = request.header(HTTPHeaderName.sessionID)
        let sessionID = requestSessionID ?? UUID().uuidString
        // Compact connector clients can add, change, or omit Mcp-Session-Id
        // between calls. Keep a stable audit label for this compatibility path,
        // but never treat that shared label as routing authority: remote calls
        // use explicit, principal-bound route receipts in ToolRouter.
        let brokerSessionID = origin == .remote
            ? ToolDispatchContext.remoteConnectorJSONSessionID
            : (requestSessionID ?? sessionID)
        let principal = governancePrincipal ?? SessionRegistry.principalKey(subject: token.subject)
        let headers = Self.connectorJSONHeaders(sessionID: sessionID)

        switch method {
        case "initialize":
            var clientName: String?
            if let params = json["params"] as? [String: Any],
               let clientInfo = params["clientInfo"] as? [String: Any],
               let name = clientInfo["name"] as? String {
                clientName = name
                let version = clientInfo["version"] as? String ?? "unknown"
                let onClientConnected = self.onClientConnected
                await MainActor.run { onClientConnected(name, version) }
                print("[SSE-Connector] Client identified: \(name) v\(version)")
            }
            let composition = await StandingOrdersDelivery.asyncComposition(clientName: clientName)
            DeliveryLog.shared.recordHandshakeDelivered(
                sessionID: sessionID,
                clientName: clientName,
                tokenCount: composition.tokenCount,
                contentHash: composition.contentHash
            )
            await connectionObservability.recordAccept(
                transportSessionId: sessionID,
                origin: origin,
                clientName: clientName,
                authMode: origin == .remote ? "oauth" : "loopback_exempt",
                tokenExpiresAt: origin == .remote ? token.exp.value : nil
            )
            let data = buildRPCResponse(id: requestId, result: [
                "protocolVersion": BridgeConstants.mcpProtocolVersion,
                "capabilities": [
                    "tools": [:] as [String: Any],
                    "resources": ["subscribe": true, "listChanged": true] as [String: Any],
                ] as [String: Any],
                "serverInfo": [
                    "name": "The Bridge",
                    "version": AppVersion.resolved
                ] as [String: Any],
                "instructions": composition.instructionsMarkdown
            ] as [String: Any]) ?? Data()
            return .data(data, headers: headers)

        case "notifications/initialized":
            return .accepted(headers: headers)

        case "tools/list":
            let disabledNames = ToolListingGates.mergedDisabledToolNames()
            var regs = await router.registrationsForListTools(disabledNames: disabledNames)
            if let allowlist = toolAllowlist {
                regs = regs.filter { allowlist.contains($0.name) }
            }
            regs = await connectorVisibleRegistrations(regs, token: token, auth: auth)
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
            let queued = origin == .remote
            let (payload, receipt) = await ConnectorCallQueue.shared.runSerialized(
                sessionKey: brokerSessionID,
                toolName: name,
                queued: queued
            ) { () -> Result<(text: String, isError: Bool), ConnectorDeliveryError> in
                let (text, isError) = await router.dispatchFormatted(
                    toolName: name,
                    arguments: argsValue,
                    context: ToolDispatchContext(
                        transportSessionId: brokerSessionID,
                        origin: origin,
                        client: origin == .remote ? "remote-connector" : nil,
                        governancePrincipal: principal,
                        routeAcknowledgementMode: origin == .remote ? .explicitReceipt : .transportSession
                    )
                )
                return .success((text: text, isError: isError))
            }
            let text = payload?.text ?? "Error: connector dispatch did not execute"
            let isError = payload?.isError ?? true
            if payload != nil && !isError { await MainActor.run { onToolCall() } }
            var result: [String: Any] = [
                "content": [["type": "text", "text": text] as [String: Any]],
                "isError": isError
            ]
            result["_meta"] = ["connectorObservation": receipt.observationDictionary]
            let data = buildRPCResponse(id: requestId, result: result) ?? Data()
            return .data(data, headers: headers)

        case "ping":
            let data = buildRPCResponse(id: requestId, result: [:] as [String: Any]) ?? Data()
            return .data(data, headers: headers)

        case "resources/list":
            let data = buildRPCResponse(id: requestId, result: [
                "resources": BridgeResources.listAsDictionaries
            ] as [String: Any]) ?? Data()
            return .data(data, headers: headers)

        case "resources/read":
            let params = json["params"] as? [String: Any] ?? [:]
            guard let uri = params["uri"] as? String else {
                let data = buildRPCError(id: requestId, code: -32602, message: "Missing 'uri' parameter") ?? Data()
                return .data(data, headers: headers)
            }
            do {
                let markdown = try await BridgeResources.markdown(for: uri, clientName: nil)
                DeliveryLog.shared.recordResourceRead(
                    sessionID: sessionID,
                    clientName: nil,
                    uri: uri,
                    contentHash: await StandingOrdersDelivery.asyncComposition().contentHash
                )
                let data = buildRPCResponse(id: requestId, result: [
                    "contents": [[
                        "uri": uri,
                        "mimeType": "text/markdown",
                        "text": markdown,
                    ] as [String: Any]]
                ] as [String: Any]) ?? Data()
                return .data(data, headers: headers)
            } catch {
                let data = buildRPCError(id: requestId, code: -32602, message: "Unknown resource URI: \(uri)") ?? Data()
                return .data(data, headers: headers)
            }

        case "resources/subscribe":
            let params = json["params"] as? [String: Any] ?? [:]
            guard params["uri"] is String else {
                let data = buildRPCError(id: requestId, code: -32602, message: "Missing 'uri' parameter") ?? Data()
                return .data(data, headers: headers)
            }
            addResourceSubscriber(sessionID: sessionID)
            let data = buildRPCResponse(id: requestId, result: [:] as [String: Any]) ?? Data()
            return .data(data, headers: headers)

        case "resources/unsubscribe":
            removeResourceSubscriber(sessionID: sessionID)
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

    private func connectorVisibleRegistrations(
        _ registrations: [ToolRegistration],
        token: BridgeAccessToken,
        auth: ConnectorAuthContext
    ) async -> [ToolRegistration] {
        guard auth.strictScopes else { return registrations }

        var visible: [ToolRegistration] = []
        for registration in registrations {
            let decision = await auth.scopeGate.evaluate(
                toolName: registration.name,
                grantedScopes: token.connectorScopes
            )
            if case .allow = decision {
                visible.append(registration)
            }
        }
        return visible
    }

    private static func connectorJSONHeaders(sessionID: String) -> [String: String] {
        [
            HTTPHeaderName.contentType: "application/json",
            HTTPHeaderName.sessionID: sessionID
        ]
    }

    // MARK: - Session Factory (Streamable HTTP)

    private func createSession(
        _ request: HTTPRequest,
        connectorAuthed: Bool = false,
        origin: ToolDispatchOrigin = .local,
        governancePrincipal: String? = nil
    ) async -> HTTPResponse {
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

        // PKT-810 R5 — origin split for the LEGACY bearer phase too. A direct-
        // loopback request (no Cloudflare tunnel header) is token-free by the
        // documented contract, so the legacy static-bearer / remote-tunnel-missing
        // validators must NOT apply to it — only to REMOTE (tunnel) requests.
        // This holds whether or not the connector OAuth path is enabled: with
        // `tunnelURL` + a static `mcpBearerToken` configured (the cloud-connector
        // operator install), a local client on 127.0.0.1 would otherwise 401 with
        // "missing Bearer token for MCP HTTP" — the same loopback dead-end the
        // origin split removes. Remote requests keep the full legacy gate, so the
        // tunnel still requires its bearer. (`connectorAuthed` already implies a
        // verified caller, so it is exempt regardless.)
        let bearerExempt = connectorAuthed || !Self.isRemoteTunnelRequest(request)
        let validationPipeline = MCPHTTPValidation.streamableHTTPPipeline(
            ssePort: port,
            connectorAuthed: bearerExempt,
            authFailureAudit: authFailureAudit
        )

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedIDGenerator(id: sessionID),
            validationPipeline: validationPipeline
        )

        let appVersion = AppVersion.resolved
        // SSOT + PKT-977 Wave 2 Q1: the Streamable-HTTP session's
        // `initialize.instructions` comes from StandingOrdersDelivery.
        // `asyncComposition` is used here: when the operator has enabled
        // memory auto-inject (global flag or per-client override), the
        // salient memory slice is appended token-capped. When the flag is
        // OFF (the default), `asyncComposition` returns the same bytes as
        // the sync path, so behaviour is byte-identical for existing sessions.
        let composition = await StandingOrdersDelivery.asyncComposition(clientName: clientName)
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
            name: "TheBridgeSSE",
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
        let toolAllowlist = (connectorAuth != nil && !connectorAuthed) ? nil : self.toolAllowlist

        // MCP resource handlers (Streamable-HTTP path). Bytes come from the
        // same StandingOrdersDelivery SSOT the stdio + legacy paths serve.
        // Subscription tracking + `notifications/resources/updated` delivery
        // for this transport is owned by the actor's `resourceSubscribers`
        // set, keyed by sessionID (see `broadcastResourcesUpdated`).
        let resourceClientName = clientName
        let resourceClientVersion = clientVersion
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
                contentHash: await StandingOrdersDelivery.asyncComposition(clientName: resourceClientName).contentHash
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
            let disabledNames = ToolListingGates.mergedDisabledToolNames()
            var registrations = await router.registrationsForListTools(disabledNames: disabledNames)
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
            let dispatchContext = ToolDispatchContext.current ?? ToolDispatchContext(
                transportSessionId: resourceSessionID,
                origin: origin,
                client: resourceClientName,
                clientVersion: resourceClientVersion,
                governancePrincipal: governancePrincipal
            )
            let (text, isError) = await router.dispatchFormatted(
                toolName: params.name,
                arguments: arguments,
                context: dispatchContext
            )
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
                clientVersion: clientVersion,
                origin: origin
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

            await connectionObservability.recordAccept(
                transportSessionId: sessionID,
                origin: origin,
                clientName: clientName,
                authMode: origin == .remote
                    ? (connectorAuth == nil ? "static_bearer" : "oauth")
                    : "loopback_exempt",
                tokenExpiresAt: nil,
                at: createdAt
            )

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
            // SSOT + PKT-977 Wave 2 Q1: legacy initialize uses asyncComposition
            // so memory auto-inject (when enabled) also reaches legacy SSE clients.
            // When the flag is OFF (default), asyncComposition is byte-identical to
            // the sync path — no behaviour change for existing sessions.
            let legacyClientName = sessionID.flatMap { legacy.clientName(sessionID: $0) }
            let composition = await StandingOrdersDelivery.asyncComposition(clientName: legacyClientName)
            let composedInstructions = composition.instructionsMarkdown
            // W2 telemetry: record the handshake we composed + shipped, same as
            // the Streamable-HTTP path (both transports emit identically). The
            // clientName was stored into `legacy` before this handler ran.
            if let sessionID {
                DeliveryLog.shared.recordHandshakeDelivered(
                    sessionID: sessionID,
                    clientName: legacyClientName,
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
            let disabledNames = ToolListingGates.mergedDisabledToolNames()
            var regs = await router.registrationsForListTools(disabledNames: disabledNames)
            if let allowlist = toolAllowlist {
                regs = regs.filter { allowlist.contains($0.name) }
            }
            let tools: [[String: Any]] = regs.compactMap { reg in
                guard let data = try? JSONEncoder().encode(MCPToolFactory.tool(for: reg)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return object
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

            let (text, isError) = await router.dispatchFormatted(
                toolName: name,
                arguments: argsValue,
                context: ToolDispatchContext(
                    transportSessionId: sessionID,
                    origin: .local,
                    client: sessionID.flatMap { legacy.clientName(sessionID: $0) }
                )
            )
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
                        contentHash: await StandingOrdersDelivery.asyncComposition(
                            clientName: legacy.clientName(sessionID: sessionID)
                        ).contentHash
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

        await connectionObservability.recordDisconnect(transportSessionId: id)

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
    private let onClientDisconnected: @Sendable (String) async -> Void  // PKT-366 F13

    /// Packet E Wave 3 (test seam ONLY): when non-nil, the PRM serving path
    /// uses this in place of `ProtectedResourceMetadataProvider.prmServingDecision()`,
    /// so the serving-path test can drive both the configured (200) and
    /// misconfigured (503) branches hermetically without mutating the process
    /// environment or `ConfigManager`. nil in every production code path (the
    /// `start()` bootstrap never sets it) ⇒ live behaviour is unchanged.
    private let prmDecisionForTesting:
        (@Sendable () -> ProtectedResourceMetadataProvider.PRMServingDecision)?

    private struct PendingRequest {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var assemblies: [PendingRequest] = []
    private var completed: [(head: HTTPRequestHead, body: Data?)] = []
    private var drainTask: Task<Void, Never>?
    private let assemblyLock = NSLock()
    private var legacySessionID: String?

    init(
        legacyBridge: LegacySSEBridge,
        endpoint: String,
        rpcHandler: @escaping @Sendable (Data, String?) async -> Data?,
        httpRequestHandler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
        healthHandler: @escaping @Sendable () async -> Data,
        onClientDisconnected: @escaping @Sendable (String) async -> Void = { _ in },
        prmDecisionForTesting:
            (@Sendable () -> ProtectedResourceMetadataProvider.PRMServingDecision)? = nil
    ) {
        self.legacyBridge = legacyBridge
        self.endpoint = endpoint
        self.rpcHandler = rpcHandler
        self.httpRequestHandler = httpRequestHandler
        self.healthHandler = healthHandler
        self.onClientDisconnected = onClientDisconnected
        self.prmDecisionForTesting = prmDecisionForTesting
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        ingest(unwrapInboundIn(data), context: context)
    }

    /// PKT-1296: assemble HTTP/1.1 requests in FIFO order and drain them
    /// serially so overlapping keepalive POSTs cannot clobber each other or
    /// interleave response writers on one channel.
    fileprivate func ingest(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        switch part {
        case .head(let head):
            withAssemblyLock {
                assemblies.append(PendingRequest(
                    head: head,
                    bodyBuffer: context.channel.allocator.buffer(capacity: 0)
                ))
            }
        case .body(var buffer):
            withAssemblyLock {
                if !assemblies.isEmpty {
                    assemblies[assemblies.count - 1].bodyBuffer.writeBuffer(&buffer)
                }
            }
        case .end:
            withAssemblyLock {
                let req: PendingRequest? = assemblies.isEmpty ? nil : assemblies.removeFirst()
                if let req {
                    completed.append(Self.completedTuple(req))
                }
            }
            startDrain(context: context)
        }
    }

    private static func completedTuple(_ req: PendingRequest) -> (head: HTTPRequestHead, body: Data?) {
        let bodyData: Data? = req.bodyBuffer.readableBytes > 0
            ? req.bodyBuffer.getBytes(at: 0, length: req.bodyBuffer.readableBytes).map { Data($0) }
            : nil
        return (req.head, bodyData)
    }

    nonisolated private func withAssemblyLock(_ body: () -> Void) {
        assemblyLock.lock()
        defer { assemblyLock.unlock() }
        body()
    }

    nonisolated private func takeNextCompleted() -> (head: HTTPRequestHead, body: Data?)? {
        assemblyLock.lock()
        defer { assemblyLock.unlock() }
        guard !completed.isEmpty else {
            drainTask = nil
            return nil
        }
        return completed.removeFirst()
    }

    nonisolated private func snapshotDrainState() -> (task: Task<Void, Never>?, remaining: Int) {
        assemblyLock.lock()
        defer { assemblyLock.unlock() }
        return (drainTask, completed.count)
    }

    private func startDrain(context: ChannelHandlerContext) {
        assemblyLock.lock()
        if drainTask == nil {
            nonisolated(unsafe) let ctx = context
            drainTask = Task { [weak self] in
                await self?.drainQueue(context: ctx)
            }
        }
        assemblyLock.unlock()
    }

    private func drainQueue(context: ChannelHandlerContext) async {
        while true {
            guard let next = takeNextCompleted() else { return }
            await processRequest(head: next.head, body: next.body, context: context)
        }
    }

    fileprivate func waitUntilIdleForTesting() async {
        while true {
            let snapshot = snapshotDrainState()
            if snapshot.task == nil && snapshot.remaining == 0 { return }
            await snapshot.task?.value
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

    // `fileprivate` (was `private`) ONLY so the same-file public test seam
    // `SSEServer.runHTTPHandlerForTesting` can invoke the UNMODIFIED dispatch;
    // still unreachable outside this file. The body is byte-unchanged.
    fileprivate func processRequest(head: HTTPRequestHead, body: Data?, context: ChannelHandlerContext) async {
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
            //
            // Packet E Wave 3 (fail-loud): when the build is misconfigured —
            // the resolved issuer is still the `auth.example.invalid`
            // placeholder (no env / config / baked identity) — do NOT serve a
            // 200 advertising that placeholder authorization server. A client
            // would be pushed into a dead OAuth discovery against a
            // non-resolvable host. Return 503 with a short error that
            // advertises NO `authorization_servers` instead. When configured,
            // `.serve(body)` carries exactly `jsonBody()` → the 200 PRM is
            // byte-identical to the pre-Wave-3 behaviour.
            //
            // `prmDecisionForTesting` is nil in every production path, so the
            // live decision is always the global `prmServingDecision()`; it is
            // set ONLY by the hermetic serving-path test seam.
            switch (prmDecisionForTesting?() ?? ProtectedResourceMetadataProvider.prmServingDecision()) {
            case .serve(let prmData):
                logAccess(method: "GET", path: path, sessionID: nil, status: 200, start: startTime)
                await writeJSONResponse(data: prmData, version: head.version, context: context)
            case .refuseMisconfigured:
                logAccess(method: "GET", path: path, sessionID: nil, status: 503, start: startTime)
                await writeResponse(
                    .error(statusCode: 503, .internalError(
                        ProtectedResourceMetadataProvider.misconfiguredPRMErrorMessage)),
                    version: head.version,
                    context: context)
            }
            return

        case .legacySSE:
            // PKT-810 R5 (hardening): the legacy SSE transport (PKT-336) is a
            // LOOPBACK-ONLY compatibility path. It is dispatched HERE — before the
            // `/mcp` connector-auth gate in `handleHTTPRequest` — so without this
            // check a Cloudflare-tunnel caller could open an UNAUTHENTICATED legacy
            // session and drive the full tool surface, bypassing the entire
            // bearer/OAuth gate that protects `/mcp`. Refuse tunnel-origin requests
            // (Cf-* present); direct loopback (older local SSE clients) is
            // unaffected. Mirrors the `/mcp` origin split exactly.
            if SSEServer.isRemoteTunnelRequest(headers: head.headers) {
                logAccess(method: "GET", path: path, sessionID: nil, status: 403, start: startTime)
                await writeResponse(
                    .error(statusCode: 403, .invalidRequest("Legacy SSE transport is loopback-only")),
                    version: head.version,
                    context: context)
                return
            }
            logAccess(method: "GET", path: path, sessionID: nil, status: 200, start: startTime)
            await handleLegacySSE(head: head, context: context)
            return

        case .legacyMessages:
            // PKT-810 R5 (hardening): loopback-only, same rationale as `.legacySSE`.
            if SSEServer.isRemoteTunnelRequest(headers: head.headers) {
                logAccess(method: "POST", path: path, sessionID: nil, status: 403, start: startTime)
                await writeResponse(
                    .error(statusCode: 403, .invalidRequest("Legacy messages transport is loopback-only")),
                    version: head.version,
                    context: context)
                return
            }
            logAccess(method: "POST", path: path, sessionID: nil, status: 200, start: startTime)
            await handleLegacyMessage(head: head, body: body, uri: fullURI, context: context)
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
        MCPInboundAudit.shared.record(status: response.statusCode)
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

// MARK: - Public test seam (Packet E Wave 3 / audit #1 + #2)
//
// `SSEHTTPHandler` and its `processRequest` are file-private, and the test
// target imports `TheBridgeLib` WITHOUT `@testable` (custom executable harness),
// so it can only reach PUBLIC API. To prove the REAL outbound behaviour of the
// live NIO route classification + origin gate (rather than re-asserting the
// predicate in isolation), this narrow public seam runs the UNMODIFIED
// `processRequest` against a caller-supplied `Channel`.
//
// The caller-supplied channel keeps `NIOEmbedded` (an `EmbeddedChannel` is a
// test-only construct) OUT of the production library's dependency graph — the
// test builds the `EmbeddedChannel`, hands it in as the NIOCore `Channel`
// protocol, then drains the outbound parts itself. Nothing here touches the
// origin-decision logic (route classify, `isRemoteTunnelRequest`, the
// legacy-route loopback-only 403, the loopback `/mcp` split): those run exactly
// as in production.
extension SSEServer {
    /// Run ONE decoded request end-to-end through the live
    /// `SSEHTTPHandler.processRequest`, writing the outbound response parts to
    /// `channel`. The caller (test) supplies the channel and reads the outbound
    /// parts back. `prmDecisionForTesting` is the only injectable seam (used by
    /// the PRM serving-path test to drive both the configured-200 and the
    /// misconfigured-503 branches hermetically); every other input flows through
    /// the unmodified route + gate code.
    public static func runHTTPHandlerForTesting(
        on channel: Channel,
        head: HTTPRequestHead,
        body: Data? = nil,
        prmDecisionForTesting:
            (@Sendable () -> ProtectedResourceMetadataProvider.PRMServingDecision)? = nil
    ) async throws {
        let handler = SSEHTTPHandler(
            legacyBridge: LegacySSEBridge(),
            endpoint: "/mcp",
            rpcHandler: { _, _ in nil },
            httpRequestHandler: { _ in .ok() },
            healthHandler: { Data("{}".utf8) },
            onClientDisconnected: { _ in },
            prmDecisionForTesting: prmDecisionForTesting
        )
        try await channel.pipeline.addHandler(handler).get()
        let context = try await channel.pipeline.context(handler: handler).get()
        await handler.processRequest(head: head, body: body, context: context)
    }

    /// PKT-1296 test seam: feed raw HTTP/1.1 parts (including overlapping
    /// heads) through the live assembler + serial drain.
    public static func ingestHTTPPartsForTesting(
        on channel: Channel,
        parts: [HTTPServerRequestPart]
    ) async throws {
        let handler = SSEHTTPHandler(
            legacyBridge: LegacySSEBridge(),
            endpoint: "/mcp",
            rpcHandler: { _, _ in nil },
            httpRequestHandler: { _ in .ok() },
            healthHandler: { Data("{\"ok\":true}".utf8) },
            onClientDisconnected: { _ in }
        )
        try await channel.pipeline.addHandler(handler).get()
        let context = try await channel.pipeline.context(handler: handler).get()
        for part in parts {
            handler.ingest(part, context: context)
        }
        await handler.waitUntilIdleForTesting()
    }
}
