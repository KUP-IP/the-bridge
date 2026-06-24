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
    // sRGB byte-exact to tokens.css `--c-*` (the v4 SSOT, authoritative).
    public static let gray   = Color(red: 0.608, green: 0.604, blue: 0.592) // #9B9A97
    public static let brown  = Color(red: 0.392, green: 0.278, blue: 0.227) // #64473A
    public static let orange = Color(red: 0.851, green: 0.451, blue: 0.051) // #D9730D
    public static let yellow = Color(red: 0.875, green: 0.671, blue: 0.004) // #DFAB01
    public static let green  = Color(red: 0.059, green: 0.482, blue: 0.424) // #0F7B6C
    public static let blue   = Color(red: 0.043, green: 0.431, blue: 0.600) // #0B6E99
    public static let purple = Color(red: 0.412, green: 0.251, blue: 0.647) // #6940A5
    public static let pink   = Color(red: 0.678, green: 0.102, blue: 0.447) // #AD1A72
    public static let red    = Color(red: 0.878, green: 0.243, blue: 0.243) // #E03E3E

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

/// Reusable Liquid Glass card — the e1 "workhorse container" (`.glass-card`).
///
/// v4: repainted entirely through the W1 `BridgeTokens.Elevation.card` rung, so
/// the four depth ingredients (surface fill + sheen · directional bevel · edge
/// hairline · dual drop shadow) are token-driven and adapt to carbon/titanium
/// for free. A faint top-edge specular `rim` strip is layered for the
/// thick-glass read. The public initializer is byte-for-byte unchanged —
/// downstream pages keep calling `BridgeGlassCard(cornerRadius:padding:)`.
public struct BridgeGlassCard<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat
    private let padding: CGFloat

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
        let rung = BridgeTokens.Elevation.card
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .padding(padding)
            // Ingredient 1 — surface fill (opaque base + top→bottom sheen).
            .background(rung.fill?.paint(in: shape))
            // Ingredient 3 — elevation EDGE hairline (.5px, materials.css `.glass-card`).
            .overlay(rung.edge.map { shape.strokeBorder($0, lineWidth: 0.5) })
            // Ingredient 2 — directional bevel (top rim-light + bottom occlusion).
            .bridgeBevel(rung.bevel, radius: cornerRadius)
            // Specular top-edge rim strip (`--rim`, top 1.5px) — sells thick glass.
            .overlay(
                shape
                    .inset(by: 0.5)
                    .stroke(BridgeTokens.rim, lineWidth: 1.0)
                    .mask(
                        LinearGradient(
                            colors: [.black, .black, .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            )
            .clipShape(shape)
            // Ingredient 4 — dual ambient + contact drop shadow.
            .modifier(OptionalShadow(rung.shadow))
    }
}

/// Applies a `BridgeShadow` when present; a no-op when the rung carries none.
private struct OptionalShadow: ViewModifier {
    let shadow: BridgeTokens.BridgeShadow?
    init(_ shadow: BridgeTokens.BridgeShadow?) { self.shadow = shadow }
    @ViewBuilder
    func body(content: Content) -> some View {
        if let s = shadow { content.bridgeShadow(s) } else { content }
    }
}

/// Section-header label rendered inside cards (small caps).
public struct BridgeCardLabel: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .bridgeCap()
            .foregroundStyle(BridgeTokens.fg4)
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
            .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
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

    // Geometry from materials.css `.toggle` + preview/cmp-toggles.html:
    // 40×24 track, 18×18 knob, 2px inset → knob travels 0 / 8 / 16px.
    private static let trackW: CGFloat = 40
    private static let trackH: CGFloat = 24
    private static let knob: CGFloat   = 18
    private static let inset: CGFloat  = 2

    public var body: some View {
        Button(action: cycle) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                    .frame(width: Self.trackW, height: Self.trackH)
                    .overlay(Capsule().strokeBorder(trackBorder, lineWidth: 0.5))
                    // Inset bevel — the recessed well the knob rides in.
                    .overlay(BridgeTokens.bevelInset.overlay(in: Capsule()))
                knobView
                    .offset(x: knobOffset)
            }
            .frame(width: Self.trackW, height: Self.trackH)
        }
        .buttonStyle(.plain)
        // Background transition `--fast` (.15s); knob travel `--med` (.22s ease).
        .animation(.easeInOut(duration: 0.15), value: state)
        .accessibilityValue(accessibilityValue)
    }

    /// White knob with its OWN inset highlight (`inset 0 1px 0 rgba(255,255,255,.5)`)
    /// + drop + .5px contact ring. Partial tints the knob lightly amber per the
    /// preview spec so the mid-track position reads as "some, not all".
    private var knobView: some View {
        let topTint: Color = (state == .partial)
            ? Color(red: 0.953, green: 0.890, blue: 0.659)   // #f3e3a8 (preview partial knob)
            : Color(white: 0.84)                              // #d6d6d6
        return Circle()
            .fill(LinearGradient(colors: [.white, topTint], startPoint: .top, endPoint: .bottom))
            .frame(width: Self.knob, height: Self.knob)
            .overlay(
                // knob's own top inset highlight
                Circle().inset(by: 0.5)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: .black.opacity(0.4), radius: 1.25, y: 1)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
            .animation(.easeInOut(duration: 0.22), value: state)
    }

    /// Knob x-offset within the 2px-inset track: 0 (off) · 8 (partial, mid) · 16 (on).
    private var knobOffset: CGFloat {
        let travel = Self.trackW - Self.knob - Self.inset * 2   // 16
        switch state {
        case .off:     return Self.inset
        case .partial: return Self.inset + travel / 2           // mid-track
        case .on:      return Self.inset + travel
        }
    }

    /// off = neutral glass · on = GREEN gradient (health-coded) · partial = AMBER
    /// gradient. Greens/ambers from preview/cmp-toggles.html (the richer spec the
    /// packet quotes); neutral uses the adaptive `chipFill` token.
    private var track: LinearGradient {
        switch state {
        case .off:
            return LinearGradient(
                colors: [BridgeTokens.chipFill, BridgeTokens.chipFill],
                startPoint: .top, endPoint: .bottom)
        case .partial:
            return LinearGradient(
                colors: [
                    Color(red: 0.961, green: 0.769, blue: 0.318).opacity(0.55), // rgba(245,196,81,.55)
                    Color(red: 0.882, green: 0.667, blue: 0.157).opacity(0.40), // rgba(225,170,40,.40)
                ],
                startPoint: .top, endPoint: .bottom)
        case .on:
            return LinearGradient(
                colors: [
                    Color(red: 0.314, green: 0.706, blue: 0.471).opacity(0.65), // rgba(80,180,120,.65)
                    Color(red: 0.157, green: 0.549, blue: 0.314).opacity(0.55), // rgba(40,140,80,.55)
                ],
                startPoint: .top, endPoint: .bottom)
        }
    }

    /// Track border: neutral hairline off; signal-tinted (60%) on/partial.
    private var trackBorder: Color {
        switch state {
        case .off:     return BridgeTokens.hairline
        case .partial: return Color(red: 0.961, green: 0.769, blue: 0.318).opacity(0.40) // rgba(245,196,81,.40)
        case .on:      return Color(red: 0.392, green: 0.784, blue: 0.549).opacity(0.40) // rgba(100,200,140,.40)
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .off:     return "off"
        case .partial: return "partial"
        case .on:      return "on"
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

/// One favorite-slot bubble in the Command Bridge tray. A rounded-square
/// squircle (18px radius, matching `.cb-bubble` in command-bridge.html — NOT a
/// circle) with the icon centered; this also matches the empty-slot well so
/// assigned and unassigned slots share one silhouette. Empty slots render as
/// `visibility:hidden` so spatial position is preserved (per locked design).
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
        let rung = BridgeTokens.Elevation.raise
        // Specular dome (hotspot → falloff). DARK: white .42→.10→.02 (unchanged).
        // LIGHT: a softer white sheen that fades to clear over the neutral tint.
        // This radial specular is the bubble's signature read; it complements the
        // token `rung.fill` underneath (the e2 raise surface) rather than
        // replacing it, so the dome now sits on the shared raised-glass material.
        // (PKT-1006 R4a · operator-resolved Q2) Firmer raised dome. The bubbles
        // read FLAT vs the design's "PURE liquid-glass bubbles"; raise the
        // specular hotspot + carry a touch more falloff so each favorite reads as
        // a raised refractive dome (e2 raise rung), with the firm rim (below)
        // holding the thin edge. Carbon ramps a brighter white hotspot; titanium
        // keeps its softer near-white sheen so it doesn't blow out on white.
        let domeColors: [Color] = isDark
            ? [Color.white.opacity(0.52), Color.white.opacity(0.14), Color.white.opacity(0.02)]
            : [Color.white.opacity(0.78), Color.white.opacity(0.26), Color.white.opacity(0.0)]
        // ROUND glass orb (operator round-2: favorites read soft + square → firm +
        // round). A circle is a squircle whose corner radius = half the edge.
        let shape = RoundedRectangle(cornerRadius: size / 2, style: .continuous)
        return ZStack {
            // Ingredient 1 — e2 raise surface fill (token-driven base + sheen).
            rung.fill?.paint(in: shape)
            // THICK-CENTRE refraction (operator: gradient thickness — a glass bead is
            // thick in the middle, thin at the rim). A real blur pooled in the centre,
            // fading to clear at the edge via a RADIAL mask, so the orb reads as a
            // thick refractive lens rather than an even tint; the firm rim (below)
            // keeps the thin edge defined.
            shape.fill(.ultraThinMaterial)
                .mask(shape.fill(RadialGradient(
                    gradient: Gradient(stops: [
                        // (PKT-1006 R4a) Thicker centre, defined edge: hold full
                        // refraction further out (0.0→0.6 solid), then fall to a
                        // thin rim so the orb reads as a domed lens, not an even tint.
                        .init(color: .black, location: 0.0),
                        .init(color: .black.opacity(0.70), location: 0.6),
                        .init(color: .clear, location: 0.98),
                    ]),
                    center: .center, startRadius: 0, endRadius: size * 0.5)))
            // Signature specular dome — centred so the lens reads thick in the middle.
            shape
                .fill(
                    RadialGradient(
                        colors: domeColors,
                        center: UnitPoint(x: 0.42, y: 0.28),
                        startRadius: 0, endRadius: size * 0.92
                    )
                )
            // Top-left specular glint (`--glint`) — the raise-rung highlight.
            shape.fill(BridgeTokens.glint).allowsHitTesting(false)
            content
        }
        .frame(width: size, height: size)
        // Ingredient 2 — directional bevel (top rim-light + bottom occlusion).
        .overlay(rung.bevel.overlay(in: shape).allowsHitTesting(false))
        // FIRM defined rim (operator round-2: orbs were too soft to make out).
        // Theme-aware `edgeRaise` (white on carbon, dark-blue on titanium) holds a
        // crisp edge on ANY backdrop — a white-only rim vanished on white. REPLACES
        // the prior edge-dissolve mask, which is exactly what read as "too soft".
        .overlay(shape.strokeBorder(BridgeTokens.edgeRaise, lineWidth: 1).allowsHitTesting(false))
        .clipShape(shape)
        // Ingredient 4 — dual ambient + contact drop shadow (e2). Keep dark's
        // prior single soft shadow feel; the dual layer reads richer on titanium.
        .modifier(OptionalShadow(rung.shadow))
        // Preserve the prior dark contact shadow so the tray dome doesn't get
        // lighter than v3.7.6 on carbon (the e2 dual shadow is softer up top).
        .shadow(color: .black.opacity(isDark ? 0.18 : 0.0), radius: 7, y: 6)
    }
}

