// BridgeInitializeModule.swift — PKT-1065A
// TheBridge · Modules · StandingOrders
//
// The single canonical `bridge_initialize` MCP tool. One call runs the
// deterministic init-core (`BridgeInitializeService.run`) — locate + load the
// doctrine, verify the doctrine SHA-256, enforce required-source + integrity
// policy, inspect routing + supplemental orders + capability — and PERSIST a
// structured handshake receipt, emitting one distinct telemetry event.
//
// Tier `.open`: a pure read + local-evidence write (its own receipt file). It
// mutates no operator config and exposes no secrets; it only records what the
// bridge observed at handshake. Mirrors bridge_status / session_info posture.

import Foundation
import MCP

public enum BridgeInitializeModule {

    public static let moduleName = "standing_orders"
    public static let toolName = "bridge_initialize"

    /// Resolves the live runtime context (connection + capability + clock) for a
    /// handshake. Injectable so ServerManager can bind live cloud state and tests
    /// can pin a deterministic instant. The default is a direct-loopback posture:
    /// local channel, Mac tools available, app clock.
    public typealias ContextProvider = @Sendable (_ client: String?) async -> BridgeInitializeContext

    /// Default provider: local channel, Mac tools available, wall-clock now.
    public static let defaultContextProvider: ContextProvider = { client in
        BridgeInitializeContext(
            client: client,
            connectionState: "local",
            macToolsAvailable: true,
            bridgeState: "running",
            now: Date()
        )
    }

    public static func register(
        on router: ToolRouter,
        contextProvider: @escaping ContextProvider = defaultContextProvider
    ) async {
        await router.register(makeTool(contextProvider: contextProvider))
    }

    /// Factory for the `bridge_initialize` registration (exposed for tests).
    public static func makeTool(
        contextProvider: @escaping ContextProvider = defaultContextProvider
    ) -> ToolRegistration {
        ToolRegistration(
            name: toolName,
            module: moduleName,
            tier: .open,
            description: "Run the canonical Bridge initialization handshake: locate + load the "
                + "standing-orders doctrine (orders.md + manifest.json + metadata.json), verify the "
                + "doctrine SHA-256 (expected vs actual), enforce the required-source + integrity "
                + "policy, inspect the routing roster + supplemental orders + capability state, and "
                + "persist a structured, durable handshake receipt. Initialization state "
                + "(INCOMPLETE|DEGRADED|COMPLETE) is reported SEPARATELY from runtime capability "
                + "state. Returns the full receipt { handshakeId, finalState, integrityResult, "
                + "expectedHash, actualHash, routingRosterState, supplementalOrderCounts, "
                + "capabilityState, telemetryEventRef, … }. Each call is one distinct evidence event.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "client": .object([
                        "type": .string("string"),
                        "description": .string("Optional client name (e.g. the MCP clientInfo.name) to attribute this handshake to.")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Bridge Initialize",
                whenToUse: [
                    "At session start, to run the canonical handshake and get a durable receipt proving the doctrine loaded and its integrity.",
                    "To re-verify doctrine integrity + routing/capability state on demand."
                ],
                whenNotToUse: [
                    "Editing standing orders (use standing_orders_save).",
                    "Checking only cloud health (use bridge_status)."
                ],
                relatedTools: ["bridge_status", "session_info", "standing_orders_list"]
            ),
            handler: { arguments in
                let client: String? = {
                    if case .object(let a) = arguments, case .string(let s)? = a["client"] {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    return nil
                }()
                let context = await contextProvider(client)
                let receipt = await BridgeInitializeService.run(context: context)
                return receiptValue(receipt)
            }
        )
    }

    // MARK: - Serialization

    /// Serialize a `HandshakeReceipt` to the MCP `Value` result. All fields the
    /// packet enumerates are present; nil hashes serialize as JSON null-safe
    /// omission via `.string`-when-present.
    public static func receiptValue(_ r: HandshakeReceipt) -> Value {
        var d: [String: Value] = [
            "ok": .bool(true),
            "tool": .string(toolName),
            "handshakeId": .string(r.handshakeId),
            "schemaVersion": .int(r.schemaVersion),
            "timestamp": .string(ISO8601DateFormatter().string(from: r.timestamp)),
            "bridgeState": .string(r.bridgeState),
            "macToolsAvailable": .bool(r.macToolsAvailable),
            "doctrineVersion": .string(r.doctrineVersion),
            "integrityResult": .string(r.integrityResult),
            "routingRosterState": .string(r.routingRosterState),
            "routingWarnings": .array(r.routingWarnings.map { .string($0) }),
            "supplementalOrderCounts": .object([
                "found": .int(r.supplementalOrderCounts.found),
                "operative": .int(r.supplementalOrderCounts.operative),
                "ignored": .int(r.supplementalOrderCounts.ignored),
            ]),
            "connectionState": .string(r.connectionState),
            "telemetryEventRef": .string(r.telemetryEventRef),
            "capabilityState": .string(r.capabilityState.rawValue),
            "capabilityMatrix": .array(r.capabilityMatrix.map { entry in
                var e: [String: Value] = [
                    "capability": .string(entry.capability),
                    "available": .bool(entry.available),
                ]
                if let detail = entry.detail { e["detail"] = .string(detail) }
                return .object(e)
            }),
            "finalState": .string(r.finalState.rawValue),
        ]
        if let client = r.client { d["client"] = .string(client) }
        if let expected = r.expectedHash { d["expectedHash"] = .string(expected) }
        if let actual = r.actualHash { d["actualHash"] = .string(actual) }
        return .object(d)
    }
}
