// DeliveryLog.swift — Standing-Orders delivery telemetry (truthful audit).
//
// W2: records what the server actually DID for each connected MCP session —
// the handshake `initialize.instructions` we composed (token count + content
// hash), every `bridge://` resource read we served (with the composition hash
// at serve time), and (audit-only) reminders_* tool calls. The Standing Orders
// settings page renders a "Delivery audit · active sessions" card off this so
// the UI shows DELIVERED + FETCHED + freshness — never "Honored", because the
// server cannot observe whether a client actually obeyed the orders. We only
// know what we shipped and what was read back; the card states exactly that.
//
// CONCURRENCY — the cross-thread ingest pattern.
// The two transports record from OFF the main actor: SSEServer is an `actor`
// (its handlers run on the cooperative pool) and the legacy NIO RPC switch runs
// on an event-loop thread. `DeliveryLog` itself is `@MainActor @Observable` so
// SwiftUI can observe it directly. To bridge those domains WITHOUT a concurrency
// violation, the recording API is a set of `nonisolated` `record*` funcs that
// each build a `Sendable` event value and hop to the main actor via an unawaited
// `Task { @MainActor in ... }`. This mirrors the W1 `BridgeResources`
// cross-thread broadcaster (`Task { await self?.broadcastResourcesUpdated(...) }`)
// and the `LegacySSEBridge` "installed once, invoked from another thread"
// posture — the caller never blocks and never crosses an isolation boundary
// with a non-Sendable value.

import Foundation
import Observation
import MCP  // `Value` — used by skillFetchFields to parse fetch_skill arguments

/// What a recorded delivery event represents.
public enum DeliveryEventKind: String, Sendable, Equatable, CaseIterable {
    /// The composed `initialize.instructions` payload we shipped at handshake.
    case handshakeDelivered
    /// A `bridge://` resource read we served (`resources/read`).
    case resourceRead
    /// A `reminders_*` tool call (audit-only — never influences anything).
    case reminderToolCall
    /// A `fetch_skill` call (audit-only routing-stability signal). Records
    /// the skill name/path that was fetched and the intent (when supplied)
    /// so the routing surface can be audited for drift / mis-routes.
    case skillFetched
    /// A `memory_*` tool call (audit-only — memories surfaced telemetry).
    case memoryToolCall
}

/// One immutable telemetry event. `Sendable` so it can be built off-main and
/// handed to the main actor in the ingest hop.
public struct DeliveryEvent: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: String
    public let clientName: String?
    public let kind: DeliveryEventKind
    /// Present for `resourceRead` (the URI served) and `reminderToolCall`
    /// (the tool name). nil for `handshakeDelivered`.
    public let uri: String?
    /// Present for `handshakeDelivered` (composed instructions token count).
    public let tokenCount: Int?
    /// The composition content hash at the time of the event — set for
    /// `handshakeDelivered` (what we shipped) and `resourceRead` (what we
    /// served). nil for `reminderToolCall`.
    public let contentHash: String?
    /// Present for `skillFetched` (the natural-language intent passed to
    /// `fetch_skill`, when one was supplied). nil for every other kind and
    /// for an intent-less skill fetch.
    public let intent: String?
    public let at: Date

    public init(
        id: UUID = UUID(),
        sessionID: String,
        clientName: String?,
        kind: DeliveryEventKind,
        uri: String? = nil,
        tokenCount: Int? = nil,
        contentHash: String? = nil,
        intent: String? = nil,
        at: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.clientName = clientName
        self.kind = kind
        self.uri = uri
        self.tokenCount = tokenCount
        self.contentHash = contentHash
        self.intent = intent
        self.at = at
    }
}

