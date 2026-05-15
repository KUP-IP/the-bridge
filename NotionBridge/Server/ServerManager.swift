// ServerManager.swift — Unified MCP Server Lifecycle
// Notion Bridge v1: Manages server setup, module registration, and transport
// Created by PKT-317: Merge NotionBridge app + server into single binary
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
    private var server: Server?
    private var router: ToolRouter?
    private var sseServer: SSEServer?
    private var auditLog: AuditLog?
    private var securityGate: SecurityGate?
    private let toolAllowlist: Set<String>?

    /// WS-B (PKT-803): the active-transport router. Default config resolves
    /// to `[.stdio]` only, so existing clients are unaffected;
    /// `BRIDGE_ENABLE_HTTP=1` additively opts into streamableHTTP (skeleton
    /// only — not served live until WS-F).
    public nonisolated let transportRouter = TransportRouter()

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
    public init(
        onToolCall: @escaping @MainActor @Sendable () -> Void,
        onClientConnected: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in },
        onClientDisconnected: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        toolAllowlist: Set<String>? = nil
    ) {
        self.onToolCall = onToolCall
        self.onClientConnected = onClientConnected
        self.onClientDisconnected = onClientDisconnected
        self.toolAllowlist = toolAllowlist
        self.ssePort = ConfigManager.shared.ssePort
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
        let sseServer = SSEServer(
            host: "127.0.0.1",
            port: ssePort,
            router: router,
            onToolCall: onToolCall,
            onClientConnected: onClientConnected,
            onClientDisconnected: onClientDisconnected,
            sessionTimeout: ConfigManager.shared.sessionTimeout
        )
        self.sseServer = sseServer

        // 2. Register modules — single source of truth in BridgeModuleRegistry
        // (consumed identically by EndToEndTests + ToolAnnotationAuditTests).
        // Production includes StripeMcpModule and supplies SessionModule's
        // live diagnosticsProvider; the registry owns module ordering.
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            includeStripe: true,
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
        // Reconcile any jobs orphaned by a prior Bridge force-quit. Flips dead-pid running jobs to .unknown
        // and runs the 7-day cleanup pass for terminal jobs.
        _ = await BgProcessRuntime.shared.reconcileOrphans()

        // 3. Register echo tool (backward compatibility from V1-01)
        await router.register(ToolRegistration(
            name: "echo",
            module: "builtin",
            tier: .open,
            description: "Health-check tool — echoes the provided message back verbatim. Use to verify MCP connectivity.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("The message to echo back")
                    ])
                ]),
                "required": .array([.string("message")])
            ]),
            handler: { arguments in
                if case .object(let args) = arguments,
                   case .string(let message) = args["message"] {
                    return .object(["echo": .string(message)])
                }
                return .object(["error": .string("Missing 'message' parameter")])
            }
        ))

        // 4. Build MCP Server — version from Bundle (single source of truth)
        let appVersion = AppVersion.resolved
        let routingInstructions = SkillsModule.buildRoutingInstructions()
        let server = Server(
            name: "NotionBridge",
            version: appVersion,
            instructions: routingInstructions,
            capabilities: .init(tools: .init())
        )
        self.server = server

        // 5. Wire ListTools handler — PKT-350: filter disabled tools
        await server.withMethodHandler(ListTools.self) { [router, toolAllowlist] _ in
            let disabledNames = CredentialsFeature.mergedDisabledToolNames()
            var registrations = await router.enabledRegistrations(disabledNames: disabledNames)
            
            if let allowlist = toolAllowlist {
                registrations = registrations.filter { allowlist.contains($0.name) }
            }
            
            let tools = registrations.map { reg in
                Tool(
                    name: reg.name,
                    description: reg.description,
                    inputSchema: reg.inputSchema,
                    annotations: ToolAnnotationCatalog.resolved(for: reg.name).mcp
                )
            }
            return .init(tools: tools)
        }

        // 6. Wire CallTool handler with tool-call notification (uses dispatchFormatted)
        await server.withMethodHandler(CallTool.self) { [router, toolAllowlist] params in
            if let allowlist = toolAllowlist, !allowlist.contains(params.name) {
                return .init(content: [.text(.init("Error: Tool '\(params.name)' is not allowed in this session"))], isError: true)
            }
            let arguments: Value = params.arguments.map { .object($0) } ?? .object([:])
            let (text, isError) = await router.dispatchFormatted(toolName: params.name, arguments: arguments)
            if !isError { await MainActor.run { onToolCall() } }
            return .init(content: [.text(.init(text))], isError: isError)
        }

        // 7. SSE server was created before module registration so session diagnostics can be injected

        return await router.allRegistrations().count
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
    public func runSSE() async throws {
        guard let sseServer = self.sseServer else {
            throw ServerManagerError.notSetUp
        }
        try await sseServer.start()
    }

    /// Request notification permission for the same SecurityGate used by ToolRouter.
    public func requestSecurityNotificationPermission() async {
        await securityGate?.requestNotificationPermission()
    }

    /// Stop the SSE server gracefully.
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
