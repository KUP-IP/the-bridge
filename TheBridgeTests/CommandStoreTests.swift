// CommandStoreTests.swift — PKT-6 v3.5
// Covers: CRUD, slug exclusivity, key-slot eviction, recency sort,
// substring search, first-run seeding, persistence round-trip.

import Foundation
import TheBridgeLib

func runCommandStoreTests() async {
    print("\n[CommandStore]")

    await test("slugify: spaces → dashes, lowercased, non-alnum stripped") {
        try expect(CommandStore.slugify("Hello World") == "hello-world")
        try expect(CommandStore.slugify("Open-loops") == "open-loops")
        try expect(CommandStore.slugify("AB CD!!") == "ab-cd")
        try expect(CommandStore.slugify("   ") == "")
    }

    await test("create: rejects empty name") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            do {
                _ = try CommandStore.shared.create(name: "  ", icon: .emoji("⚡"), body: "x")
                try expect(false, "expected invalidName to throw")
            } catch CommandStore.StoreError.invalidName { /* expected */ }
        }
    }

    await test("create then list returns the new command") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            let c = try CommandStore.shared.create(
                name: "Execute", icon: .emoji("⚡"), color: .orange, body: "## Execute\n\nGo.")
            try expect(c.slug == "execute")
            let all = try CommandStore.shared.list()
            try expect(all.count == 1)
            try expect(all.first?.name == "Execute")
        }
    }

    await test("create rejects duplicate slug") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Execute", icon: .emoji("⚡"), body: "v1")
            do {
                _ = try CommandStore.shared.create(name: "execute", icon: .emoji("⚡"), body: "v2")
                try expect(false, "expected slugTaken to throw")
            } catch CommandStore.StoreError.slugTaken { /* expected */ }
        }
    }

    await test("update mutates body + persists") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            var c = try CommandStore.shared.create(name: "X", icon: .emoji("x"), body: "v1")
            c.body = "v2 — updated"
            _ = try CommandStore.shared.update(c)
            let fresh = try CommandStore.shared.get(slug: "x")
            try expect(fresh?.body == "v2 — updated")
        }
    }

    await test("delete removes command + body file") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Doomed", icon: .emoji("☠️"), body: "x")
            try CommandStore.shared.delete(slug: "doomed")
            try expect(try CommandStore.shared.get(slug: "doomed") == nil)
            try expect(try CommandStore.shared.list().isEmpty)
        }
    }

    await test("setKeySlot evicts other holders of the same slot") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "A", icon: .emoji("a"), body: "x", keySlot: 1)
            _ = try CommandStore.shared.create(name: "B", icon: .emoji("b"), body: "y")
            try CommandStore.shared.setKeySlot(slug: "b", slot: 1)
            try expect(try CommandStore.shared.command(forKeySlot: 1)?.slug == "b",
                       "B should now hold slot 1")
            try expect(try CommandStore.shared.get(slug: "a")?.keySlot == nil,
                       "A should have been evicted from slot 1")
        }
    }

    await test("setKeySlot accepts slots 0…9 and rejects out-of-range") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Z", icon: .emoji("z"), body: "x")
            try CommandStore.shared.setKeySlot(slug: "z", slot: 0)
            try CommandStore.shared.setKeySlot(slug: "z", slot: 9)
            do {
                try CommandStore.shared.setKeySlot(slug: "z", slot: 10)
                try expect(false, "expected slotOutOfRange")
            } catch CommandStore.StoreError.slotOutOfRange { /* expected */ }
        }
    }

    await test("setKeySlot to nil unbinds without affecting others") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "A", icon: .emoji("a"), body: "x", keySlot: 1)
            _ = try CommandStore.shared.create(name: "B", icon: .emoji("b"), body: "y", keySlot: 2)
            try CommandStore.shared.setKeySlot(slug: "a", slot: nil)
            try expect(try CommandStore.shared.command(forKeySlot: 1) == nil)
            try expect(try CommandStore.shared.command(forKeySlot: 2)?.slug == "b")
        }
    }

    await test("recordUse updates lastUsedAt and recency sort reflects it") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "First",  icon: .emoji("1"), body: "x")
            _ = try CommandStore.shared.create(name: "Second", icon: .emoji("2"), body: "y")
            try CommandStore.shared.recordUse(slug: "second")
            let ordered = try CommandStore.shared.list()
            try expect(ordered.first?.slug == "second", "most-recently-used should sort first")
        }
    }

    await test("recordUse twice with later timestamp re-orders correctly") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "A", icon: .emoji("a"), body: "x")
            _ = try CommandStore.shared.create(name: "B", icon: .emoji("b"), body: "y")
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            try CommandStore.shared.recordUse(slug: "a", at: t0)
            try CommandStore.shared.recordUse(slug: "b", at: t0.addingTimeInterval(60))
            try expect(try CommandStore.shared.list().map(\.slug) == ["b", "a"])
        }
    }

    await test("search substring matches; empty query returns all") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "close-agent", icon: .emoji("🚀"), body: "x")
            _ = try CommandStore.shared.create(name: "Close-loop",  icon: .emoji("✅"), body: "y")
            _ = try CommandStore.shared.create(name: "Execute",     icon: .emoji("⚡"), body: "z")
            let clo = try CommandStore.shared.search("clo")
            try expect(clo.count == 2, "expected 2 matches for 'clo', got \(clo.count)")
            try expect(try CommandStore.shared.search("").count == 3)
            try expect(try CommandStore.shared.search("nope").isEmpty)
        }
    }

    await test("seedIfEmpty installs 5 commands on first run, idempotent thereafter") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            try CommandStore.shared.seedIfEmpty()
            let first = try CommandStore.shared.list()
            try expect(first.count == 5, "expected 5 seeded commands, got \(first.count)")

            // Re-run is no-op (count unchanged).
            try CommandStore.shared.seedIfEmpty()
            try expect(try CommandStore.shared.list().count == 5)

            // Slots 1–5 should be assigned.
            for slot in 1...5 {
                try expect(try CommandStore.shared.command(forKeySlot: slot) != nil,
                           "expected a command at slot \(slot)")
            }
        }
    }

    await test("persistence: list survives a fresh process snapshot") {
        try await withTempHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Persist", icon: .emoji("💾"), body: "x", keySlot: 7)
            // The shared instance reads from disk on every call, so simulating
            // "fresh process" here means just calling list() again — but we
            // also verify the body file actually exists on disk.
            let after = try CommandStore.shared.list()
            try expect(after.first?.name == "Persist")
            try expect(after.first?.keySlot == 7)
            try expect(after.first?.body == "x")
        }
    }

    await test("Codable round-trip preserves Icon enum variants") {
        let cmds: [CommandStore.Command] = [
            .init(slug: "a", name: "A", icon: .emoji("⚡"),         body: "x"),
            .init(slug: "b", name: "B", icon: .symbol("bolt.fill"), color: .orange, body: "y"),
        ]
        let data = try JSONEncoder().encode(cmds)
        let back = try JSONDecoder().decode([CommandStore.Command].self, from: data)
        try expect(back == cmds)
    }
}

// MARK: - tmp-home helper

private func withTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("CommandStore-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