/// A per-session rollup the "Delivery audit" card renders as one row.
public struct SessionAudit: Sendable, Equatable, Identifiable {
    public var id: String { sessionID }
    public let sessionID: String
    public let clientName: String?
    /// The handshake we delivered (tokens + when). nil if we somehow have a
    /// session with no recorded handshake (defensive — the card just omits it).
    public let deliveredTokens: Int?
    public let deliveredAt: Date?
    /// The most recent resource read we served for this session, if any.
    public let lastResourceReadAt: Date?
    /// The composition hash on the LAST resource read this session made.
    public let lastReadHash: String?
    /// Truthful freshness: the last read served the CURRENT composition hash.
    /// `nil` when there has been no read yet (so the card shows nothing rather
    /// than implying staleness). Computed against the live composition hash.
    public let isFresh: Bool?

    public init(
        sessionID: String,
        clientName: String?,
        deliveredTokens: Int?,
        deliveredAt: Date?,
        lastResourceReadAt: Date?,
        lastReadHash: String?,
        isFresh: Bool?
    ) {
        self.sessionID = sessionID
        self.clientName = clientName
        self.deliveredTokens = deliveredTokens
        self.deliveredAt = deliveredAt
        self.lastResourceReadAt = lastResourceReadAt
        self.lastReadHash = lastReadHash
        self.isFresh = isFresh
    }
}

/// Pure, view-free derivation of the TRUTHFUL labels the "Delivery audit" card
/// renders for one session row. Factored out of the SwiftUI view so the
/// honesty invariants are unit-testable WITHOUT a render: the server can only
/// state what it shipped (DELIVERED) and what was read back (FETCHED) — it can
/// NEVER claim a client "Honored" the orders, because it cannot observe
/// obedience. These rules pin that contract:
///   • `deliveredLabel` is present iff a handshake was recorded (tokens + when).
///   • `fetchedLabel` is present iff a real resource read occurred — the
///     ABSENCE of a read is NEVER rendered as "not honored" / "not fetched".
///   • Neither label ever contains the word "Honored".
public enum DeliveryAuditLabels {

    /// The "Delivered · N tok" segment, or nil when no handshake was recorded.
    /// (The relative-time suffix stays in the view — it is clock-dependent and
    /// not part of the truthful-label contract.)
    public static func deliveredLabel(for row: SessionAudit) -> String? {
        guard let tokens = row.deliveredTokens, row.deliveredAt != nil else { return nil }
        return "Delivered · \(tokens) tok"
    }

    /// The "Fetched ✓" segment, or nil when NO read has happened. Truthful:
    /// only a recorded read produces this; absence renders nothing (it is NOT
    /// "not honored"). Never the word "Honored".
    public static func fetchedLabel(for row: SessionAudit) -> String? {
        row.lastResourceReadAt == nil ? nil : "Fetched ✓"
    }
}

/// `@MainActor @Observable` singleton holding recent delivery telemetry keyed
/// by sessionID. Bounded: per-session the LATEST event of each kind is kept
/// (so a session's audit row is O(1)), plus a small capped recent-history ring
/// for the debug timeline. Off-main transport code records via the
/// `nonisolated record*` funcs, which hop to the main actor.
@MainActor
@Observable
public final class DeliveryLog {

    /// `nonisolated(unsafe)` so the off-main transports (the `SSEServer` actor,
    /// the NIO event-loop RPC switch, the stdio handler) can reference the
    /// singleton to call the `nonisolated record*` funcs WITHOUT crossing into
    /// the main actor at the call site. The reference itself is immutable and
    /// the instance is fully `@MainActor`-isolated — every mutation happens on
    /// the main actor inside `ingest` (reached via the record* hop), so the
    /// `unsafe` is sound: nothing reads or writes the actor-isolated state from
    /// off-main. Mirrors the `nonisolated(unsafe)` posture of the W1
    /// `BridgeResources` broadcaster + the `LegacySSEBridge` references.
    nonisolated(unsafe) public static let shared = DeliveryLog()

    /// Cap on the recent-history ring (the debug timeline). Oldest evicted.
    public static let historyCap = 200

