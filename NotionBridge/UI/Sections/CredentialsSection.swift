// CredentialsSection.swift — Premium Credentials vault (v3.7.6 Wave 4a).
// Mirrors the locked design at design/.../the-bridge/Credentials.jsx +
// credentials.css:
//   - Keychain "vault" hero (key orb · title · sub · stats stored/attention · +)
//   - ONE keychain-safety banner (the single place "Keychain" is named)
//   - Stored-credential rows: branded service mark · name · masked secret +
//     "added <date>" · real "used by" dep chips · LIVE status badge · actions
//     (Copy · Rotate · Delete; Reconnect when revoked/invalid)
//   - Header "Validate all" + per-row "Revalidate" affordance
//   - Credential policy card with TWO real toggles (Touch-ID-to-reveal,
//     auto-validate weekly), both persisted
//
// TRUTHFUL UI (CLAUDE.md standing orders): every value comes from real state —
// rows from CredentialManager.list(), dates from CredentialEntry.createdAt,
// status from the LAST-KNOWN CredentialValidator result (persisted), deps only
// when derivable from live tool wiring. A credential that can't be validated is
// `.unchecked`, never "Valid". The add/replace sheet is the only write path and
// the biometric gate fires inside CredentialManager.save.
//
// All color comes from adaptive BridgeTokens (no hardcoded Color.white/black).

import SwiftUI

public struct CredentialsSection: View {
    @State private var stored: [CredentialEntry] = []
    @State private var health: [String: CredentialHealthRecord] = [:]
    @State private var isLoading = true
    @State private var isValidatingAll = false
    @State private var revalidating: Set<String> = []
    @State private var errorMessage: String?

    @State private var entryToDelete: (service: String, account: String)?
    @State private var showDeleteConfirmation = false

    @State private var sheetMode: CredentialSheetMode?

    // Policy toggles (persisted; default ON — enterprise-grade protection +
    // proactive token-health monitoring; the user can opt out in the policy card).
    @AppStorage(CredentialRevealGate.requireTouchIDKey) private var requireTouchID = true
    @AppStorage(CredentialAutoValidatePolicy.enabledKey) private var autoValidateWeekly = true

    private let store = CredentialHealthStore()

