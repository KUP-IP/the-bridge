// BridgeTheme.swift — Design System for NotionBridge
// PKT-353: Liquid Glass + Popover Redesign
// Semantic color palette, spacing scale, and reusable ViewModifiers
// Applied to DashboardView; other UI files can adopt incrementally.

import SwiftUI

// MARK: - Color Palette

/// Semantic color palette for NotionBridge UI.
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

/// Single-pill labeled badge. Replaces ad-hoc HStack badges scattered
/// across rows; one component = one visual language across the app.
struct BridgeBadge: View {
    let label: String
    let systemImage: String?
    let tone: Tone

    enum Tone {
        case neutral
        case info
        case success
        case warning

        var background: Color {
            switch self {
            case .neutral: return Color.secondary.opacity(0.10)
            case .info:    return BridgeTokens.accent.opacity(0.12)
            case .success: return BridgeTokens.ok.opacity(0.12)
            case .warning: return BridgeTokens.warn.opacity(0.14)
            }
        }
        var foreground: Color {
            switch self {
            case .neutral: return Color.secondary
            case .info:    return BridgeTokens.infoText
            case .success: return BridgeTokens.okText
            case .warning: return BridgeTokens.warnText
            }
        }
    }

    init(_ label: String, systemImage: String? = nil, tone: Tone = .neutral) {
        self.label = label
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, BridgeSpacing.xs)
        .padding(.vertical, 3)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 4))
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