// ============================================================================
// MARK: - v4 base controls (button · chip · input · status dot)
// ============================================================================
//
// The small interactive vocabulary, in the evolved-glass idiom. Each consumes
// the W1 tokens (glassControl · bevelControl · accent family · signals · focus
// ring · wellFill · bevelInset) so both carbon + titanium come for free. Motion
// matches materials.css: `--fast` (.15s) ease on background/shadow.

/// Translucent-glass button — the four `.btn` variants from materials.css /
/// preview/cmp-buttons.html. 30px tall, control radius (8). States:
/// default · hover (brighten) · active (1px nudge) · focus (focus ring) · disabled.
///
///   • `.primary` — translucent blue gradient, onAccent text.
///   • `.default` — raised glass (`glassControl`) + control bevel.
///   • `.danger`  — red-tinted fill, `#ff9b9b` text.
///   • `.link`    — borderless accent text + `↗` affordance.
public struct BridgeButton: View {
    public enum Variant: Sendable, Equatable { case primary, `default`, danger, link }

    private let title: String
    private let systemImage: String?
    private let variant: Variant
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        systemImage: String? = nil,
        variant: Variant = .default,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.variant = variant
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: variant == .link ? 3 : 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                if variant == .link {
                    Text("↗").font(.system(size: 10)).opacity(0.65)
                }
            }
            .font(variant == .link ? BridgeTokens.Typeface.sub : BridgeTokens.Typeface.base600)
        }
        .buttonStyle(BridgeButtonStyle(variant: variant))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)   // `.btn:disabled { opacity:.42 }`
    }
}

