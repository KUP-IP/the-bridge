// BridgeInitializeService.swift — PKT-1065A
// TheBridge · Modules · StandingOrders
//
// The canonical, deterministic init-core. One call to
// `BridgeInitializeService.run(...)` executes the standing-orders manifest
// sequence end-to-end and returns a structured, durable HANDSHAKE RECEIPT:
//
//   1. Locate + load the doctrine files (orders.md + manifest.json +
//      metadata.json) via `StandingOrdersStore`.
//   2. Compute the doctrine SHA-256 and compare expected(manifest) vs actual.
//   3. Enforce the required-source + integrity policy (INCOMPLETE on a missing
//      required source; DEGRADED on hash / version drift).
//   4. Inspect the routing roster + supplemental orders + connection +
//      capability state.
//   5. PERSIST a structured `HandshakeReceipt` to disk (one file per handshake)
//      and emit a per-handshake telemetry event linked to session telemetry.
//
// DESIGN — init-state vs capability-state are SEPARATE axes:
//   • `finalState` (INCOMPLETE|DEGRADED|COMPLETE) is the INITIALIZATION verdict:
//     did the doctrine + integrity + required routing roster load correctly?
//   • `capabilityState` describes what the RUNTIME can do right now (Mac tools,
//     cloud reachability). A perfectly initialized bridge can still be capability
//     -limited (offline cloud), and a capability-rich bridge can be INCOMPLETE
//     (missing doctrine). The two never collapse into one another.
//
// The clock is INJECTED (`now`). `Date.now` is unavailable in some contexts
// (the app supplies its wall clock); tests pass a fixed instant for determinism.

import Foundation
import CryptoKit

/// The runtime capability axis — SEPARATE from initialization state.
/// Derived from the cloud connection state + whether Mac tools are exposed.
public enum CapabilityState: String, Codable, Sendable, Equatable {
    /// Mac tools available and (if cloud is enabled) reachable.
    case full = "FULL"
    /// Some capability present but impaired (degraded tunnel, cloud connecting).
    case limited = "LIMITED"
    /// Mac tools not exposed to callers in the current state (offline/disabled cloud).
    case unavailable = "UNAVAILABLE"
}

/// One capability entry — a named runtime capability and whether it is live.
public struct CapabilityEntry: Codable, Sendable, Equatable {
    public let capability: String
    public let available: Bool
    public let detail: String?

    public init(capability: String, available: Bool, detail: String? = nil) {
        self.capability = capability
        self.available = available
        self.detail = detail
    }
}

/// Supplemental-order tri-state counts. An order is:
///   • `operative` — an active (non-archived), non-no-op directive;
///   • `ignored`   — present but deliberately inert (archived, or explicitly
///     marked TEMP / no-op via the `[no-op]` / `TEMP` marker convention);
///   • `found`     — operative + ignored (every supplemental order located).
public struct SupplementalOrderCounts: Codable, Sendable, Equatable {
    public let found: Int
    public let operative: Int
    public let ignored: Int

    public init(found: Int, operative: Int, ignored: Int) {
        self.found = found
        self.operative = operative
        self.ignored = ignored
    }
}

/// The persisted, structured handshake receipt. One per `run(...)`.
public struct HandshakeReceipt: Codable, Sendable, Equatable {
    public let handshakeId: String
    public let schemaVersion: Int
    public let timestamp: Date
    public let client: String?
    public let bridgeState: String
    public let macToolsAvailable: Bool
    public let doctrineVersion: String
    public let expectedHash: String?
    public let actualHash: String?
    public let integrityResult: String
    public let routingRosterState: String
    public let routingWarnings: [String]
    public let supplementalOrderCounts: SupplementalOrderCounts
    public let connectionState: String
    public let telemetryEventRef: String
    public let capabilityState: CapabilityState
    public let capabilityMatrix: [CapabilityEntry]
    public let finalState: StandingOrdersStore.InitializationState

    public init(
        handshakeId: String,
        schemaVersion: Int,
        timestamp: Date,
        client: String?,
        bridgeState: String,
        macToolsAvailable: Bool,
        doctrineVersion: String,
        expectedHash: String?,
        actualHash: String?,
        integrityResult: String,
        routingRosterState: String,
        routingWarnings: [String],
        supplementalOrderCounts: SupplementalOrderCounts,
        connectionState: String,
        telemetryEventRef: String,
        capabilityState: CapabilityState,
        capabilityMatrix: [CapabilityEntry],
        finalState: StandingOrdersStore.InitializationState
    ) {
        self.handshakeId = handshakeId
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.client = client
        self.bridgeState = bridgeState
        self.macToolsAvailable = macToolsAvailable
        self.doctrineVersion = doctrineVersion
        self.expectedHash = expectedHash
        self.actualHash = actualHash
        self.integrityResult = integrityResult
        self.routingRosterState = routingRosterState
        self.routingWarnings = routingWarnings
        self.supplementalOrderCounts = supplementalOrderCounts
        self.connectionState = connectionState
        self.telemetryEventRef = telemetryEventRef
        self.capabilityState = capabilityState
        self.capabilityMatrix = capabilityMatrix
        self.finalState = finalState
    }
}

