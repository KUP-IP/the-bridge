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

    /// config.json key for the durable enable-HTTP flag (Packet E W2). String
    /// "1" / "true" (case-insensitive) enables; anything else is off.
    public static let httpEnableConfigKey = "enableHTTP"

    private let httpEnabled: Bool

    /// Resolves the enable-HTTP flag with a durable precedence (Packet E W2,
    /// mirroring `ProtectedResourceMetadataProvider.resolvedIssuer`):
    /// `BRIDGE_ENABLE_HTTP` env override → config.json (`enableHTTP`,
    /// per-install) → fail-closed default (off, so existing stdio installs
    /// stay untouched). No build-baked layer: HTTP-on is a per-install
    /// operator choice, not a binary constant. `config` is injectable so this
    /// stays pure under test (no ConfigManager singleton dependency).
    ///
    /// - Parameters:
    ///   - environment: process environment (injectable for tests).
    ///   - config: config.json reader seam (injectable for tests).
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: (String) -> String? = { ConfigManager.shared.value(forKey: $0) as? String }
    ) {
        if let env = environment[Self.httpEnableEnvKey], !env.isEmpty {
            // Env present (any value) is authoritative — preserves the exact
            // prior contract: only "1" enables, every other explicit value
            // (e.g. "0", "true") leaves it off.
            self.httpEnabled = env == "1"
        } else if let cfg = config(Self.httpEnableConfigKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !cfg.isEmpty {
            self.httpEnabled = cfg == "1" || cfg.caseInsensitiveCompare("true") == .orderedSame
        } else {
            self.httpEnabled = false
        }
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
