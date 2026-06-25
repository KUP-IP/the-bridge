// MemoryAgentTab.swift — Settings → Memory → Agent tab (PKT-MEM-104)
// TheBridge · UI · Sections · read-only MemoryStore list

import SwiftUI

public struct MemoryAgentTab: View {
    @State private var entries: [MemoryEntry] = []
    @State private var status: String = ""
    @State private var busy = false
    @State private var scopeFilter: ScopeFilter = .all
    @State private var typeFilter: TypeFilter = .all

    public enum ScopeFilter: String, CaseIterable, Identifiable {
        case all, global, mac, project, people, skill, time

        public var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All scopes"
            default: return rawValue
            }
        }

        var scopeValue: String? { self == .all ? nil : rawValue }
    }

    public enum TypeFilter: String, CaseIterable, Identifiable {
        case all, fact, preference, decision, reference

        public var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All types"
            default: return rawValue.capitalized
            }
        }

        var entryType: MemoryEntry.EntryType? {
            MemoryEntry.EntryType(rawValue: rawValue)
        }
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                filterBar
                if !status.isEmpty {
                    Text(status)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                if entries.isEmpty {
                    emptyState
                } else {
                    ForEach(entries, id: \.id) { entry in
                        agentRow(entry)
                    }
                }
            }
            .padding(.horizontal, BridgeTokens.Space.paneH)
            .padding(.vertical, BridgeTokens.Space.cardGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.agentList)
        .overlay {
            if busy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task { await reload() }
        .onChange(of: scopeFilter) { _, _ in Task { await reload() } }
        .onChange(of: typeFilter) { _, _ in Task { await reload() } }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Scope", selection: $scopeFilter) {
                ForEach(ScopeFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(BridgeAXID.Memory.agentScopeFilter)

            Picker("Type", selection: $typeFilter) {
                ForEach(TypeFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(BridgeAXID.Memory.agentTypeFilter)
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("No agent memories")
                Text("Agent memories saved via memory_remember appear here. This view is read-only.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func agentRow(_ entry: MemoryEntry) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.text)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg1)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if entry.pinned {
                        BridgeBadge("Pinned", tone: .ok, showsDot: true)
                    }
                }
                HStack(spacing: 10) {
                    BridgeBadge(entry.scope, tone: .info)
                    BridgeBadge(entry.type.rawValue, tone: .info)
                    if let entity = entry.entity, !entity.isEmpty {
                        Text(entity)
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg4)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("Used \(entry.useCount)×")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                }
            }
        }
        .accessibilityIdentifier(BridgeAXID.Memory.agentRow)
    }

    private func reload() async {
        busy = true
        defer { busy = false }
        do {
            let store = MemoryStore.shared
            try await store.open()
            var list = try await store.list(scope: scopeFilter.scopeValue)
            if typeFilter != .all, let t = typeFilter.entryType {
                list = list.filter { $0.type == t }
            }
            entries = list
            status = entries.isEmpty
                ? "No memories match the current filters."
                : "\(entries.count) memor\(entries.count == 1 ? "y" : "ies")"
        } catch {
            entries = []
            status = "Could not load agent memories: \(error.localizedDescription)"
        }
    }
}
