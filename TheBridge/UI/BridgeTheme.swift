// BridgeTheme.swift — Design System for The Bridge
// PKT-353: Liquid Glass + Popover Redesign
// Semantic color palette, spacing scale, and reusable ViewModifiers
// Applied to DashboardView; other UI files can adopt incrementally.

import SwiftUI

// MARK: - Color Palette

/// Semantic color palette for The Bridge UI.
/// Uses system-adaptive colors that work with Liquid Glass materials.
enum BridgeColors {
    /// Primary text color — high contrast, used for headings and key labels
    static let primary = Color.primary

    /// Secondary text color — medium contrast, used for supporting text
    static let secondary = Color.secondary

    /// Success indicator — server running, connected status (emerald #13B87A)
    static let success = BridgeTokens.ok

    /// Warning indicator — partial, expiring, needs attention (amber #E9A93A)
    static let warning = BridgeTokens.warn

    /// Error indicator — server stopped, disconnected status (red #C23A3A)
    static let error = BridgeTokens.bad

    /// Interactive accent — primary buttons, selection, links (royal blue #2A48C0)
    static let accent = BridgeTokens.accent

    /// Muted text color — tertiary info, timestamps, subtle labels
    static let muted = Color(nsColor: .tertiaryLabelColor)
}

// MARK: - Spacing Scale

/// Consistent spacing constants based on a 4pt grid.
enum BridgeSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
}

// MARK: - View Modifiers

/// Standard label style for primary row labels in the dashboard.
/// Callout font, primary color, no extra weight.
struct BridgeLabelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .foregroundStyle(BridgeColors.primary)
    }
}

/// Secondary value style for supporting info — version numbers, timestamps, stats.
/// Caption font, secondary color.
struct BridgeSecondaryModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(BridgeColors.secondary)
    }
}

/// Standard row layout modifier — consistent horizontal padding and vertical spacing.
/// Used for each content section in the dashboard popover.
struct BridgeRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, BridgeSpacing.md)
            .padding(.vertical, BridgeSpacing.sm)
    }
}

// MARK: - View Extensions

extension View {
    /// Apply primary label styling (callout font, primary color).
    func bridgeLabel() -> some View {
        modifier(BridgeLabelModifier())
    }

    /// Apply secondary value styling (caption font, secondary color).
    func bridgeSecondary() -> some View {
        modifier(BridgeSecondaryModifier())
    }

    /// Apply standard row padding (16pt horizontal, 12pt vertical).
    func bridgeRow() -> some View {
        modifier(BridgeRowModifier())
    }
}

// MARK: - W4 (3.4.1): Shared Components — used across all 7 Settings tabs.

/// Single-pill labeled badge — the v4 `.badge` status pill. One component =
/// one visual language across the app.
///
/// v4: refined to a 999px pill (20px tall) with a `.5px` signal-tinted border
/// over a translucent signal fill + the signal *Text token for the label, per
/// materials.css / preview/cmp-badges-chips.html. The five tones map to the
/// design's `ok · warn · bad · neutral · info`. The pre-v4 `.success` /
/// `.warning` cases are kept as back-compat aliases of `ok` / `warn`, and a new
/// `.bad` (== `.error`) tone is added (additive). Signal colors come from the
/// W1 tokens, so both carbon + titanium are covered.
struct BridgeBadge: View {
    let label: String
    let systemImage: String?
    let tone: Tone
    let showsDot: Bool

    enum Tone {
        case neutral
        case info
        case ok
        case warn
        case bad
        // ── back-compat aliases (pre-v4 call sites) ──
        case success   // == ok
        case warning   // == warn

        /// Collapse the alias cases to the five canonical signals.
        fileprivate var canonical: Tone {
            switch self {
            case .success: return .ok
            case .warning: return .warn
            default:       return self
            }
        }

