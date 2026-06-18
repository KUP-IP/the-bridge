// DeliveryLogTests.swift — W2 delivery telemetry.
//
// Covers DeliveryLog: ingest + per-(session,kind) latest rollup, the bounded
// recent-history ring (historyCap), the per-session audit projection, the
// truthful freshness logic (last read hash == current composition hash), and
// session prune on teardown. DeliveryLog is @MainActor; each test hops via
// `await MainActor.run`. Freshness is hermetic — a fresh DeliveryLog is built
// with an injected `currentHash` closure so no file I/O / singleton is touched.

import Foundation
import TheBridgeLib

func runDeliveryLogTests() async {
    print("\n[DeliveryLog]")

    await test("DeliveryLog: handshake then read rolls up to one session audit row") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "HASH_A" })
            log.ingest(.init(
                sessionID: "s1", clientName: "claude", kind: .handshakeDelivered,
                tokenCount: 1200, contentHash: "HASH_A"))
            log.ingest(.init(
                sessionID: "s1", clientName: "claude", kind: .resourceRead,
                uri: BridgeResources.standingOrdersURI, contentHash: "HASH_A"))
            let rows = log.sessions()
            try expect(rows.count == 1, "one session row, got \(rows.count)")
            let row = rows[0]
            try expect(row.sessionID == "s1")
            try expect(row.clientName == "claude")
            try expect(row.deliveredTokens == 1200, "delivered tokens carried from handshake")
            try expect(row.deliveredAt != nil)
            try expect(row.lastResourceReadAt != nil, "a read was recorded")
        }
    }

    await test("DeliveryLog: a session with no read reports nil read + nil freshness (NOT stale)") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "HASH_A" })
            log.ingest(.init(
                sessionID: "s1", clientName: "c", kind: .handshakeDelivered,
                tokenCount: 10, contentHash: "HASH_A"))
            let row = log.sessions().first
            try expect(row?.lastResourceReadAt == nil, "no read → nil read time")
            try expect(row?.isFresh == nil, "no read → freshness is nil (we never imply 'not honored')")
        }
    }

    await test("DeliveryLog: freshness is emerald when last read hash == current composition hash") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "HASH_CURRENT" })
            log.ingest(.init(
                sessionID: "s1", clientName: "c", kind: .resourceRead,
                uri: BridgeResources.standingOrdersURI, contentHash: "HASH_CURRENT"))
            let row = log.sessions().first
            try expect(row?.isFresh == true, "read hash matches current → fresh")
            try expect(row?.lastReadHash == "HASH_CURRENT")
        }
    }

    await test("DeliveryLog: freshness is stale when orders changed since the last read") {
        try await MainActor.run {
            // The read served HASH_OLD, but the live composition is now HASH_NEW.
            let log = DeliveryLog(currentHash: { _ in "HASH_NEW" })
            log.ingest(.init(
                sessionID: "s1", clientName: "c", kind: .resourceRead,
                uri: BridgeResources.standingOrdersURI, contentHash: "HASH_OLD"))
            let row = log.sessions().first
            try expect(row?.isFresh == false, "stale: read hash != current composition hash")
        }
    }

    await test("DeliveryLog: latest-per-kind keeps only the newest read for a session") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "H2" })
            let t0 = Date(timeIntervalSince1970: 1000)
            let t1 = Date(timeIntervalSince1970: 2000)
            log.ingest(.init(
                sessionID: "s1", clientName: "c", kind: .resourceRead,
                uri: "bridge://standing-orders", contentHash: "H1", at: t0))
            log.ingest(.init(
                sessionID: "s1", clientName: "c", kind: .resourceRead,
                uri: "bridge://routing-skills", contentHash: "H2", at: t1))
            let row = log.sessions().first
            try expect(row?.lastReadHash == "H2", "newest read wins the per-session rollup")
            try expect(row?.lastResourceReadAt == t1)
            try expect(row?.isFresh == true, "newest read served the current hash")
        }
    }

    await test("DeliveryLog: history ring is bounded at historyCap") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "H" })
            let overflow = DeliveryLog.historyCap + 50
            for i in 0..<overflow {
                log.ingest(.init(
                    sessionID: "s\(i)", clientName: "c", kind: .reminderToolCall,
                    uri: "reminders_list"))
            }
            let timeline = log.timeline(limit: overflow)
            try expect(timeline.count == DeliveryLog.historyCap,
                       "history capped at \(DeliveryLog.historyCap), got \(timeline.count)")
        }
    }

    await test("DeliveryLog: timeline is newest-first and respects the limit") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "H" })
            for i in 0..<10 {
                log.ingest(.init(
                    sessionID: "s\(i)", clientName: "c", kind: .handshakeDelivered,
                    tokenCount: i, contentHash: "H",
                    at: Date(timeIntervalSince1970: Double(i))))
            }
            let recent = log.timeline(limit: 3)
            try expect(recent.count == 3, "limit honored")
            try expect(recent[0].tokenCount == 9, "newest first")
            try expect(recent[2].tokenCount == 7)
        }
    }

    await test("DeliveryLog: reminderToolCall is recorded with the tool name (audit-only)") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "H" })
            log.ingest(.init(
                sessionID: "s1", clientName: "c", kind: .reminderToolCall,
                uri: "reminders_create"))
            let ev = log.timeline(limit: 1).first
            try expect(ev?.kind == .reminderToolCall)
            try expect(ev?.uri == "reminders_create", "tool name stored in uri field")
            try expect(ev?.contentHash == nil, "reminder events carry no composition hash")
        }
    }

    await test("DeliveryLog: prune drops a session from rows and timeline") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "H" })
            log.ingest(.init(
                sessionID: "s1", clientName: "a", kind: .handshakeDelivered,
                tokenCount: 1, contentHash: "H"))
            log.ingest(.init(
                sessionID: "s2", clientName: "b", kind: .handshakeDelivered,
                tokenCount: 2, contentHash: "H"))
            try expect(log.sessions().count == 2)
            log.prune(sessionID: "s1")
            let rows = log.sessions()
            try expect(rows.count == 1, "s1 pruned")
            try expect(rows[0].sessionID == "s2", "only s2 remains")
            try expect(log.timeline(limit: 50).allSatisfy { $0.sessionID == "s2" },
                       "no s1 events linger in the timeline")
        }
    }

    await test("DeliveryLog: sessions render in first-seen order") {
        try await MainActor.run {
            let log = DeliveryLog(currentHash: { _ in "H" })
            for sid in ["z", "a", "m"] {
                log.ingest(.init(
                    sessionID: sid, clientName: sid, kind: .handshakeDelivered,
                    tokenCount: 1, contentHash: "H"))
            }
            let order = log.sessions().map(\.sessionID)
            try expect(order == ["z", "a", "m"], "first-seen order preserved, got \(order)")
        }
    }
}
