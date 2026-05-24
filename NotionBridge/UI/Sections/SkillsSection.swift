// SkillsSection.swift — Settings → Skills pane.
// PKT-3 v3.5: Skills promoted to its own top-level Settings section
// (previously nested inside Commands). Wraps the existing SkillsView
// CRUD with a Liquid-Glass-themed header so it slots into the new shell.

import SwiftUI

public struct SkillsSection: View {
    @State private var skillsManager = SkillsManager()
    private let fetchSkillDisabled: Bool

    public init(fetchSkillDisabled: Bool = false) {
        self.fetchSkillDisabled = fetchSkillDisabled
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
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