/// The `ButtonStyle` that paints `BridgeButton` — owns the per-variant fills,
/// borders, bevels, hover/active feedback, and focus ring so the whole control
/// vocabulary is one consistent material.
public struct BridgeButtonStyle: ButtonStyle {
    let variant: BridgeButton.Variant

    // ButtonStyle is NOT a View, so @State/@FocusState are inert here. Hover +
    // focus live in `BridgeButtonChrome` (a real ViewModifier body), which is
    // where SwiftUI property wrappers actually drive updates.
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .modifier(BridgeButtonChrome(variant: variant, pressed: configuration.isPressed))
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return BridgeTokens.onAccent
        case .default: return BridgeTokens.fg1
        case .danger:  return BridgeTokens.badText
        case .link:    return BridgeTokens.accentLink
        }
    }
}

/// The geometry + surface chrome for a `BridgeButton`, factored out so the
/// style stays readable AND so the hover/focus property wrappers run in a real
/// View body. Handles padding, the four fills, borders, bevels, the active
/// translate, and the focus halo.
private struct BridgeButtonChrome: ViewModifier {
    let variant: BridgeButton.Variant
    let pressed: Bool
    @State private var hovering = false
    @FocusState private var focused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if variant == .link {
            content
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(BridgeTokens.accent.opacity(hovering ? 0.12 : 0)) // `.link-btn:hover`
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .focused($focused)
                .onHover { hovering = $0 }
                .animation(.easeInOut(duration: 0.15), value: hovering)
        } else {
            let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
            content
                .frame(height: 30)
                .padding(.horizontal, 13)
                .background(fillView(shape))
                .overlay(shape.strokeBorder(border, lineWidth: 0.5))
                .modifier(BevelIf(apply: variant == .default || variant == .danger, bevel: BridgeTokens.bevelControl, radius: BridgeTokens.Radius.control))
                .overlay(
                    // focus ring (`--focus`: 0 0 0 3px) — a halo stroke outside the edge.
                    shape.strokeBorder(BridgeTokens.focusRing, lineWidth: focused ? BridgeTokens.focusRingWidth : 0)
                )
                .clipShape(shape)
                .contentShape(shape)
                .focused($focused)
                .onHover { hovering = $0 }
                .animation(.easeInOut(duration: 0.15), value: hovering)
                .offset(y: pressed ? 0.5 : 0)   // `.btn:active { transform: translateY(.5px) }`
        }
    }

    @ViewBuilder
    private func fillView<S: Shape>(_ shape: S) -> some View {
        switch variant {
        case .primary:
            // Translucent blue gradient (preview): rgba(120,160,220,.4)→rgba(80,120,200,.35).
            shape.fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.471, green: 0.627, blue: 0.863).opacity(hovering ? 0.52 : 0.40),
                        Color(red: 0.314, green: 0.471, blue: 0.784).opacity(hovering ? 0.47 : 0.35),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
        case .default:
            // Raised glass control + brighten-on-hover (`color-mix … fg-1 8%`).
            shape.fill(BridgeTokens.glassControl)
                .overlay(shape.fill(BridgeTokens.fg1.opacity(hovering ? 0.08 : 0)))
        case .danger:
            // Red-tinted LIQUID GLASS: the neutral control glass carries the depth
            // (bevel + sheen), a red wash sets the danger tone (brightening on
            // hover). Matches `.default`'s material so a Restart/Quit pair reads as
            // one set of controls instead of glass-vs-flat.
            shape.fill(BridgeTokens.glassControl)
                .overlay(shape.fill(Color(red: 1.0, green: 0.353, blue: 0.353).opacity(hovering ? 0.26 : 0.16)))
        case .link:
            shape.fill(.clear)
        }
    }

    private var border: Color {
        switch variant {
        case .primary: return Color(red: 0.588, green: 0.706, blue: 0.902).opacity(0.40) // rgba(150,180,230,.4)
        case .default: return BridgeTokens.hairlineStrong
        case .danger:  return Color(red: 1.0, green: 0.353, blue: 0.353).opacity(0.34)   // red-tinted glass edge
        case .link:    return .clear
        }
    }
}

