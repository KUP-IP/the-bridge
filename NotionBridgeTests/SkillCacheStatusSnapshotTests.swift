// SkillCacheStatusSnapshotTests.swift — PKT-1003 Skills Truth-Up · Wave B
// NotionBridge · Tests
//
// Locks the pure body-cache snapshot the UI binds to so the row pip, the
// `N cached` count, and the "Body cached" indicator read REAL store state
// (SkillBodyCacheStore) instead of the old `!summary.isEmpty` proxy.
//
// Covers: page-id normalization (dashed/URL-ish/whitespace → store key),
// cached/stale lookups, empty-id guard, and the cached-count helper used by
// the counts row. Pure value-type assertions — no actor, no filesystem.

import Foundation
import NotionBridgeLib

func runSkillCacheStatusSnapshotTests() async {
    print("\n\u{1F4BE} PKT-1003 SkillBodyCacheSnapshot (real body-store state for pip + counts)")

    let dashed = "114b3fe3-cbaf-4656-887f-4466a10cfcb3"
    let bare   = "114b3fe3cbaf4656887f4466a10cfcb3"

    // -----------------------------------------------------------------
    // 1. A stored page id is found via any id shape (normalization).
    // -----------------------------------------------------------------
    await test("snapshot: cached lookup is normalization-tolerant (dashed vs bare vs spaced)") {
        let snap = SkillBodyCacheSnapshot(entries: [
            dashed: .init(cached: true, stale: false)
        ])
        try expect(snap.isCached(dashed), "dashed id should resolve")
        try expect(snap.isCached(bare), "bare id should resolve to the same entry")
        try expect(snap.isCached("  \(dashed.uppercased())  "), "spaced/upper id should resolve")
    }

    // -----------------------------------------------------------------
    // 2. An absent page id is NOT cached (and an empty id never is).
    // -----------------------------------------------------------------
    await test("snapshot: absent + empty ids are not cached") {
        let snap = SkillBodyCacheSnapshot(entries: [bare: .init(cached: true, stale: false)])
        try expect(snap.isCached("ffffffffffffffffffffffffffffffff") == false, "absent id reported cached")
        try expect(snap.isCached("") == false, "empty id reported cached")
        try expect(snap.isCached("   ") == false, "whitespace id reported cached")
    }

    // -----------------------------------------------------------------
    // 3. Stale flag is surfaced independently of cached.
    // -----------------------------------------------------------------
    await test("snapshot: stale flag tracks the stored entry; false when absent") {
        let snap = SkillBodyCacheSnapshot(entries: [
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": .init(cached: true, stale: true),
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": .init(cached: true, stale: false)
        ])
        try expect(snap.isStale("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "stale entry should report stale")
        try expect(snap.isStale("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") == false, "fresh entry should not be stale")
        try expect(snap.isStale("cccccccccccccccccccccccccccccccc") == false, "absent entry should not be stale")
    }

    // -----------------------------------------------------------------
    // 4. cachedCount(amongPageIds:) counts only the stored ids (the
    //    `N cached` count the list row computes).
    // -----------------------------------------------------------------
    await test("snapshot: cachedCount counts only stored page ids") {
        let snap = SkillBodyCacheSnapshot(entries: [
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": .init(cached: true, stale: false),
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": .init(cached: true, stale: true)
        ])
        let ids = [
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",            // cached (upper)
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",        // cached (dashed)
            "cccccccccccccccccccccccccccccccc",            // not cached
            ""                                              // empty → ignored
        ]
        try expect(snap.cachedCount(amongPageIds: ids) == 2, "expected 2 cached, got \(snap.cachedCount(amongPageIds: ids))")
    }

    // -----------------------------------------------------------------
    // 5. The default (empty) snapshot caches nothing — the honest
    //    "no bodies stored yet" baseline the pip/indicator start from.
    // -----------------------------------------------------------------
    await test("snapshot: default empty snapshot caches nothing") {
        let snap = SkillBodyCacheSnapshot()
        try expect(snap.isCached(bare) == false, "empty snapshot should cache nothing")
        try expect(snap.cachedCount(amongPageIds: [bare, dashed]) == 0, "empty snapshot count should be 0")
    }
}
