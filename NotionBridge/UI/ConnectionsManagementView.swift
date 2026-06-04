import SwiftUI

/// Unified workspace-connections management UI.
/// Uses ConnectionRegistry for normalized models and performs live validation asynchronously
/// so the list renders immediately while health checks stream in.
public struct ConnectionsManagementView: View {
    @State private var connections: [BridgeConnection] = []
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    @State private var showAddSheet = false
    @State private var showDeleteAlert = false
    @State private var connectionToDelete: BridgeConnection?
    @State private var showRenameAlert = false
    @State private var renameTarget: BridgeConnection?
    @State private var renameText = ""
    @State private var expandedConnectionId: String?
    @State private var showLastConnectionWarning = false
    @State private var showPrimaryBlockedAlert = false
    @State private var primaryBlockedMessage = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading workspace connections…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else if connections.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "network.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No workspace connections configured")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                ForEach(connections) { connection in
                    VStack(spacing: 0) {
                        connectionRow(connection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedConnectionId = expandedConnectionId == connection.id ? nil : connection.id
                                }
                            }
                            .contextMenu { contextMenu(for: connection) }

                        if expandedConnectionId == connection.id {
                            connectionDetail(connection)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if connection.id != connections.last?.id {
                            Divider()
                                .padding(.leading, 24)
                        }
                    }
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(BridgeTokens.warn)
                    .padding(.top, 8)
            }

            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Notion Integration", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.borderless)

                Spacer()

                if isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Validating…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await reloadConnections() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh workspace connection status")
            }
            .padding(.top, 8)
        }
        .task { await reloadConnections() }
        .sheet(isPresented: $showAddSheet) {
            AddWorkspaceConnectionSheet {
                Task { await reloadConnections() }
            }
        }
        .alert("Remove Workspace", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let connectionToDelete {
                    Task { await beginRemove(connectionToDelete) }
                }
            }
        } message: {
            if let connectionToDelete {
                Text("Remove \"\(connectionToDelete.name)\"? The stored token will be deleted.")
            }
        }
        .alert("Cannot Delete Primary", isPresented: $showPrimaryBlockedAlert) {
            Button("OK") {}
        } message: {
            Text(primaryBlockedMessage)
        }
        .alert("Delete Last Workspace?", isPresented: $showLastConnectionWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Anyway", role: .destructive) {
                if let connectionToDelete {
                    Task { await confirmLastWorkspaceDeletion(connectionToDelete) }
                }
            }
        } message: {
            Text("You’re about to delete your only workspace connection. Bridge features that need a workspace will stop working until you add a new one.")
        }
        .alert("Rename Workspace", isPresented: $showRenameAlert) {
            TextField("Workspace name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renameTarget, !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await renameConnection(renameTarget, to: renameText) }
                }
            }
        } message: {
            Text("Enter a new display name for this workspace connection.")
        }
    }

    private func connectionRow(_ connection: BridgeConnection) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg1)
            }
            .help(connection.status.label)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name)
                        .font(.system(size: 14, weight: connection.isPrimary ? .semibold : .medium))
                        .foregroundStyle(BridgeTokens.fg1)

                    if connection.isPrimary {
                        Text("PRIMARY")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(BridgeTokens.accent.opacity(0.14))
                            .foregroundStyle(BridgeTokens.accentLink)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                HStack(spacing: 6) {
                    Text(connection.provider.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg4)
                    if let maskedCredential = connection.maskedCredential, !maskedCredential.isEmpty {
                        Text("·").foregroundStyle(BridgeTokens.fg5)
                        Text(maskedCredential)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                }
            }

            Spacer()

            statusChip(connection.status)

            Image(systemName: expandedConnectionId == connection.id ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.vertical, 6)
    }

    private func statusChip(_ status: BridgeConnectionStatus) -> some View {
        let color = statusColor(status)
        return Text(status.label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.5))
            .foregroundStyle(color)
    }

    private func connectionDetail(_ connection: BridgeConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(label: "Provider", value: connection.provider.displayName)
            detailRow(label: "Status", value: connection.status.label, icon: connection.status.systemImage, iconColor: statusColor(connection.status))
            if let maskedCredential = connection.maskedCredential, !maskedCredential.isEmpty {
                detailRow(label: "Token", value: maskedCredential, monospaced: true)
            }
            if connection.isPrimary {
                detailRow(label: "Role", value: "Primary workspace — used when no workspace is specified")
            }
            if let summary = connection.summary, !summary.isEmpty {
                detailRow(label: "Summary", value: summary)
            }
            if let validatedAt = connection.lastValidatedAt, !validatedAt.isEmpty {
                detailRow(label: "Checked", value: validatedAt)
            }
            if !connection.capabilities.isEmpty {
                detailRow(label: "Tools", value: connection.capabilities.joined(separator: " • "))
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func detailRow(
        label: String,
        value: String,
        icon: String? = nil,
        iconColor: Color = .secondary,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.fg4)
                .frame(width: 60, alignment: .leading)
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(iconColor)
            }
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(BridgeTokens.fg2)
        }
    }

    @ViewBuilder
    private func contextMenu(for connection: BridgeConnection) -> some View {
        Button {
            renameTarget = connection
            renameText = connection.name
            showRenameAlert = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        if !connection.isPrimary {
            Button {
                Task { await setPrimary(connection) }
            } label: {
                Label("Set as Primary", systemImage: "star")
            }
        }

        Divider()

        Button(role: .destructive) {
            connectionToDelete = connection
            showDeleteAlert = true
        } label: {
            Label("Remove Workspace", systemImage: "trash")
        }
    }

    @MainActor
    private func reloadConnections() async {
        isLoading = true
        errorMessage = nil

        // PKT-440: Invalidate stale cache so re-validation fetches fresh results
        await ConnectionHealthChecker.shared.invalidateAll()

        do {
            let snapshot = try await ConnectionRegistry.shared.listConnections(kind: .workspace, validateLive: false)
            connections = sortConnections(snapshot)
            isLoading = false
            await refreshStatuses(for: snapshot.map(\.id))
        } catch {
            connections = []
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func refreshStatuses(for ids: [String]? = nil) async {
        let targetIds = await MainActor.run {
            ids ?? connections.map(\.id)
        }
        guard !targetIds.isEmpty else { return }

        await MainActor.run { isRefreshing = true }

        let validated = await withTaskGroup(of: BridgeConnection?.self, returning: [BridgeConnection].self) { group in
            for id in targetIds {
                group.addTask {
                    try? await ConnectionRegistry.shared.validateConnection(id: id)
                }
            }

            var results: [BridgeConnection] = []
            for await connection in group {
                if let connection {
                    results.append(connection)
                }
            }
            return results
        }

        await MainActor.run {
            for connection in validated {
                upsert(connection)
            }
            isRefreshing = false
        }
    }

    @MainActor
    private func upsert(_ connection: BridgeConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        connections = sortConnections(connections)
    }

    private func beginRemove(_ connection: BridgeConnection) async {
        let preflight = await NotionClientRegistry.shared.preflightRemove(name: connection.name)
        switch preflight {
        case .primaryBlocked(let message):
            await MainActor.run {
                primaryBlockedMessage = message
                showPrimaryBlockedAlert = true
            }
        case .lastConnectionWarning:
            await MainActor.run {
                connectionToDelete = connection
                showLastConnectionWarning = true
            }
        case .removed:
            await removeConnection(connection)
        }
    }

    private func confirmLastWorkspaceDeletion(_ connection: BridgeConnection) async {
        do {
            try await ConnectionRegistry.shared.removeConnection(id: connection.id)
            await reloadConnections()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeConnection(_ connection: BridgeConnection) async {
        do {
            try await ConnectionRegistry.shared.removeConnection(id: connection.id)
            await reloadConnections()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func renameConnection(_ connection: BridgeConnection, to newName: String) async {
        do {
            try await ConnectionRegistry.shared.renameConnection(id: connection.id, to: newName)
            await reloadConnections()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setPrimary(_ connection: BridgeConnection) async {
        do {
            try await ConnectionRegistry.shared.setPrimary(id: connection.id)
            await reloadConnections()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sortConnections(_ items: [BridgeConnection]) -> [BridgeConnection] {
        items.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary && !rhs.isPrimary
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func statusColor(_ status: BridgeConnectionStatus) -> Color {
        switch status {
        case .connected:
            return BridgeTokens.ok
        case .warning:
            return BridgeTokens.warn
        case .disconnected:
            return BridgeTokens.bad
        case .notConfigured:
            return .gray
        case .checking:
            return BridgeTokens.warn
        case .invalid:
            return BridgeTokens.bad
        }
    }
}

/// UEP-004: Provider-agnostic connection sheet supporting Notion, Stripe, and Generic API keys.
enum AddConnectionProvider: String, CaseIterable, Identifiable {
    case notion = "Notion"

    var id: String { rawValue }

    var namePlaceholder: String {
        "Workspace name (e.g. Work, Personal)"
    }

    var tokenPlaceholder: String {
        "Notion API token (ntn_...)"
    }

    var helpURL: URL? {
        URL(string: "https://www.notion.so/profile/integrations")
    }

    var helpLabel: String {
        "Create a Notion integration at notion.so"
    }

    var saveButtonLabel: String {
        "Test & Save"
    }
}

struct AddWorkspaceConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: () -> Void

    @State private var selectedProvider: AddConnectionProvider = .notion
    @State private var connectionName = ""
    @State private var token = ""
    @State private var makePrimary = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Notion Integration")
                .font(.headline)

            

            TextField(selectedProvider.namePlaceholder, text: $connectionName)
                .textFieldStyle(.roundedBorder)

            SecureField(selectedProvider.tokenPlaceholder, text: $token)
                .textContentType(.none)
                .textFieldStyle(.roundedBorder)

            Toggle("Set as primary workspace", isOn: $makePrimary)
                    .font(.callout)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(BridgeTokens.bad)
            }

            if let helpURL = selectedProvider.helpURL {
                Link(destination: helpURL) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.caption2)
                        Text(selectedProvider.helpLabel)
                            .font(.caption)
                    }
                }
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(selectedProvider.saveButtonLabel) {
                    Task { await saveConnection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.isEmpty || isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func saveConnection() async {
        await MainActor.run {
            isSaving = true
            errorMessage = nil
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedToken.hasPrefix("ntn_") else {
            await MainActor.run {
                errorMessage = "Invalid token \u{2014} Notion API tokens must start with \"ntn_\""
                isSaving = false
            }
            return
        }

        do {
            _ = try await ConnectionRegistry.shared.configureNotionConnection(
                name: connectionName,
                token: token,
                primary: makePrimary
            )
            await MainActor.run {
                onComplete()
                dismiss()
                isSaving = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