/// Applies a bevel only when `apply` is true (the default-variant raised look).
private struct BevelIf: ViewModifier {
    let apply: Bool
    let bevel: BridgeTokens.Bevel
    let radius: CGFloat
    @ViewBuilder
    func body(content: Content) -> some View {
        if apply { content.bridgeBevel(bevel, radius: radius) } else { content }
    }
}

/// Neutral-glass pill for triggers / tags (`.chip`). 26px tall, full-pill
/// radius. `on` → accent-blue selected; `anti` → red. Hover brightens the
/// neutral fill + lifts text to fg1, matching materials.css `.chip:hover`.
public struct BridgeChip: View {
    public enum State: Sendable, Equatable { case neutral, on, anti }

    private let title: String
    private let systemImage: String?
    private let state: State
    private let action: (() -> Void)?
    @SwiftUI.State private var hovering = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        state: State = .neutral,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.state = state
        self.action = action
    }

    @ViewBuilder
    public var body: some View {
        if let action {
            Button(action: action) { pillLabel }.buttonStyle(.plain)
        } else {
            pillLabel
        }
    }

    /// The rendered pill (everything except the optional tap target).
    private var pillLabel: some View {
        let pill = Capsule(style: .continuous)
        return HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11))
            }
            Text(title).font(BridgeTokens.Typeface.meta)
        }
        .foregroundStyle(foreground)
        .frame(height: 26)
        .padding(.horizontal, 10)
        .background(fillView(pill))
        .overlay(pill.strokeBorder(border, lineWidth: 0.5))
        .modifier(BevelIf(apply: state == .neutral, bevel: BridgeTokens.bevelControl, radius: 999))
        .clipShape(pill)
        .contentShape(pill)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private var foreground: Color {
        switch state {
        case .neutral: return hovering ? BridgeTokens.fg1 : BridgeTokens.fg3
        case .on:      return BridgeTokens.onAccent
        case .anti:    return BridgeTokens.badText
        }
    }

    @ViewBuilder
    private func fillView<S: Shape>(_ shape: S) -> some View {
        switch state {
        case .neutral:
            shape.fill(BridgeTokens.glassControl)
                .overlay(shape.fill(BridgeTokens.fg1.opacity(hovering ? 0.08 : 0)))
        case .on:
            shape.fill(BridgeTokens.accent)
        case .anti:
            shape.fill(Color(red: 1.0, green: 0.353, blue: 0.353).opacity(0.10)) // rgba(255,90,90,.10)
        }
    }

    private var border: Color {
        switch state {
        case .neutral: return BridgeTokens.hairline
        case .on:      return BridgeTokens.accentBorder
        case .anti:    return Color(red: 1.0, green: 0.353, blue: 0.353).opacity(0.24) // rgba(255,90,90,.24)
        }
    }
}

