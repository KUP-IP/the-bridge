// CredentialsSection.swift — Security · Vault tab body (Settings-Redesign PKT-security).
//
// This is the **Vault** tab inside the merged Security page (posture header +
// Vault | Gates). The bespoke `SecuritySection` composite owns the single
// posture header (replacing this file's old orb-hero) and the tab bar; this
// view is now hero-less and renders only the Vault contents:
//   - ONE keychain-safety banner (the single place "Keychain" is named)
//   - ONE add pill (the old hero orb `+` is dropped — one add per surface)
//   - Stored-credential rows: branded service mark · name · masked secret +
//     "added <date>" · real "used by" dep chips · LIVE status badge · actions
//     (Copy · Rotate · Delete; Reconnect when revoked/invalid). Rows are keyed
//     by stable service+account so reorder/delete animations don't break.
//   - Header "Validate all" + per-row "Revalidate" affordance
//   - Credential policy card with TWO real toggles (Touch-ID-to-reveal,
//     auto-validate weekly), both persisted (Touch-ID is mirrored read-only in
//     the posture header chip)
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
            VStack(spacing: BridgeSpacing.sm) {
                keychainBanner
                storedCredentialsCard
                policyCard
            }
            .padding(BridgeTokens.Space.paneH)
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

    // MARK: - Keychain banner (the ONE place keychain is named)

    /// W2 `.banner` (info) — the single keychain-safety notice. Royal-blue ink,
    /// faint accent fill + accent border, key glyph. The mono store name reads as
    /// a lowercase module/tool token per the v4 grammar.
    private var keychainBanner: some View {
        BridgeBanner(
            signal: .info,
            message:
                "Secrets live in your macOS Keychain under kup.solutions.notion-bridge. "
                + "Touch ID to reveal — Bridge never writes plaintext to disk.",
            systemImage: "key.fill"
        )
    }

    // MARK: - Stored credentials

    private var storedCredentialsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BridgeCardLabel("Stored credentials")
                    Spacer(minLength: 8)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    autoValidateBadge
                    validateAllButton
                    addCredentialPill
                }

                if let errorMessage {
                    BridgeBanner(signal: .bad, message: errorMessage)
                }

                if stored.isEmpty && !isLoading {
                    emptyState
                } else {
                    // Each credential sits in its own recessed well (design source:
                    // `var(--well)` + `--bevel-inset` + faint hairline, radius 10),
                    // keyed by a STABLE service+account id (not array offset) so
                    // reorder/delete animations keep row identity intact.
                    VStack(spacing: 6) {
                        ForEach(stored, id: \.rowID) { entry in
                            credentialRow(entry)
                        }
                    }
                }
            }
        }
    }

    /// Truthful "auto-validates" status pill — the W2 `.badge` (ok, dot), shown
    /// only when the weekly policy is actually ON (mirrors the design's
    /// "Auto-validates every 6h" badge, but honest to the real cadence + toggle).
    @ViewBuilder
    private var autoValidateBadge: some View {
        if autoValidateWeekly {
            BridgeBadge("Auto-validates weekly", tone: .ok, showsDot: true)
                .help("Bridge re-checks each service about every 7 days. Toggle in Credential policy below.")
                .accessibilityLabel("Auto-validates weekly is on")
        }
    }

    /// "Validate all" affordance — the W2 neutral-glass chip (design `.btn sm`).
    /// Shows a transient "Validating…" label while the sweep runs.
    @ViewBuilder
    private var validateAllButton: some View {
        if isValidatingAll {
            BridgeChip("Validating\u{2026}", systemImage: "checkmark.shield")
                .help("Re-validate every stored credential against its service")
        } else if !stored.isEmpty {
            BridgeChip("Validate all", systemImage: "checkmark.shield") {
                Task { await validateAll() }
            }
            .help("Re-validate every stored credential against its service")
        }
    }

    /// Add affordance — the canonical W2 primary button (translucent accent
    /// gradient · onAccent ink · accentBorder edge), no longer a hand-rolled
    /// re-implementation of the same chrome.
    private var addCredentialPill: some View {
        BridgeButton("Add credential", systemImage: "plus", variant: .primary) {
            sheetMode = .add
        }
        .help("Add a new credential")
    }

    private var emptyState: some View {
        BridgeEmptyStateView(
            systemImage: "key.fill",
            title: "No stored credentials yet",
            message: "Only credentials saved through Bridge appear here — system and third-party items are intentionally hidden. Add an API key, password, or card to get started."
        ) {
            BridgeButton("Add credential", systemImage: "plus", variant: .primary) {
                sheetMode = .add
            }
        }
    }

    @ViewBuilder
    private func credentialRow(_ entry: CredentialEntry) -> some View {
        let normalizedName = CredentialValidationMapper.normalizedProvider(forService: entry.service)
        let isFocused = (anchor == normalizedName)
        let record = resolvedHealth(for: entry)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            credentialIcon(for: entry)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: BridgeTokens.Space.s2) {
                    Text(displayName(for: entry))
                        .font(BridgeTokens.Typeface.body.weight(.semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    statusBadge(record.health)
                }
                Text(maskedSubtitle(for: entry))
                    .font(BridgeTokens.Typeface.mono)
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
            actions(for: entry, record: record)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        // Each row is a recessed well (design source: --well + --bevel-inset +
        // faint hairline). A focused/anchored row tints the well accent so a
        // deep-link from another page lands on a highlighted credential.
        .background(
            shape.fill(isFocused ? BridgeTokens.accent.opacity(0.10) : BridgeTokens.wellFill)
                .overlay(shape.strokeBorder(
                    isFocused ? BridgeTokens.accent.opacity(0.28) : BridgeTokens.hairlineFaint,
                    lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
        )
    }

    /// "checked <relative>" line — last-known timestamp, NOT a live call.
    @ViewBuilder
    private func checkedLine(for entry: CredentialEntry, record: CredentialHealthRecord) -> some View {
        let key = CredentialHealthStore.key(service: entry.service, account: entry.account)
        let isBusy = revalidating.contains(key)
        HStack(spacing: BridgeTokens.Space.s1 + 1) {
            if isBusy {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(BridgeTokens.Typeface.cap.weight(.regular))
                    .foregroundStyle(BridgeTokens.fg5)
            } else if let checkedAt = record.checkedAt {
                Text("checked \(Self.relative(checkedAt))")
                    .font(BridgeTokens.Typeface.cap.weight(.regular))
                    .foregroundStyle(BridgeTokens.fg5)
            } else if isValidatable(entry) {
                Text("not yet validated")
                    .font(BridgeTokens.Typeface.cap.weight(.regular))
                    .foregroundStyle(BridgeTokens.fg5)
            } else {
                Text("no automatic check for this service")
                    .font(BridgeTokens.Typeface.cap.weight(.regular))
                    .foregroundStyle(BridgeTokens.fg5)
            }
            if isValidatable(entry) && !isBusy {
                Button {
                    Task { await revalidate(entry) }
                } label: {
                    Text("Revalidate")
                        .font(BridgeTokens.Typeface.cap)
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
        // Bind the row title (credential name) as each control's VoiceOver label
        // so an icon button announces e.g. "Rotate Notion", not a bare glyph.
        let name = displayName(for: entry)
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
                        .font(BridgeTokens.Typeface.cap)
                        .foregroundStyle(BridgeTokens.onAccent)
                        .padding(.horizontal, BridgeTokens.Space.s3).padding(.vertical, 5)
                        .background(BridgeTokens.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Re-authenticate this credential")
                .accessibilityLabel("Reconnect \(name)")
            } else {
                iconButton(systemImage: "arrow.triangle.2.circlepath", help: "Rotate", a11yLabel: "Rotate \(name)") {
                    requestReveal {
                        sheetMode = .replace(
                            service: entry.service, account: entry.account,
                            type: entry.type, reconnect: false
                        )
                    }
                }
            }
            iconButton(systemImage: "doc.on.doc", help: "Copy", a11yLabel: "Copy \(name)") {
                requestReveal { copyToClipboard(entry: entry) }
            }
            iconButton(systemImage: "trash", help: "Delete", danger: true, a11yLabel: "Delete \(name)") {
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
        a11yLabel: String? = nil,
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(a11yLabel ?? help)
    }

    /// Branded service mark (REUSES NotionMark / StripeMark for those services
    /// by matching the service name); SF-symbol fallback otherwise.
    @ViewBuilder
    private func credentialIcon(for entry: CredentialEntry) -> some View {
        let provider = CredentialValidationMapper.normalizedProvider(forService: entry.service)
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(BridgeTokens.chipFill)
                .frame(width: 34, height: 34)
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
        .frame(width: 34, height: 34)
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

    /// Status pill driven by the LAST-KNOWN validation result, rendered with the
    /// W2 `.badge` (`BridgeBadge`). unchecked → neutral (truthful), valid → ok,
    /// expiring → warn, revoked/error → bad.
    @ViewBuilder
    private func statusBadge(_ health: CredentialHealth) -> some View {
        let tone: BridgeBadge.Tone = {
            switch health.badgeTone {
            case .ok:      return .ok
            case .warn:    return .warn
            case .bad:     return .bad
            case .neutral: return .neutral
            }
        }()
        BridgeBadge(health.badgeLabel, tone: tone)
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

// MARK: - Stable row identity

extension CredentialEntry {
    /// Stable identity for ForEach (service+account) so reorder/delete
    /// animations keep row identity intact (replaces the fragile array offset).
    var rowID: String { "\(service)\u{001F}\(account)" }
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

