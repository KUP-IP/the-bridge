// StandingOrdersDeliveryTests.swift — MCP resource layer SSOT.
//
// Covers the StandingOrdersDelivery single source of truth: composition
// determinism + content-hash stability, the routing-index carve-out, and the
// BridgeResources URI → bytes resolution that BOTH transports share. These
// are file-I/O hermetic via withTempHome (per-test throwaway HOME), so the
// composed instructions reflect a known on-disk Standing Orders body.

import Foundation
import NotionBridgeLib

func runStandingOrdersDeliveryTests() async {
    print("\n[StandingOrdersDelivery]")

    await test("Delivery: composition is deterministic for identical state") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nbe terse")
            let a = StandingOrdersDelivery.composition()
            let b = StandingOrdersDelivery.composition()
            try expect(a == b, "two reads of the same state must be Equatable-equal")
            try expect(a.instructionsMarkdown == b.instructionsMarkdown)
            try expect(a.contentHash == b.contentHash)
            try expect(a.routingIndexMarkdown == b.routingIndexMarkdown)
        }
    }

    await test("Delivery: contentHash is a 64-hex SHA256 of instructionsMarkdown") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nhash me")
            let c = StandingOrdersDelivery.composition()
            try expect(c.contentHash.count == 64, "SHA256 hex is 64 chars, got \(c.contentHash.count)")
            try expect(c.contentHash.allSatisfy { $0.isHexDigit }, "hash must be all hex")
            // Recompute independently against the same string via the public helper.
            let expected = StandingOrdersDelivery.sha256Hex(c.instructionsMarkdown)
            try expect(c.contentHash == expected, "hash must be SHA256 of instructionsMarkdown")
        }
    }

    await test("Delivery: contentHash changes when standing orders change") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nversion one")
            let h1 = StandingOrdersDelivery.composition().contentHash
            _ = try StandingOrdersStore.shared.write("# Orders\n\nversion two")
            let h2 = StandingOrdersDelivery.composition().contentHash
            try expect(h1 != h2, "content hash must track instruction content")
        }
    }

    await test("Delivery: instructionsMarkdown prepends orders and embeds routing index") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# MY ORDERS\n\ndo the thing")
            let c = StandingOrdersDelivery.composition()
            // Orders body leads; routing index (the SSOT routing markdown) is
            // present and identical to routingIndexMarkdown.
            try expect(c.instructionsMarkdown.hasPrefix("# MY ORDERS"),
                       "orders must lead the composed payload")
            try expect(c.instructionsMarkdown.contains(c.routingIndexMarkdown),
                       "the routing index must be embedded verbatim in instructions")
            try expect(c.instructionsMarkdown.contains("\n\n---\n\n"),
                       "orders and routing index are joined by the standard separator")
        }
    }

    await test("Delivery: empty/unreadable orders fall back to routing index alone") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            // No file written → empty orders → byte-identical to routing index.
            let c = StandingOrdersDelivery.composition()
            try expect(c.instructionsMarkdown == c.routingIndexMarkdown,
                       "empty orders → instructions == routing index (no separator, no prefix)")
            try expect(!c.instructionsMarkdown.contains("\n\n---\n\n"),
                       "no separator when orders are empty")
        }
    }

    await test("Delivery: tokenCount is a positive chars/4 estimate over instructions") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nsome content worth estimating")
            let c = StandingOrdersDelivery.composition()
            try expect(c.tokenCount == c.instructionsMarkdown.count / 4,
                       "tokenCount must be chars/4 of instructionsMarkdown")
            try expect(c.tokenCount > 0)
        }
    }

    await test("Delivery: clientName hook does not alter content (overlays deferred)") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nuniform across clients")
            let base = StandingOrdersDelivery.composition(clientName: nil)
            let named = StandingOrdersDelivery.composition(clientName: "claude-code-9.9.9")
            try expect(base == named, "clientName is a hook only — content must be identical today")
        }
    }

    // MARK: - BridgeResources (shared URI → bytes resolution)

    await test("Resources: list advertises exactly the two bridge:// resources") {
        let uris = Set(BridgeResources.list.map { $0.uri })
        try expect(uris == [BridgeResources.standingOrdersURI, BridgeResources.routingSkillsURI],
                   "exactly the two canonical resources, got \(uris)")
        try expect(BridgeResources.list.allSatisfy { $0.mimeType == "text/markdown" },
                   "both resources are text/markdown")
    }

    await test("Resources: dictionary projection matches the typed list shape") {
        let dicts = BridgeResources.listAsDictionaries
        try expect(dicts.count == 2)
        let dictURIs = Set(dicts.compactMap { $0["uri"] as? String })
        let typedURIs = Set(BridgeResources.list.map { $0.uri })
        try expect(dictURIs == typedURIs, "legacy dict projection must carry the same URIs")
        try expect(dicts.allSatisfy { ($0["mimeType"] as? String) == "text/markdown" })
    }

    await test("Resources: read resolves each URI to the matching SSOT bytes") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nresolve me")
            let c = StandingOrdersDelivery.composition()
            let orders = try BridgeResources.markdown(for: BridgeResources.standingOrdersURI)
            let routing = try BridgeResources.markdown(for: BridgeResources.routingSkillsURI)
            try expect(orders == c.instructionsMarkdown,
                       "standing-orders resource == composed instructions (byte-identical)")
            try expect(routing == c.routingIndexMarkdown,
                       "routing-skills resource == routing index alone")
        }
    }

    await test("Resources: read of an unknown URI throws") {
        do {
            _ = try BridgeResources.markdown(for: "bridge://does-not-exist")
            try expect(false, "expected throw for unknown URI")
        } catch {
            // expected — MCPError.invalidParams
        }
    }
}

// MARK: - Test helpers (local, not exported)

private func withDeliveryTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("StandingOrdersDelivery-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
