// BridgeShell.swift — Resurface shell for The Bridge (v3.7.2).
// The carbon "stage" wallpaper, the custom Liquid-Glass section-nav, the
// hero titlebar + footbar, and the four custom vector glyphs (bow / crossed
// tools / two gears / key) the operator flagged. Mirrors design/design-system
// (kit.css .desktop / .secnav / .sec / .titlebar / .footbar) — the SSOT.
//
// Colors come from BridgeTokens; nothing here hardcodes a palette value.

import SwiftUI

// MARK: - The stage (carbon base + three mood lights + carbon-fibre weave)

/// Full-bleed background behind every glass surface. A SOLID carbon fill —
/// no gradient/aurora — with a faint carbon-fibre weave layered as texture.
/// Color enters the UI only through small accents (blue/gold) + signals.
public struct BridgeStage: View {
    public init() {}

    public var body: some View {
        ZStack {
            BridgeTokens.bgCanvas
            BridgeCarbonWeave()
        }
        .ignoresSafeArea()
    }
}

/// Subtle diagonal cross-hatch evoking carbon fibre, layered over the canvas
/// fill. Faint by design. On DARK: white .02 / black .22 hairlines (unchanged
/// carbon weave). On LIGHT: a whisper — the harsh black@.22 would scar the
/// titanium ground, so the woven texture is preserved with a faint dark
/// hairline (black@.04) plus a soft white highlight. Drawn once per size.
struct BridgeCarbonWeave: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Resolve stroke styling for the active appearance up front so the
        // Canvas closure (which captures by value) stays cheap & deterministic.
        let isDark = colorScheme == .dark
        let highlight = isDark ? Color.white.opacity(0.02) : Color.white.opacity(0.30)
        let shadow    = isDark ? Color.black.opacity(0.22) : Color.black.opacity(0.04)
        return Canvas { ctx, size in
            let step: CGFloat = 4
            var light = Path()
            var dark = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                light.move(to: CGPoint(x: x, y: 0));    light.addLine(to: CGPoint(x: x + size.height, y: size.height))
                dark.move(to: CGPoint(x: x + 2, y: 0));  dark.addLine(to: CGPoint(x: x + 2 + size.height, y: size.height))
                x += step
            }
            ctx.stroke(light, with: .color(highlight), lineWidth: 1)
            ctx.stroke(dark,  with: .color(shadow),    lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Custom vector glyphs (the four the operator flagged)

/// The four hero nav glyphs drawn from the design system's inline SVG
/// (Lucide/Tabler idiom), translated to a 24-grid SwiftUI path. Stroked with
/// the ambient foreground style so they inherit nav state colors.
public struct BridgeVectorIcon: View {
    public enum Glyph: Sendable { case skills, tools, advanced, credentials }
    public let glyph: Glyph
    public init(_ glyph: Glyph) { self.glyph = glyph }

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let lineWidth = (glyph == .advanced ? 1.4 : 1.8) * size / 24.0
            BridgeIconShape(glyph: glyph)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct BridgeIconShape: Shape {
    let glyph: BridgeVectorIcon.Glyph

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func ring(_ cx: CGFloat, _ cy: CGFloat, _ rr: CGFloat) -> CGRect {
            CGRect(x: (cx - rr) * s, y: (cy - rr) * s, width: 2 * rr * s, height: 2 * rr * s)
        }
        var path = Path()

        switch glyph {
        case .skills: // bow & arrow
            // arrow fletching (top-right) + shaft + nock (bottom-left)
            path.move(to: p(17, 3)); path.addLine(to: p(21, 3)); path.addLine(to: p(21, 7))
            path.move(to: p(21, 3)); path.addLine(to: p(6, 18))
            path.move(to: p(3, 18)); path.addLine(to: p(6, 18)); path.addLine(to: p(6, 21))
            // bow arc (three cubic segments + closing chord)
            path.move(to: p(16.5, 20))
            path.addCurve(to: p(19, 13.5),  control1: p(18.08, 18.42), control2: p(19, 15.9))
            path.addCurve(to: p(10.5, 5),   control1: p(19, 8.69),     control2: p(15.31, 5))
            path.addCurve(to: p(4, 7.5),    control1: p(8.08, 5),      control2: p(5.58, 5.91))
            path.addLine(to: p(16.5, 20))

        case .tools: // crossed hammer + wrench
            path.move(to: p(3, 21)); path.addLine(to: p(7, 21)); path.addLine(to: p(20, 8))
            path.addQuadCurve(to: p(16, 4), control: p(18.2, 5.8)) // ≈ a1.5 1.5 0 0 0 -4 -4
            path.addLine(to: p(3, 17)); path.addLine(to: p(3, 21))
            path.move(to: p(14.5, 5.5)); path.addLine(to: p(18.5, 9.5))
            path.move(to: p(12, 8)); path.addLine(to: p(7, 3)); path.addLine(to: p(3, 7)); path.addLine(to: p(8, 12))
            path.move(to: p(7, 8)); path.addLine(to: p(5.5, 9.5))
            path.move(to: p(16, 12)); path.addLine(to: p(21, 17)); path.addLine(to: p(17, 21)); path.addLine(to: p(12, 16))
            path.move(to: p(16, 17)); path.addLine(to: p(14.5, 18.5))

        case .advanced: // two gears
            path.addEllipse(in: ring(9, 9, 2.6))
            path.move(to: p(9, 3));    path.addLine(to: p(9, 4.6))
            path.move(to: p(9, 13.4)); path.addLine(to: p(9, 15))
            path.move(to: p(3, 9));    path.addLine(to: p(4.6, 9))
            path.move(to: p(13.4, 9)); path.addLine(to: p(15, 9))
            path.move(to: p(5.1, 5.1)); path.addLine(to: p(6.2, 6.2))
            path.move(to: p(11.8, 11.8)); path.addLine(to: p(12.9, 12.9))
            path.move(to: p(5.1, 12.9)); path.addLine(to: p(6.2, 11.8))
            path.move(to: p(11.8, 6.2)); path.addLine(to: p(12.9, 5.1))
            path.addEllipse(in: ring(16.5, 16.5, 1.9))
            path.move(to: p(16.5, 12.9)); path.addLine(to: p(16.5, 13.9))
            path.move(to: p(16.5, 20.1)); path.addLine(to: p(16.5, 19.1))
            path.move(to: p(12.9, 16.5)); path.addLine(to: p(13.9, 16.5))
            path.move(to: p(20.1, 16.5)); path.addLine(to: p(19.1, 16.5))
            path.move(to: p(14.4, 14.4)); path.addLine(to: p(15.1, 15.1))
            path.move(to: p(18.6, 18.6)); path.addLine(to: p(17.9, 17.9))
            path.move(to: p(14.4, 18.6)); path.addLine(to: p(15.1, 17.9))
            path.move(to: p(18.6, 14.4)); path.addLine(to: p(17.9, 15.1))

        case .credentials: // key
            path.addEllipse(in: ring(7.5, 15.5, 5.5))
            path.move(to: p(21, 2)); path.addLine(to: p(11.4, 11.6))
            path.move(to: p(15.5, 7.5)); path.addLine(to: p(18.5, 10.5)); path.addLine(to: p(22, 7)); path.addLine(to: p(19, 4))
        }
        return path
    }
}

// MARK: - Section nav (custom 188px .secnav)

/// The locked design's left section-nav. Replaces the native
/// NavigationSplitView sidebar so we control the glass + custom icons while
/// keeping `nav.section` as the single selection source (deep-link safe).
public struct BridgeSectionNav: View {
    @Binding public var selection: SettingsSection
    public init(selection: Binding<SettingsSection>) { self._selection = selection }

    public var body: some View {
        VStack(spacing: 1) {
            ForEach(SettingsSection.allCases) { section in
                BridgeSectionNavItem(
                    section: section,
                    isSelected: section == selection,
                    action: { selection = section }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: 188)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(colors: [BridgeTokens.hairlineFaint, BridgeTokens.hairlineFaint.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .trailing) {
            Rectangle().fill(BridgeTokens.hairline).frame(width: 0.5)
        }
        // Restore the keyboard navigation NavigationSplitView's List gave us
        // for free: Up/Down arrows move `selection` to the previous/next
        // SettingsSection. Clamps at the ends (no wrap); mouse clicking and
        // the per-item visual states are untouched.
        .focusable()
        .onMoveCommand { direction in
            moveSelection(direction)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = SettingsSection.allCases
        guard let current = sections.firstIndex(of: selection) else { return }
        switch direction {
        case .up:
            let next = max(sections.startIndex, current - 1)
            selection = sections[next]
        case .down:
            let next = min(sections.index(before: sections.endIndex), current + 1)
            selection = sections[next]
        default:
            break
        }
    }
}

struct BridgeSectionNavItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 18, height: 18)
                    .foregroundStyle(isSelected ? BridgeTokens.fg1 : BridgeTokens.fg4)
                Text(section.rawValue)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? BridgeTokens.fg1 : BridgeTokens.fg3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch section {
        case .skills:      BridgeVectorIcon(.skills)
        case .tools:       BridgeVectorIcon(.tools)
        case .advanced:    BridgeVectorIcon(.advanced)
        case .credentials: BridgeVectorIcon(.credentials)
        default:           Image(systemName: section.icon).font(.system(size: 14))
        }
    }

    @ViewBuilder private var background: some View {
        if isSelected {
            BridgeTokens.accent.opacity(0.14)
        } else if hovering {
            BridgeTokens.hoverFill
        } else {
            Color.clear
        }
    }
}

// MARK: - Hero titlebar + footbar

/// 44px titlebar: leaves room for the native traffic lights, centers the
/// breadcrumb title. Sits inside the full-size-content window.
public struct BridgeTitleBar: View {
    public let title: String
    public init(title: String) { self.title = title }

    public var body: some View {
        ZStack {
            HStack(spacing: 6) {
                Text("The Bridge").foregroundStyle(BridgeTokens.fg4)
                Text("›").foregroundStyle(BridgeTokens.fg5)
                Text(title).foregroundStyle(BridgeTokens.fg2)
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)
        }
    }
}

/// 30px footbar with a subtle version readout + neutral status dot.
public struct BridgeFootBar: View {
    public let version: String
    public init(version: String) { self.version = version }

    public var body: some View {
        HStack(spacing: 6) {
            Text("The Bridge").foregroundStyle(BridgeTokens.fg4)
            Spacer(minLength: 0)
            Text(version).foregroundStyle(BridgeTokens.fg4)
            Circle().fill(BridgeTokens.ok).frame(width: 7, height: 7)
                .shadow(color: BridgeTokens.ok.opacity(0.55), radius: 3)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(BridgeTokens.chipFill)
        .overlay(alignment: .top) {
            Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)
        }
    }
}