/// The immutable runtime inputs the init-core needs but cannot derive itself.
/// Injected so the service stays pure + hermetically testable (no live cloud
/// manager, no wall clock, no server actor reach-in).
public struct BridgeInitializeContext: Sendable {
    public let client: String?
    /// The current connection state raw value (e.g. "online"/"offline"/"disabled").
    public let connectionState: String
    /// Whether Mac tools are exposed to a caller in the current state.
    public let macToolsAvailable: Bool
    /// The running bridge lifecycle label (e.g. "running").
    public let bridgeState: String
    /// Injected wall clock — `Date.now` is unavailable in some contexts.
    public let now: Date

    public init(
        client: String? = nil,
        connectionState: String = "local",
        macToolsAvailable: Bool = true,
        bridgeState: String = "running",
        now: Date
    ) {
        self.client = client
        self.connectionState = connectionState
        self.macToolsAvailable = macToolsAvailable
        self.bridgeState = bridgeState
        self.now = now
    }
}

/// The deterministic init-core. Stateless: every call reads the live on-disk
/// doctrine + supplemental registry, classifies, persists a receipt, and emits
/// a telemetry event.
public enum BridgeInitializeService {

    /// Current receipt schema contract version. Bump on any shape change.
    public static let schemaVersion = 1

    /// A supplemental order is deliberately inert ("ignored") when it is
    /// archived OR explicitly marked as a no-op / TEMP directive. The marker
    /// convention is a case-insensitive `[no-op]` / `[noop]` / `TEMP` token in
    /// the title (cheap, operator-visible, and stable across edits).
    public static func isIgnoredOrder(title: String, archived: Bool) -> Bool {
        if archived { return true }
        let t = title.lowercased()
        return t.contains("[no-op]") || t.contains("[noop]") || t.contains("temp")
    }

    /// Derive the runtime capability axis from the connection state + Mac-tool
    /// exposure. INDEPENDENT of initialization state.
    ///   • local / online + Mac tools     → FULL
    ///   • degraded / connecting          → LIMITED
    ///   • Mac tools not exposed           → UNAVAILABLE
    public static func capabilityState(connectionState: String, macToolsAvailable: Bool) -> CapabilityState {
        guard macToolsAvailable else { return .unavailable }
        switch connectionState.lowercased() {
        case "degraded", "connecting":
            return .limited
        case "offline", "disabled":
            // Mac tools reported available but the channel is down → limited.
            return .limited
        default:
            return .full
        }
    }

    /// Build (but do NOT persist) the receipt for the given context, reading the
    /// live doctrine + supplemental registry. Pure aside from disk reads; used by
    /// `run(...)` and directly by tests that want the classification without I/O
    /// side effects. `telemetryEventRef` is the id of the event `run(...)` emits.
    public static func buildReceipt(
        context: BridgeInitializeContext,
        supplemental: [StandingOrderSummary],
        handshakeId: String = UUID().uuidString,
        telemetryEventRef: String
    ) -> HandshakeReceipt {
        // 1–3: doctrine load + hash verify + integrity policy (init axis).
        try? StandingOrdersStore.shared.ensureInitializationContract()
        let report = StandingOrdersStore.shared.initializationReport()

        // Compute actual doctrine hash from the live orders.md (nil when absent).
        let actualHash: String? = {
            guard let snapshot = try? StandingOrdersStore.shared.read(),
                  report.doctrineLoaded else { return nil }
            return StandingOrdersStore.sha256Hex(snapshot.markdown)
        }()
        // The manifest's expected hash (nil when the manifest is missing).
        let expectedHash = StandingOrdersStore.shared.manifestDoctrineHash()

        // 4: routing roster state + warnings (init axis — required source).
        let routingIndex = SkillsModule.buildRoutingInstructions()
        let routingLoaded = !routingIndex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var routingWarnings: [String] = []
        var finalState = report.state
        if !routingLoaded {
            routingWarnings.append("Required routing roster is empty.")
            finalState = .incomplete
        }

        // Supplemental order tri-state (found / operative / ignored).
        let found = supplemental.count
        let ignored = supplemental.filter {
            isIgnoredOrder(title: $0.title, archived: $0.archived)
        }.count
        let counts = SupplementalOrderCounts(
            found: found,
            operative: max(0, found - ignored),
            ignored: ignored
        )

        // integrityResult: COMPLETE = clean; DEGRADED = hash/version drift only;
        // MISSING when a required doctrine/integrity source is absent.
        let integrityResult: String = {
            if !report.doctrineLoaded || !report.manifestLoaded { return "MISSING_REQUIRED_SOURCE" }
            switch report.state {
            case .complete: return report.metadataVerified ? "VERIFIED" : "DEGRADED"
            case .degraded: return "DEGRADED"
            case .incomplete: return "MISSING_REQUIRED_SOURCE"
            }
        }()

        // Capability axis — SEPARATE from finalState.
        let capState = capabilityState(
            connectionState: context.connectionState,
            macToolsAvailable: context.macToolsAvailable
        )
        let matrix: [CapabilityEntry] = [
            CapabilityEntry(capability: "mac_tools", available: context.macToolsAvailable),
            CapabilityEntry(
                capability: "cloud_channel",
                available: context.connectionState.lowercased() == "online"
                    || context.connectionState.lowercased() == "degraded"
                    || context.connectionState.lowercased() == "local",
                detail: context.connectionState
            ),
            CapabilityEntry(capability: "doctrine_loaded", available: report.doctrineLoaded),
            CapabilityEntry(capability: "routing_roster", available: routingLoaded),
        ]

        return HandshakeReceipt(
            handshakeId: handshakeId,
            schemaVersion: schemaVersion,
            timestamp: context.now,
            client: context.client,
            bridgeState: context.bridgeState,
            macToolsAvailable: context.macToolsAvailable,
            doctrineVersion: report.doctrineVersion,
            expectedHash: expectedHash,
            actualHash: actualHash,
            integrityResult: integrityResult,
            routingRosterState: routingLoaded ? "loaded" : "missing",
            routingWarnings: routingWarnings,
            supplementalOrderCounts: counts,
            connectionState: context.connectionState,
            telemetryEventRef: telemetryEventRef,
            capabilityState: capState,
            capabilityMatrix: matrix,
            finalState: finalState
        )
    }