/// Inset-well text field (`.input`): control radius 8, recessed `wellFill`
/// surface + `bevelInset`, focus ring + accent border on focus, caret tinted
/// `accentStrong`, placeholder `fg5`. Wraps a SwiftUI `TextField` so existing
/// `@State`/`@Binding` text flows unchanged; `mono` swaps to the mono face.
public struct BridgeInput: View {
    private let placeholder: String
    @Binding private var text: String
    private let mono: Bool
    @FocusState private var focused: Bool

    public init(_ placeholder: String, text: Binding<String>, mono: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.mono = mono
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous)
        return TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? BridgeTokens.Typeface.mono : BridgeTokens.Typeface.base)
            .foregroundStyle(BridgeTokens.fg1)
            .tint(BridgeTokens.accentStrong)            // caret + selection = accent-strong
            .focused($focused)
            .frame(height: 32)
            .padding(.horizontal, 11)
            .background(shape.fill(BridgeTokens.wellFill))     // inset well surface
            .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.input)
            .overlay(shape.strokeBorder(focused ? BridgeTokens.accentBorder : BridgeTokens.hairline, lineWidth: 0.5))
            .overlay(
                // focus ring (`--focus`: 0 0 0 3px).
                shape.strokeBorder(BridgeTokens.focusRing, lineWidth: focused ? BridgeTokens.focusRingWidth : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

// `BridgeStatusDot` is defined once, in BridgeUIKit.swift (the component layer),
// where it uses the richer `BridgeSignal` palette (ok/warn/bad/info/neutral) and
// is consumed by the rows/strips/table. The earlier duplicate that lived here
// (a `.ok/.warn/.bad/.idle` variant) was removed at the W2 checkpoint to resolve
// the redefinition — map a former `.idle` dot to `BridgeStatusDot(.neutral)`.

// MARK: - SF Symbol section-nav icons

/// Single source of truth for the sidebar nav icon used per section.
/// Matches the SVG glyphs in `design/shell.js` order.
public enum BridgeSectionIcon {
    public static func systemImage(for section: SettingsSection) -> String {
        switch section {
        case .orders:     return "command"
        case .skills:     return "sparkles"
        case .jobs:       return "clock.badge.checkmark"
        case .tools:      return "hammer"
        case .security:   return "lock.shield"
        case .connection: return "network"
        case .datasources: return "tablecells"
        case .advanced:   return "wrench.and.screwdriver"
        }
    }
}