        /// Translucent signal fill (`color-mix(in srgb, <signal> ~16%, transparent)`).
        var background: Color {
            switch canonical {
            case .neutral: return BridgeTokens.chipFill
            case .info:    return BridgeTokens.accent.opacity(0.16)
            case .ok:      return BridgeTokens.ok.opacity(0.16)
            case .warn:    return BridgeTokens.warn.opacity(0.16)
            case .bad:     return BridgeTokens.bad.opacity(0.15)
            case .success, .warning: return .clear // unreachable (canonicalized)
            }
        }
        /// `.5px` signal-tinted border (`color-mix(<signal> ~32%, transparent)`),
        /// or the `accentBorder` token for `.info`, the hairline for `.neutral`.
        var border: Color {
            switch canonical {
            case .neutral: return BridgeTokens.hairline
            case .info:    return BridgeTokens.accentBorder
            case .ok:      return BridgeTokens.ok.opacity(0.32)
            case .warn:    return BridgeTokens.warn.opacity(0.34)
            case .bad:     return BridgeTokens.bad.opacity(0.30)
            case .success, .warning: return .clear // unreachable
            }
        }
        var foreground: Color {
            switch canonical {
            case .neutral: return BridgeTokens.fg3
            case .info:    return BridgeTokens.infoText
            case .ok:      return BridgeTokens.okText
            case .warn:    return BridgeTokens.warnText
            case .bad:     return BridgeTokens.badText
            case .success, .warning: return .clear // unreachable
            }
        }
    }

    /// `showsDot` prepends a 6px `currentColor` status dot (materials.css
    /// `.badge .dot`). Off by default to preserve the prior badge silhouette.
    init(_ label: String, systemImage: String? = nil, tone: Tone = .neutral, showsDot: Bool = false) {
        self.label = label
        self.systemImage = systemImage
        self.tone = tone
        self.showsDot = showsDot
    }

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(tone.foreground).frame(width: 6, height: 6)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(BridgeTokens.Typeface.cap)
            }
            Text(label)
                .font(BridgeTokens.Typeface.cap)
                .tracking(0.1)   // `.badge { letter-spacing: .01em }`
        }
        .foregroundStyle(tone.foreground)
        .frame(height: 20)
        .padding(.horizontal, 9)
        .background(tone.background, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(tone.border, lineWidth: 0.5))
        .accessibilityLabel(systemImage == nil ? label : "\(label), \(systemImage!)")
    }
}

/// macOS-style keyboard-chip group. Renders one keycap per modifier and
/// the trailing key. Replaces the plain bordered text field used to
/// display the Commands hot-key.
public struct BridgeKbdChips: View {
    public let chips: [String]

    /// Pure, nonisolated chip splitter — extracted so headless tests can
    /// exercise the logic without entering the MainActor.
    public nonisolated static func splitChips(displayString: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        let modifierSet: Set<Character> = ["\u{2303}", "\u{2325}", "\u{2318}", "\u{21E7}"] // ⌃ ⌥ ⌘ ⇧
        for ch in displayString {
            if modifierSet.contains(ch) {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(String(ch))
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Convenience: split a display string like `⌃⌥⌘C` into chips. Each
    /// modifier symbol becomes its own chip; the trailing non-modifier
    /// characters become the final chip.
    public init(displayString: String) {
        self.chips = Self.splitChips(displayString: displayString)
    }

    public init(chips: [String]) {
        self.chips = chips
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                Text(c)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.30), lineWidth: 0.5)
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keyboard shortcut " + chips.joined(separator: " "))
    }
}

/// Empty-state card. Used when a list has zero items in some semantic
/// state ("0 skills in palette", "0 connections configured", etc.).
/// Provides an icon, title, body, and an optional primary CTA.
struct BridgeEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    let primaryAction: PrimaryAction?

    struct PrimaryAction {
        let label: String
        let action: () -> Void
    }

    init(
        systemImage: String,
        title: String,
        body: String,
        primaryAction: PrimaryAction? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = body
        self.primaryAction = primaryAction
    }

    var body: some View {
        HStack(alignment: .top, spacing: BridgeSpacing.sm) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: BridgeSpacing.xxs) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let p = primaryAction {
                    Button(p.label, action: p.action)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .padding(.top, BridgeSpacing.xxs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(BridgeSpacing.sm)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}
