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

import SwiftUI

public struct SkillsSection: View {
    @State private var skillsManager = SkillsManager()
    @State private var cacheBusy: Bool = false
    @State private var cacheMessage: String? = nil
    @State private var cacheIsError: Bool = false
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
            onRefreshCache: { Task { await refreshCache() } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    // MARK: - Skill cache (demoted from a full-width card to the list overflow)

    /// v3.7·1: refreshes the on-disk Notion skills cache. The cache feeds the
    /// routing index + Standing Orders composer; the first-load refresh runs
    /// automatically in `SkillsManager`, this action is the manual override.
    /// PKT-skills: the trigger now lives in the list-column overflow menu;
    /// the logic below is unchanged.
    @MainActor
    private func refreshCache() async {
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
        cacheMessage = "Refreshed \(count) parent\(count == 1 ? "" : "s")"
        cacheIsError = false
    }
}
