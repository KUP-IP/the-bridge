// DeliveryAuditWave3Tests.swift — Wave 3 delivery-audit regression coverage.
//
// Closes the four coverage gaps the delivery-audit audit flagged:
//   (a) overlay-freshness regression — a client with a ClientOverlayStore
//       overlay must report isFresh == true after reading ITS OWN composition
//       (it was permanently amber/stale because freshness compared against the
//       overlay-LESS default hash). Exercises the REAL composition(clientName:)
//       path under a tmp HOME (no injected hash), so it would fail before the fix.
//   (b) legacy-prune regression — a legacy SSE session's delivery events must
//       be pruned on disconnect (Streamable-HTTP + stdio already prune via
//       removeSession; legacy SSE did not). Drives the SAME teardown seam
//       channelInactive now runs (SSEServer.pruneLegacyDeliveryTelemetry).
//   (c) recording-wiring — the nonisolated record* funcs must land the expected
//       DeliveryEvent (session id, client, tokens, hash) on the shared log.
//       This thin seam had ZERO coverage.
//   (d) UI-invariant — the truthful-label rules: "Fetched ✓" ONLY when a real
//       read occurred; never "Honored"; absence of a read is never "not honored".
//       Tested against the pure DeliveryAuditLabels helper (no render).
//
// (a) is tmp-HOME-hermetic; (b)/(c) reset the shared DeliveryLog and give the
// record/prune main-actor hop a turn; (d) is pure. All run in CI and local.

import Foundation
import NotionBridgeLib

