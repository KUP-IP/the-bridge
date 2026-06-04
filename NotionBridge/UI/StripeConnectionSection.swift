// StripeConnectionSection.swift — Stripe API Key Management UI
// NotionBridge · UI

import SwiftUI

/// Inline section content for managing a single Stripe API key connection.
struct StripeConnectionSection: View {
    @State private var connection: BridgeConnection?
    @State private var isLoading = true
    @State private var isValidating = false
    @State private var expanded = false
    @State private var showConnectSheet = false
    @State private var showRemoveAlert = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let connection, connection.status != .notConfigured {
                connectedView(connection)
            } else {
                emptyView
            }
        }
        .task { await load() }
        .sheet(isPresented: $showConnectSheet) {
            StripeConnectionSheet { await load() }
        }
        .alert("Remove Stripe Key?", isPresented: $showRemoveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await remove() }
            }
        } message: {
            Text("The API key will be deleted from Keychain. Stripe tools will become unavailable.")
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private func connectedView(_ conn: BridgeConnection) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: conn.status.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(statusColor(conn.status))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(conn.name)
                            .font(.callout)
                        if let masked = conn.maskedCredential {
                            Text(masked)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Text(conn.status.label)
                        .font(.caption2)
                        .foregroundStyle(statusColor(conn.status))

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                detailView(conn)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func detailView(_ conn: BridgeConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let acct = conn.metadata["account_id"], !acct.isEmpty {
                detailRow("Account", acct, monospaced: true)
            }
            if let country = conn.metadata["country"], !country.isEmpty {
                detailRow("Country", country)
            }
            if let charges = conn.metadata["charges_enabled"] {
                detailRow("Charges", charges == "true" ? "Enabled" : "Disabled")
            }
            if let validated = conn.lastValidatedAt {
                detailRow("Checked", validated)
            }
            if let err = conn.metadata["last_error"], !err.isEmpty {
                detailRow("Error", err)
            }

            HStack(spacing: 12) {
                Button("Validate") {
                    Task { await validate() }
                }
                .font(.caption)
                .disabled(isValidating)

                Button("Remove", role: .destructive) {
                    showRemoveAlert = true
                }
                .font(.caption)

                if isValidating {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .padding(.top, 4)
        }
        .padding(.leading, 20)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                showConnectSheet = true
            } label: {
                Label("Connect Stripe", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            // Phase 1: Instant snapshot with last-known status (PKT-440)
            connection = try await ConnectionRegistry.shared.getConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                validateLive: false
            )
            isLoading = false

            // Phase 2: Live validation in background (PKT-440)
            // Fixes bug where Stripe stayed "Checking…" forever
            if let conn = connection, conn.status != .notConfigured {
                isValidating = true
                if let validated = try? await ConnectionRegistry.shared.validateConnection(id: conn.id) {
                    connection = validated
                }
                isValidating = false
            }
        } catch {
            connection = nil
            isLoading = false
        }
    }

    private func validate() async {
        isValidating = true
        do {
            connection = try await ConnectionRegistry.shared.validateConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isValidating = false
    }

    private func remove() async {
        do {
            try await ConnectionRegistry.shared.removeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default"
            )
            connection = nil
            expanded = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func statusColor(_ status: BridgeConnectionStatus) -> Color {
        switch status {
        case .connected: return BridgeTokens.ok
        case .warning: return BridgeTokens.warn
        case .disconnected: return BridgeTokens.bad
        case .notConfigured: return .gray
        case .checking: return BridgeTokens.warn
        case .invalid: return BridgeTokens.bad
        }
    }
}

// MARK: - StripeConnectionSheet

/// Focused sheet for adding a Stripe API key.
struct StripeConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: () async -> Void

    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect Stripe")
                .font(.headline)

            SecureField("Stripe API key (sk_… or rk_…)", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(BridgeTokens.bad)
            }

            Link(destination: URL(string: "https://dashboard.stripe.com/apikeys")!) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.caption2)
                    Text("Get your API key from Stripe Dashboard")
                        .font(.caption)
                }
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Test & Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk_") || trimmed.hasPrefix("rk_") else {
            errorMessage = "Stripe API keys start with \"sk_\" or \"rk_\""
            isSaving = false
            return
        }

        do {
            _ = try await ConnectionRegistry.shared.configureStripeAPIKey(trimmed)
            dismiss()
            await onComplete()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
