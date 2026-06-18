// SkillsCacheTests.swift — Bridge v3.7·A
// TheBridge · Tests
//
// Coverage for the on-disk skills cache pipeline:
//   - CachedParent / CachedSpecialist persistence schema (forwards-tolerant
//     decode, round-trip stability).
//   - SkillsCacheReader: read(parentId:), readAll(), TTL boundary + stale
//     flag semantics, missing-entry graceful nil, BridgePaths resolution.
//   - SkillsCacheWriter: atomic write, last-writer-wins under concurrent
//     dispatch, refreshAll() idempotency.
//   - BridgeDefaults.skillsCacheTTLHours UserDefaults override propagating
//     through skillsCacheTTLHoursEffective.
//
// Test isolation: every test runs under a fresh tmpdir routed through
// BridgePaths.overrideHomeForTesting(_:). The override is per-process —
// tests serialize their use of the seam and restore it in a `defer`.
//
// Closes the v3.7·A test wave for PKT-907 carve-out (Notion-source eager
// enumeration) and the v3.6·5 StandingOrders cachedRoutingSkills TODO.

import Foundation
import TheBridgeLib

// MARK: - Test fixture helpers

/// Sandbox HOME for a single test. The override is per-process; the
/// `defer` block restores it so the suite stays hermetic regardless of
/// success/failure path.
private func withTempHome(_ body: (URL) async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-skillscachetest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: tmp)
    }
    try await body(tmp)
}

