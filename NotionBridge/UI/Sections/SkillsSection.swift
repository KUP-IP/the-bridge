// SkillsSection.swift — Settings → Skills pane.
// PKT-3 v3.5: Skills promoted to its own top-level Settings section
// (previously nested inside Commands).
// v3.7.2 bundle-2 redesign: carbon-canvas scaffold + hero (bow&arrow orb,
// stat tiles, quick actions) over the twin master–detail SkillsView, mirroring
// the approved Standing Orders redesign. The cache card keeps its real
// SkillsCacheWriter logic verbatim; only the chrome was restyled to
// BridgeTokens. No bindings changed.

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
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    // MARK: - Hero

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BridgeTokens.accent.opacity(0.22))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 1))
                    BridgeVectorIcon(.skills)
                        .foregroundStyle(BridgeTokens.accentLink)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Skills")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("Routing skills are surfaced to MCP clients in the Standing Orders index. Toggle, edit, or fetch from Notion.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    statTile(value: "\(skillsManager.skills.count)", label: "skills", color: BridgeTokens.gold)
                    statTile(value: "\(routingCount)", label: "routing", color: BridgeTokens.ok)
                }
            }
        }
    }

    private var routingCount: Int {
        skillsManager.skills.filter { $0.enabled && $0.routingDiscoverable }.count
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    // MARK: - Cache card

    /// v3.7·1: Operator-action card that refreshes the on-disk Notion
    /// skills cache. The cache feeds the routing index + Standing Orders
    /// composer; the first-load refresh runs automatically in
    /// `SkillsManager`, this button is the manual override.
    private var cacheCard: some View {
        BridgeGlassCard {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BridgeTokens.accentLink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skill cache")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("Re-enumerates every Notion-source routing skill's child pages.")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer()
                if let msg = cacheMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(cacheIsError ? BridgeTokens.bad : BridgeTokens.fg3)
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
}
