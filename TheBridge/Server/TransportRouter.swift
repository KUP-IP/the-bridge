// TransportRouter.swift — WS-B (v2.3, PKT-803)
// TheBridge · Server
//
// Splits the MCP transport surface into named transports behind a single
// router. WS-B lands the router + the stdio path only; the streamableHTTP
// endpoint is NOT served live here (WS-F). Default config keeps only
// stdio active so existing Claude Desktop installs are untouched —
// `BRIDGE_ENABLE_HTTP=1` additively opts into the (still-skeleton)
// streamableHTTP transport for smoke validation.

import Foundation

/// The transports the MCP server can expose. Stable raw values — these
/// appear in smoke tests and (later) operator-facing config.
public enum BridgeTransport: String, Sendable, CaseIterable, Equatable {
    case stdio
    case streamableHTTP
}

/// Resolves which transports are active for this process. Pure value type
/// computed from the environment so it is deterministic under test.
public struct TransportRouter: Sendable, Equatable {

    /// Environment variable that additively enables the streamableHTTP
    /// transport. Any value other than "1" leaves it disabled.
    public static let httpEnableEnvKey = "BRIDGE_ENABLE_HTTP"

    private let httpEnabled: Bool

    /// - Parameter environment: process environment (injectable for tests).
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.httpEnabled = environment[Self.httpEnableEnvKey] == "1"
    }

    /// Active transports. Always includes `.stdio`; appends
    /// `.streamableHTTP` only when `BRIDGE_ENABLE_HTTP=1`. Order is
    /// stable: stdio first.
    public var activeTransports: [BridgeTransport] {
        httpEnabled ? [.stdio, .streamableHTTP] : [.stdio]
    }

    /// Whether `transport` is active in this configuration.
    public func isActive(_ transport: BridgeTransport) -> Bool {
        activeTransports.contains(transport)
    }
}
