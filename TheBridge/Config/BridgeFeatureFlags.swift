// BridgeFeatureFlags.swift — WS-C (v2.3, PKT-798)
// TheBridge · Config
//
// Single fail-closed source of truth for the not-yet-live capability
// gates surfaced in PermissionView. Both flags default OFF and only flip
// on an exact "1" — any other value (including "true", "0", unset) stays
// disabled. While a flag is off the app must never request the underlying
// macOS permission; the rows render an inert "feature disabled" state.
//
//   - BRIDGE_ENABLE_HTTP  → Network Listening (remote MCP, WS-F)
//   - BRIDGE_ENABLE_VOICE → Microphone        (Handy STT sidecar, WS-E)
//
// HTTP reuses TransportRouter.httpEnableEnvKey so the router and the
// permission UI cannot disagree about whether HTTP is enabled.

import Foundation

public struct BridgeFeatureFlags: Sendable, Equatable {

    /// Reused from the WS-B transport router — one key, one truth.
    public static let httpEnableEnvKey = TransportRouter.httpEnableEnvKey
    public static let voiceEnableEnvKey = "BRIDGE_ENABLE_VOICE"

    public let httpEnabled: Bool
    public let voiceEnabled: Bool

    /// - Parameter environment: process environment (injectable for tests).
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.httpEnabled = environment[Self.httpEnableEnvKey] == "1"
        self.voiceEnabled = environment[Self.voiceEnableEnvKey] == "1"
    }
}
