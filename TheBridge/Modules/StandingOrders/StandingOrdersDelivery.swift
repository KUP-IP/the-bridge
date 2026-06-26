// StandingOrdersDelivery.swift — Single source of truth (SSOT) for the
// composed handshake payload AND the MCP resource bytes.
//
// Both delivery sites (the MCP Swift SDK `Server` in ServerManager and the
// hand-rolled JSON-RPC switch in SSETransport) called the SAME inline concat
// to build `initialize.instructions`:
//
//   composed = standing_orders_markdown + routing_index + initialization_receipt
//
// That logic now lives here exactly once. `composition(clientName:)` returns:
//   • instructionsMarkdown   — doctrine + routing + evidence-backed receipt
//   • routingIndexMarkdown   — the routing index alone (the `bridge://routing-
//                              skills` resource body)
//   • initializationReceipt  — COMPLETE / DEGRADED / INCOMPLETE source evidence
//   • tokenCount             — cheap chars/4 estimate
//   • contentHash            — SHA256 hex of instructionsMarkdown (resource
//                              change detection / determinism guard)
//
// `clientName` selects an optional per-client overlay. The overlay remains the
// final client-specific instruction layer; the initialization receipt is always
// present before it.

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
    /// `resources/read` still succeeds. Standing-orders initialization failures
    /// use the separate explicit receipt contract above.
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

    public struct InitializationReceipt: Equatable, Sendable {
        public let bridgeState: String
        public let doctrineVersion: String
        public let routingRosterState: String
        public let supplementalOrderCount: Int
        public let initializationState: StandingOrdersStore.InitializationState
        public let issues: [String]

        public var markdown: String {
            var lines = [
                "## Bridge initialization receipt",
                "",
                "- Bridge state: \(bridgeState)",
                "- Doctrine version: \(doctrineVersion)",
                "- Routing roster: \(routingRosterState)",
                "- Supplemental orders: \(supplementalOrderCount)",
                "- Initialization: \(initializationState.rawValue)",
            ]
            if !issues.isEmpty {
                lines.append("")
                lines.append("### Initialization issues")
                lines.append(contentsOf: issues.map { "- \($0)" })
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The composed delivery payload, served identically by every transport.
    public struct Composition: Equatable, Sendable {
        /// The full handshake payload: standing orders + routing index + receipt.
        public let instructionsMarkdown: String
        /// The routing index alone (the `bridge://routing-skills` resource).
        public let routingIndexMarkdown: String
        /// Evidence-backed initialization result included in the handshake.
        public let initializationReceipt: InitializationReceipt
        /// Cheap token estimate (chars / 4) over `instructionsMarkdown`.
        public let tokenCount: Int
        /// SHA256 hex of `instructionsMarkdown` — stable per identical content.
        public let contentHash: String

        public init(
            instructionsMarkdown: String,
            routingIndexMarkdown: String,
            initializationReceipt: InitializationReceipt,
            tokenCount: Int,
            contentHash: String
        ) {
            self.instructionsMarkdown = instructionsMarkdown
            self.routingIndexMarkdown = routingIndexMarkdown
            self.initializationReceipt = initializationReceipt
            self.tokenCount = tokenCount
            self.contentHash = contentHash
        }
    }

    /// Build the composition and attach an evidence-backed initialization
    /// receipt. Missing required doctrine never silently becomes “no standing
    /// orders”: the handshake remains available, but reports INCOMPLETE or
    /// DEGRADED with the exact failed assertion.
    public static func composition(clientName: String? = nil) -> Composition {
        let routingIndex = SkillsModule.buildRoutingInstructions()

        // Migrate legacy installations by creating only missing integrity files.
        // Existing mismatches are never overwritten; the report below surfaces them.
        try? StandingOrdersStore.shared.ensureInitializationContract()
        let report = StandingOrdersStore.shared.initializationReport()
        let supplemental = StandingOrdersRecordStore.inspectOnDisk()

        var issues = report.issues
        var finalState = report.state
        let routingRosterLoaded = !routingIndex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !routingRosterLoaded {
            issues.append("Required routing roster is empty.")
            finalState = .incomplete
        }
        if !supplemental.loaded {
            if let issue = supplemental.issue { issues.append(issue) }
            if finalState == .complete { finalState = .degraded }
        }

        let receipt = InitializationReceipt(
            bridgeState: "running",
            doctrineVersion: report.doctrineVersion,
            routingRosterState: routingRosterLoaded ? "loaded" : "missing",
            supplementalOrderCount: supplemental.activeCount,
            initializationState: finalState,
            issues: issues
        )

        var instructions: String = {
            guard report.doctrineLoaded,
                  let snapshot = try? StandingOrdersStore.shared.read() else {
                return routingIndex
            }
            let orders = snapshot.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !orders.isEmpty else { return routingIndex }
            return orders + "\n\n---\n\n" + routingIndex
        }()

        // The receipt is always present, including valid zero supplemental orders.
        instructions += "\n\n---\n\n" + receipt.markdown

        // Item 6: per-client overlay. Append the operator-authored addendum
        // for THIS client, if one is set. It remains the final client-specific
        // instruction layer after the initialization evidence.
        if let name = clientName,
           let overlay = ClientOverlayStore.shared.overlay(forClient: name)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !overlay.isEmpty {
            instructions += "\n\n---\n\n" + overlay
        }

        // Note: memory auto-inject (Q1) is wired in `asyncComposition(clientName:)`.
        // The sync path stays byte-deterministic and is used by resource callers.
        return Composition(
            instructionsMarkdown: instructions,
            routingIndexMarkdown: routingIndex,
            initializationReceipt: receipt,
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
            initializationReceipt: base.initializationReceipt,
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
        MemoryRowFormatter.markdown(entries)
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

    /// PKT-MEM-115 Wave 3: seed Cursor ON when the override map is empty and
    /// global inject is OFF. Idempotent — does not overwrite operator edits.
    public static func seedWave3DefaultsIfNeeded() {
        let store = shared
        guard store.allOverrides().isEmpty,
              !BridgeDefaults.memoryHandshakeAutoInjectEffective else { return }
        store.setOverride(true, forClient: "cursor")
    }
}
