// BridgeThemeV2.swift — Liquid Glass extensions for The Bridge 3.5
// PKT-2 v3.5. Builds on the existing BridgeTheme tokens with the
// surfaces the design pass requires: Notion color palette, glass card +
// bubble, dep-link chip, partial toggle, jump links.
//
// macOS 26+ — Liquid Glass material is native; no fallback path needed
// per Package.swift `.macOS(.v26)`.

import SwiftUI
import AppKit

// MARK: - Notion color palette

/// Notion's swatch palette used across icon pickers and dep-link chips.
public enum NotionPalette {
    public static let gray   = Color(red: 0.608, green: 0.604, blue: 0.592)
    public static let brown  = Color(red: 0.392, green: 0.278, blue: 0.227)
    public static let orange = Color(red: 0.851, green: 0.451, blue: 0.051)
    public static let yellow = Color(red: 0.874, green: 0.670, blue: 0.004)
    public static let green  = Color(red: 0.058, green: 0.482, blue: 0.424)
    public static let blue   = Color(red: 0.043, green: 0.431, blue: 0.600)
    public static let purple = Color(red: 0.411, green: 0.251, blue: 0.647)
    public static let pink   = Color(red: 0.678, green: 0.102, blue: 0.447)
    public static let red    = Color(red: 0.878, green: 0.243, blue: 0.243)

    public static let all: [(name: String, color: Color)] = [
        ("gray", gray), ("brown", brown), ("orange", orange),
        ("yellow", yellow), ("green", green), ("blue", blue),
        ("purple", purple), ("pink", pink), ("red", red),
    ]

    /// Map a name string ("blue", "orange", ...) → Color. Stable for use
    /// from non-View code (e.g. CommandStore.NotionColor → SwiftUI Color).
    public static func color(named name: String) -> Color? {
        all.first(where: { $0.name == name })?.color
    }
}

// MARK: - Glass surfaces

/// Reusable Liquid Glass card. Wraps content with the rounded-rect
/// translucent material, subtle rim highlight, and inset glow.
public struct BridgeGlassCard<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat
    private let padding: CGFloat

    // System-tethered (v3.7.6): the white sheen + white hairlines assume a dark
    // base and VANISH on titanium. On LIGHT we swap to a subtle dark/neutral
    // sheen + a darker hairline so cards still read as RAISED glass; DARK is
    // byte-for-byte unchanged.
    @Environment(\.colorScheme) private var colorScheme

    public init(
        cornerRadius: CGFloat = 12,
        padding: CGFloat = 14,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.padding = padding
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        // Sheen gradient (top→bottom). DARK: white .07→.02 (unchanged).
        // LIGHT: a brighter near-white lift on top fading out, so the card
        // surface reads slightly raised off the #ECEDEF canvas.
        let sheenTop    = isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.65)
        let sheenBottom = isDark ? Color.white.opacity(0.02) : Color.white.opacity(0.30)
        // Tint opacity: the dark tint sits low; the light neutral tint sits even
        // lower so it just cools the white sheen rather than graying the card.
        let tintOpacity = isDark ? 0.20 : 0.10
        // Edge hairline. DARK: white@.10 (unchanged). LIGHT: black@.06 so the
        // card has a visible darker border on the light ground.
        let hairline = isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        // Top rim highlight. DARK: white@.25 (unchanged). LIGHT: a soft white
        // rim still helps, but darker beneath — keep a faint white top rim.
        let rimHighlight = isDark ? Color.white.opacity(0.25) : Color.white.opacity(0.55)

        return content
            .padding(padding)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [sheenTop, sheenBottom],
                        startPoint: .top, endPoint: .bottom
                    )
                    BridgeTokens.glassCardTint.opacity(tintOpacity)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(hairline, lineWidth: 0.5)
            )
            .overlay(
                // top rim highlight
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(
                        LinearGradient(
                            colors: [rimHighlight, .clear],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            )
    }
}

/// Section-header label rendered inside cards (small caps).
public struct BridgeCardLabel: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(BridgeTokens.fg3)
    }
}

/// A small inline "→ jump to X" deep-link chip used to surface cross-page
/// dependencies (Tools → Permissions, Credentials → Tools, etc.).
public struct BridgeDepLink: View {
    public enum Variant: Sendable { case info, bad }
    private let label: String
    private let variant: Variant
    private let action: () -> Void

    public init(_ label: String, variant: Variant = .info, action: @escaping () -> Void) {
        self.label = label
        self.variant = variant
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                Text("↗").opacity(0.7)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
            .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch variant {
        case .info: return BridgeTokens.accent.opacity(0.10)
        case .bad:  return BridgeTokens.bad.opacity(0.10)
        }
    }
    private var border: Color {
        switch variant {
        case .info: return BridgeTokens.accent.opacity(0.20)
        case .bad:  return BridgeTokens.bad.opacity(0.28)
        }
    }
    private var foreground: Color {
        switch variant {
        case .info: return BridgeTokens.infoText
        case .bad:  return BridgeTokens.badText
        }
    }
}