/// Build a deterministic CachedParent for a given parentId + writtenAt.
/// Children are intentionally non-sorted so the writer's sort-on-encode
/// can be exercised by the round-trip tests.
private func sampleParent(
    id: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    title: String = "Sample Parent",
    writtenAt: Date = Date(),
    ttlHours: Int = 24,
    children: [CachedSpecialist] = [
        CachedSpecialist(id: "cccccccccccccccccccccccccccccccc", title: "Charlie", summary: "third"),
        CachedSpecialist(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab", title: "Alice", summary: "first", aliases: ["a", "al"]),
        CachedSpecialist(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", title: "Bob", summary: "second"),
    ]
) -> CachedParent {
    return CachedParent(
        writtenAt: writtenAt,
        ttlHours: ttlHours,
        parentId: id,
        parentTitle: title,
        children: children
    )
}

/// Compute the canonical on-disk path the reader/writer agree on, without
/// depending on the internal `fileURL(for:)` helper. Mirrors the
/// normalization rule (strip dashes/whitespace, lowercase, `.json`).
private func cacheFileURL(for parentId: String) -> URL {
    let normalized = parentId
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
    return BridgePaths.applicationSupport(.skillsCache)
        .appendingPathComponent("\(normalized).json", isDirectory: false)
}

// MARK: - Runner

func runSkillsCacheTests() async {
    print("\n\u{1F4E6} v3.7·A SkillsCacheReader/Writer")

    // -----------------------------------------------------------------
    // 1. Write → read round-trip preserves the full CachedParent shape.
    // -----------------------------------------------------------------
    await test("write→read round-trip preserves parent + children + writtenAt + ttlHours") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let parent = sampleParent(writtenAt: now, ttlHours: 12)
            try await writer.write(parent: parent)

            let reader = SkillsCacheReader(clock: { now })
            guard let got = await reader.read(parentId: parent.parentId) else {
                throw TestError.assertion("expected non-nil read after write")
            }
            try expect(got.parentId == parent.parentId, "parentId mismatch")
            try expect(got.parentTitle == parent.parentTitle, "parentTitle mismatch")
            try expect(got.ttlHours == 12, "ttlHours mismatch: got \(got.ttlHours)")
            try expect(got.children.count == 3, "children count mismatch: \(got.children.count)")
            // ISO-8601 string carries millisecond precision; tolerate sub-second
            // drift from the fractional-seconds round-trip.
            let drift = abs(got.writtenAt.timeIntervalSince(now))
            try expect(drift < 1.0, "writtenAt drift > 1s: \(drift)")
            // Round-trip preserves all child fields (alphabetized by writer).
            let alice = got.children.first(where: { $0.title == "Alice" })
            try expect(alice != nil, "Alice missing")
            try expect(alice?.aliases == ["a", "al"], "aliases lost: \(String(describing: alice?.aliases))")
            try expect(alice?.summary == "first", "summary lost")
            // Fresh write → not stale.
            try expect(got.stale == false, "fresh entry should not be stale")
        }
    }

    // -----------------------------------------------------------------
    // 2. Multi-parent isolation: two parents land in two files, reads
    //    return the right one without cross-contamination.
    // -----------------------------------------------------------------
    await test("multi-parent isolation — per-file storage, no cross-contamination") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let p1 = sampleParent(id: "1111111111111111111111111111aaaa", title: "P1")
            let p2 = sampleParent(id: "2222222222222222222222222222bbbb", title: "P2",
                                  children: [CachedSpecialist(id: "ddddddddddddddddddddddddddddddd0", title: "Delta")])
            try await writer.write(parent: p1)
            try await writer.write(parent: p2)

            let reader = SkillsCacheReader()
            let got1 = await reader.read(parentId: p1.parentId)
            let got2 = await reader.read(parentId: p2.parentId)
            try expect(got1?.parentTitle == "P1", "expected P1 title")
            try expect(got2?.parentTitle == "P2", "expected P2 title")
            try expect(got1?.children.count == 3, "P1 children count")
            try expect(got2?.children.count == 1, "P2 children count")
            try expect(got1?.children.contains(where: { $0.title == "Delta" }) == false,
                       "P1 must not see P2's children")
        }
    }

    // -----------------------------------------------------------------
    // 3. readAll() returns every parent (order-independent set check).
    // -----------------------------------------------------------------
    await test("readAll() lists all parents — set semantics, no missing entries") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let ids = [
                "00000000000000000000000000000001",
                "00000000000000000000000000000002",
                "00000000000000000000000000000003",
            ]
            for id in ids {
                try await writer.write(parent: sampleParent(id: id, title: "T-\(id)"))
            }
            let all = await SkillsCacheReader().readAll()
            try expect(all.count == 3, "expected 3 entries, got \(all.count)")
            let got = Set(all.map { $0.parentId })
            try expect(got == Set(ids), "id set mismatch: \(got)")
        }
    }

    // -----------------------------------------------------------------
    // 4. TTL boundary: writtenAt + ttlHours window → NOT stale.
    // -----------------------------------------------------------------
    await test("TTL boundary: fresh entry within window → stale=false") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
            let parent = sampleParent(writtenAt: writtenAt, ttlHours: 24)
            try await writer.write(parent: parent)

            // Clock 1 hour after writtenAt — well within the 24h TTL.
            let clock: @Sendable () -> Date = { writtenAt.addingTimeInterval(3600) }
            let reader = SkillsCacheReader(clock: clock)
            let got = await reader.read(parentId: parent.parentId)
            try expect(got?.stale == false, "expected fresh, got stale=\(String(describing: got?.stale))")
        }
    }

    // -----------------------------------------------------------------
    // 5. TTL exceeded: clock past the TTL → stale=true.
    // -----------------------------------------------------------------
    await test("TTL exceeded: clock past ttlHours → stale=true") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
            let parent = sampleParent(writtenAt: writtenAt, ttlHours: 24)
            try await writer.write(parent: parent)

            // Clock 25 hours after writtenAt — past the 24h TTL.
            let clock: @Sendable () -> Date = { writtenAt.addingTimeInterval(25 * 3600) }
            let reader = SkillsCacheReader(clock: clock)
            let got = await reader.read(parentId: parent.parentId)
            try expect(got?.stale == true, "expected stale=true, got \(String(describing: got?.stale))")
        }
    }

    // -----------------------------------------------------------------
    // 6. Stale entries are still returned (graceful-fallback contract).
    // -----------------------------------------------------------------
    await test("stale entries still readable — data returned alongside stale=true") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
            let parent = sampleParent(writtenAt: writtenAt, ttlHours: 1)
            try await writer.write(parent: parent)

            let clock: @Sendable () -> Date = { writtenAt.addingTimeInterval(10 * 3600) }
            let reader = SkillsCacheReader(clock: clock)
            let got = await reader.read(parentId: parent.parentId)
            try expect(got != nil, "stale entry must still be returned, not nil")
            try expect(got?.children.count == 3, "stale entry must still carry children")
            try expect(got?.stale == true, "stale flag must be set")
        }
    }

    // -----------------------------------------------------------------
    // 7. Missing parent → graceful nil (no throw, no log).
    // -----------------------------------------------------------------
    await test("missing parent → read(parentId:) returns nil gracefully") {
        try await withTempHome { _ in
            let reader = SkillsCacheReader()
            let got = await reader.read(parentId: "ffffffffffffffffffffffffffffffff")
            try expect(got == nil, "expected nil for missing entry, got \(String(describing: got))")
        }
    }

    // -----------------------------------------------------------------
    // 8. BridgePaths resolution: cache files land under
    //    applicationSupport(.skillsCache).
    // -----------------------------------------------------------------
    await test("BridgePaths resolution — file lands under applicationSupport(.skillsCache)") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let parent = sampleParent(id: "99999999999999999999999999999999")
            try await writer.write(parent: parent)
            let dir = BridgePaths.applicationSupport(.skillsCache)
            let expected = dir.appendingPathComponent("99999999999999999999999999999999.json")
            try expect(FileManager.default.fileExists(atPath: expected.path),
                       "expected file at \(expected.path)")
            // Parent dir must be the skills-cache subdir, not a sibling.
            try expect(expected.deletingLastPathComponent().lastPathComponent == "skills-cache",
                       "wrong parent dir: \(expected.deletingLastPathComponent().lastPathComponent)")
        }
    }

    // -----------------------------------------------------------------
    // 9. JSON forwards-tolerant decode: unknown extra keys are ignored.
    // -----------------------------------------------------------------
    await test("forwards-tolerant decode — unknown keys do not break read") {
        try await withTempHome { _ in
            let dir = try BridgePaths.ensureApplicationSupport(.skillsCache)
            let pid = "deadbeefdeadbeefdeadbeefdeadbeef"
            let file = dir.appendingPathComponent("\(pid).json")
            // Hand-crafted JSON with unknown top-level + unknown child key.
            // Writer would never emit `futureFlag` or `extraChildField` but
            // future writer revisions might — older readers must survive.
            let writtenAtISO = "2026-05-27T10:00:00.000Z"
            let json = """
            {
              "writtenAt": "\(writtenAtISO)",
              "ttlHours": 24,
              "parentId": "\(pid)",
              "parentTitle": "Future-Schema Parent",
              "futureFlag": "ignore-me",
              "children": [
                {
                  "id": "aaaa1111aaaa1111aaaa1111aaaa1111",
                  "title": "Future Child",
                  "summary": "x",
                  "aliases": [],
                  "extraChildField": 42
                }
              ]
            }
            """
            try json.write(to: file, atomically: true, encoding: .utf8)

            let reader = SkillsCacheReader()
            guard let got = await reader.read(parentId: pid) else {
                throw TestError.assertion("unknown-key JSON must still decode")
            }
            try expect(got.parentTitle == "Future-Schema Parent", "title decode failed")
            try expect(got.children.count == 1, "children decode failed")
            try expect(got.children[0].title == "Future Child", "child title decode failed")
        }
    }

    // -----------------------------------------------------------------
    // 10. Concurrent-write safety: two writes serialize through the
    //     actor; no corruption, last-writer-wins.
    // -----------------------------------------------------------------
    await test("concurrent writes to same parent serialize — last-writer-wins, no corruption") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let pid = "concurrent11111111111111111111aa"
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let parentA = sampleParent(id: pid, title: "A", writtenAt: now, ttlHours: 24,
                                       children: [CachedSpecialist(id: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1", title: "A-child")])
            let parentB = sampleParent(id: pid, title: "B", writtenAt: now.addingTimeInterval(1), ttlHours: 24,
                                       children: [CachedSpecialist(id: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2", title: "B-child")])

            // Fan out 10 writes alternating between A and B through a
            // TaskGroup — the actor mailbox must serialize them.
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<10 {
                    group.addTask {
                        let p = (i % 2 == 0) ? parentA : parentB
                        try? await writer.write(parent: p)
                    }
                }
            }

            let reader = SkillsCacheReader()
            guard let got = await reader.read(parentId: pid) else {
                throw TestError.assertion("expected readable entry after concurrent writes")
            }
            // Must decode cleanly to one of the two payloads — corruption
            // would surface here as a decode failure (nil) or a torn mix.
            let titleOK = (got.parentTitle == "A" || got.parentTitle == "B")
            try expect(titleOK, "torn write: title=\(got.parentTitle)")
            try expect(got.children.count == 1, "torn write: children=\(got.children.count)")
            let childTitle = got.children[0].title
            try expect(childTitle == "A-child" || childTitle == "B-child",
                       "torn write: child=\(childTitle)")
            // Title and child must be consistent with EACH OTHER (i.e. we
            // got a coherent A-write OR a coherent B-write — not "A title
            // + B child", which would indicate a partial write was read).
            if got.parentTitle == "A" {
                try expect(childTitle == "A-child", "inconsistent payload: A title + non-A child")
            } else {
                try expect(childTitle == "B-child", "inconsistent payload: B title + non-B child")
            }
        }
    }

    // -----------------------------------------------------------------
    // 11. BridgeDefaults.skillsCacheTTLHours override changes the
    //     stale boundary via skillsCacheTTLHoursEffective.
    // -----------------------------------------------------------------
    await test("BridgeDefaults.skillsCacheTTLHours override changes stale boundary") {
        try await withTempHome { _ in
            // Snapshot + restore the user-defaults key so this test is
            // hermetic regardless of suite-order or prior test contamination.
            let key = BridgeDefaults.skillsCacheTTLHours
            let saved = UserDefaults.standard.object(forKey: key)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }

            // Default: missing/<=0 → 24h.
            UserDefaults.standard.removeObject(forKey: key)
            try expect(BridgeDefaults.skillsCacheTTLHoursEffective == 24,
                       "default TTL must be 24, got \(BridgeDefaults.skillsCacheTTLHoursEffective)")
            // Non-positive → still 24 (defensive).
            UserDefaults.standard.set(0, forKey: key)
            try expect(BridgeDefaults.skillsCacheTTLHoursEffective == 24,
                       "zero TTL must fall back to 24")
            UserDefaults.standard.set(-5, forKey: key)
            try expect(BridgeDefaults.skillsCacheTTLHoursEffective == 24,
                       "negative TTL must fall back to 24")
            // Positive override → effective value flows through.
            UserDefaults.standard.set(6, forKey: key)
            try expect(BridgeDefaults.skillsCacheTTLHoursEffective == 6,
                       "override TTL=6 must flow through")

            // Now exercise the boundary end-to-end via refreshAll(): a
            // parent written with ttlHours=6 + clock advanced 7h must be
            // stale; same parent with ttlHours=24 + clock advanced 7h
            // must be fresh.
            let writer = SkillsCacheWriter()
            let pid = "00000000000000000000000000000abc"
            let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
            let source = SkillsCacheWriter.ParentSource(load: {
                [SkillsCacheWriter.ParentSource.Parent(id: pid, title: "TTLProbe")]
            })
            let enumerator = SkillsCacheWriter.ChildEnumerator(listChildren: { _ in
                [CachedSpecialist(id: "x1x1x1x1x1x1x1x1x1x1x1x1x1x1x1x1", title: "X")]
            })
            _ = await writer.refreshAll(source: source, enumerator: enumerator,
                                        ttlHours: BridgeDefaults.skillsCacheTTLHoursEffective,
                                        now: writtenAt)

            let clock: @Sendable () -> Date = { writtenAt.addingTimeInterval(7 * 3600) }
            let reader = SkillsCacheReader(clock: clock)
            let got = await reader.read(parentId: pid)
            try expect(got?.ttlHours == 6, "writer must persist effective ttlHours, got \(String(describing: got?.ttlHours))")
            try expect(got?.stale == true, "7h > 6h TTL must be stale")
        }
    }

    // -----------------------------------------------------------------
    // 12. refreshAll() idempotency — same inputs → same on-disk state
    //     (children sorted deterministically, decoded round-trip stable).
    // -----------------------------------------------------------------
    await test("refreshAll() idempotent — same inputs → same decoded on-disk state") {
        try await withTempHome { _ in
            let writer = SkillsCacheWriter()
            let pid = "ababababababababababababababcdcd"
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let source = SkillsCacheWriter.ParentSource(load: {
                [SkillsCacheWriter.ParentSource.Parent(id: pid, title: "Idem")]
            })
            let enumerator = SkillsCacheWriter.ChildEnumerator(listChildren: { _ in
                [
                    CachedSpecialist(id: "cccccccccccccccccccccccccccccccc", title: "Charlie"),
                    CachedSpecialist(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", title: "Alpha"),
                    CachedSpecialist(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", title: "Bravo"),
                ]
            })

            let n1 = await writer.refreshAll(source: source, enumerator: enumerator,
                                             ttlHours: 24, now: now)
            try expect(n1 == 1, "refreshAll first pass must report 1 parent, got \(n1)")
            let file = cacheFileURL(for: pid)
            let bytes1 = try Data(contentsOf: file)

            let n2 = await writer.refreshAll(source: source, enumerator: enumerator,
                                             ttlHours: 24, now: now)
            try expect(n2 == 1, "refreshAll second pass must report 1 parent, got \(n2)")
            let bytes2 = try Data(contentsOf: file)

            // With identical `now` + sorted-keys + sorted-children, the
            // on-disk bytes must be byte-identical between passes. (Any
            // future change that introduces a non-deterministic field —
            // e.g. an unsorted set — should fail this test loudly.)
            try expect(bytes1 == bytes2, "refreshAll not byte-idempotent: \(bytes1.count) vs \(bytes2.count) bytes")

            // And the decoded shape must match: writer sorts children by
            // id ascending (Alpha < Bravo < Charlie when sorted by id —
            // ids start with aaa..., bbb..., ccc... respectively).
            let reader = SkillsCacheReader(clock: { now })
            guard let got = await reader.read(parentId: pid) else {
                throw TestError.assertion("expected entry after refreshAll")
            }
            try expect(got.children.map(\.title) == ["Alpha", "Bravo", "Charlie"],
                       "children not deterministically sorted: \(got.children.map(\.title))")
        }
    }
}
