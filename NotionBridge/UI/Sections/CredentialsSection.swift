// CredentialsSection.swift — Liquid Glass reskin of Settings → Credentials.
// PKT-876 v3.6.1. Per design/credentials.html:
//   - Glass-hero header
//   - Keychain protection banner
//   - Each stored credential rendered as a glass row with:
//       * icon · service name · masked secret
//       * "Used by" BridgeDepLink chips → Tools (derived from live tools)
//       * status badge · row actions (copy/delete)
//   - Credential policy card (Touch ID, auto-validate)
//
// Behavior is delegated to the existing CredentialsView body for CRUD
// (Add Password / Card / API Key) — only the visual shell and the
// dep-link surface are part of this packet.

import SwiftUI

public struct CredentialsSection: View {
    @State private var stored: [CredentialEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var entryToDelete: (service: String, account: String)?
    @State private var showDeleteConfirmation = false

    /// Live tool list — used to derive "Used by" dep-link chip counts at
    /// render time so the chips are always accurate (locked decision Q1).
    let liveTools: [ToolInfo]
    let anchor: String?

    public init(liveTools: [ToolInfo], anchor: String? = nil) {
        self.liveTools = liveTools
        self.anchor = anchor
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                keychainBanner
                storedCredentialsCard
                policyCard
                crudCard
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { loadCredentials() }
        .onReceive(NotificationCenter.default.publisher(for: .notionBridgeCredentialsFeatureDidChange)) { _ in
            loadCredentials()
        }
        .confirmationDialog(
            "Delete Credential?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = entryToDelete {
                    Task { await deleteCredential(service: target.service, account: target.account) }
                }
            }
            Button("Cancel", role: .cancel) { entryToDelete = nil }
        } message: {
            if let target = entryToDelete {
                Text("Delete \"\(target.service) / \(target.account)\"? This cannot be undone.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .credentials)
        return BridgeSettingsSectionHeader(
            title: spec.title,
            subtitle: spec.subtitle,
            systemImage: spec.systemImage,
            tint: spec.tint
        ) {
            credentialCountAccessory
        }
    }

    private var credentialCountAccessory: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(stored.count)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.50))
            Text(stored.count == 1 ? "credential" : "credentials")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var keychainBanner: some View {
        BridgeGlassCard(cornerRadius: 9, padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.66, green: 0.78, blue: 1.0))
                Text("Secrets are stored in your macOS Keychain. Bridge never writes plaintext to disk.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.86))
                Spacer()
            }
        }
    }

    // MARK: - Stored credentials

    private var storedCredentialsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Stored credentials")
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if stored.isEmpty && !isLoading {
                    Text("No stored credentials. Add API keys, passwords, or cards from the Keychain CRUD pane below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(stored.enumerated()), id: \.offset) { idx, entry in
                        credentialRow(entry)
                        if idx < stored.count - 1 {
                            Divider().background(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func credentialRow(_ entry: CredentialEntry) -> some View {
        let normalizedName = normalizedServiceName(entry.service)
        let isFocused = (anchor == normalizedName)
        HStack(alignment: .top, spacing: 12) {
            credentialIcon(for: entry)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(for: entry))
                    .font(.system(size: 14, weight: .medium))
                Text(maskedSubtitle(for: entry))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                BridgeDepLinkRow(
                    label: "USED BY",
                    chips: ToolDepLinks.usedByChips(
                        forCredentialService: entry.service,
                        liveTools: liveTools
                    )
                )
            }
            Spacer()
            statusBadge(for: entry)
            HStack(spacing: 4) {
                iconButton(systemImage: "doc.on.doc", help: "Copy") {
                    copyToClipboard(entry: entry)
                }
                iconButton(systemImage: "trash", help: "Delete", danger: true) {
                    entryToDelete = (service: entry.service, account: entry.account)
                    showDeleteConfirmation = true
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            isFocused
                ? RoundedRectangle(cornerRadius: 8)
                    .fill(NotionPalette.orange.opacity(0.10))
                    .padding(.horizontal, -6)
                : nil
        )
    }

    @ViewBuilder
    private func iconButton(
        systemImage: String,
        help: String,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(danger ? Color(red: 1.0, green: 0.61, blue: 0.61) : Color.white.opacity(0.6))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func credentialIcon(for entry: CredentialEntry) -> some View {
        let provider = serviceProvider(entry.service)
        let (system, color): (String, Color) = {
            switch provider {
            case "notion":   return ("doc.text", Color.white.opacity(0.88))
            case "stripe":   return ("creditcard", Color(red: 0.62, green: 0.55, blue: 0.92))
            case "openai":   return ("brain.head.profile", Color(red: 0.50, green: 0.84, blue: 1.0))
            case "github":   return ("chevron.left.forwardslash.chevron.right", Color.white.opacity(0.85))
            default:         return ("key.fill", Color.white.opacity(0.78))
            }
        }()
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func statusBadge(for entry: CredentialEntry) -> some View {
        Text("Stored")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.green.opacity(0.28), lineWidth: 0.5))
            .foregroundStyle(Color.green)
    }

    // MARK: - Policy

    private var policyCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Credential policy")
                policyRow(
                    title: "Apple Keychain Credentials",
                    subtitle: "Master switch for the credential MCP tools (read/save/delete).",
                    isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: CredentialsFeature.userDefaultsKey) },
                        set: { UserDefaults.standard.set($0, forKey: CredentialsFeature.userDefaultsKey) }
                    )
                )
                Divider().background(Color.white.opacity(0.08))
                NavigateRow(
                    title: "Manage Keychain entries",
                    subtitle: "Open the CRUD pane to add / remove API keys, passwords, and cards.",
                    actionLabel: "Open CRUD pane"
                ) {
                    SettingsNavigation.shared.go(.credentials, anchor: "crud")
                }
            }
        }
    }

    @ViewBuilder
    private func policyRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    // MARK: - CRUD pane (delegates to the existing CredentialsView body)

    /// Embeds the legacy Form-based CRUD flows (Notion Integrations, Add
    /// Password / Card / API Key) as the final card. Behavior preserved
    /// verbatim — only the wrapping chrome changes. The whole card carries
    /// a `crud` anchor so the policy NavigateRow above can deep-link here.
    private var crudCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Keychain CRUD")
                CredentialsView()
                    .frame(minHeight: 200)
            }
        }
        .id("crud")
    }

    // MARK: - Helpers

    private func serviceProvider(_ service: String) -> String {
        let s = service.lowercased()
        if s.hasPrefix("api_key:") {
            return String(s.dropFirst("api_key:".count))
        }
        return s
    }

    private func normalizedServiceName(_ service: String) -> String {
        serviceProvider(service)
    }

    private func displayName(for entry: CredentialEntry) -> String {
        let provider = serviceProvider(entry.service)
        switch provider {
        case "notion":  return "Notion"
        case "stripe":  return "Stripe"
        case "openai":  return "OpenAI"
        case "github":  return "GitHub"
        default:        return provider.capitalized
        }
    }

    private func maskedSubtitle(for entry: CredentialEntry) -> String {
        let last4 = entry.metadata.last4 ?? "\u{2022}\u{2022}\u{2022}\u{2022}"
        return "\(entry.service) \u{00B7} \u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(last4)"
    }

    private func copyToClipboard(entry: CredentialEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.service, forType: .string)
    }

    private func loadCredentials() {
        isLoading = true
        errorMessage = nil
        do {
            stored = try CredentialManager.shared.list()
            isLoading = false
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func deleteCredential(service: String, account: String) async {
        do {
            _ = try await CredentialManager.shared.deleteCredential(service: service, account: account)
            loadCredentials()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        entryToDelete = nil
    }
}

// MARK: - Reusable navigate row

/// Generic "title / subtitle / action button" row in a glass card. Used
/// by several sections; lives next to CredentialsSection so it's available
/// without a separate file but kept simple (no card chrome of its own).
struct NavigateRow: View {
    let title: String
    let subtitle: String
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionLabel, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
