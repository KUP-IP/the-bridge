// LicenseCard.swift — PKT-909 (Sell/Distribute v3 · 1) W3
// NotionBridge · UI · Sections
//
// The License card lives inside Settings → Advanced. It is the single UI
// surface the user touches for paste-key activation + trial status. The
// card is a small, self-contained component so a future "Subscriptions"
// section (PKT-911 / PKT-913) can reuse the same status-pill visual
// language without forking copy.
//
// State model: the card is fully driven from a `LicenseUIState` value
// snapshot. The owning view (SettingsView) reads `LicenseManager.shared`
// once on appear (and on the `.licenseStateDidChange` notification),
// rebuilds the snapshot, and passes it in. The card itself contains no
// async code — it only emits intents (paste/activate/deactivate) the
// host translates into actor calls.
//
// HONEST-LEDGER: the .accessibilityLabel block reuses Bridge's existing
// VoiceOver patterns from PKT-879 (Dashboard); the paste-button rapid-
// click guard is the host's concern (debounce on the `onActivate`
// callback). The card has no internal isInFlight latch.

import SwiftUI
import AppKit

// MARK: - View-only snapshot of LicenseManager state

/// Pure value snapshot the host builds from `LicenseManager`. No
/// references to the actor → the card renders in SwiftUI previews and
/// snapshot tests with zero runtime state.
public struct LicenseUIState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case trial(daysRemaining: Int)
        case trialExpired
        case licensed(subjectDisplay: String, expiresAtDisplay: String?)
        case licenseExpired(subjectDisplay: String, expiredAtDisplay: String?)
        case grandfathered
    }

    public let kind: Kind
    /// Last activation error message, if any (cleared by the host on
    /// successful activate or when the user edits the paste field).
    public let lastError: String?
    /// True when the bundled public key is missing → paste-activation
    /// path is disabled (the field still renders but the button is
    /// off). Drives the small "activation unavailable" hint.
    public let canPasteActivate: Bool

    public init(kind: Kind, lastError: String? = nil, canPasteActivate: Bool = true) {
        self.kind = kind
        self.lastError = lastError
        self.canPasteActivate = canPasteActivate
    }

    /// Build from a LicenseStatus + paste-availability. The expiry
    /// display strings use the user's locale via a fixed formatter.
    public static func from(_ status: LicenseStatus, canPasteActivate: Bool, lastError: String? = nil) -> LicenseUIState {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none

        let kind: Kind
        switch status {
        case .trial(let d):
            kind = .trial(daysRemaining: d)
        case .trialExpired:
            kind = .trialExpired
        case .licensed(let payload):
            let expS = payload.exp.map { fmt.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
            kind = .licensed(subjectDisplay: payload.sub, expiresAtDisplay: expS)
        case .licenseExpired(let payload):
            let expS = payload.exp.map { fmt.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
            kind = .licenseExpired(subjectDisplay: payload.sub, expiredAtDisplay: expS)
        case .grandfathered:
            kind = .grandfathered
        }
        return LicenseUIState(kind: kind, lastError: lastError, canPasteActivate: canPasteActivate)
    }
}

// MARK: - LicenseCard view

public struct LicenseCard: View {
    let state: LicenseUIState
    @Binding var pasteField: String
    let onActivate: () -> Void
    let onDeactivate: () -> Void
    let onBuy: () -> Void

    public init(
        state: LicenseUIState,
        pasteField: Binding<String>,
        onActivate: @escaping () -> Void,
        onDeactivate: @escaping () -> Void,
        onBuy: @escaping () -> Void
    ) {
        self.state = state
        self._pasteField = pasteField
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onBuy = onBuy
    }

    public var body: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    premiumGlyph
                    BridgeCardLabel("License")
                    Spacer(minLength: 8)
                    statusPill
                }
                content
                if let err = state.lastError {
                    BridgeBanner(signal: .bad, message: err)
                        .accessibilityLabel("License activation error: \(err)")
                }
            }
        }
    }

    /// Leading premium glyph — gold "bolt" for licensed/grandfathered (the v4
    /// gold-premium accent), royal-blue for an active trial, signal-tinted when
    /// lapsed. Echoes the design source's gold license mark.
    private var premiumGlyph: some View {
        let (symbol, tint): (String, Color) = {
            switch state.kind {
            case .trial:           return ("bolt.fill", BridgeTokens.accentLink)
            case .trialExpired:    return ("bolt.slash.fill", BridgeTokens.badText)
            case .licensed:        return ("bolt.fill", BridgeTokens.goldSoft)
            case .licenseExpired:  return ("bolt.slash.fill", BridgeTokens.warnText)
            case .grandfathered:   return ("bolt.fill", BridgeTokens.goldSoft)
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    // MARK: Status pill (visible on every variant)

    private var statusPillColor: Color {
        switch state.kind {
        case .trial:           return BridgeTokens.accent
        case .trialExpired:    return BridgeTokens.bad
        case .licensed:        return BridgeTokens.ok
        case .licenseExpired:  return BridgeTokens.warn
        case .grandfathered:   return BridgeTokens.ok
        }
    }

    private var statusPillLabel: String {
        switch state.kind {
        case .trial(let d):       return d == 1 ? "Trial · 1 day left" : "Trial · \(d) days left"
        case .trialExpired:       return "Trial expired"
        case .licensed:           return "Licensed"
        case .licenseExpired:     return "License expired"
        case .grandfathered:      return "Licensed (3.x)"
        }
    }

    private var statusPill: some View {
        Text(statusPillLabel)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(statusPillColor.opacity(0.18), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(statusPillColor.opacity(0.45), lineWidth: 0.5))
            .foregroundStyle(statusPillColor.opacity(0.95))
            .accessibilityLabel("License status: \(statusPillLabel)")
    }

    // MARK: Per-variant content

    @ViewBuilder
    private var content: some View {
        switch state.kind {
        case .trial(let d):
            VStack(alignment: .leading, spacing: 8) {
                Text(d == 1
                     ? "Your Bridge trial ends within 24 hours. Activate a license to keep automating after the trial ends."
                     : "Your Bridge trial has \(d) days left. Bring a license now to skip the countdown later.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BridgeTokens.fg3)
                pasteRow
                buyRow
            }
        case .trialExpired:
            VStack(alignment: .leading, spacing: 8) {
                Text("Your trial has ended. The Bridge will refuse to dispatch tools until a license is activated. Local data is untouched and will resume the moment a key activates.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BridgeTokens.fg3)
                pasteRow
                buyRow
            }
        case .licensed(let subject, let expS):
            VStack(alignment: .leading, spacing: 6) {
                licenseKVRow("Licensed to", subject, muted: false)
                if let expS = expS {
                    licenseKVRow("Expires", expS, muted: false)
                } else {
                    licenseKVRow("Expires", "Never", muted: true)
                }
                HStack {
                    Spacer()
                    BridgeButton("Remove license", variant: .danger, action: onDeactivate)
                }
            }
        case .licenseExpired(let subject, let expS):
            VStack(alignment: .leading, spacing: 8) {
                Text("Your license\(expS.map { " (expired \($0))" } ?? "") has lapsed. Activate a renewed key or remove the expired one.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BridgeTokens.fg3)
                Text(subject).font(.system(size: 12)).foregroundStyle(BridgeTokens.fg4)
                pasteRow
                HStack {
                    Spacer()
                    BridgeButton("Remove license", variant: .danger, action: onDeactivate)
                }
            }
        case .grandfathered:
            VStack(alignment: .leading, spacing: 6) {
                Text("You upgraded from a previous version of The Bridge — your install is licensed automatically and no trial countdown will appear. Thank you for being an early user.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BridgeTokens.fg3)
            }
        }
    }

    /// Key/value row used by the `.licensed` variant — mirrors the
    /// About-card kv treatment so the two cards read as one family.
    @ViewBuilder
    private func licenseKVRow(_ key: String, _ value: String, muted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg3)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(muted ? BridgeTokens.fg4 : BridgeTokens.fg1)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: Paste + activate row

    private var pasteRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // v4 well input (mirrors the credential-sheet field treatment):
                // recessed fill + hairline, mono face for the key.
                TextField("License key (paste here)", text: $pasteField)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg1)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                    .accessibilityLabel("License key input")
                BridgeButton(
                    "Activate",
                    variant: .primary,
                    isEnabled: !pasteField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.canPasteActivate,
                    action: onActivate
                )
            }
            if !state.canPasteActivate {
                Text("Paste-activation is unavailable in this build (no bundled public key). Reach out to support if you have a valid key.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
            }
        }
    }

    private var buyRow: some View {
        HStack {
            Spacer()
            BridgeButton("Buy a license", variant: .default, action: onBuy)
        }
    }
}