    /// Latest event per (sessionID, kind). Drives the per-session audit rows
    /// without unbounded growth.
    private var latest: [String: [DeliveryEventKind: DeliveryEvent]] = [:]

    /// Bounded recent-history ring (newest last). Drives the debug timeline.
    private var history: [DeliveryEvent] = []

    /// Insertion order of session ids (first handshake wins ordering) so the
    /// card renders sessions stably rather than dictionary-random.
    private var sessionOrder: [String] = []

    /// Resolves the CLIENT-APPROPRIATE current composition hash for freshness
    /// comparison. Injected so tests are hermetic; production reads the live
    /// SSOT for the given client name.
    ///
    /// BUG FIX (overlay freshness): a read records the CLIENT-specific
    /// composition hash (`composition(clientName:).contentHash` — see
    /// SSETransport `recordResourceRead`), so freshness MUST be computed against
    /// that same per-client live hash. Passing the session's client name here
    /// makes a client with a `ClientOverlayStore` overlay compare its read
    /// against ITS OWN live composition — not the overlay-less default — so it
    /// is no longer permanently amber/stale. With no overlay set (the default
    /// for every install) `composition(clientName:)` is byte-identical to
    /// `composition()`, so the no-overlay path is unchanged.
    private let currentHash: @Sendable (_ clientName: String?) -> String

    nonisolated public init(currentHash: @escaping @Sendable (_ clientName: String?) -> String = { clientName in
        StandingOrdersDelivery.composition(clientName: clientName).contentHash
    }) {
        self.currentHash = currentHash
    }

    // MARK: - Ingest (main-actor; off-main callers use the nonisolated hops)

    /// Record an event on the main actor. Updates the per-(session,kind) latest
    /// map and appends to the bounded history ring.
    public func ingest(_ event: DeliveryEvent) {
        if latest[event.sessionID] == nil {
            latest[event.sessionID] = [:]
            sessionOrder.append(event.sessionID)
        }
        latest[event.sessionID]?[event.kind] = event

        history.append(event)
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
    }

    /// Drop every event for a torn-down session (called from `removeSession`).
    public func prune(sessionID: String) {
        latest[sessionID] = nil
        sessionOrder.removeAll { $0 == sessionID }
        history.removeAll { $0.sessionID == sessionID }
    }

    /// Test/diagnostic reset.
    public func resetForTesting() {
        latest = [:]
        history = []
        sessionOrder = []
    }

    // MARK: - Cross-thread record API (nonisolated → main-actor hop)
    //
    // Mirrors the W1 BridgeResources broadcaster pattern: build a Sendable
    // value off-main, then `Task { @MainActor in ingest(...) }`. The caller
    // (SSEServer actor / NIO event loop / stdio handler) never blocks and never
    // hands a non-Sendable value across an isolation boundary.

    /// Record the handshake `initialize.instructions` we composed + shipped.
    public nonisolated func recordHandshakeDelivered(
        sessionID: String,
        clientName: String?,
        tokenCount: Int,
        contentHash: String,
        at: Date = Date()
    ) {
        let event = DeliveryEvent(
            sessionID: sessionID,
            clientName: clientName,
            kind: .handshakeDelivered,
            tokenCount: tokenCount,
            contentHash: contentHash,
            at: at
        )
        Task { @MainActor in DeliveryLog.shared.ingest(event) }
    }

    /// Record a `bridge://` resource read we served, with the composition hash
    /// at serve time so freshness can be computed against the live hash later.
    public nonisolated func recordResourceRead(
        sessionID: String,
        clientName: String?,
        uri: String,
        contentHash: String,
        at: Date = Date()
    ) {
        let event = DeliveryEvent(
            sessionID: sessionID,
            clientName: clientName,
            kind: .resourceRead,
            uri: uri,
            contentHash: contentHash,
            at: at
        )
        Task { @MainActor in DeliveryLog.shared.ingest(event) }
    }

