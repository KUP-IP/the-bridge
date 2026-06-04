// StandingOrdersDelivery.swift — Single source of truth (SSOT) for the
// composed handshake payload AND the MCP resource bytes.
//
// Both delivery sites (the MCP Swift SDK `Server` in ServerManager and the
// hand-rolled JSON-RPC switch in SSETransport) called the SAME inline concat
// to build `initialize.instructions`:
//
//   composed = standing_orders_markdown + "\n\n---\n\n" + routing_index
//            (or routing_index alone when orders are empty / unreadable)
//
// That logic now lives here exactly once. `composition(clientName:)` returns:
//   • instructionsMarkdown   — byte-identical to the pre-SSOT handshake payload
//   • routingIndexMarkdown   — the routing index alone (the `bridge://routing-
//                              skills` resource body)
//   • tokenCount             — cheap chars/4 estimate
//   • contentHash            — SHA256 hex of instructionsMarkdown (resource
//                              change detection / determinism guard)
//
// The `clientName` parameter is a deliberate HOOK for future per-client
// overlays / memory injection (see StandingOrdersComposer.ClientOverlay). It
// is intentionally IGNORED for content today — overlays are not implemented
// here yet, and the default-empty-overlay thesis (one center across every
// system) holds. Resolving the connecting client now keeps the seam wired so
// the resource handlers can pass it through without re-plumbing.

import Foundation
import CryptoKit
import MCP

/// The MCP resource surface, shared by BOTH transports (the SDK `Server` in
/// ServerManager and the hand-rolled JSON-RPC switch in SSETransport) so the
/// `resources/list` entries and the `resources/read` bytes are a single
/// source of truth. The bytes themselves come from `StandingOrdersDelivery`.
public enum BridgeResources {

    /// Canonical resource URIs.
    public static let standingOrdersURI = "bridge://standing-orders"
    public static let routingSkillsURI = "bridge://routing-skills"

    /// The two advertised resources (typed, for the SDK ListResources handler).
    public static var list: [Resource] {
        [
            Resource(
                name: "Standing Orders",
                uri: standingOrdersURI,
                description: "The composed operating preamble (standing orders + routing index) delivered at handshake.",
                mimeType: "text/markdown"
            ),
            Resource(
                name: "Routing Skills",
                uri: routingSkillsURI,
                description: "The routing-skills index alone — what is routable via fetch_skill.",
                mimeType: "text/markdown"
            ),
        ]
    }

    /// Plain-dictionary projection of `list` for the legacy JSON-RPC switch
    /// (SSETransport builds raw `[String: Any]` payloads, not Codable types).
    public static var listAsDictionaries: [[String: Any]] {
        [
            [
                "uri": standingOrdersURI,
                "name": "Standing Orders",
                "description": "The composed operating preamble (standing orders + routing index) delivered at handshake.",
                "mimeType": "text/markdown",
            ],
            [
                "uri": routingSkillsURI,
                "name": "Routing Skills",
                "description": "The routing-skills index alone — what is routable via fetch_skill.",
                "mimeType": "text/markdown",
            ],
        ]
    }

    /// Process-wide broadcast hook for "a bridge:// resource changed". The
    /// live SSE transport installs this in `SSEServer.start()` so a write to
    /// the Standing Orders store can fan out `notifications/resources/updated`
    /// to subscribed sessions WITHOUT coupling the pure file store to the
    /// server actor. `nil` (no transport running, e.g. stdio-only or tests)
    /// makes the notify call a no-op. `nonisolated(unsafe)` + the lock mirror
    /// the `LegacySSEBridge` cross-thread pattern: installed once at startup,
    /// invoked from the store's write thread.
    nonisolated(unsafe) private static var resourcesUpdatedBroadcaster: (@Sendable (String) -> Void)?
    private static let broadcasterLock = NSLock()

    /// Install (or clear) the resources-updated broadcaster. Called by the
    /// SSE transport at startup.
    public static func setResourcesUpdatedBroadcaster(_ hook: (@Sendable (String) -> Void)?) {
        broadcasterLock.withLock { resourcesUpdatedBroadcaster = hook }
    }

    /// Fire the installed broadcaster for `uri`, if any. Safe no-op otherwise.
    public static func notifyResourceChanged(uri: String) {
        let hook = broadcasterLock.withLock { resourcesUpdatedBroadcaster }
        hook?(uri)
    }

    /// Resolve a resource URI to its markdown body. Both transports call this
    /// so the resolved bytes are identical. `clientName` is the future-overlay
    /// hook (currently ignored for content). Throws `MCPError.invalidParams`
    /// for an unknown URI.
    public static func markdown(for uri: String, clientName: String? = nil) throws -> String {
        let composition = StandingOrdersDelivery.composition(clientName: clientName)
        switch uri {
        case standingOrdersURI:
            return composition.instructionsMarkdown
        case routingSkillsURI:
            return composition.routingIndexMarkdown
        default:
            throw MCPError.invalidParams("Unknown resource URI: \(uri)")
        }
    }

    /// Typed `ReadResource.Result` for the SDK ReadResource handler.
    public static func read(uri: String, clientName: String? = nil) throws -> ReadResource.Result {
        let body = try markdown(for: uri, clientName: clientName)
        return .init(contents: [.text(body, uri: uri, mimeType: "text/markdown")])
    }
}

public enum StandingOrdersDelivery {

