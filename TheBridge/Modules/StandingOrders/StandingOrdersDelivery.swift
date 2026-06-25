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
    public static let memoryURI = "bridge://memory"

    /// The advertised resources (typed, for the SDK ListResources handler).
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
            Resource(
                name: "Memory",
                uri: memoryURI,
                description: "Recent salient memories the agent has stored",
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
            [
                "uri": memoryURI,
                "name": "Memory",
                "description": "Recent salient memories the agent has stored",
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
    ///
    /// `async` because the `bridge://memory` branch reads the `MemoryStore`
    /// actor; the other URIs resolve synchronously (their `await`-free bodies
    /// add no suspension). Both transports' `resources/read` handlers already
    /// run in async contexts, so this routes through the single SSOT cleanly.
    public static func markdown(for uri: String, clientName: String? = nil) async throws -> String {
        switch uri {
        case standingOrdersURI:
            return StandingOrdersDelivery.composition(clientName: clientName).instructionsMarkdown
        case routingSkillsURI:
            return StandingOrdersDelivery.composition(clientName: clientName).routingIndexMarkdown
        case memoryURI:
            return await memoryMarkdown()
        default:
            throw MCPError.invalidParams("Unknown resource URI: \(uri)")
        }
    }

    /// Typed `ReadResource.Result` for the SDK ReadResource handler.
    public static func read(uri: String, clientName: String? = nil) async throws -> ReadResource.Result {
        let body = try await markdown(for: uri, clientName: clientName)
        return .init(contents: [.text(body, uri: uri, mimeType: "text/markdown")])
    }

    /// Render the lightweight READABLE memory slice for `bridge://memory`.
    ///
    /// Reads `MemoryStore.shared.handshakeSlice(limit: 20)` (pinned + top-
    /// salience, NON-promoting — a passive surface read must not perturb recall
    /// counters) and renders it via `StandingOrdersDelivery.renderMemoryMarkdown`.
    /// Best-effort: a store read failure degrades to the empty-state line so
    /// `resources/read` still succeeds, mirroring the composition's degrade-to-
    /// routing-index posture.
    public static func memoryMarkdown() async -> String {
        let entries: [MemoryEntry]
        do {
            entries = try await MemoryStore.shared.handshakeSlice(limit: 20)
        } catch {
            entries = []
        }
        return StandingOrdersDelivery.renderMemoryMarkdown(entries)
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

        // Note: memory auto-inject (Q1) is wired in `asyncComposition(clientName:)`.
        // The sync path stays byte-deterministic and is used by the legacy SSE path
        // and by callers that cannot await. Auto-inject consumers call the async variant.

        return Composition(
            instructionsMarkdown: instructions,
            routingIndexMarkdown: routingIndex,
            tokenCount: estimateTokens(instructions),
            contentHash: sha256Hex(instructions)
        )
    }

    /// PKT-977 Wave 2 (Q1): async variant that optionally appends the salient
    /// memory slice to `instructions` when the operator has enabled auto-inject.
    ///
    /// Decision Q1: opt-in, default OFF. The global flag
    /// (`BridgeDefaults.memoryHandshakeAutoInjectEffective`) gates the feature;
    /// the per-client flag (`BridgeDefaults.memoryAutoInjectClientOverride`) can
    /// force it on/off for a specific client name, overriding the global.
    ///
    /// Token cap: `memoryHandshakeTokenBudget` tokens (chars/4 estimate). The
    /// memory slice is truncated by the `handshakeSlice(limit:)` salience order —
    /// highest-salience entries are included first; the rest are dropped when the
    /// cap would be exceeded.
    ///
    /// Best-effort: a store read failure logs and omits the slice (degrades
    /// gracefully — the base composition is still delivered).
    public static func asyncComposition(clientName: String? = nil) async -> Composition {
        let base = composition(clientName: clientName)

        // Resolve auto-inject flag: per-client override wins over global.
        let shouldInject: Bool = {
            if let name = clientName,
               let override = MemoryAutoInjectClientStore.shared.override(forClient: name) {
                return override
            }
            return BridgeDefaults.memoryHandshakeAutoInjectEffective
        }()

        guard shouldInject else { return base }

        // Append the memory slice, token-capped.
        let memorySlice = await buildTokenCappedMemorySlice(
            budget: Self.memoryHandshakeTokenBudget
        )
        guard !memorySlice.isEmpty, memorySlice != "No memories stored yet." else { return base }

        let injected = base.instructionsMarkdown + "\n\n---\n\n## Memory\n\n" + memorySlice
        return Composition(
            instructionsMarkdown: injected,
            routingIndexMarkdown: base.routingIndexMarkdown,
            tokenCount: estimateTokens(injected),
            contentHash: sha256Hex(injected)
        )
    }

    /// Token budget for the injected memory slice (chars / 4). ~500 tokens.
    public static let memoryHandshakeTokenBudget = 2_000   // chars → ~500 tokens

    /// Build the memory markdown capped to `budget` chars. Reads
    /// `handshakeSlice` and renders via `renderMemoryMarkdown`, then truncates
    /// to fit. Best-effort: returns empty string on any store failure.
    private static func buildTokenCappedMemorySlice(budget: Int) async -> String {
        do {
            let entries = try await MemoryStore.shared.handshakeSlice(limit: 20)
            let full = renderMemoryMarkdown(entries)
            if full.count <= budget { return full }
            // Truncate at the last newline boundary within budget.
            let prefix = String(full.prefix(budget))
            if let lastNewline = prefix.lastIndex(of: "\n") {
                return String(prefix[prefix.startIndex..<lastNewline]) + "\n…(truncated)"
            }
            return String(prefix) + "…"
        } catch {
            return ""
        }
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

    // MARK: - Memory slice rendering (bridge://memory body)

    /// Render the `bridge://memory` body from a memory slice. PURE (no actor /
    /// I/O) so it is unit-testable against sample entries — `BridgeResources`
    /// owns the actor read and hands the rows here.
    ///
    /// Shape: entries grouped by `## <scope>` (pinned entries lead, then the
    /// input order — `handshakeSlice` already sorts pinned-first then by
    /// salience). Each row is `- [<type>] <text> · <entity?> · used N×`, with
    /// the `· <entity>` segment omitted when there is no entity and the
    /// `· used N×` segment omitted when useCount is 0. An empty slice renders a
    /// single one-line notice.
    public static func renderMemoryMarkdown(_ entries: [MemoryEntry]) -> String {
        guard !entries.isEmpty else { return "No memories stored yet." }

        // Stable scope ordering = first appearance in the (already-ranked)
        // slice, so the highest-salience scope leads. Pinned-first is preserved
        // because handshakeSlice emits pinned rows ahead of the rest.
        var scopeOrder: [String] = []
        var byScope: [String: [MemoryEntry]] = [:]
        for e in entries {
            if byScope[e.scope] == nil { scopeOrder.append(e.scope) }
            byScope[e.scope, default: []].append(e)
        }

        var sections: [String] = []
        for scope in scopeOrder {
            var lines = ["## \(scope)"]
            for e in byScope[scope] ?? [] {
                var row = "- [\(e.type.rawValue)] \(e.text)"
                if let entity = e.entity?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !entity.isEmpty {
                    row += " · \(entity)"
                }
                if e.useCount > 0 {
                    row += " · used \(e.useCount)×"
                }
                lines.append(row)
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
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

    /// The full overlay map (normalized client-name keys → addendum markdown).
    /// EMPTY DICT on a fresh install. Public surface over the private
    /// `readAll()` so callers that need to resolve per-client live composition
    /// hashes (the delivery-audit freshness path) — and a future overlays
    /// card — can enumerate the set without re-plumbing storage.
    public func allOverlays() -> [String: String] {
        readAll()
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

// MARK: - MemoryAutoInjectClientStore (PKT-977 Wave 2 · Q1)

/// Per-client memory auto-inject overrides. Each entry overrides the global
/// `BridgeDefaults.memoryHandshakeAutoInject` flag for a specific client.
/// When no per-client entry is set (the default), the global flag governs.
///
/// Storage: one JSON dict in `UserDefaults` under
/// `BridgeDefaults.memoryAutoInjectClientOverrides`. Lookup is
/// case-insensitive on the client name (normalized to lowercased+trimmed).
///
/// `@unchecked Sendable`: the only state is the process-global
/// `UserDefaults.standard` (itself thread-safe). Mirrors `ClientOverlayStore`.
public final class MemoryAutoInjectClientStore: @unchecked Sendable {
    public static let shared = MemoryAutoInjectClientStore()

    private let defaultsKey = BridgeDefaults.memoryAutoInjectClientOverrides
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func normalizedKey(_ clientName: String) -> String {
        clientName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func readAll() -> [String: Bool] {
        guard let data = defaults.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return map
    }

    private func writeAll(_ map: [String: Bool]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The per-client override for `clientName`, or nil when none is set.
    /// nil means "use the global flag". Case-insensitive on the client name.
    public func override(forClient clientName: String) -> Bool? {
        let k = normalizedKey(clientName)
        guard !k.isEmpty else { return nil }
        return readAll()[k]
    }

    /// All overrides. EMPTY DICT on a fresh install.
    public func allOverrides() -> [String: Bool] {
        readAll()
    }

    /// Set (or, with nil, clear) the override for `clientName`.
    /// A nil value removes the entry so the global flag governs again.
    public func setOverride(_ override: Bool?, forClient clientName: String) {
        let k = normalizedKey(clientName)
        guard !k.isEmpty else { return }
        var map = readAll()
        if let override {
            map[k] = override
        } else {
            map.removeValue(forKey: k)
        }
        writeAll(map)
    }

    /// Test/diagnostic reset — clears all per-client overrides.
    public func resetForTesting() {
        defaults.removeObject(forKey: defaultsKey)
    }
}
