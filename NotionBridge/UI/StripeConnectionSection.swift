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
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(red: 0.463, green: 0.333, blue: 0.922).opacity(0.18))
                            .frame(width: 36, height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(red: 0.616, green: 0.553, blue: 1.0)) // #9d8dff
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(conn.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(BridgeTokens.fg1)
                        if let masked = conn.maskedCredential {
                            Text(masked)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(BridgeTokens.fg4)
                        }
                    }

                    Spacer()

                    statusChip(conn.status)

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(BridgeTokens.fg4)
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
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.fg4)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(BridgeTokens.fg2)
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                Image(systemName: "creditcard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Stripe")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg1)
                Text("Not configured · add an API key")
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
            }
            Spacer()
            Button {
                showConnectSheet = true
            } label: {
                Label("Connect", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(BridgeTokens.accent)
            .controlSize(.small)
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
