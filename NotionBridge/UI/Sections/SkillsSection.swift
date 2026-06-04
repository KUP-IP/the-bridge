// SkillsSection.swift — Settings → Skills pane.
// PKT-3 v3.5: Skills promoted to its own top-level Settings section
// (previously nested inside Commands). Wraps the existing SkillsView
// CRUD with a Liquid-Glass-themed header so it slots into the new shell.

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
        ScrollView {
            VStack(spacing: 14) {
                hero
                cacheCard
                BridgeGlassCard(padding: 0) {
                    SkillsView(
                        skillsManager: skillsManager,
                        fetchSkillDisabled: fetchSkillDisabled
                    )
                    .padding(.vertical, 4)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    /// v3.7·1: Operator-action card that refreshes the on-disk Notion
    /// skills cache. The cache feeds the routing index + Standing Orders
    /// composer; the first-load refresh runs automatically in
    /// `SkillsManager`, this button is the manual override for when an
    /// operator added a new child page in Notion and wants the routing
    /// hints to reflect it without waiting for the TTL.
    private var cacheCard: some View {
        BridgeGlassCard {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.66, green: 0.78, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skill cache")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Re-enumerates every Notion-source routing skill's child pages.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let msg = cacheMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(cacheIsError ? BridgeTokens.bad : .secondary)
                }
                Button {
                    Task { await refreshCache() }
                } label: {
                    if cacheBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh skill cache")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(cacheBusy)
            }
        }
    }

    /// Run `SkillsCacheWriter.refreshAll()` against the live Notion
    /// client + current `SkillsManager` snapshot. Surfaces success /
    /// failure via the inline status text — the cache is a hint, so a
    /// failure here never blocks any other Settings flow.
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

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(NotionPalette.blue.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.66, green: 0.78, blue: 1.0))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Routing skills are surfaced to MCP clients in the Standing Orders index. Toggle, edit, or fetch from Notion.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}