// MARK: - Partial-state toggle (used by Tools module groups)

/// `ToggleStyle` representing three states: all-on / all-off / partial.
/// "Partial" renders an amber knob mid-track so the user sees that some
/// children are enabled and some are not.
public enum TripleState: Sendable, Equatable {
    case off, partial, on
}

public struct PartialToggle: View {
    @Binding public var state: TripleState
    public init(state: Binding<TripleState>) { self._state = state }

    public var body: some View {
        Button(action: cycle) {
            ZStack(alignment: alignment) {
                Capsule()
                    .fill(track)
                    .frame(width: 40, height: 24)
                    .overlay(Capsule().strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                Circle()
                    .fill(LinearGradient(colors: [.white, Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .padding(.horizontal, 3)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: state)
    }

    private var alignment: Alignment {
        switch state {
        case .off:     return .leading
        case .partial: return .center
        case .on:      return .trailing
        }
    }
    private var track: LinearGradient {
        switch state {
        case .off:
            return LinearGradient(
                colors: [BridgeTokens.chipFill, BridgeTokens.chipFill],
                startPoint: .top, endPoint: .bottom)
        case .partial:
            return LinearGradient(
                colors: [BridgeTokens.warn.opacity(0.55), BridgeTokens.warn.opacity(0.40)],
                startPoint: .top, endPoint: .bottom)
        case .on:
            return LinearGradient(
                colors: [BridgeTokens.ok.opacity(0.65), BridgeTokens.ok.opacity(0.55)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    private func cycle() {
        // Click semantics per design Q6: from .partial, complete to .on; from
        // .on go to .off; from .off go to .on.
        switch state {
        case .off:     state = .on
        case .partial: state = .on
        case .on:      state = .off
        }
    }
}

// MARK: - Glass bubble (Command Bridge popup tray)

/// One favorite-slot bubble in the Command Bridge tray. 52pt circle with
/// the icon centered. Empty slots render as `visibility:hidden` so spatial
/// position is preserved (per locked design).
public struct BridgeGlassBubble<Content: View>: View {
    private let content: Content?
    private let size: CGFloat

    // System-tethered (v3.7.6): the white specular dome + white rim assume a
    // dark base and VANISH on titanium, leaving a flat invisible slot. On LIGHT
    // we swap to a subtle near-white sheen over a faint neutral tint plus a
    // darker rim so the bubble still reads as a RAISED glass dome; DARK is
    // byte-for-byte unchanged.
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = 52, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.size = size
    }

    /// Empty-slot constructor — renders an invisible placeholder of the
    /// same size so the tray's number-key positions stay aligned.
    public static func empty(size: CGFloat = 52) -> BridgeGlassBubble<EmptyView> {
        BridgeGlassBubble<EmptyView>(size: size, content: { EmptyView() })
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        // Specular dome (hotspot → falloff). DARK: white .42→.10→.02 (unchanged).
        // LIGHT: a softer white sheen that fades to clear over the neutral tint.
        let domeColors: [Color] = isDark
            ? [Color.white.opacity(0.42), Color.white.opacity(0.10), Color.white.opacity(0.02)]
            : [Color.white.opacity(0.70), Color.white.opacity(0.22), Color.white.opacity(0.0)]
        // Surface tint under the sheen. DARK: white@.06 (unchanged). LIGHT: a
        // faint neutral well so the dome sits on a cooler, slightly-recessed base.
        let surfaceTint = isDark ? Color.white.opacity(0.06) : BridgeTokens.chipFill
        // Rim. DARK: white@.18 (unchanged). LIGHT: a darker hairline edge.
        let rim = isDark ? Color.white.opacity(0.18) : BridgeTokens.hairlineStrong
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: domeColors,
                        center: UnitPoint(x: 0.3, y: 0.18),
                        startRadius: 0, endRadius: size * 0.9
                    )
                )
                .overlay(Circle().fill(surfaceTint))
            Circle().strokeBorder(rim, lineWidth: 1)
            content
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.32), radius: 7, y: 6)
    }
}

// MARK: - SF Symbol section-nav icons

/// Single source of truth for the sidebar nav icon used per section.
/// Matches the SVG glyphs in `design/shell.js` order.
public enum BridgeSectionIcon {
    public static func systemImage(for section: SettingsSection) -> String {
        switch section {
        case .standingOrders: return "scroll"
        case .commands:       return "command"
        case .connections:    return "network"
        case .remoteAccess:   return "cloud"
        case .skills:         return "sparkles"
        case .permissions:    return "lock.shield"
        case .credentials:    return "key.fill"
        case .tools:          return "hammer"
        case .jobs:           return "clock.badge.checkmark"
        case .advanced:       return "wrench.and.screwdriver"
        }
    }
}