    /// Record a `reminders_*` tool call. AUDIT ONLY — never gates or alters
    /// dispatch; this is pure observability.
    public nonisolated func recordReminderToolCall(
        sessionID: String,
        clientName: String?,
        toolName: String,
        at: Date = Date()
    ) {
        let event = DeliveryEvent(
            sessionID: sessionID,
            clientName: clientName,
            kind: .reminderToolCall,
            uri: toolName,
            at: at
        )
        Task { @MainActor in DeliveryLog.shared.ingest(event) }
    }

    /// Record a `fetch_skill` call. AUDIT ONLY — a routing-stability signal,
    /// never gates or alters dispatch. `skill` is the requested name/path
    /// (e.g. "project-keepr" or "project-keepr/update"); `intent` is the
    /// natural-language intent when one was supplied (nil otherwise).
    public nonisolated func recordSkillFetched(
        sessionID: String,
        clientName: String?,
        skill: String,
        intent: String?,
        at: Date = Date()
    ) {
        let event = DeliveryEvent(
            sessionID: sessionID,
            clientName: clientName,
            kind: .skillFetched,
            uri: skill,
            intent: intent,
            at: at
        )
        Task { @MainActor in DeliveryLog.shared.ingest(event) }
    }

    /// Extract the `(skill, intent?)` pair from a `fetch_skill` arguments
    /// value for the routing-stability audit. `skill` is the `name` string
    /// (empty when absent); `intent` is the trimmed `intent` string when
    /// non-empty, else nil. Pure + nonisolated — touches only its argument.
    /// Record a `memory_*` tool call. AUDIT ONLY — never gates dispatch.
    public nonisolated func recordMemoryToolCall(
        sessionID: String,
        clientName: String?,
        toolName: String,
        at: Date = Date()
    ) {
        let event = DeliveryEvent(
            sessionID: sessionID,
            clientName: clientName,
            kind: .memoryToolCall,
            uri: toolName,
            at: at
        )
        Task { @MainActor in DeliveryLog.shared.ingest(event) }
    }

    public nonisolated static func skillFetchFields(from arguments: Value?) -> (skill: String, intent: String?) {
        guard case .object(let dict)? = arguments else { return ("", nil) }
        let skill: String = {
            if case .string(let s)? = dict["name"] { return s }
            return ""
        }()
        let intent: String? = {
            if case .string(let s)? = dict["intent"] {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            return nil
        }()
        return (skill, intent)
    }

    // MARK: - Read accessors (UI + tests)

    /// One audit row per active session, in first-seen order. Freshness is
    /// computed against the CLIENT-APPROPRIATE current composition hash (so a
    /// Standing Orders edit flips already-read sessions to stale) — resolved
    /// per-session via the session's client name so a client with a per-client
    /// overlay compares its read against ITS OWN live composition rather than
    /// the overlay-less default (the overlay-freshness bug fix).
    public func sessions() -> [SessionAudit] {
        return sessionOrder.compactMap { sid -> SessionAudit? in
            guard let byKind = latest[sid] else { return nil }
            let handshake = byKind[.handshakeDelivered]
            let read = byKind[.resourceRead]
            let clientName = handshake?.clientName ?? read?.clientName
            // Resolve the live hash for THIS client (overlay-aware) and compare
            // the last read against it. No-overlay clients resolve the default
            // composition hash, so their freshness is unchanged.
            let isFresh: Bool? = read.map { $0.contentHash == currentHash(clientName) }
            return SessionAudit(
                sessionID: sid,
                clientName: clientName,
                deliveredTokens: handshake?.tokenCount,
                deliveredAt: handshake?.at,
                lastResourceReadAt: read?.at,
                lastReadHash: read?.contentHash,
                isFresh: isFresh
            )
        }
    }

    /// Recent events newest-first, capped at `limit`, for the debug timeline.
    public func timeline(limit: Int = 50) -> [DeliveryEvent] {
        Array(history.suffix(max(0, limit)).reversed())
    }
}
