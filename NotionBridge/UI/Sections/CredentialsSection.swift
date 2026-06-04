// CredentialsSection.swift — Liquid Glass reskin of Settings → Credentials.
// PKT-876 v3.6.1 · v3.7.2 bundle-2 redesign. Mirrors the locked mockup at
// design/.../the-bridge/Credentials.jsx + credentials.css:
//   - Keychain "vault" hero (orb + stats + add-credential action)
//   - ONE keychain-safety banner (the single place "Keychain" is named)
//   - Stored-credential rows: brand-tinted icon · service name · masked
//     secret (mono) · "Used by" dep-link chips · status badge · copy/delete
//   - Add-credential CTA in the card-label row
//   - Credential policy card
//   - Keychain CRUD pane embedded as the final card (behavior unchanged)
//
// All CRUD / store / clipboard / delete logic is preserved verbatim — only
// the view layer is restructured. The init signature is unchanged so the
// injected `liveTools` + `anchor` from SettingsWindow+Sections stay wired.

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
                hero
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

    // MARK: - Hero (keychain vault)

    private var attentionCount: Int {
        // Cards expiring within 60 days surface as "needs attention".
        stored.filter { isExpiringSoon($0) }.count
    }

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BridgeTokens.accent.opacity(0.22))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 1))
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.accentLink)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Credentials")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Connect a service once. Bridge lends the stored secret to every tool that needs it.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    statTile(value: "\(stored.count)", label: "stored", color: BridgeTokens.okText)
                    statTile(
                        value: "\(attentionCount)",
                        label: "attention",
                        color: attentionCount > 0 ? BridgeTokens.warnText : BridgeTokens.fg4
                    )
                }
                addCredentialButton
            }
        }
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
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    /// Hero "+" action — jumps to the CRUD pane where adds actually happen.
    private var addCredentialButton: some View {
        Button {
            SettingsNavigation.shared.go(.credentials, anchor: "crud")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BridgeTokens.fg2)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add credential")
    }

    // MARK: - Keychain banner (the ONE place keychain is named)

    private var keychainBanner: some View {
        BridgeGlassCard(cornerRadius: 11, padding: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BridgeTokens.accentLink)
                (
                    Text("Secrets live in your macOS Keychain under ")
                        .foregroundStyle(BridgeTokens.fg2)
                    + Text("com.kupsolutions.notion-bridge")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(BridgeTokens.accentLink)
                    + Text(". Bridge never writes plaintext to disk.")
                        .foregroundStyle(BridgeTokens.fg2)
                )
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Stored credentials

    private var storedCredentialsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BridgeCardLabel("Stored credentials")
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        SettingsNavigation.shared.go(.credentials, anchor: "crud")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text("Add credential").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            LinearGradient(
                                colors: [BridgeTokens.accent.opacity(0.55), BridgeTokens.accent.opacity(0.40)],
                                startPoint: .top, endPoint: .bottom),
                            in: Capsule())
                        .overlay(Capsule().strokeBorder(BridgeTokens.accentStrong.opacity(0.55), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Add a new credential")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(BridgeTokens.bad)
                }

                if stored.isEmpty && !isLoading {
                    // PKT-934 ·5: post-PKT-933 the list shows ONLY Bridge-saved
                    // items — system + third-party Keychain entries are scoped
                    // out. Explain why this looks emptier than Keychain Access so
                    // users don't think their credentials vanished.
                    emptyState
                } else {
                    ForEach(Array(stored.enumerated()), id: \.offset) { idx, entry in
                        credentialRow(entry)
                        if idx < stored.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 0.5)
                                .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No stored credentials yet.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BridgeTokens.fg2)
            Text("Only credentials saved through Bridge appear here — system and third-party items are intentionally hidden. Add API keys, passwords, or cards from the CRUD pane below.")
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.fg4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
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
                    .foregroundStyle(BridgeTokens.fg1)
                Text(maskedSubtitle(for: entry))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg4)
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
            Spacer(minLength: 8)
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
        .padding(.vertical, 5)
        .padding(.horizontal, isFocused ? 8 : 0)
        .background(
            isFocused
                ? RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(BridgeTokens.accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(BridgeTokens.accent.opacity(0.28), lineWidth: 0.5))
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(danger ? BridgeTokens.badText : BridgeTokens.fg3)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
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
            case "notion":   return ("doc.text.fill", BridgeTokens.fg1)
            case "stripe":   return ("creditcard.fill", Color(red: 0.616, green: 0.553, blue: 1.0))   // #9d8dff per mockup
            case "openai":   return ("brain.head.profile", Color(red: 0.498, green: 0.839, blue: 1.0)) // #7fd6ff per mockup
            case "github":   return ("chevron.left.forwardslash.chevron.right", BridgeTokens.fg2)
            case "card":     return ("creditcard.fill", BridgeTokens.fg2)
            default:         return ("key.fill", BridgeTokens.fg2)
            }
        }()
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .inset(by: 0.5)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                )
            Image(systemName: system)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
        }
        .accessibilityHidden(true)
    }

    /// Status pill — ok by default, amber when a card is expiring soon.
    @ViewBuilder
    private func statusBadge(for entry: CredentialEntry) -> some View {
        let expiring = isExpiringSoon(entry)
        let (text, color): (String, Color) = expiring
            ? ("Expiring", BridgeTokens.warn)
            : ("Valid", BridgeTokens.ok)
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.5))
            .foregroundStyle(expiring ? BridgeTokens.warnText : BridgeTokens.okText)
            .fixedSize()
    }

    // MARK: - Policy

    private var policyCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Credential policy")
                policyRow(
                    title: "Apple Keychain Credentials",
                    subtitle: "Master switch for the credential MCP tools (read / save / delete).",
                    isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: CredentialsFeature.userDefaultsKey) },
                        set: { UserDefaults.standard.set($0, forKey: CredentialsFeature.userDefaultsKey) }
                    )
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.vertical, 1)
                NavigateRow(
                    title: "Manage stored entries",
                    subtitle: "Open the CRUD pane to add or remove API keys, passwords, and cards.",
                    actionLabel: "Open CRUD pane"
                ) {
                    SettingsNavigation.shared.go(.credentials, anchor: "crud")
                }
            }
        }
    }

    @ViewBuilder
    private func policyRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(BridgeTokens.fg2)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    // MARK: - CRUD pane (delegates to the existing CredentialsView body)

    /// Embeds the legacy Form-based CRUD flows (Notion Integrations, Add
    /// Password / Card / API Key) as the final card. Behavior preserved
    /// verbatim — only the wrapping chrome changes. The whole card carries
    /// a `crud` anchor so the hero / policy / list jump here.
    private var crudCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Add & manage")
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
        case "card":    return entry.metadata.brand?.capitalized ?? "Card"
        default:        return provider.capitalized
        }
    }

    private func maskedSubtitle(for entry: CredentialEntry) -> String {
        let last4 = entry.metadata.last4 ?? "\u{2022}\u{2022}\u{2022}\u{2022}"
        return "\(entry.service) \u{00B7} \u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(last4)"
    }

    /// True when a card credential expires within ~60 days. Non-card
    /// credentials never report "expiring".
    private func isExpiringSoon(_ entry: CredentialEntry) -> Bool {
        guard entry.type == .card,
              let month = entry.metadata.expMonth,
              let year = entry.metadata.expYear,
              let expiry = Calendar.current.date(from: DateComponents(year: year, month: month))
        else { return false }
        // First of the month *after* the expiry month is the true cutoff.
        guard let endOfExpiryMonth = Calendar.current.date(byAdding: .month, value: 1, to: expiry)
        else { return false }
        let soon = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
        return endOfExpiryMonth <= soon
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
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(BridgeTokens.fg2)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(actionLabel, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
