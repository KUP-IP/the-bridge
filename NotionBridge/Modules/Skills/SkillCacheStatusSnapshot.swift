// SkillCacheStatusSnapshot.swift — PKT-1003 Skills Truth-Up · Wave B
// NotionBridge · Modules · Skills
//
// A pure, Sendable value snapshot of the TWO honest cache layers, computed once
// off the SwiftUI render path and handed to SkillsView so the row pip, the
// counts, and the detail-pane indicators all read REAL store state instead of
// the old `!summary.isEmpty` proxy.
//
//   • Routing synced — the parent/routing cache (SkillsCacheReader, feeds the
//     routing index + Standing Orders). A workspace-level boolean.
//   • Body cached    — the per-skill body store (SkillBodyCacheStore.state),
//     keyed by Notion page id.
//
// Decision #3 (ratified 2026-06-16): two honest indicators, each reading its
// real store state. This type is the pure mapping layer the UI binds to; the
// async store reads happen in SkillsSection and are folded into a snapshot.

import Foundation

/// Per-skill body-cache state, normalized for page-id lookup. Built from the
/// async `SkillBodyCacheStore.state(pageId:)` reads so the view can do a
/// synchronous, render-safe lookup.
public struct SkillBodyCacheSnapshot: Sendable, Equatable {
    /// normalizedPageId → (cached, stale). Absent key ⇒ not cached.
    private let entries: [String: BodyState]

    public struct BodyState: Sendable, Equatable {
        public let cached: Bool
        public let stale: Bool
        public init(cached: Bool, stale: Bool) {
            self.cached = cached
            self.stale = stale
        }
    }

    public init(entries: [String: BodyState] = [:]) {
        var normalized: [String: BodyState] = [:]
        for (k, v) in entries {
            normalized[Self.normalize(k)] = v
        }
        self.entries = normalized
    }

    /// Page-id normalization matching the body store's on-disk key rule
    /// (strip dashes/whitespace, lowercase) so a URL-form or dashed id from the
    /// UI resolves to the same entry the store wrote.
    public static func normalize(_ pageId: String) -> String {
        pageId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    /// Is a body stored for this page id? Empty/blank id ⇒ false.
    public func isCached(_ pageId: String) -> Bool {
        let key = Self.normalize(pageId)
        guard !key.isEmpty else { return false }
        return entries[key]?.cached ?? false
    }

    /// Is the stored body past its TTL? False when absent or fresh.
    public func isStale(_ pageId: String) -> Bool {
        let key = Self.normalize(pageId)
        guard !key.isEmpty else { return false }
        return entries[key]?.stale ?? false
    }

    /// Count of the given page ids that have a stored body. Used by the list
    /// counts row (`N cached`).
    public func cachedCount<S: Sequence>(amongPageIds ids: S) -> Int where S.Element == String {
        ids.reduce(0) { $0 + (isCached($1) ? 1 : 0) }
    }
}
