// SkillsSection.swift — Settings → Skills pane.
// PKT-3 v3.5: Skills promoted to its own top-level Settings section
// (previously nested inside Commands).
// PKT-skills (settings redesign): collapsed to ONE full-height master–detail
// surface. The in-pane hero is gone (the titlebar carries the section name),
// the outer ScrollView is gone (only the list/detail columns scroll), and the
// standalone cache card is demoted into the list-column overflow menu. The real
// SkillsCacheWriter logic is preserved verbatim and surfaced to SkillsView via
// a closure + transient status bindings. No persistence/security bindings
// changed.
//
// PKT-1003 (Skills Truth-Up · Wave B): the TWO cache layers are now wired
// HONESTLY and separately.
//   • Routing synced — the parent/routing cache (SkillsCacheWriter.refreshAll →
//     SkillsCacheReader). Drives the "Routing synced" indicator + feeds the
//     routing index / Standing Orders.
//   • Body cached    — the per-skill body store (SkillBodyCacheStore.warmAll /
//     refresh / state). Drives the row pip, the `N cached` count, the detail
//     "Body cached" indicator, and the Cache-all/Cache-now/Refresh buttons.
// The buttons used to ALL fire the parent-cache refresh (the body store was a
// backend wired to nothing); they now drive the body store, and a real-state
// snapshot is folded back into the view after every op + on appear.

import SwiftUI

public struct SkillsSection: View {
    @State private var skillsManager = SkillsManager()
    @State private var cacheBusy: Bool = false
    @State private var cacheMessage: String? = nil
    @State private var cacheIsError: Bool = false
    /// Real body-store state, keyed by Notion page id. Refreshed after every
    /// cache op + on appear so the pip/counts/indicator read truth.
    @State private var bodyCacheSnapshot = SkillBodyCacheSnapshot()
    /// Real routing/parent-cache state: true when at least one fresh (non-stale)
    /// parent is on disk. Drives the "Routing synced" indicator.
    @State private var routingSynced: Bool = false
    private let fetchSkillDisabled: Bool

    public init(fetchSkillDisabled: Bool = false) {
        self.fetchSkillDisabled = fetchSkillDisabled
    }

    public var body: some View {
        // Edge-to-edge under the (foundation) titlebar — the page IS the
        // master–detail. No outer padding, no ScrollView, no hero card.
        SkillsView(
            skillsManager: skillsManager,
            fetchSkillDisabled: fetchSkillDisabled,
            cacheBusy: cacheBusy,
            cacheMessage: cacheMessage,
            cacheIsError: cacheIsError,
            bodyCacheSnapshot: bodyCacheSnapshot,
            routingSynced: routingSynced,
            onRefreshRoutingCache: { Task { await refreshRoutingCache() } },
            onCacheAllBodies: { Task { await cacheAllBodies() } },
            onRefreshBody: { pageId in Task { await refreshBody(pageId: pageId) } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { await refreshSnapshots() }
    }

    // MARK: - Routing/parent cache (the "Routing synced" layer)

    /// v3.7·1: refreshes the on-disk Notion routing/parent cache. The cache
    /// feeds the routing index + Standing Orders composer; the first-load
    /// refresh runs automatically in `SkillsManager`, this action is the manual
    /// override. PKT-1003: now distinct from the body-cache warm.
    @MainActor
    private func refreshRoutingCache() async {
        cacheBusy = true
        cacheMessage = nil
        cacheIsError = false
        defer { cacheBusy = false }
        guard let client = try? NotionClient() else {
            cacheMessage = "Notion token missing"
            cacheIsError = true
            return
        }
        let source = SkillsCacheWriter.ParentSource.fromSkillsManager(skillsManager)
        let enumerator = SkillsCacheWriter.ChildEnumerator.live(client: client)
        let count = await SkillsCacheWriter.shared.refreshAll(
            source: source,
            enumerator: enumerator
        )
        cacheMessage = "Synced \(count) routing parent\(count == 1 ? "" : "s")"
        cacheIsError = false
        await refreshSnapshots()
    }

    // MARK: - Body cache (the "Body cached" layer)

    /// "Cache all bodies" / "Cache now": fetch + store EVERY Notion-source
    /// skill body via the real body store, then refresh the snapshot.
    @MainActor
    private func cacheAllBodies() async {
        cacheBusy = true
        cacheMessage = nil
        cacheIsError = false
        defer { cacheBusy = false }
        guard let client = try? NotionClient() else {
            cacheMessage = "Notion token missing"
            cacheIsError = true
            return
        }
        let source = Self.bodySource(from: skillsManager)
        let warmed = await SkillBodyCacheStore.shared.warmAll(source: source, client: client)
        cacheMessage = "Cached \(warmed) skill bod\(warmed == 1 ? "y" : "ies")"
        cacheIsError = false
        await refreshSnapshots()
    }

    /// "Refresh" (single skill): re-pull + rewrite ONE body via the real body
    /// store, then refresh the snapshot.
    @MainActor
    private func refreshBody(pageId: String) async {
        let pid = pageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else { return }
        cacheBusy = true
        cacheMessage = nil
        cacheIsError = false
        defer { cacheBusy = false }
        guard let client = try? NotionClient() else {
            cacheMessage = "Notion token missing"
            cacheIsError = true
            return
        }
        let entry = await SkillBodyCacheStore.shared.refresh(pageId: pid, client: client)
        if entry == nil {
            cacheMessage = "Body refresh failed"
            cacheIsError = true
        } else {
            cacheMessage = "Body refreshed"
            cacheIsError = false
        }
        await refreshSnapshots()
    }

    // MARK: - Snapshot folding (async store reads → render-safe value)

    /// Read BOTH cache layers off the render path and fold them into value
    /// snapshots the view binds to. Body store: per-skill `state(pageId:)`.
    /// Routing cache: any fresh parent on disk.
    @MainActor
    private func refreshSnapshots() async {
        // Body store — one state read per Notion-source skill.
        let pageIds: [String] = skillsManager.skills.compactMap { skill in
            let pid = skill.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
            return pid.isEmpty ? nil : pid
        }
        let store = SkillBodyCacheStore.shared
        var entries: [String: SkillBodyCacheSnapshot.BodyState] = [:]
        for pid in pageIds {
            let s = await store.state(pageId: pid)
            if s.cached {
                entries[pid] = .init(cached: true, stale: s.stale)
            }
        }
        bodyCacheSnapshot = SkillBodyCacheSnapshot(entries: entries)

        // Routing cache — synced when at least one fresh parent is on disk.
        let parents = await SkillsCacheReader.shared.readAll()
        routingSynced = parents.contains { !$0.stale }
    }

    /// Build a body-store `BodySource` from the manager's Notion-source skills
    /// (mirrors `SkillsCacheWriter.ParentSource.fromSkillsManager`). Snapshotted
    /// on the main actor; the captured array is value-typed + Sendable.
    @MainActor
    private static func bodySource(from manager: SkillsManager) -> SkillBodyCacheStore.BodySource {
        let snapshot: [(id: String, title: String)] = manager.skills.compactMap { skill in
            guard skill.source.isFile == false else { return nil }
            let pid = skill.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pid.isEmpty else { return nil }
            return (id: pid, title: skill.name)
        }
        return SkillBodyCacheStore.BodySource(load: { snapshot })
    }
}
