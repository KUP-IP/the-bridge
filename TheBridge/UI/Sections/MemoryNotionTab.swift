// MemoryNotionTab.swift — Settings → Memory → Notion tab (PKT-MEM-104)
// TheBridge · UI · Sections

import SwiftUI
import AppKit

public struct MemoryNotionTab: View {
    @StateObject private var vm = MemoryNotionViewModel()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                HStack {
                    Spacer(minLength: 0)
                    BridgeButton("Refresh", systemImage: "arrow.clockwise") {
                        Task { await vm.refresh() }
                    }
                    .disabled(vm.busy)
                    .accessibilityIdentifier(BridgeAXID.Memory.notionRefresh)
                }
                if !vm.status.isEmpty {
                    Text(vm.status)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                if vm.rows.isEmpty {
                    emptyState
                } else {
                    ForEach(vm.rows, id: \.pageId) { row in
                        notionRow(row)
                    }
                }
            }
            .padding(.horizontal, BridgeTokens.Space.paneH)
            .padding(.vertical, BridgeTokens.Space.cardGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.notionList)
        .overlay {
            if vm.busy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task { await vm.load() }
    }

    private var emptyState: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("No Notion Memory rows")
                Text("Recent Memory registry rows appear here after capture or registry_create.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func notionRow(_ row: CachedRow) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title.isEmpty ? "Untitled" : row.title)
                        .font(BridgeTokens.Typeface.name)
                        .foregroundStyle(BridgeTokens.fg1)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if row.isExpired() {
                        BridgeBadge("Stale", tone: .warn)
                    } else {
                        BridgeBadge("Cached", tone: .info)
                    }
                }
                Text(editedLabel(row.lastEditedTime))
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
                HStack(spacing: 8) {
                    BridgeButton("Open in Notion", systemImage: "arrow.up.right.square") {
                        openURL(row.url)
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.notionOpen)
                    Spacer(minLength: 0)
                    Button {
                        SettingsNavigation.shared.go(.datasources)
                    } label: {
                        Text("Data Sources")
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.accentLink)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier(BridgeAXID.Memory.notionRow)
    }

    private func editedLabel(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return "Edited \(display.string(from: date))"
        }
        return "Edited \(iso)"
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