    /// Live tool list — used to derive real "used by" dep-link chips.
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
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .notionBridgeCredentialsFeatureDidChange)) { _ in
            load()
        }
        .sheet(item: $sheetMode) { mode in
            CredentialAddSheet(mode: mode) {
                load()
                // Re-validate the just-saved service so the badge updates.
                Task { await validateAll() }
            }
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

    /// Real attention count: revoked + expiring + error (NOT unchecked/valid).
    private var attentionCount: Int {
        stored.filter { resolvedHealth(for: $0).health.needsAttention }.count
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
                    Text("Connect a service once. Bridge stores the secret in your macOS Keychain and lends it to every tool that needs it.")
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
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
    }

    private var addCredentialButton: some View {
        Button {
            sheetMode = .add
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
                    validateAllButton
                    addCredentialPill
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(BridgeTokens.badText)
                }

                if stored.isEmpty && !isLoading {
                    emptyState
                } else {
                    ForEach(Array(stored.enumerated()), id: \.offset) { idx, entry in
                        credentialRow(entry)
                        if idx < stored.count - 1 {
                            Rectangle()
                                .fill(BridgeTokens.hairlineFaint)
                                .frame(height: 0.5)
                                .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
    }

    private var validateAllButton: some View {
        Button {
            Task { await validateAll() }
        } label: {
            HStack(spacing: 4) {
                if isValidatingAll {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.shield").font(.system(size: 10, weight: .bold))
                }
                Text("Validate all").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(BridgeTokens.fg2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(BridgeTokens.chipFill, in: Capsule())
            .overlay(Capsule().strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(isValidatingAll || stored.isEmpty)
        .help("Re-validate every stored credential against its service")
    }

    private var addCredentialPill: some View {
        Button {
            sheetMode = .add
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("Add credential").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(BridgeTokens.onAccent)
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No stored credentials yet.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BridgeTokens.fg2)
            Text("Only credentials saved through Bridge appear here — system and third-party items are intentionally hidden. Add an API key, password, or card to get started.")
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.fg4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func credentialRow(_ entry: CredentialEntry) -> some View {
        let normalizedName = CredentialValidationMapper.normalizedProvider(forService: entry.service)
        let isFocused = (anchor == normalizedName)
        let record = resolvedHealth(for: entry)
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
                checkedLine(for: entry, record: record)
            }
            Spacer(minLength: 8)
            statusBadge(record.health)
            actions(for: entry, record: record)
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

    /// "checked <relative>" line — last-known timestamp, NOT a live call.
    @ViewBuilder
    private func checkedLine(for entry: CredentialEntry, record: CredentialHealthRecord) -> some View {
        let key = CredentialHealthStore.key(service: entry.service, account: entry.account)
        let isBusy = revalidating.contains(key)
        HStack(spacing: 5) {
            if isBusy {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(BridgeTokens.fg5)
            } else if let checkedAt = record.checkedAt {
                Text("checked \(Self.relative(checkedAt))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(BridgeTokens.fg5)
            } else if isValidatable(entry) {
                Text("not yet validated")
                    .font(.system(size: 10.5))
                    .foregroundStyle(BridgeTokens.fg5)
            } else {
                Text("no automatic check for this service")
                    .font(.system(size: 10.5))
                    .foregroundStyle(BridgeTokens.fg5)
            }
            if isValidatable(entry) && !isBusy {
                Button {
                    Task { await revalidate(entry) }
                } label: {
                    Text("Revalidate")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(BridgeTokens.infoText)
                }
                .buttonStyle(.plain)
                .help("Check this credential against its service now")
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func actions(for entry: CredentialEntry, record: CredentialHealthRecord) -> some View {
        HStack(spacing: 4) {
            if record.health.requiresReconnect {
                // Revoked / invalid → primary action becomes Reconnect (re-auth).
                Button {
                    requestReveal {
                        sheetMode = .replace(
                            service: entry.service, account: entry.account,
                            type: entry.type, reconnect: true
                        )
                    }
                } label: {
                    Text("Reconnect")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BridgeTokens.onAccent)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(BridgeTokens.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Re-authenticate this credential")
            } else {
                iconButton(systemImage: "arrow.triangle.2.circlepath", help: "Rotate") {
                    requestReveal {
                        sheetMode = .replace(
                            service: entry.service, account: entry.account,
                            type: entry.type, reconnect: false
                        )
                    }
                }
            }
            iconButton(systemImage: "doc.on.doc", help: "Copy") {
                requestReveal { copyToClipboard(entry: entry) }
            }
            iconButton(systemImage: "trash", help: "Delete", danger: true) {
                entryToDelete = (service: entry.service, account: entry.account)
                showDeleteConfirmation = true
            }
        }
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
                .background(BridgeTokens.hoverFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Branded service mark (REUSES NotionMark / StripeMark for those services
    /// by matching the service name); SF-symbol fallback otherwise.
    @ViewBuilder
    private func credentialIcon(for entry: CredentialEntry) -> some View {
        let provider = CredentialValidationMapper.normalizedProvider(forService: entry.service)
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(BridgeTokens.chipFill)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .inset(by: 0.5)
                        .stroke(BridgeTokens.hairlineStrong, lineWidth: 0.5)
                        .mask(LinearGradient(colors: [BridgeTokens.fg1, .clear], startPoint: .top, endPoint: .center))
                )
            serviceMark(provider: provider, type: entry.type)
                .frame(width: 17, height: 17)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func serviceMark(provider: String, type: CredentialType) -> some View {
        switch provider {
        case "notion":
            NotionMark()
        case "stripe":
            StripeMark()
        default:
            let (system, color): (String, Color) = {
                switch provider {
                case "openai": return ("brain.head.profile", Color(red: 0.498, green: 0.839, blue: 1.0))
                case "github", "gh": return ("chevron.left.forwardslash.chevron.right", BridgeTokens.fg2)
                default:
                    return type == .card
                        ? ("creditcard.fill", BridgeTokens.fg2)
                        : ("key.fill", BridgeTokens.fg2)
                }
            }()
            Image(systemName: system)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
        }
    }

    /// Status pill driven by the LAST-KNOWN validation result. unchecked →
    /// neutral (truthful), valid → ok, expiring → warn, revoked/error → bad.
    @ViewBuilder
    private func statusBadge(_ health: CredentialHealth) -> some View {
        let (fill, text): (Color, Color) = {
            switch health.badgeTone {
            case .ok:      return (BridgeTokens.ok, BridgeTokens.okText)
            case .warn:    return (BridgeTokens.warn, BridgeTokens.warnText)
            case .bad:     return (BridgeTokens.bad, BridgeTokens.badText)
            case .neutral: return (BridgeTokens.fg4, BridgeTokens.fg3)
            }
        }()
        Text(health.badgeLabel)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(fill.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(fill.opacity(0.30), lineWidth: 0.5))
            .foregroundStyle(text)
            .fixedSize()
    }

    // MARK: - Policy

    private var policyCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Credential policy")
                policyRow(
                    title: "Require Touch ID to reveal",
                    subtitle: "Prompt for biometric auth before copying, rotating, or reconnecting any credential. Uses LocalAuthentication.",
                    isOn: $requireTouchID
                )
                Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5).padding(.vertical, 1)
                policyRow(
                    title: "Auto-validate weekly",
                    subtitle: "Bridge re-checks each service about every 7 days (on launch when due) to detect revoked or expiring tokens.",
                    isOn: Binding(
                        get: { autoValidateWeekly },
                        set: { newValue in
                            autoValidateWeekly = newValue
                            // Turning it on runs an immediate check if due.
                            if newValue && CredentialAutoValidatePolicy.isDue(
                                enabled: true, lastRun: CredentialAutoValidatePolicy.lastRun()
                            ) {
                                Task { await validateAll() }
                            }
                        }
                    )
                )
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

    // MARK: - Health resolution

    /// The health verdict shown for a row. Cards compute expiry locally (no
    /// network); everything else uses the persisted last-known validator result.
    private func resolvedHealth(for entry: CredentialEntry) -> CredentialHealthRecord {
        if entry.type == .card {
            let h = CredentialCardExpiry.health(
                expMonth: entry.metadata.expMonth,
                expYear: entry.metadata.expYear
            )
            return CredentialHealthRecord(health: h, checkedAt: nil)
        }
        let key = CredentialHealthStore.key(service: entry.service, account: entry.account)
        return health[key] ?? .unchecked
    }

    private func isValidatable(_ entry: CredentialEntry) -> Bool {
        // Cards have a local expiry verdict but no "revalidate" network action.
        guard entry.type != .card else { return false }
        return CredentialValidationMapper.isValidatable(
            service: entry.service, type: entry.type, account: entry.account
        )
    }

    // MARK: - Display helpers

    private func displayName(for entry: CredentialEntry) -> String {
        let provider = CredentialValidationMapper.normalizedProvider(forService: entry.service)
        switch provider {
        case "notion":  return "Notion"
        case "stripe":  return "Stripe"
        case "openai":  return "OpenAI"
        case "github", "gh":  return "GitHub"
        case "card":    return entry.metadata.brand?.capitalized ?? "Card"
        default:        return provider.capitalized
        }
    }

    /// Masked secret + "added <date>". Suffix shows a REAL last4 only when we
    /// have it (cards / api keys that stored last4); otherwise just dots.
    private func maskedSubtitle(for entry: CredentialEntry) -> String {
        let dots = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
        let masked: String
        if let last4 = entry.metadata.last4, !last4.isEmpty {
            masked = dots + last4
        } else {
            masked = dots
        }
        if let created = entry.createdAt {
            return "\(masked) · added \(Self.shortDate(created))"
        }
        return masked
    }

    // MARK: - Touch-ID reveal gate

    /// Run `action` after the reveal policy is satisfied. When the
    /// "Require Touch ID to reveal" toggle is ON, gate via requireBiometric;
    /// OFF passes through immediately.
    private func requestReveal(_ action: @escaping () -> Void) {
        guard CredentialRevealGate.shouldGate(requireTouchID: requireTouchID) else {
            action()
            return
        }
        Task {
            do {
                try await CredentialManager.shared.requireBiometric(reason: "Reveal credential")
                await MainActor.run { action() }
            } catch {
                await MainActor.run { errorMessage = "Authentication required: \(error.localizedDescription)" }
            }
        }
    }

    private func copyToClipboard(entry: CredentialEntry) {
        // Copy the actual secret when the feature can read it; otherwise copy
        // the service identifier. read() requires the .app bundle.
        let value: String
        if let read = try? CredentialManager.shared.read(service: entry.service, account: entry.account),
           let secret = read.password, !secret.isEmpty {
            value = secret
        } else {
            value = entry.service
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: - Data loading + validation

    private func load() {
        isLoading = true
        errorMessage = nil
        do {
            stored = try CredentialManager.shared.list()
            // Drop persisted health for credentials that no longer exist.
            let liveKeys = Set(stored.map { CredentialHealthStore.key(service: $0.service, account: $0.account) })
            store.prune(keeping: liveKeys)
            health = store.load()
            isLoading = false
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func revalidate(_ entry: CredentialEntry) async {
        let key = CredentialHealthStore.key(service: entry.service, account: entry.account)
        revalidating.insert(key)
        defer { revalidating.remove(key) }
        let record = await CredentialValidator.shared.validate(
            service: entry.service, account: entry.account, type: entry.type
        )
        await MainActor.run {
            health[key] = record
        }
    }

    private func validateAll() async {
        guard !isValidatingAll else { return }
        isValidatingAll = true
        defer { isValidatingAll = false }
        let map = await CredentialValidator.shared.validateAll()
        CredentialAutoValidatePolicy.recordRun()
        await MainActor.run {
            health = map.isEmpty ? store.load() : map
        }
    }

    private func deleteCredential(service: String, account: String) async {
        do {
            _ = try await CredentialManager.shared.deleteCredential(service: service, account: account)
            load()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        entryToDelete = nil
    }

    // MARK: - Date formatting

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Sheet identity

extension CredentialSheetMode: Identifiable {
    public var id: String {
        switch self {
        case .add: return "add"
        case .replace(let service, let account, _, let reconnect):
            return "replace|\(service)|\(account)|\(reconnect)"
        }
    }
}

