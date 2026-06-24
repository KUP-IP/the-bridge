// MemorySection.swift — Settings → Memory inspector (PKT-977 Wave 2 · Q4)
// TheBridge · UI · Sections
//
// Read-only memory inspector: shows live memory entries from MemoryStore with
// pin/forget actions (soft-tombstone consistent with the tool path). No CRUD
// authoring in this wave — entries are added/updated via the `memory_remember`
// tool. The auto-inject toggle (Q1) is also surfaced here.
//
// Decision Q4: read-only inspector, own nav section, pin/forget only,
// soft-tombstone consistent with tools, auto-inject toggle. Full CRUD authoring
// deferred.
//
// All color comes from adaptive BridgeTokens (no hardcoded Color.white/black).

import SwiftUI

// MARK: - MemoryEntryRow model (UI snapshot)

private struct MemoryRow: Identifiable, Equatable {
    let id: String
    let scope: String
    let entity: String?
    let text: String
    let type: String
    let pinned: Bool
    let useCount: Int
    let source: String
    let createdAt: Date
    let lastUsedAt: Date
}

private extension MemoryEntry {
    var row: MemoryRow {
        MemoryRow(
            id: id, scope: scope, entity: entity, text: text,
            type: type.rawValue, pinned: pinned, useCount: useCount,
            source: source, createdAt: createdAt, lastUsedAt: lastUsedAt
        )
    }
}

// MARK: - MemorySection

public struct MemorySection: View {

    @State private var rows: [MemoryRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var forgetTarget: MemoryRow?
    @State private var showForgetConfirmation = false
    @State private var filterScope: String = ""

    // Q1: global auto-inject toggle (OFF by default)
    @AppStorage(BridgeDefaults.memoryHandshakeAutoInject)
    private var autoInjectEnabled: Bool = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: BridgeTokens.Space.cardGap) {
                settingsCard
                if isLoading {
                    loadingCard
                } else if rows.isEmpty {
                    emptyCard
                } else {
                    entriesCard
                }
            }
            .padding(.horizontal, BridgeTokens.Space.paneH)
            .padding(.vertical, BridgeTokens.Space.paneH)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { await load() }
        .confirmationDialog(
            "Forget this memory?",
            isPresented: $showForgetConfirmation,
            presenting: forgetTarget
        ) { target in
            Button("Forget", role: .destructive) {
                Task { await forget(id: target.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("\"\(String(target.text.prefix(80)))\" will be soft-tombstoned and excluded from recall. The row is preserved for audit.")
        }
    }

    // MARK: - Cards

    private var settingsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.s2) {
                BridgeCardLabel("Settings")
                    .accessibilityIdentifier("\(BridgeAXID.root).memory.settings.label")

                Toggle(isOn: $autoInjectEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-inject memory at handshake")
                            .font(BridgeTokens.Typeface.body)
                            .foregroundStyle(BridgeTokens.fg2)
                        Text("When enabled, the salient memory slice is appended to initialize.instructions for connecting MCP clients. Default OFF — memory stays opt-in via bridge://memory.")
                            .font(.system(size: 12))
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("\(BridgeAXID.root).memory.settings.autoInject")
            }
        }
    }

    private var loadingCard: some View {
        BridgeGlassCard {
            HStack {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.75)
                Text("Loading memories…")
                    .font(.system(size: 13))
                    .foregroundStyle(BridgeTokens.fg4)
            }
        }
    }

    private var emptyCard: some View {
        BridgeGlassCard {
            VStack(spacing: BridgeTokens.Space.s3) {
                Image(systemName: "brain")
                    .font(.system(size: 28))
                    .foregroundStyle(BridgeTokens.fg4)
                Text("No memories stored yet.")
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg4)
                Text("Use memory_remember from any MCP client to start building the shared memory store.")
                    .font(.system(size: 12))
                    .foregroundStyle(BridgeTokens.fg4)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var entriesCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.s2) {
                HStack {
                    BridgeCardLabel("Memories (\(displayedRows.count))")
                    Spacer()
                    Button(action: { Task { await load() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BridgeTokens.fg4)
                    .accessibilityIdentifier("\(BridgeAXID.root).memory.entries.refresh")
                }

                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(BridgeTokens.fg4)
                    TextField("Filter by scope", text: $filterScope)
                        .font(.system(size: 12))
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("\(BridgeAXID.root).memory.entries.scopeFilter")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(BridgeTokens.wellFill)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Divider()

                ForEach(displayedRows) { row in
                    entryRow(row)
                    if row.id != displayedRows.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func entryRow(_ row: MemoryRow) -> some View {
        HStack(alignment: .top, spacing: BridgeTokens.Space.s2) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if row.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(BridgeTokens.accent)
                    }
                    Text(row.scope + (row.entity.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(BridgeTokens.fg4)
                    BridgeBadge(row.type, tone: .neutral)
                    if row.useCount > 0 {
                        Text("used \(row.useCount)×")
                            .font(.system(size: 11))
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                }
                Text(row.text)
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg2)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.source.isEmpty {
                    Text("via \(row.source)")
                        .font(.system(size: 11))
                        .foregroundStyle(BridgeTokens.fg4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                Button(action: { Task { await togglePin(row) } }) {
                    Image(systemName: row.pinned ? "pin.slash" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(row.pinned ? BridgeTokens.accent : BridgeTokens.fg4)
                }
                .buttonStyle(.plain)
                .help(row.pinned ? "Unpin" : "Pin to top of recall")
                .accessibilityIdentifier("\(BridgeAXID.root).memory.entries.\(row.id).pin")

                Button(action: {
                    forgetTarget = row
                    showForgetConfirmation = true
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                .buttonStyle(.plain)
                .help("Forget (soft-tombstone)")
                .accessibilityIdentifier("\(BridgeAXID.root).memory.entries.\(row.id).forget")
            }
        }
        .accessibilityIdentifier("\(BridgeAXID.root).memory.entries.\(row.id)")
    }

    // MARK: - Filtered rows

    private var displayedRows: [MemoryRow] {
        let scope = filterScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if scope.isEmpty { return rows }
        return rows.filter {
            $0.scope.lowercased().contains(scope) ||
            ($0.entity?.lowercased().contains(scope) ?? false)
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let entries = try await MemoryStore.shared.list()
            rows = entries.map(\.row)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func togglePin(_ row: MemoryRow) async {
        do {
            try await MemoryStore.shared.pin(id: row.id, !row.pinned)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func forget(id: String) async {
        do {
            try await MemoryStore.shared.forget(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