    /// The canonical one-call init sequence. Reads the live supplemental
    /// registry, builds the receipt, PERSISTS it durably, and emits a
    /// per-handshake telemetry event linked to session telemetry.
    @discardableResult
    public static func run(
        context: BridgeInitializeContext,
        store: StandingOrdersRecordStore = .shared,
        receiptStore: HandshakeReceiptStore = .shared
    ) async -> HandshakeReceipt {
        let supplemental = await store.list(includeArchived: true)
        let handshakeId = UUID().uuidString
        // The telemetry event id is bound INTO the receipt (each handshake =
        // one distinct evidence event), then the event is emitted below.
        let telemetryEventId = UUID().uuidString
        let receipt = buildReceipt(
            context: context,
            supplemental: supplemental,
            handshakeId: handshakeId,
            telemetryEventRef: telemetryEventId
        )
        // Persist durably (best-effort; a write failure must not crash a
        // handshake — the receipt is still returned and telemetry still fires).
        try? receiptStore.persist(receipt)
        // Emit the per-handshake telemetry event, linked to session telemetry.
        DeliveryLog.shared.recordHandshakeInitialized(
            eventID: telemetryEventId,
            sessionID: context.client ?? handshakeId,
            clientName: context.client,
            handshakeId: handshakeId,
            finalState: receipt.finalState.rawValue,
            at: context.now
        )
        return receipt
    }
}

// MARK: - Durable receipt persistence

/// Persists handshake receipts to disk — one JSON file per handshake, so a
/// controller/human can audit every init as distinct durable evidence. Stored
/// under the standing-orders support dir in a `handshakes/` subfolder.
public final class HandshakeReceiptStore: @unchecked Sendable {
    public static let shared = HandshakeReceiptStore()

    /// Cap on retained receipt files. Oldest are pruned on write so the folder
    /// never grows unbounded across a long-lived install.
    public static let retentionCap = 200

    private let baseDir: URL

    /// Default location: `…/The Bridge/standing-orders/handshakes/`. Injectable
    /// for hermetic tests.
    public init(baseDir: URL = HandshakeReceiptStore.defaultDir()) {
        self.baseDir = baseDir
    }

    public static func defaultDir() -> URL {
        BridgePaths.applicationSupport(.standingOrders)
            .appendingPathComponent("handshakes", isDirectory: true)
    }

    private func fileURL(for id: String) -> URL {
        baseDir.appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// Write one receipt atomically. Filename is the handshakeId (unique per
    /// handshake), so distinct handshakes never overwrite one another.
    public func persist(_ receipt: HandshakeReceipt) throws {
        if !FileManager.default.fileExists(atPath: baseDir.path) {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        try data.write(to: fileURL(for: receipt.handshakeId), options: [.atomic])
        pruneIfNeeded()
    }

    /// Load one receipt by id, or nil when absent/unreadable.
    public func load(id: String) -> HandshakeReceipt? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HandshakeReceipt.self, from: data)
    }

    /// The number of persisted receipt files currently on disk.
    public func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }.count ?? 0
    }

    /// Prune oldest receipt files beyond the retention cap (by mtime).
    private func pruneIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter({ $0.pathExtension == "json" }), files.count > Self.retentionCap else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
        for file in sorted.prefix(files.count - Self.retentionCap) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Test/diagnostic reset — remove every persisted receipt.
    public func resetForTesting() {
        try? FileManager.default.removeItem(at: baseDir)
    }
}
