// ServerManager.swift — Unified MCP Server Lifecycle
// The Bridge v1: Manages server setup, module registration, and transport
// Created by PKT-317: Merge TheBridge app + server into single binary
// Updated by PKT-318: Added SSE transport on :9700
// Updated by PKT-329: Configurable port via NOTION_BRIDGE_PORT env var
// Updated by PKT-341: Version from Bundle (single source of truth), AuditLog simplified
// V1-QUALITY-C2: Added onClientConnected callback for client identification.
//   SSEServer and legacy RPC now extract clientInfo from initialize requests.
// PKT-354: Added ScreenModule registration (screen_capture + screen_ocr).
// PKT-356: Added AccessibilityModule + screen recording tools.
// PKT-356-hotfix: Added AppleScriptModule for in-process AppleScript — fixes TCC prompt storm.

import Foundation
import MCP

/// Encapsulates the MCP server lifecycle: component creation, module registration,
/// handler wiring, and transport startup. Designed to run in a background Task
/// from AppDelegate while exposing status to the UI via StatusBarController.
///
/// Pattern: Nudge Server — SwiftUI + async MCP server coexistence.
/// The actor isolates all server state; UI updates flow through a MainActor callback.
public actor ServerManager {
    /// W2 telemetry: the stable synthetic session id under which the single
    /// stdio connection's delivery events (handshake + resource reads) roll up
    /// into one Delivery-audit row. stdio has no per-session id of its own.
    public static let stdioSessionID = "stdio-local"

    private var server: Server?
    private var router: ToolRouter?
    private var sseServer: SSEServer?
    private var auditLog: AuditLog?
    private var securityGate: SecurityGate?
    private let toolAllowlist: Set<String>?

    // MARK: - WS-D (PKT-921): Bridge Cloud Access wiring

    /// The live cloud manager, assembled in `setup()` ONLY when Bridge Cloud
    /// Access is enabled (`BridgeDefaults.cloudAccessEnabled`). Owns the
    /// connection-state machine the heartbeat probes and the `bridge_status`
    /// tool reads. nil in every default (cloud-off) install.
    private var cloudManager: BridgeCloudManager?

    /// The heartbeat loop driving `cloudManager.refreshHealth()` on a ~30s
    /// cadence while cloud access is enabled. Started at launch when enabled
    /// and on the cloudAccessEnabled→true toggle; stopped on the →false toggle.
    private var cloudHeartbeat: CloudHeartbeat?

    /// Injectable resolver for "is THIS tools/list request arriving over the
    /// CLOUD transport?". A cloud-originated request (served via the WS-A/WS-B
    /// tunnel) must have its Mac tools hidden when the channel is offline; a
    /// local stdio/SSE request always sees the full surface.
    ///
    /// Live cloud-route header detection lands with the operator tunnel
    /// (PKT-810 / WS-A / WS-B); until then the production resolver returns
    /// `false`, so the stdio/SSE ListTools handler is byte-for-byte unchanged.
    /// The seam exists so the conditional is unit-testable now and the cloud
    /// transport can flip it without re-plumbing `setup()`.
    public typealias CloudRouteResolver = @Sendable () async -> Bool
    private let isCloudRequest: CloudRouteResolver

    /// WS-B (PKT-803): the active-transport router. Default config resolves
    /// to `[.stdio]` only, so existing clients are unaffected;
    /// `BRIDGE_ENABLE_HTTP=1` additively opts into streamableHTTP.
    ///
    /// S4 (PKT-800): now an injected init parameter (default
    /// `TransportRouter()` — production behaviour is byte-for-byte
    /// unchanged: the no-arg init reads `ProcessInfo` exactly as the
    /// prior hardcoded `let` did). The seam lets a test drive the
    /// streamableHTTP-active path of `runStreamableHTTP()` /
    /// `isStreamableHTTPActive` deterministically without setting a
    /// process-wide env var or launching the GUI.
    public nonisolated let transportRouter: TransportRouter

    /// The configured SSE port (config.json -> env var -> default).
    public nonisolated let ssePort: Int

    /// Callback invoked on the main actor after each successful tool dispatch.
    private let onToolCall: @MainActor @Sendable () -> Void

    /// V1-QUALITY-C2: Callback invoked on the main actor when a client connects.
    /// Parameters: (clientName: String, clientVersion: String)
    private let onClientConnected: @MainActor @Sendable (String, String) -> Void

    /// PKT-366 F13: Callback invoked on the main actor when a client disconnects.
    private let onClientDisconnected: @MainActor @Sendable (String) -> Void

    /// - Parameter onToolCall: Closure called on MainActor after each tool call completes.
    ///   Use this to increment StatusBarController.totalToolCalls.
    /// - Parameter onClientConnected: Closure called on MainActor when an MCP client connects.
    ///   Use this to update StatusBarController.connectedClients.
    /// - Parameter transportRouter: S4 (PKT-800) test seam. Defaults to
    ///   `TransportRouter()` (reads `ProcessInfo` — production callers omit
    ///   this and behaviour is byte-for-byte unchanged). A test may inject
    ///   one built from an explicit environment to exercise the
    ///   streamableHTTP-active path without a process-wide env var.
    public init(
        onToolCall: @escaping @MainActor @Sendable () -> Void,
        onClientConnected: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in },
        onClientDisconnected: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        toolAllowlist: Set<String>? = nil,
        transportRouter: TransportRouter = TransportRouter(),
        isCloudRequest: @escaping CloudRouteResolver = { false }
    ) {
        self.onToolCall = onToolCall
        self.onClientConnected = onClientConnected
        self.onClientDisconnected = onClientDisconnected
        self.toolAllowlist = toolAllowlist
        self.transportRouter = transportRouter
        self.ssePort = ConfigManager.shared.ssePort
        self.isCloudRequest = isCloudRequest
    }

    // MARK: - Setup

    /// Set up server components, register all modules, wire MCP handlers.
    /// Returns the number of registered tools.
    public func setup() async -> Int {
        // 1. Create core components
        let securityGate = SecurityGate()
        self.securityGate = securityGate
        let auditLog = AuditLog()
        self.auditLog = auditLog
        let router = ToolRouter(securityGate: securityGate, auditLog: auditLog)
        self.router = router

        let onToolCall = self.onToolCall
        let onClientConnected = self.onClientConnected
        let onClientDisconnected = self.onClientDisconnected

        // PKT-800 S2: connector bearer/scope context is built ONLY when
        // the streamableHTTP transport is gated on (`BRIDGE_ENABLE_HTTP=1`).
        // In every default install the transport router is stdio-only, so
        // this stays `nil` and `SSEServer` runs byte-for-byte as before —
        // the legacy SSE listener / `/health` / job callback / stdio are
        // untouched. Keys are resolved from `BRIDGE_OAUTH_JWKS` (inline
        // JSON or a local file — never the network); absent ⇒ a
        // fail-closed validator that rejects every bearer.
        let connectorAuth: ConnectorAuthContext? = await {
            guard transportRouter.isActive(.streamableHTTP) else { return nil }
            let issuer = ProtectedResourceMetadataProvider.resolvedIssuer()
            let resource = ProtectedResourceMetadataProvider.resolvedResource(port: ssePort)
            let validator = await ConnectorBearerValidator.fromEnvironment(
                expectedIssuer: issuer,
                expectedAudience: resource
            )
            // PKT-810 R5: whether the cloud OAuth tenant is ACTUALLY provisioned
            // (`WorkOSConfig.isConfigured` — a real, non-placeholder client id).
            // The PUBLIC resource_metadata pointer is conditioned on this: a
            // non-live tenant must never be advertised to a client as a real
            // sign-in service.
            let cloudOAuthLive = WorkOSConfig.resolved().isConfigured
            // PKT-810: the RFC 9728 resource_metadata pointer in the
            // WWW-Authenticate challenge MUST be reachable by the REMOTE
            // client — derive it from the (possibly public) resolved
            // resource origin, NOT a hardcoded 127.0.0.1:port. With
            // BRIDGE_PUBLIC_RESOURCE set this becomes
            // https://mcp.kup.solutions/.well-known/oauth-protected-resource;
            // unset, it falls back to the local origin (dev/stdio default).
            //
            // PKT-810 R5: BUT only advertise the PUBLIC cloud PRM when WorkOS is
            // actually live. With no provisioned tenant, pointing any client at
            // https://mcp.kup.solutions/.well-known/… would send it into a
            // WorkOS DCR that can only fail (placeholder client id) — so a stray
            // 401 must point at the LOCAL origin instead, never a non-existent
            // sign-in service. Loopback is never gated at all (SSETransport
            // origin split); this guards the off-loopback (tunnel) challenge.
            let prmURL: String = {
                if cloudOAuthLive,
                   let c = URLComponents(string: resource),
                   let scheme = c.scheme, let host = c.host {
                    let portPart = c.port.map { ":\($0)" } ?? ""
                    return "\(scheme)://\(host)\(portPart)/.well-known/oauth-protected-resource"
                }
                return "http://127.0.0.1:\(ssePort)/.well-known/oauth-protected-resource"
            }()
            return ConnectorAuthContext(
                validator: validator,
                resourceMetadataURL: prmURL
            )
        }()

        let sseServer = SSEServer(
            host: "127.0.0.1",
            port: ssePort,
            router: router,
            onToolCall: onToolCall,
            onClientConnected: onClientConnected,
            onClientDisconnected: onClientDisconnected,
            sessionTimeout: ConfigManager.shared.sessionTimeout,
            connectorAuth: connectorAuth
        )
        self.sseServer = sseServer

        // 2. Register modules — single source of truth in BridgeModuleRegistry
        // (consumed identically by EndToEndTests + ToolAnnotationAuditTests).
        // Production includes StripeMcpModule and supplies SessionModule's
        // live diagnosticsProvider; the registry owns module ordering.
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            registerSession: { sessionRouter in
                await SessionModule.register(
                    on: sessionRouter,
                    auditLog: auditLog,
                    diagnosticsProvider: {
                        let diagnostics = await sseServer.sessionRuntimeDiagnostics()
                        return SessionModule.RuntimeDiagnostics(
                            connections: diagnostics.activeClients,
                            activeClients: diagnostics.activeClients
                        )
                    }
                )
            }
        )
        // WS-D (PKT-921): Bridge Cloud Access — register the cloud-gated
        // `bridge_status` tool and start the health heartbeat ONLY when cloud
        // access is enabled. In every default (cloud-off) install this whole
        // block is skipped: no `bridge_status` tool, no heartbeat task, and the
        // static tool surface is byte-for-byte unchanged. WS-F added both the
        // `cloudAccessEnabled` key and the manager assembly seam.
        if BridgeDefaults.cloudAccessEnabledValue {
            let manager = Self.makeCloudManager()
            self.cloudManager = manager
            await BridgeModuleRegistry.registerCloudStatusTool(on: router, manager: manager)
            await startCloudHeartbeat(for: manager)
        }

        // Reconcile any jobs orphaned by a prior Bridge force-quit. Flips dead-pid running jobs to .unknown
        // and runs the 7-day cleanup pass for terminal jobs.
        _ = await BgProcessRuntime.shared.reconcileOrphans()

        // Sprint A · mcp-builder #8: builtin `echo` tool removed.
        // `session_info` covers connectivity-health checks; `echo` was a
        // duplicate signal that added noise to the tool list. Audit §3
        // marked this for silent removal — no deprecation alias needed.

        // 4. Build MCP Server — version from Bundle (single source of truth)
        let appVersion = AppVersion.resolved

        // PKT-9 v3.5 (now SSOT): the composed handshake payload (Standing
        // Orders + routing index) comes from StandingOrdersDelivery so this
        // path and the SSETransport legacy path serve byte-identical bytes
        // — the same composition that backs the bridge:// resources. The
        // best-effort store-read fallback lives inside the SSOT.
        let composition = StandingOrdersDelivery.composition()
        let composedInstructions = composition.instructionsMarkdown

        // W2 telemetry: record the handshake we composed + shipped on the
        // stdio path, identically to both SSE paths. stdio is a single
        // connection with no per-session id, so it rolls up under one stable
        // synthetic session id (`Self.stdioSessionID`).
        DeliveryLog.shared.recordHandshakeDelivered(
            sessionID: Self.stdioSessionID,
            clientName: "stdio",
            tokenCount: composition.tokenCount,
            contentHash: composition.contentHash
        )

        let server = Server(
            // PKT-1 v3.5: serverInfo.name announces the new brand to clients.
            // MCP spec treats this field as informational — clients should
            // not key off it for routing. Existing clients that displayed
            // "TheBridge" will now see "The Bridge".
            name: "The Bridge",
            version: appVersion,
            instructions: composedInstructions,
            // Advertise resources (subscribe + listChanged) alongside tools so
            // clients discover the bridge:// resource surface at handshake.
            capabilities: .init(
                resources: .init(subscribe: true, listChanged: true),
                tools: .init()
            )
        )
        self.server = server

        // 5. Wire ListTools handler — PKT-350: filter disabled tools
        let isCloudRequest = self.isCloudRequest
        let cloudManager = self.cloudManager
        await server.withMethodHandler(ListTools.self) { [router, toolAllowlist, isCloudRequest, cloudManager] _ in
            let disabledNames = CredentialsFeature.mergedDisabledToolNames()
            var registrations = await router.enabledRegistrations(disabledNames: disabledNames)

            if let allowlist = toolAllowlist {
                registrations = registrations.filter { allowlist.contains($0.name) }
            }

            // WS-D (PKT-921): on a CLOUD request, hide Mac tools when the cloud
            // channel is offline/disabled. A local stdio/SSE request (the
            // default — `isCloudRequest` resolves false) always sees the full
            // surface, so this is behaviour-preserving for existing clients.
            if await isCloudRequest() {
                let cloudState = await cloudManager?.state ?? .disabled
                registrations = Self.filterForCloud(registrations, cloudState: cloudState)
            }

            // v3.0·0.5: single source of truth — same factory as SSETransport.
            let tools = registrations.map { MCPToolFactory.tool(for: $0) }
            return .init(tools: tools)
        }

        // 6. Wire CallTool handler with tool-call notification (uses dispatchFormatted)
        await server.withMethodHandler(CallTool.self) { [router, toolAllowlist] params in
            if let allowlist = toolAllowlist, !allowlist.contains(params.name) {
                return .init(content: [.text(.init("Error: Tool '\(params.name)' is not allowed in this session"))], isError: true)
            }
            // Routing-stability telemetry (AUDIT ONLY — never gates dispatch):
            // record fetch_skill calls {skill name/path, intent} on the stdio
            // path under the stable synthetic stdio session id, identical to
            // how the SSE paths record them.
            if params.name == "fetch_skill" {
                let (skill, intent) = DeliveryLog.skillFetchFields(from: params.arguments.map { Value.object($0) })
                DeliveryLog.shared.recordSkillFetched(
                    sessionID: Self.stdioSessionID,
                    clientName: "stdio",
                    skill: skill,
                    intent: intent
                )
            }
            var arguments: Value = params.arguments.map { .object($0) } ?? .object([:])
            if params.name == "memory_remember" {
                arguments = MemoryModule.argumentsWithClientSource(arguments, clientName: "stdio")
            }
            if params.name.hasPrefix("memory_") {
                DeliveryLog.shared.recordMemoryToolCall(
                    sessionID: Self.stdioSessionID,
                    clientName: "stdio",
                    toolName: params.name
                )
            }
            let (text, isError) = await router.dispatchFormatted(toolName: params.name, arguments: arguments)
            if !isError { await MainActor.run { onToolCall() } }
            return .init(content: [.text(.init(text))], isError: isError)
        }

        // 6b. Wire MCP resource handlers (stdio path). The bytes come from the
        // SAME StandingOrdersDelivery SSOT the SSE transport serves, so both
        // paths resolve byte-identical resource content. stdio is a single
        // connection, so resources/subscribe + resources/unsubscribe are
        // accepted (Empty result) and `notifications/resources/updated` is
        // delivered directly over this connection via `server.notify`. The
        // per-session subscriber set lives on SSEServer (multi-session).
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: BridgeResources.list)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            let result = try await BridgeResources.read(uri: params.uri, clientName: nil)
            // W2 telemetry: record the resource read we served on the stdio
            // path + the composition hash at serve time, identical to the SSE
            // paths (under the stable synthetic stdio session id).
            DeliveryLog.shared.recordResourceRead(
                sessionID: Self.stdioSessionID,
                clientName: "stdio",
                uri: params.uri,
                contentHash: StandingOrdersDelivery.composition().contentHash
            )
            return result
        }
        await server.withMethodHandler(ResourceSubscribe.self) { _ in Empty() }
        await server.withMethodHandler(ResourceUnsubscribe.self) { _ in Empty() }

        // 7. SSE server was created before module registration so session diagnostics can be injected

        // PKT-381 (Scheduler Resilience): hand the live router to JobsManager so
        // its missed-occurrence reconciler can serially DRAIN the durable backlog
        // through the same ToolRouter the SSE job-callback uses. bootstrap(router:)
        // is idempotent — if AppDelegate already bootstrapped the store, this call
        // just supplies the router and triggers a reconcile+drain of anything that
        // was enqueued before the server was up. Detached so server startup is not
        // blocked by the (potentially long) catch-up drain.
        Task.detached { [router] in
            await JobsManager.shared.bootstrap(router: router)
        }

        return await router.allRegistrations().count
    }

    // MARK: - WS-D (PKT-921): Bridge Cloud Access — heartbeat + tools/list filter

    /// The set of tools a CLOUD caller may always see, regardless of channel
    /// health. `bridge_status` is the cloud-safe probe; everything else is a
    /// "Mac tool" hidden when the channel is offline/disabled.
    public static let cloudAlwaysVisibleTools: Set<String> = [CloudStatusModule.toolName]

    /// Pure, unit-testable tools/list conditional. For a CLOUD request:
    ///   • state ∈ {.offline, .disabled} → omit Mac tools (keep only
    ///     `cloudAlwaysVisibleTools`, e.g. `bridge_status`).
    ///   • state ∈ {.online, .degraded, .connecting} → full list.
    /// A non-cloud (local) request never calls this; it always gets the full
    /// list. Mirrors `CloudStatusPayload.macToolsAvailable`.
    public static func filterForCloud(
        _ registrations: [ToolRegistration],
        cloudState: CloudConnectionState
    ) -> [ToolRegistration] {
        guard CloudStatusPayload.macToolsAvailable(cloudState) else {
            return registrations.filter { cloudAlwaysVisibleTools.contains($0.name) }
        }
        return registrations
    }

    /// Assemble the production `BridgeCloudManager` over the WS-C seams. The
    /// real cloudflared / Secure-Enclave conformers land with the live Worker
    /// (PKT-810 / WS-A); until then the manager runs over the in-memory fakes
    /// so the state machine + heartbeat + `bridge_status` are all live without
    /// touching the network. Mirrors `RemoteAccessSection.defaultFlow()`.
    static func makeCloudManager() -> BridgeCloudManager {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let deviceID = host.isEmpty ? "this-mac" : host
        return BridgeCloudManager(
            tunnel: FakeTunnelProcess(),
            passkeyGate: FakePasskeyGate(outcome: .approved),
            node: LocalNodeContext(ownerID: "local", deviceID: deviceID)
        )
    }

    /// Start (or restart) the health heartbeat over `manager`. Idempotent: a
    /// prior loop is stopped first so a re-enable never leaves two timers.
    func startCloudHeartbeat(for manager: BridgeCloudManager) async {
        await cloudHeartbeat?.stop()
        let heartbeat = CloudHeartbeat(manager: manager)
        self.cloudHeartbeat = heartbeat
        await heartbeat.start()
    }

    /// Stop the heartbeat loop (cloud access disabled). Safe when not running.
    func stopCloudHeartbeat() async {
        await cloudHeartbeat?.stop()
        cloudHeartbeat = nil
    }

    /// React to a live `cloudAccessEnabled` toggle WITHOUT a relaunch.
    /// ON  → assemble the manager (if absent), enable the tunnel, register
    ///       `bridge_status`, and start the heartbeat.
    /// OFF → stop the heartbeat, deregister `bridge_status`, and disable the
    ///       manager. Mirrors the launch-time gate in `setup()`.
    public func setCloudAccessEnabled(_ enabled: Bool) async {
        guard let router = self.router else { return }
        if enabled {
            let manager = cloudManager ?? Self.makeCloudManager()
            self.cloudManager = manager
            _ = await manager.enable()
            await BridgeModuleRegistry.registerCloudStatusTool(on: router, manager: manager)
            await startCloudHeartbeat(for: manager)
        } else {
            await stopCloudHeartbeat()
            await router.deregister(name: CloudStatusModule.toolName)
            if let manager = cloudManager { _ = await manager.disable() }
        }
    }

    /// Current cloud connection state (`.disabled` when cloud access is off /
    /// no manager). Drives the `bridge_status` payload + the tools/list filter.
    public func cloudConnectionState() async -> CloudConnectionState {
        await cloudManager?.state ?? .disabled
    }

    /// Whether the heartbeat loop is currently scheduled (test/diagnostic).
    public func isCloudHeartbeatRunning() async -> Bool {
        await cloudHeartbeat?.isRunning ?? false
    }

    // MARK: - Tool Info (PKT-350: F2)

    /// Get all tool metadata for UI display.
    public func allToolInfo() async -> [ToolInfo] {
        guard let router = self.router else { return [] }
        return await router.allRegistrations().map { reg in
            ToolInfo(name: reg.name, module: reg.module, tier: reg.tier.rawValue, description: reg.description)
        }
    }

    // MARK: - Run

    /// Start the stdio transport. Blocks until the server stops or the task is cancelled.
    public func run() async throws {
        guard let server = self.server else {
            throw ServerManagerError.notSetUp
        }
        // WS-B (PKT-803): the stdio path now traverses TransportRouter.
        // `.stdio` is invariantly active in the default config, so this is
        // behaviour-preserving for existing clients; it is the seam WS-F
        // uses to bring streamableHTTP online.
        guard transportRouter.isActive(.stdio) else {
            throw ServerManagerError.transportInactive(.stdio)
        }
        let transport = StdioTransport()
        try await server.start(transport: transport)
    }

    /// Start the SSE transport. Blocks until the server stops or the task is cancelled.
    ///
    /// Behaviour-preserving: this hosts the legacy SSE path (`GET /sse` +
    /// `POST /messages`), `GET /health`, the job callback, and — already,
    /// since PKT-318/336 — the Streamable HTTP `/mcp` endpoint backed by
    /// `StatefulHTTPServerTransport`. It runs unconditionally exactly as
    /// before; the streamableHTTP *transport gate* is the separate
    /// `runStreamableHTTP()` seam below so the legacy SSE listener is
    /// untouched by `BRIDGE_ENABLE_HTTP`.
    public func runSSE() async throws {
        guard let sseServer = self.sseServer else {
            throw ServerManagerError.notSetUp
        }
        try await sseServer.start()
    }

    /// PKT-800 S1/S3 (corrected): the gated streamableHTTP seam, symmetric
    /// to `run()`'s stdio guard. `BridgeTransport.streamableHTTP` is
    /// inactive in the default config (stdio-only), so this throws unless
    /// `BRIDGE_ENABLE_HTTP=1` — keeping default behaviour byte-for-byte
    /// unchanged.
    ///
    /// IMPORTANT: the connector's `/mcp` endpoint is ALREADY served by the
    /// shared `runSSE()` listener (the single `SSEServer` NIO listener
    /// hosts `/mcp` via `StatefulHTTPServerTransport` since PKT-318/336).
    /// This entrypoint exists ONLY as the gated seam/guard and must NEVER
    /// bind a second listener: calling `sseServer.start()` here would
    /// double-`bind` the same `127.0.0.1:<ssePort>` already bound by
    /// `runSSE()` (second bind fails "address in use", silently swallowed).
    /// It therefore enforces the gate and returns a non-binding NO-OP. The
    /// invariant is exactly ONE listener bind ever; connector-auth gating
    /// is handled independently in `setup()` where `connectorAuth` is built
    /// iff `transportRouter.isActive(.streamableHTTP)`.
    public func runStreamableHTTP() async throws {
        guard self.sseServer != nil else {
            throw ServerManagerError.notSetUp
        }
        guard transportRouter.isActive(.streamableHTTP) else {
            throw ServerManagerError.transportInactive(.streamableHTTP)
        }
        // Gated NO-OP: `/mcp` is served by the shared `runSSE()` listener.
        // Do NOT call `sseServer.start()` — that would bind a second
        // listener on the SSE port. This seam only proves the gate.
    }

    /// Whether the streamableHTTP transport is active in this process
    /// (i.e. `BRIDGE_ENABLE_HTTP=1`). Pure read of the transport router;
    /// stdio is always active so this never affects the stdio invariant.
    public nonisolated var isStreamableHTTPActive: Bool {
        transportRouter.isActive(.streamableHTTP)
    }

    /// Request notification permission for the same SecurityGate used by ToolRouter.
    public func requestSecurityNotificationPermission() async {
        await securityGate?.requestNotificationPermission()
    }

    /// Stop the SSE server gracefully. ITEM [session]: this also writes the
    /// clean-shutdown marker + preserves the durable session snapshot for
    /// resume (see `SSEServer.stop()`).
    public func stopSSE() async {
        await sseServer?.stop()
    }

    /// Invalidate all active MCP sessions (e.g. after remote access config change).
    public func invalidateAllSessions(reason: String) async {
        await sseServer?.invalidateAllSessions(reason: reason)
    }
}

// MARK: - Errors

public enum ServerManagerError: Error, LocalizedError {
    case notSetUp
    case transportInactive(BridgeTransport)

    public var errorDescription: String? {
        switch self {
        case .notSetUp:
            return "ServerManager.setup() must be called before run()"
        case .transportInactive(let t):
            return "Transport '\(t.rawValue)' is not active in this configuration"
        }
    }
}