func runDeliveryAuditWave3Tests() async {
    print("\n\u{1F4E6} Delivery Audit (Wave 3)")

    // MARK: - (a) overlay-freshness regression (the headline bug)

    await test("DeliveryAudit: a client WITH an overlay reads its own composition → FRESH (not stale)") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            ClientOverlayStore.shared.resetForTesting()
            defer { ClientOverlayStore.shared.resetForTesting() }

            _ = try StandingOrdersStore.shared.write("# Orders\n\nbase orders")
            // This client has an operator-authored overlay.
            ClientOverlayStore.shared.setOverlay("CLIENT-SPECIFIC NOTE", forClient: "claude-code")

            // The read records the CLIENT-specific composition hash (exactly as
            // SSETransport.recordResourceRead does).
            let clientHash = StandingOrdersDelivery.composition(clientName: "claude-code").contentHash
            let overlaylessHash = StandingOrdersDelivery.composition(clientName: nil).contentHash
            try expect(clientHash != overlaylessHash,
                       "precondition: the overlay must make the client hash differ from the default")

            // PRODUCTION freshness path: default DeliveryLog → composition(clientName:).
            try await MainActor.run {
                let log = DeliveryLog()
                log.resetForTesting()
                log.ingest(.init(
                    sessionID: "sess-overlay", clientName: "claude-code",
                    kind: .handshakeDelivered, tokenCount: 100, contentHash: clientHash))
                log.ingest(.init(
                    sessionID: "sess-overlay", clientName: "claude-code",
                    kind: .resourceRead, uri: BridgeResources.standingOrdersURI,
                    contentHash: clientHash))
                let row = log.sessions().first
                // Before the fix this compared clientHash against the
                // overlay-less default hash → false (permanently amber).
                try expect(row?.isFresh == true,
                           "an overlay client that read its own composition is FRESH, not stale")
            }
        }
    }

    await test("DeliveryAudit: an overlay client whose orders CHANGED since its read → STALE") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            ClientOverlayStore.shared.resetForTesting()
            defer { ClientOverlayStore.shared.resetForTesting() }

            _ = try StandingOrdersStore.shared.write("# Orders\n\nbase orders")
            ClientOverlayStore.shared.setOverlay("CLIENT-SPECIFIC NOTE", forClient: "claude-code")
            // A read served against the CURRENT-then composition...
            let staleReadHash = StandingOrdersDelivery.composition(clientName: "claude-code").contentHash
            // ...then the orders change underneath this client.
            _ = try StandingOrdersStore.shared.write("# Orders\n\nDIFFERENT orders now")

            try await MainActor.run {
                let log = DeliveryLog()
                log.resetForTesting()
                log.ingest(.init(
                    sessionID: "sess-overlay-2", clientName: "claude-code",
                    kind: .resourceRead, uri: BridgeResources.standingOrdersURI,
                    contentHash: staleReadHash))
                let row = log.sessions().first
                try expect(row?.isFresh == false,
                           "the live (overlay-aware) composition changed since the read → stale")
            }
        }
    }

    await test("DeliveryAudit: no-overlay client freshness path is unchanged (byte-identical default)") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            ClientOverlayStore.shared.resetForTesting()
            defer { ClientOverlayStore.shared.resetForTesting() }

            _ = try StandingOrdersStore.shared.write("# Orders\n\nuniform")
            let h = StandingOrdersDelivery.composition(clientName: "no-overlay-client").contentHash
            let dflt = StandingOrdersDelivery.composition(clientName: nil).contentHash
            try expect(h == dflt, "no overlay → client hash equals the default composition hash")

            try await MainActor.run {
                let log = DeliveryLog()
                log.resetForTesting()
                log.ingest(.init(
                    sessionID: "sess-plain", clientName: "no-overlay-client",
                    kind: .resourceRead, uri: BridgeResources.standingOrdersURI, contentHash: h))
                try expect(log.sessions().first?.isFresh == true,
                           "no-overlay client that read the current composition is fresh")
            }
        }
    }

    // MARK: - (b) legacy-prune regression

    await test("DeliveryAudit: legacy SSE session events are pruned on disconnect") {
        // Record a handshake + a read for a legacy session, then drive the SAME
        // teardown seam channelInactive runs and assert the row is gone.
        let legacySession = "legacy-sess-\(UUID().uuidString)"
        await MainActor.run {
            DeliveryLog.shared.resetForTesting()
            DeliveryLog.shared.ingest(.init(
                sessionID: legacySession, clientName: "Notion",
                kind: .handshakeDelivered, tokenCount: 200, contentHash: "H"))
            DeliveryLog.shared.ingest(.init(
                sessionID: legacySession, clientName: "Notion",
                kind: .resourceRead, uri: BridgeResources.standingOrdersURI, contentHash: "H"))
        }
        // Sanity: the row + events exist before disconnect.
        try await MainActor.run {
            try expect(DeliveryLog.shared.sessions().contains { $0.sessionID == legacySession },
                       "legacy session row exists before disconnect")
            try expect(DeliveryLog.shared.timeline(limit: 50).contains { $0.sessionID == legacySession },
                       "legacy session events exist before disconnect")
        }

        // The disconnect teardown (the bug fix): exactly what channelInactive now calls.
        SSEServer.pruneLegacyDeliveryTelemetry(sessionID: legacySession)
        // The prune hops to the main actor on an unawaited Task — poll until it lands.
        let pruned = await waitForDeliveryHop {
            !DeliveryLog.shared.sessions().contains { $0.sessionID == legacySession }
        }
        try expect(pruned, "legacy session row pruned on disconnect")
        try await MainActor.run {
            try expect(DeliveryLog.shared.timeline(limit: 50).allSatisfy { $0.sessionID != legacySession },
                       "no legacy session events linger in the timeline after disconnect")
        }
        await MainActor.run { DeliveryLog.shared.resetForTesting() }
    }

    // MARK: - (c) recording-wiring (the record* seam — previously zero coverage)

    await test("DeliveryAudit: recordHandshakeDelivered lands the expected event on the shared log") {
        await MainActor.run { DeliveryLog.shared.resetForTesting() }
        let sid = "wire-hs-\(UUID().uuidString)"
        DeliveryLog.shared.recordHandshakeDelivered(
            sessionID: sid, clientName: "claude-code", tokenCount: 1234, contentHash: "HASH_HS")
        let landed = await waitForDeliveryHop {
            DeliveryLog.shared.timeline(limit: 50).contains { $0.sessionID == sid }
        }
        try expect(landed, "the record* hop landed the event on the shared log")
        try await MainActor.run {
            guard let ev = DeliveryLog.shared.timeline(limit: 10).first(where: { $0.sessionID == sid }) else {
                throw TestError.assertion("expected a handshake event for the recorded session")
            }
            try expect(ev.kind == .handshakeDelivered)
            try expect(ev.clientName == "claude-code", "client name carried through the hop")
            try expect(ev.tokenCount == 1234, "token count carried through the hop")
            try expect(ev.contentHash == "HASH_HS", "content hash carried through the hop")
            DeliveryLog.shared.resetForTesting()
        }
    }

    await test("DeliveryAudit: recordResourceRead lands the expected event (session, client, uri, hash)") {
        await MainActor.run { DeliveryLog.shared.resetForTesting() }
        let sid = "wire-read-\(UUID().uuidString)"
        DeliveryLog.shared.recordResourceRead(
            sessionID: sid, clientName: "Notion",
            uri: BridgeResources.routingSkillsURI, contentHash: "HASH_READ")
        let landed = await waitForDeliveryHop {
            DeliveryLog.shared.timeline(limit: 50).contains { $0.sessionID == sid }
        }
        try expect(landed, "the record* hop landed the resource-read event on the shared log")
        try await MainActor.run {
            guard let ev = DeliveryLog.shared.timeline(limit: 10).first(where: { $0.sessionID == sid }) else {
                throw TestError.assertion("expected a resourceRead event for the recorded session")
            }
            try expect(ev.kind == .resourceRead)
            try expect(ev.clientName == "Notion")
            try expect(ev.uri == BridgeResources.routingSkillsURI, "served URI carried through the hop")
            try expect(ev.contentHash == "HASH_READ", "serve-time hash carried through the hop")
            // And it rolls up into a session audit row.
            try expect(DeliveryLog.shared.sessions().contains { $0.sessionID == sid },
                       "the recorded read produced a session audit row")
            DeliveryLog.shared.resetForTesting()
        }
    }

    // MARK: - (d) UI-invariant: truthful labels (pure helper, no render)

    await test("DeliveryAudit labels: 'Fetched ✓' ONLY when a real read occurred; never 'Honored'") {
        // A session that DELIVERED a handshake but has NO read.
        let noRead = SessionAudit(
            sessionID: "s1", clientName: "c", deliveredTokens: 500,
            deliveredAt: Date(), lastResourceReadAt: nil, lastReadHash: nil, isFresh: nil)
        try expect(DeliveryAuditLabels.deliveredLabel(for: noRead) == "Delivered · 500 tok",
                   "delivered label present when a handshake was recorded")
        try expect(DeliveryAuditLabels.fetchedLabel(for: noRead) == nil,
                   "NO read → no 'Fetched' label (absence is NOT rendered as 'not honored')")

        // A session that delivered AND has a read.
        let withRead = SessionAudit(
            sessionID: "s2", clientName: "c", deliveredTokens: 800,
            deliveredAt: Date(), lastResourceReadAt: Date(), lastReadHash: "H", isFresh: true)
        try expect(DeliveryAuditLabels.fetchedLabel(for: withRead) == "Fetched ✓",
                   "a real read → 'Fetched ✓'")

        // No handshake recorded → no delivered label (defensive).
        let noHandshake = SessionAudit(
            sessionID: "s3", clientName: "c", deliveredTokens: nil,
            deliveredAt: nil, lastResourceReadAt: Date(), lastReadHash: "H", isFresh: true)
        try expect(DeliveryAuditLabels.deliveredLabel(for: noHandshake) == nil,
                   "no handshake → no delivered label")

        // The honesty invariant: NEITHER label ever says "Honored".
        for row in [noRead, withRead, noHandshake] {
            let combined = (DeliveryAuditLabels.deliveredLabel(for: row) ?? "")
                + (DeliveryAuditLabels.fetchedLabel(for: row) ?? "")
            try expect(!combined.localizedCaseInsensitiveContains("honored"),
                       "the server NEVER claims a client 'Honored' the orders")
        }
    }
}

// MARK: - Test fixture helpers (local, not exported)

/// Poll a main-actor-evaluated condition until it holds or a bounded number of
/// turns elapse. The `record*` / prune APIs hop to the main actor on an
/// UNAWAITED `Task { @MainActor }`, so the caller must let that hop land; a
/// fixed sleep is load-fragile, so we re-check on a short interval and return
/// the final state. Returns `true` as soon as the condition holds.
private func waitForDeliveryHop(
    timeoutMs: Int = 2000,
    _ condition: @MainActor @escaping () -> Bool
) async -> Bool {
    let stepMs = 10
    var elapsed = 0
    while elapsed < timeoutMs {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
        elapsed += stepMs
    }
    return await MainActor.run(body: condition)
}

private func withDeliveryTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("DeliveryAuditWave3-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
