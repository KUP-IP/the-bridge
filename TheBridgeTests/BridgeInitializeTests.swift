// BridgeInitializeTests.swift — PKT-1065A
// Covers the deterministic init-core (BridgeInitializeService) + the
// bridge_initialize MCP tool + durable receipt persistence + per-handshake
// telemetry:
//   • manifest/metadata parse + hash verify (expected vs actual)
//   • receipt serialize round-trip (Codable + MCP Value)
//   • status classification: INCOMPLETE on a missing required source
//   • no-op supplemental order → found-but-ignored tri-state counts
//   • init-state vs capability-state are SEPARATE axes
//   • each handshake is a distinct persisted receipt + distinct evidence event
// File-I/O hermetic via a per-test throwaway HOME (BridgePaths override).

import Foundation
import MCP
import TheBridgeLib

func runBridgeInitializeTests() async {
    print("\n\u{1F91D} BridgeInitialize (PKT-1065A · init-core + handshake receipt)")

    let fixedClock = Date(timeIntervalSince1970: 1_700_000_000)

    func ctx(
        client: String? = "test-client",
        connectionState: String = "local",
        macTools: Bool = true
    ) -> BridgeInitializeContext {
        BridgeInitializeContext(
            client: client,
            connectionState: connectionState,
            macToolsAvailable: macTools,
            bridgeState: "running",
            now: fixedClock
        )
    }

    // ── COMPLETE path: doctrine + manifest + metadata all present ──────
    await test("Init: fully-seeded doctrine classifies COMPLETE with matching hashes") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nbe terse")
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(),
                supplemental: [],
                telemetryEventRef: "evt-1"
            )
            try expect(receipt.finalState == .complete, "expected COMPLETE, got \(receipt.finalState.rawValue)")
            try expect(receipt.expectedHash != nil, "manifest must carry an expected doctrine hash")
            try expect(receipt.actualHash != nil, "actual doctrine hash must be computed")
            try expect(receipt.expectedHash == receipt.actualHash,
                       "expected vs actual doctrine hash must match on a clean seed")
            try expect(receipt.integrityResult == "VERIFIED",
                       "clean seed integrityResult must be VERIFIED, got \(receipt.integrityResult)")
            // doctrineVersion is sourced from the manifest the write path stamped
            // (parse-from-markdown is a bundled-seed concern); it must be resolved,
            // not the "unknown" sentinel a failed manifest load would leave.
            try expect(receipt.doctrineVersion != "unknown",
                       "doctrineVersion must be resolved from the manifest, got \(receipt.doctrineVersion)")
            try expect(receipt.routingRosterState == "loaded" || receipt.routingRosterState == "missing")
        }
    }

    await test("Init: bundled-seed doctrineVersion is parsed from the amendment record") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            StandingOrdersStore.bundledSeedOverrideForTesting = .init(
                markdown: "# Orders\n\n> **Amendment record:** v9.1.2\n\nseed body",
                doctrineVersion: "v9.1.2"
            )
            defer { StandingOrdersStore.bundledSeedOverrideForTesting = nil }
            try StandingOrdersStore.shared.seedIfEmpty()
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(), supplemental: [], telemetryEventRef: "evt-1b")
            try expect(receipt.doctrineVersion == "v9.1.2",
                       "doctrineVersion from bundled seed manifest, got \(receipt.doctrineVersion)")
            try expect(receipt.finalState == .complete)
            try expect(receipt.expectedHash == receipt.actualHash, "seeded hashes match")
        }
    }

    // ── INCOMPLETE path: required doctrine source missing ──────────────
    await test("Init: missing required doctrine classifies INCOMPLETE (not silent success)") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            // No write → orders.md absent.
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(),
                supplemental: [],
                telemetryEventRef: "evt-2"
            )
            try expect(receipt.finalState == .incomplete,
                       "missing required source must be INCOMPLETE, got \(receipt.finalState.rawValue)")
            try expect(receipt.integrityResult == "MISSING_REQUIRED_SOURCE",
                       "integrityResult must flag the missing source, got \(receipt.integrityResult)")
            try expect(receipt.actualHash == nil, "no doctrine → no actual hash")
        }
    }

    // ── DEGRADED path: doctrine present but hash drift ─────────────────
    await test("Init: doctrine hash drift classifies DEGRADED (integrity, not required-source)") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\noriginal body")
            // Tamper the orders.md on disk WITHOUT rewriting the manifest/metadata,
            // so the recorded expected hash no longer matches the actual bytes.
            let dir = BridgePaths.applicationSupport(.standingOrders)
            let ordersURL = dir.appendingPathComponent("orders.md")
            try "# Orders\n\nTAMPERED body".write(to: ordersURL, atomically: true, encoding: .utf8)
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(),
                supplemental: [],
                telemetryEventRef: "evt-3"
            )
            try expect(receipt.finalState == .degraded,
                       "hash drift must be DEGRADED, got \(receipt.finalState.rawValue)")
            try expect(receipt.expectedHash != receipt.actualHash,
                       "expected vs actual must diverge after tamper")
            try expect(receipt.integrityResult == "DEGRADED",
                       "integrityResult must be DEGRADED, got \(receipt.integrityResult)")
        }
    }

    // ── no-op supplemental order → found-but-ignored ───────────────────
    await test("Init: TEMP supplemental order counts as found-but-ignored (operative excludes it)") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nseed")
            let operative = StandingOrderSummary(
                id: "a", title: "Real directive", scope: .global,
                updatedAt: fixedClock, archived: false)
            let temp = StandingOrderSummary(
                id: "b", title: "TEMP scratch note", scope: .global,
                updatedAt: fixedClock, archived: false)
            let archived = StandingOrderSummary(
                id: "c", title: "Old directive", scope: .global,
                updatedAt: fixedClock, archived: true)
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(),
                supplemental: [operative, temp, archived],
                telemetryEventRef: "evt-4"
            )
            try expect(receipt.supplementalOrderCounts.found == 3, "found = all located")
            try expect(receipt.supplementalOrderCounts.ignored == 2,
                       "TEMP + archived are ignored, got \(receipt.supplementalOrderCounts.ignored)")
            try expect(receipt.supplementalOrderCounts.operative == 1,
                       "only the real directive is operative, got \(receipt.supplementalOrderCounts.operative)")
        }
    }

    await test("Init: isIgnoredOrder marker convention (TEMP / [no-op] / archived)") {
        try expect(BridgeInitializeService.isIgnoredOrder(title: "TEMP foo", archived: false))
        try expect(BridgeInitializeService.isIgnoredOrder(title: "cleanup [no-op]", archived: false))
        try expect(BridgeInitializeService.isIgnoredOrder(title: "live", archived: true))
        try expect(!BridgeInitializeService.isIgnoredOrder(title: "live directive", archived: false))
    }

    // ── init-state vs capability-state SEPARATION ──────────────────────
    await test("Init: capability-state is SEPARATE from init-state") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            // No doctrine → INCOMPLETE init — but Mac tools fully available.
            let full = BridgeInitializeService.buildReceipt(
                context: ctx(connectionState: "local", macTools: true),
                supplemental: [],
                telemetryEventRef: "evt-5a"
            )
            try expect(full.finalState == .incomplete, "init is INCOMPLETE (no doctrine)")
            try expect(full.capabilityState == .full,
                       "capability is FULL despite INCOMPLETE init — axes are independent")

            // Now seed doctrine (COMPLETE init) but report Mac tools unavailable.
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let unavail = BridgeInitializeService.buildReceipt(
                context: ctx(connectionState: "offline", macTools: false),
                supplemental: [],
                telemetryEventRef: "evt-5b"
            )
            try expect(unavail.finalState == .complete, "init is COMPLETE (doctrine seeded)")
            try expect(unavail.capabilityState == .unavailable,
                       "capability UNAVAILABLE when Mac tools not exposed — independent of COMPLETE init")
        }
    }

    await test("Init: capabilityState derivation (full / limited / unavailable)") {
        try expect(BridgeInitializeService.capabilityState(connectionState: "local", macToolsAvailable: true) == .full)
        try expect(BridgeInitializeService.capabilityState(connectionState: "online", macToolsAvailable: true) == .full)
        try expect(BridgeInitializeService.capabilityState(connectionState: "degraded", macToolsAvailable: true) == .limited)
        try expect(BridgeInitializeService.capabilityState(connectionState: "connecting", macToolsAvailable: true) == .limited)
        try expect(BridgeInitializeService.capabilityState(connectionState: "offline", macToolsAvailable: true) == .limited)
        try expect(BridgeInitializeService.capabilityState(connectionState: "local", macToolsAvailable: false) == .unavailable)
    }

    // ── receipt Codable round-trip ─────────────────────────────────────
    await test("Init: receipt Codable round-trips losslessly") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(),
                supplemental: [],
                handshakeId: "hs-fixed",
                telemetryEventRef: "evt-6"
            )
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let data = try enc.encode(receipt)
            let back = try dec.decode(HandshakeReceipt.self, from: data)
            try expect(back == receipt, "Codable round-trip must be lossless")
            try expect(back.handshakeId == "hs-fixed")
            try expect(back.telemetryEventRef == "evt-6")
            try expect(back.schemaVersion == BridgeInitializeService.schemaVersion)
        }
    }

    // ── MCP Value serialization has every packet-required field ────────
    await test("Init: bridge_initialize tool result carries every required receipt field") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(), supplemental: [], telemetryEventRef: "evt-7")
            guard case .object(let d) = BridgeInitializeModule.receiptValue(receipt) else {
                throw TestError.assertion("receiptValue must be an object")
            }
            let required = [
                "handshakeId", "schemaVersion", "timestamp", "bridgeState",
                "macToolsAvailable", "doctrineVersion", "integrityResult",
                "routingRosterState", "routingWarnings", "supplementalOrderCounts",
                "connectionState", "telemetryEventRef", "capabilityState",
                "capabilityMatrix", "finalState",
            ]
            for key in required {
                try expect(d[key] != nil, "receipt Value missing required field '\(key)'")
            }
        }
    }

    // ── run(): durable persistence + distinct evidence per handshake ───
    await test("Init: run() persists a durable receipt + emits one telemetry event") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let store = StandingOrdersRecordStore(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("nb-init-\(UUID().uuidString).json"))
            let receiptStore = HandshakeReceiptStore(baseDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("nb-hs-\(UUID().uuidString)", isDirectory: true))
            receiptStore.resetForTesting()

            let r1 = await BridgeInitializeService.run(context: ctx(), store: store, receiptStore: receiptStore)
            let loaded = receiptStore.load(id: r1.handshakeId)
            try expect(loaded != nil, "receipt must be durably persisted")
            try expect(loaded?.handshakeId == r1.handshakeId)
            try expect(receiptStore.count() == 1, "one handshake → one persisted receipt")
        }
    }

    await test("Init: each handshake is a DISTINCT receipt (distinct id + file)") {
        try await withInitTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let store = StandingOrdersRecordStore(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("nb-init-\(UUID().uuidString).json"))
            let receiptStore = HandshakeReceiptStore(baseDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("nb-hs-\(UUID().uuidString)", isDirectory: true))
            receiptStore.resetForTesting()

            let r1 = await BridgeInitializeService.run(context: ctx(), store: store, receiptStore: receiptStore)
            let r2 = await BridgeInitializeService.run(context: ctx(), store: store, receiptStore: receiptStore)
            try expect(r1.handshakeId != r2.handshakeId, "distinct handshakes → distinct ids")
            try expect(r1.telemetryEventRef != r2.telemetryEventRef, "distinct evidence event per handshake")
            try expect(receiptStore.count() == 2, "two handshakes → two persisted receipts")
        }
    }

    // ── tool registration + tier ───────────────────────────────────────
    await test("Init: bridge_initialize registers at tier .open under standing_orders module") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeInitializeModule.register(on: router)
        let reg = await router.allRegistrations().first { $0.name == "bridge_initialize" }
        try expect(reg != nil, "bridge_initialize must be registered")
        try expect(reg?.tier == .open, "bridge_initialize must be tier .open")
        try expect(reg?.module == "standing_orders", "joins the standing_orders family (no new family)")
    }

    await test("Init: bridge_initialize has an explicit annotation catalog entry") {
        let ann = ToolAnnotationCatalog.annotations(for: "bridge_initialize")
        try expect(ann != nil, "bridge_initialize must carry an explicit annotation")
        try expect(ann?.destructiveHint == false, "not destructive")
        try expect(ann?.requiresConfirmation == false, "no confirmation (tier .open)")
        try expect(ann?.openWorld == false, "touches only this app's own doctrine/evidence")
    }
}

// Per-test throwaway HOME so the on-disk standing-orders + receipt stores are
// hermetic (BridgePaths override, mirrors withDeliveryTempHome).
private func withInitTempHome(_ body: () async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("BridgeInitialize-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body()
}