    /// The composed delivery payload, served identically by every transport.
    public struct Composition: Equatable, Sendable {
        /// The full handshake payload: standing orders + routing index.
        /// Byte-identical to what `initialize.instructions` sent pre-SSOT.
        public let instructionsMarkdown: String
        /// The routing index alone (the `bridge://routing-skills` resource).
        public let routingIndexMarkdown: String
        /// Cheap token estimate (chars / 4) over `instructionsMarkdown`.
        public let tokenCount: Int
        /// SHA256 hex of `instructionsMarkdown` — stable per identical content.
        public let contentHash: String

        public init(
            instructionsMarkdown: String,
            routingIndexMarkdown: String,
            tokenCount: Int,
            contentHash: String
        ) {
            self.instructionsMarkdown = instructionsMarkdown
            self.routingIndexMarkdown = routingIndexMarkdown
            self.tokenCount = tokenCount
            self.contentHash = contentHash
        }
    }

    /// Build the composition.
    ///
    /// `clientName` selects the per-client overlay (item 6): an optional
    /// operator-authored addendum, persisted by client name, that is
    /// appended to the composed instructions when that client connects.
    /// EMPTY BY DEFAULT — with no overlay set for the client (the default
    /// for every install), the composed bytes are byte-identical to the
    /// pre-overlay payload, so existing sessions see no change.
    ///
    /// Best-effort posture preserved from the prior inline compose: if the
    /// on-disk Standing Orders store is missing or unreadable, the payload
    /// falls back to the routing index alone so initialize still succeeds.
    public static func composition(clientName: String? = nil) -> Composition {
        let routingIndex = SkillsModule.buildRoutingInstructions()

        // PKT-9 v3.5 (now SSOT): prepend user-authored Standing Orders to the
        // routing index. Best-effort — a read failure degrades to routing-only,
        // exactly as the two inline composes did before this refactor.
        var instructions: String = {
            do {
                let snapshot = try StandingOrdersStore.shared.read()
                let orders = snapshot.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                if orders.isEmpty { return routingIndex }
                return orders + "\n\n---\n\n" + routingIndex
            } catch {
                return routingIndex
            }
        }()

        // Item 6: per-client overlay. Append the operator-authored addendum
        // for THIS client, if one is set. No-op (byte-identical) when the
        // client is nil or has no overlay — the default for every install.
        if let name = clientName,
           let overlay = ClientOverlayStore.shared.overlay(forClient: name)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !overlay.isEmpty {
            instructions += "\n\n---\n\n" + overlay
        }

        return Composition(
            instructionsMarkdown: instructions,
            routingIndexMarkdown: routingIndex,
            tokenCount: estimateTokens(instructions),
            contentHash: sha256Hex(instructions)
        )
    }

    // MARK: - Helpers

    /// Rough token approximation: ~4 chars/token. Mirrors
    /// `StandingOrdersStore.estimateTokens`; kept local so the SSOT has no
    /// hidden cross-type coupling for this trivial estimate.
    public static func estimateTokens(_ s: String) -> Int {
        max(0, s.count / 4)
    }

    /// SHA256 hex of the UTF-8 bytes. Same pattern as ArtifactModule's
    /// file_hash (`SHA256.hash(...).map { String(format: "%02x", $0) }`).
    /// Public so the determinism guard can recompute it independently.
    public static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ClientOverlayStore (item 6: per-client overlay hook)

/// A small persisted store of optional per-client Standing-Orders addenda.
/// Keyed by client name (the `clientInfo.name` from the MCP initialize
/// handshake), each value is markdown appended to the composed instructions
/// when that client connects. EMPTY BY DEFAULT — no overlay is set on a
/// fresh install, so `composition(clientName:)` is byte-identical to its
/// pre-overlay output until an operator sets one.
///
/// Storage: one JSON dict in `UserDefaults` under
/// `BridgeDefaults.standingOrdersClientOverlays`. Lookup + writes are
/// case-insensitive on the client name (normalized to lowercased+trimmed)
/// so "Claude Code" and "claude code" resolve to the same overlay.
///
/// `@unchecked Sendable`: the only state is the process-global
/// `UserDefaults.standard` (itself thread-safe); the type holds no mutable
/// stored properties of its own. Mirrors the `StandingOrdersStore`
/// `@unchecked Sendable` posture.
public final class ClientOverlayStore: @unchecked Sendable {
    public static let shared = ClientOverlayStore()

    private let defaultsKey = BridgeDefaults.standingOrdersClientOverlays
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Normalize a client name to its lookup key (trimmed + lowercased).
    private func key(_ clientName: String) -> String {
        clientName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Read the full overlay map (normalized keys → addendum markdown).
    private func readAll() -> [String: String] {
        guard let data = defaults.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private func writeAll(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The overlay addendum for `clientName`, or nil when none is set / the
    /// name is empty. Case-insensitive on the client name.
    public func overlay(forClient clientName: String) -> String? {
        let k = key(clientName)
        guard !k.isEmpty else { return nil }
        return readAll()[k]
    }

    /// Set (or, with nil/empty, clear) the overlay for `clientName`.
    /// Case-insensitive on the client name. A nil or whitespace-only
    /// `overlay` removes the entry so it reverts to the empty default.
    public func setOverlay(_ overlay: String?, forClient clientName: String) {
        let k = key(clientName)
        guard !k.isEmpty else { return }
        var map = readAll()
        if let overlay, !overlay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            map[k] = overlay
        } else {
            map.removeValue(forKey: k)
        }
        writeAll(map)
    }

    /// Test/diagnostic reset — clears every overlay.
    public func resetForTesting() {
        defaults.removeObject(forKey: defaultsKey)
    }
}
