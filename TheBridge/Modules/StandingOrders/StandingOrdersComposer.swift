// StandingOrdersComposer.swift — Builds the final `instructions` string
// that Bridge returns from MCP `InitializeResult`. PKT-9.
//
//   composed = standing_orders_markdown
//           + "\n\n---\n\n"
//           + routing_index_markdown
//           + optional client-specific overlay
//
// The composer is pure: pass it a snapshot + a skill list + a clientInfo
// and it returns the text. No I/O. Easy to test.

import Foundation

public struct ComposedInstructions: Equatable, Sendable {
    public let text: String
    public let estimatedTokens: Int
    public let clientName: String?

    public init(text: String, estimatedTokens: Int, clientName: String?) {
        self.text = text
        self.estimatedTokens = estimatedTokens
        self.clientName = clientName
    }
}

public enum StandingOrdersComposer {

    /// Per-client overlay. Bridge supports tailoring a short addendum
    /// based on the connecting client's name. Pass nil for the global
    /// default.
    ///
    /// PKT v3.6·8 design decision: the on-disk `orders.md` is authored
    /// as a **universal chief-of-staff preamble** that serves every
    /// MCP client equally well via the principle-first / Notion-impl-
    /// footnote dual-register pattern. Overlays are intentionally empty
    /// by default — the unified-preamble thesis is that one center
    /// across every system compounds operator alignment more than
    /// per-client tailoring would. This mechanism remains available
    /// as a future lever if any single client proves problematic
    /// (e.g. a host whose own system prompt collides hard with the
    /// universal preamble), but reaching for it should require a
    /// fresh design decision, not a default.
    public struct ClientOverlay: Equatable, Sendable {
        public let clientName: String   // e.g. "claude-code", "cursor", "chatgpt-dev-mode"
        public let addendum: String

        public init(clientName: String, addendum: String) {
            self.clientName = clientName
            self.addendum = addendum
        }
    }

    /// Compose the final instructions text.
    public static func compose(
        standingOrders: String,
        skills: [RoutingSkillSummary],
        connectingClient: String? = nil,
        overlays: [ClientOverlay] = []
    ) -> ComposedInstructions {
        var parts: [String] = []
        let trimmed = standingOrders.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }

        if let client = connectingClient,
           let overlay = matchOverlay(overlays, for: client) {
            parts.append("---\n\n## Client-specific notes (\(client))\n\n\(overlay.addendum.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // PKT v3.6·8: suppress auto-trailer when the standing-orders body
        // already carries a curated "Routing skills" section inline.
        // Prevents the double-render observed at handshake when on-disk
        // orders.md contains the section header itself.
        if !trimmed.contains("## Routing skills") {
            parts.append("---\n\n\(RoutingIndex.render(skills))")
        }

        let text = parts.joined(separator: "\n\n")
        return ComposedInstructions(
            text: text,
            estimatedTokens: StandingOrdersStore.estimateTokens(text),
            clientName: connectingClient
        )
    }

    /// Case-insensitive match. Supports prefix matches so "claude-code-2.1.0"
    /// resolves the "claude-code" overlay.
    private static func matchOverlay(
        _ overlays: [ClientOverlay],
        for client: String
    ) -> ClientOverlay? {
        let needle = client.lowercased()
        // Exact match wins; then prefix-of-needle (e.g. "claude-code" overlay
        // matches client "claude-code-2.1.0"); then needle-prefix-of-overlay.
        if let exact = overlays.first(where: { $0.clientName.lowercased() == needle }) {
            return exact
        }
        if let prefix = overlays.first(where: { needle.hasPrefix($0.clientName.lowercased()) }) {
            return prefix
        }
        return nil
    }
}
