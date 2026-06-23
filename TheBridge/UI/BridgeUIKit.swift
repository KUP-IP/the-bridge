// BridgeUIKit.swift — The Bridge v4 component layer (PKT-W2b).
//
// The Settings-window COMPONENT layer, ported from
// design/the-bridge-design-system/project/bridge-ui.css. Self-contained
// SwiftUI views that consume ONLY the W1 token ladder (BridgeTokens) + SwiftUI.
// These are the composite pieces the seven Settings pages assemble in Wave 3.
//
// Scope (this file): .seg · the security-tier control (.tier / .tier-pill,
// Open · Notify · Confirm) · .statstrip + .tile · .lrow · the Tools table
// (.tbl / .trow / .tool-row) · .banner · empty/loading/error · .md · .peek/.float.
// The .bw-* window SHELL is a different packet and is intentionally NOT here.
//
// Theming: every color comes from a BridgeTokens adaptive token, so BOTH the
// carbon (dark) and titanium (light) themes resolve for free — no `data-theme`
// branching needed. CSS `color-mix(in srgb, <signal> N%, transparent)` is
// mirrored as `<signalColor>.opacity(N/100)`.
//
// All views expose clear public initializers so the page agents can instantiate
// them directly. Where a piece carries selectable state, the initializer takes a
// `Binding` (live control) OR a plain value + `onSelect`/`onTap` closure (when
// the page owns the state) — both forms are provided where it matters.

import SwiftUI

// ============================================================================
// MARK: - Shared vocabulary
// ============================================================================

/// The three security tiers, mirroring the domain `SecurityTier`
/// (open / notify / request) but kept LOCAL so this kit stays self-contained.
/// Page agents map their `SecurityTier` rawValue ("open"/"notify"/"request")
/// to this via `BridgeTier(rawValue:)`.
///
///   • `.open`    — read-only / safe: runs free.            (emerald ink)
///   • `.notify`  — runs, then pings the operator.          (accent ink)
///   • `.confirm` — asks approval (Allow / Deny / Always).  (amber ink)
///
/// NOTE the rawValue of `.confirm` is **"request"** so it round-trips with the
/// domain `SecurityTier` rawValue; only the human LABEL is "Confirm".
public enum BridgeTier: String, CaseIterable, Sendable, Hashable {
    case open    = "open"
    case notify  = "notify"
    case confirm = "request"   // domain rawValue is "request"; UI label "Confirm"

    /// Human label shown in the control / pill.
    public var label: String {
        switch self {
        case .open:    return "Open"
        case .notify:  return "Notify"
        case .confirm: return "Confirm"
        }
    }

    /// The tier-colored ink (dot + label). Open=emerald, Notify=accent, Confirm=amber.
    /// Matches bridge-ui.css `.tier button.on.{open|notify|request}` and the pills.
    public var ink: Color {
        switch self {
        case .open:    return BridgeTokens.okText
        case .notify:  return BridgeTokens.infoText
        case .confirm: return BridgeTokens.warnText
        }
    }

    /// The pill's translucent fill (`color-mix(... 16%, transparent)`).
    fileprivate var pillFill: Color {
        switch self {
        case .open:    return BridgeTokens.ok.opacity(0.16)
        case .notify:  return BridgeTokens.accent.opacity(0.16)
        case .confirm: return BridgeTokens.warn.opacity(0.16)
        }
    }

    /// The pill's border tint.
    fileprivate var pillBorder: Color {
        switch self {
        case .open:    return BridgeTokens.ok.opacity(0.32)
        case .notify:  return BridgeTokens.accentBorder
        case .confirm: return BridgeTokens.warn.opacity(0.34)
        }
    }
}

/// The signal palette used by banners, stat tiles and the status strip.
/// `info` maps to the accent (royal blue), matching the CSS `.info` rules.
public enum BridgeSignal: Sendable, Hashable {
    case ok, warn, bad, info, neutral

    /// Primary signal hue (the dot fill / strong border seed).
    var base: Color {
        switch self {
        case .ok:      return BridgeTokens.ok
        case .warn:    return BridgeTokens.warn
        case .bad:     return BridgeTokens.bad
        case .info:    return BridgeTokens.accent
        case .neutral: return BridgeTokens.fg4
        }
    }

    /// Legible-on-glass text variant.
    var text: Color {
        switch self {
        case .ok:      return BridgeTokens.okText
        case .warn:    return BridgeTokens.warnText
        case .bad:     return BridgeTokens.badText
        case .info:    return BridgeTokens.infoText
        case .neutral: return BridgeTokens.fg2
        }
    }

    /// Tile big-number tint (`.tile.ok b` etc.); neutral uses fg1.
    var tileValueColor: Color {
        switch self {
        case .neutral: return BridgeTokens.fg1
        default:       return text
        }
    }
}

// ============================================================================
// MARK: - Small shared atoms (self-contained — not from other packets)
// ============================================================================

/// A signal status dot with the CSS glow (`box-shadow: 0 0 Npx currentColor`).
/// `.dot.ok/.warn/.bad/.idle` — small, used in rows/strips/list trailing.
public struct BridgeStatusDot: View {
    private let signal: BridgeSignal
    private let size: CGFloat
    /// - Parameters:
    ///   - signal: which signal color (use `.neutral` for an idle/off dot).
    ///   - size: dot diameter (default 8pt; the CSS strip uses ~8, list ~8).
    public init(_ signal: BridgeSignal, size: CGFloat = 8) {
        self.signal = signal
        self.size = size
    }
    public var body: some View {
        Circle()
            .fill(signal.base)
            .frame(width: size, height: size)
            .shadow(color: signal.base.opacity(0.55), radius: size * 0.7)
            .overlay(   // inset top rim-light (`inset 0 1px 0 rgba(255,255,255,.35)`)
                Circle().strokeBorder(BridgeTokens.fg1.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// A small pill toggle matching materials.css `.toggle` (compact 34×20 variant
/// used inside table rows). Self-contained so the kit needn't import the shell.
/// Supports a `.partial` (family-level mixed) presentation via `isPartial`.
public struct BridgeToggle: View {
    @Binding private var isOn: Bool
    private let isPartial: Bool
    private let width: CGFloat
    private let height: CGFloat

    /// - Parameters:
    ///   - isOn: the bound on/off state.
    ///   - isPartial: render the "mixed" look (family with some children on).
    ///   - compact: 34×20 (table) when true, 40×24 (rows) when false.
    public init(isOn: Binding<Bool>, isPartial: Bool = false, compact: Bool = false) {
        self._isOn = isOn
        self.isPartial = isPartial
        self.width  = compact ? 34 : 40
        self.height = compact ? 20 : 24
    }

    private var knobSize: CGFloat { height - 6 }

    public var body: some View {
        let track = RoundedRectangle(cornerRadius: BridgeTokens.Radius.pill, style: .continuous)
        ZStack {
            track
                .fill(trackFill)
                .overlay(track.strokeBorder(trackBorder, lineWidth: 0.5))
            HStack {
                if isOn { Spacer(minLength: 0) }
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.white, Color(white: 0.84)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                if !isOn { Spacer(minLength: 0) }
            }
            .padding(3)
        }
        .frame(width: width, height: height)
        .contentShape(track)
        .onTapGesture { isOn.toggle() }
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var trackFill: Color {
        if isOn { return BridgeTokens.ok.opacity(0.55) }
        if isPartial { return BridgeTokens.warn.opacity(0.40) }
        return BridgeTokens.chipFill
    }
    private var trackBorder: Color {
        if isOn { return BridgeTokens.ok.opacity(0.40) }
        if isPartial { return BridgeTokens.warn.opacity(0.34) }
        return BridgeTokens.hairline
    }
}

// ============================================================================
// MARK: - 1 · Segmented control (.seg)
// ============================================================================

/// `.seg` — a pill segmented control. Selection is a raised NEUTRAL thumb
/// (native macOS idiom; accent stays reserved for primary actions). Use for
/// tabs / filters / mode switches: "Orders | Commands", "Vault | Gates",
/// "Preview | Markdown".
///
/// Generic over a `Hashable` value so callers bind to an enum directly.
public struct BridgeSegmented<Value: Hashable>: View {
    @Binding private var selection: Value
    private let segments: [(value: Value, label: String, systemImage: String?)]

    /// - Parameters:
    ///   - selection: bound selected value.
    ///   - segments: ordered (value, label, optional SF Symbol) tuples.
    public init(selection: Binding<Value>,
                segments: [(value: Value, label: String, systemImage: String?)]) {
        self._selection = selection
        self.segments = segments
    }

    /// Convenience for label-only segments.
    public init(selection: Binding<Value>, options: [(Value, String)]) {
        self.init(selection: selection,
                  segments: options.map { ($0.0, $0.1, nil) })
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                segmentButton(seg)
            }
        }
        .padding(2)
        .background(wellBackground)
    }

    @ViewBuilder
    private func segmentButton(_ seg: (value: Value, label: String, systemImage: String?)) -> some View {
        let isOn = seg.value == selection
        Button {
            selection = seg.value
        } label: {
            HStack(spacing: 6) {
                if let sym = seg.systemImage {
                    Image(systemName: sym).font(.system(size: 11, weight: .semibold))
                }
                Text(seg.label)
                    .font(BridgeTokens.Typeface.meta.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn ? BridgeTokens.fg1 : BridgeTokens.fg3)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(thumb(isOn: isOn))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumb(isOn: Bool) -> some View {
        if isOn {
            // raised neutral thumb: flat control fill + strong inner rim + drop
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(BridgeTokens.glassControl)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.24), radius: 1, y: 1)
        } else {
            Color.clear
        }
    }

    /// The inset "well" track (`background: var(--well); bevel-inset; hairline`).
    private var wellBackground: some View {
        RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
            .fill(BridgeTokens.wellFill)
            .overlay(
                RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.control)
    }
}

// ============================================================================
// MARK: - 2 · Security-tier control (.tier  ·  Open · Notify · Confirm)
// ============================================================================

/// `.tier` — the 3-tier security control (the load-bearing approval picker on
/// the Tools + Security pages). Three color-coded segments on a neutral well:
/// **Open · Notify · Confirm**. The active segment gets a neutral raised thumb
/// plus tier-colored ink (dot + label) — never color-alone. Used per-tool and
/// per-family.
public struct BridgeTierControl: View {
    @Binding private var tier: BridgeTier
    private let onChange: ((BridgeTier) -> Void)?

    /// - Parameters:
    ///   - tier: bound selected tier.
    ///   - onChange: optional side-effect when the tier changes (e.g. persist).
    public init(tier: Binding<BridgeTier>, onChange: ((BridgeTier) -> Void)? = nil) {
        self._tier = tier
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(BridgeTier.allCases, id: \.self) { t in
                tierButton(t)
            }
        }
        .padding(2)
        .background(wellBackground)
    }

    @ViewBuilder
    private func tierButton(_ t: BridgeTier) -> some View {
        let isOn = t == tier
        Button {
            tier = t
            onChange?(t)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(isOn ? t.ink : BridgeTokens.fg4)
                    .frame(width: 6, height: 6)
                    .opacity(isOn ? 1 : 0.5)
                    .shadow(color: isOn ? t.ink : .clear, radius: isOn ? 2.5 : 0)
                Text(t.label)
                    .font(BridgeTokens.Typeface.micro.weight(.semibold))
            }
            .foregroundStyle(isOn ? t.ink : BridgeTokens.fg4)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(thumb(isOn: isOn))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumb(isOn: Bool) -> some View {
        if isOn {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(BridgeTokens.glassControl)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
        } else {
            Color.clear
        }
    }

    private var wellBackground: some View {
        RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
            .fill(BridgeTokens.wellFill)
            .overlay(
                RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.control)
    }
}

/// `.tier-pill` — the compact, content-hugging single-pill tier indicator for
/// dense table rows. Tinted fill + border + dot + label in the tier ink.
/// Clickable (optional) so a row can cycle/open the tier picker.
public struct BridgeTierPill: View {
    private let tier: BridgeTier
    private let onTap: (() -> Void)?

    /// - Parameters:
    ///   - tier: the tier to display.
    ///   - onTap: optional tap handler (open the picker / cycle the tier).
    public init(_ tier: BridgeTier, onTap: (() -> Void)? = nil) {
        self.tier = tier
        self.onTap = onTap
    }

    public var body: some View {
        let pill = Capsule(style: .continuous)
        let content = HStack(spacing: 4) {
            Circle().fill(tier.ink).frame(width: 5, height: 5)
            Text(tier.label)
                .font(BridgeTokens.Typeface.cap)   // 11/600 (no uppercase here)
        }
        .foregroundStyle(tier.ink)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(pill.fill(tier.pillFill))
        .overlay(pill.strokeBorder(tier.pillBorder, lineWidth: 0.5))
        .contentShape(pill)

        if let onTap {
            Button(action: onTap) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

// ============================================================================
// MARK: - 3 · Stat strip (.statstrip) + Stat tile (.tile)
// ============================================================================

/// `.tile` — an inset stat tile: a big tabular value over an UPPERCASE cap
/// label. Signal-tinted value via `signal` (`.ok/.warn/.bad/.info`, `.neutral`
/// → fg1, plus a `.gold` convenience initializer).
public struct BridgeStatTile: View {
    private let value: String
    private let label: String
    private let valueColor: Color

    /// - Parameters:
    ///   - value: the big number / value (tabular).
    ///   - label: the cap label under it (auto-uppercased).
    ///   - signal: tint for the value (default `.neutral` = fg1).
    public init(value: String, label: String, signal: BridgeSignal = .neutral) {
        self.value = value
        self.label = label
        self.valueColor = signal.tileValueColor
    }

    /// Explicit-color initializer (e.g. the gold token for token counts).
    public init(value: String, label: String, valueColor: Color) {
        self.value = value
        self.label = label
        self.valueColor = valueColor
    }

    /// The `.tile.gold` variant (token counts).
    public static func gold(value: String, label: String) -> BridgeStatTile {
        BridgeStatTile(value: value, label: label, valueColor: BridgeTokens.goldSoft)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(BridgeTokens.Typeface.hero)
                .tracking(-0.3)
                .monospacedDigit()
                .foregroundStyle(valueColor)
            Text(label).bridgeCap().foregroundStyle(BridgeTokens.fg4)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(insetWell)
    }

    private var insetWell: some View {
        RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
            .fill(BridgeTokens.wellFill)
            .overlay(
                RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                    .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
            .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.control)
    }
}

/// `.statstrip` — the horizontal stat strip of inset tiles, used atop pages
/// (e.g. "147 of 162 tools active"). A raised-glass (e1) rail that lays its
/// children out in an even row. Pass `BridgeStatTile`s (or any views).
public struct BridgeStatStrip<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - spacing: gap between tiles (default 14, the `--card-gap`).
    ///   - content: the tiles (typically `BridgeStatTile`s).
    public init(spacing: CGFloat = BridgeTokens.Space.cardGap,
                @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: spacing) { content }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(raisedRail)
    }

    private var raisedRail: some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous)
        return BridgeTokens.glassRaise.paint(in: shape)
            .overlay(shape.strokeBorder(BridgeTokens.edgeRaise, lineWidth: 0.5))
            .bridgeBevel(BridgeTokens.bevelRaise, radius: BridgeTokens.Radius.card)
            .bridgeShadow(BridgeTokens.shadowE1)
    }
}

/// The "live status" variant of the strip (`.statstrip` with a lead dot + name,
/// mono meta, and a trailing accessory). Mirrors the connection/health line:
/// dot + label + mono meta · right accessory; `.warn` / `.bad` border tints.
public struct BridgeStatusStrip<Trailing: View>: View {
    private let signal: BridgeSignal
    private let title: String
    private let meta: [String]
    private let trailing: Trailing

    /// - Parameters:
    ///   - signal: the lead dot + (for warn/bad) the border tint.
    ///   - title: the lead label ("Connected" / "Degraded" / "Offline").
    ///   - meta: mono meta fragments, joined with a faint "·" separator.
    ///   - trailing: a right-aligned accessory (badge / button).
    public init(signal: BridgeSignal,
                title: String,
                meta: [String],
                @ViewBuilder trailing: () -> Trailing) {
        self.signal = signal
        self.title = title
        self.meta = meta
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                BridgeStatusDot(signal)
                Text(title)
                    .font(BridgeTokens.Typeface.name)
                    .foregroundStyle(BridgeTokens.fg1)
                    .fixedSize()
            }
            HStack(spacing: 9) {
                ForEach(Array(meta.enumerated()), id: \.offset) { idx, frag in
                    if idx > 0 { Text("·").foregroundStyle(BridgeTokens.fg5) }
                    Text(frag).fixedSize()
                }
            }
            .font(BridgeTokens.Typeface.mono)
            .foregroundStyle(BridgeTokens.fg3)
            .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(raisedRail)
    }

    private var borderColor: Color {
        switch signal {
        case .warn: return BridgeTokens.warn.opacity(0.34)
        case .bad:  return BridgeTokens.bad.opacity(0.32)
        default:    return BridgeTokens.edgeRaise
        }
    }

    private var raisedRail: some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous)
        return BridgeTokens.glassRaise.paint(in: shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: 0.5))
            .bridgeBevel(BridgeTokens.bevelRaise, radius: BridgeTokens.Radius.card)
            .bridgeShadow(BridgeTokens.shadowE1)
    }
}

// ============================================================================
// MARK: - 4 · List row (.lrow)
// ============================================================================

/// `.lrow` — a generic list row: leading icon tile (or status dot) · title +
/// sub · trailing accessory. Hover + selected fills, plus a `.dim` state.
/// Selected = neutral raised control fill + hairline border.
public struct BridgeListRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let subtitleMono: Bool
    private let isSelected: Bool
    private let isDimmed: Bool
    private let onTap: (() -> Void)?
    private let leading: Leading
    private let trailing: Trailing

    @State private var hovering = false

    /// Full initializer (custom leading + trailing views).
    /// - Parameters:
    ///   - title: row name (single-line, truncates).
    ///   - subtitle: optional sub-line.
    ///   - subtitleMono: render the sub-line in the mono face.
    ///   - isSelected: selected (raised) state.
    ///   - isDimmed: `.dim` (disabled / 50%) state.
    ///   - onTap: optional tap handler.
    ///   - leading: leading view (icon tile / dot).
    ///   - trailing: trailing accessory.
    public init(title: String,
                subtitle: String? = nil,
                subtitleMono: Bool = false,
                isSelected: Bool = false,
                isDimmed: Bool = false,
                onTap: (() -> Void)? = nil,
                @ViewBuilder leading: () -> Leading,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleMono = subtitleMono
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.onTap = onTap
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 11) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg1)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(subtitleMono ? BridgeTokens.Typeface.mono : BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 9) { trailing }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(rowBackground)
        .opacity(isDimmed ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if isSelected {
            shape.fill(BridgeTokens.glassControl)
                .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelControl, radius: 9)
        } else if hovering {
            shape.fill(BridgeTokens.hoverFill)
        } else {
            Color.clear
        }
    }
}

public extension BridgeListRow where Leading == BridgeListIconTile {
    /// Convenience: a row whose leading is the standard 28pt icon tile built
    /// from an SF Symbol.
    init(title: String,
         subtitle: String? = nil,
         subtitleMono: Bool = false,
         systemImage: String,
         isSelected: Bool = false,
         isDimmed: Bool = false,
         onTap: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, subtitleMono: subtitleMono,
                  isSelected: isSelected, isDimmed: isDimmed, onTap: onTap,
                  leading: { BridgeListIconTile(systemImage: systemImage) },
                  trailing: trailing)
    }
}

/// The standard 28×28 leading icon tile for `.lrow` (`.lr-ic`): a small well
/// with a centered glyph.
public struct BridgeListIconTile: View {
    private let systemImage: String
    public init(systemImage: String) { self.systemImage = systemImage }
    public var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(BridgeTokens.wellFill)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(BridgeTokens.fg3))
    }
}

// ============================================================================
// MARK: - 5 · Tools table (.tbl / .trow / .tool-row)
// ============================================================================

/// Column geometry for the Tools table (CSS `--tcols`):
/// `minmax(0,1fr) 48px 92px 40px` → name(fluid) · On · Tier · (toggle/spacer).
/// In the family header the order is name · count · tier · toggle; in a nested
/// tool row the name+desc share the fluid cell, then tier · toggle.
public enum BridgeToolTableMetrics {
    public static let onCol: CGFloat   = 48
    public static let tierCol: CGFloat = 92
    public static let endCol: CGFloat  = 40
    public static let hPad: CGFloat    = 14
    public static let colGap: CGFloat  = 10
}

/// `.tbl` — the Tools database/table container: a rounded e1 card that clips a
/// header row + a vertical stack of family groups. Pass the head columns and
/// the group rows as content.
public struct BridgeToolTable<Content: View>: View {
    private let columns: [String]   // header labels, e.g. ["Family · tool","On","Tier",""]
    private let content: Content

    /// - Parameters:
    ///   - columns: the 4 header labels (last is usually empty).
    ///   - content: the family groups (`BridgeToolGroupRow` + nested `BridgeToolRow`s).
    public init(columns: [String] = ["Family · tool", "On", "Tier", ""],
                @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous)
                .strokeBorder(BridgeTokens.edgeCard, lineWidth: 0.5))
        .bridgeShadow(BridgeTokens.shadowE1)
    }

    private var header: some View {
        HStack(spacing: BridgeToolTableMetrics.colGap) {
            Text(columns.indices.contains(0) ? columns[0] : "")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(columns.indices.contains(1) ? columns[1] : "")
                .frame(width: BridgeToolTableMetrics.onCol, alignment: .leading)
            Text(columns.indices.contains(2) ? columns[2] : "")
                .frame(width: BridgeToolTableMetrics.tierCol, alignment: .leading)
            Text(columns.indices.contains(3) ? columns[3] : "")
                .frame(width: BridgeToolTableMetrics.endCol, alignment: .leading)
        }
        // cap-label styling applied at the row level (the View-level twin of
        // `Text.bridgeCap()`, which is Text-only): font + uppercase + tracking
        // all propagate into the child Texts.
        .font(BridgeTokens.Typeface.cap)
        .textCase(.uppercase)
        .tracking(BridgeTokens.Typeface.trackCap)
        .foregroundStyle(BridgeTokens.fg4)
        .padding(.vertical, 8)
        .padding(.horizontal, BridgeToolTableMetrics.hPad)
        .background(BridgeTokens.wellFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)
        }
    }

    private var card: some View {
        BridgeTokens.glassCard.paint(
            in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous))
    }
}

/// A family group inside `BridgeToolTable`: the disclosure header row (`.trow`)
/// followed by its nested tool rows (`.tbl-nested`) when expanded. Owns the
/// hairline group separators.
public struct BridgeToolGroup<Nested: View>: View {
    private let isExpanded: Bool
    private let header: BridgeToolGroupRow
    private let nested: Nested

    /// - Parameters:
    ///   - isExpanded: whether the nested rows are shown.
    ///   - header: the `BridgeToolGroupRow` (family disclosure row).
    ///   - nested: the nested `BridgeToolRow`s.
    public init(isExpanded: Bool,
                header: BridgeToolGroupRow,
                @ViewBuilder nested: () -> Nested) {
        self.isExpanded = isExpanded
        self.header = header
        self.nested = nested()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                VStack(spacing: 0) { nested }
                    .background(BridgeTokens.wellFillDeep)
                    .overlay(alignment: .top) {
                        Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
        }
    }
}

/// `.trow` — a family disclosure header row: chevron · icon tile · name + desc ·
/// count badge (full/part/none tint) · tier pill · family toggle.
public struct BridgeToolGroupRow: View {
    private let name: String
    private let desc: String
    private let systemImage: String
    private let isExpanded: Bool
    private let activeCount: Int
    private let totalCount: Int
    private let tier: BridgeTier
    @Binding private var isOn: Bool
    private let onToggleExpand: () -> Void
    private let onTierTap: (() -> Void)?

    @State private var hovering = false

    /// - Parameters:
    ///   - name: family name.
    ///   - desc: short family description.
    ///   - systemImage: family glyph.
    ///   - isExpanded: rotates the chevron 90°.
    ///   - activeCount/totalCount: drives the "n/m" count + its tint.
    ///   - tier: the family-level tier pill.
    ///   - isOn: family master toggle (use `isPartial` via counts internally).
    ///   - onToggleExpand: toggles disclosure.
    ///   - onTierTap: optional handler to open the tier picker.
    public init(name: String,
                desc: String,
                systemImage: String,
                isExpanded: Bool,
                activeCount: Int,
                totalCount: Int,
                tier: BridgeTier,
                isOn: Binding<Bool>,
                onToggleExpand: @escaping () -> Void,
                onTierTap: (() -> Void)? = nil) {
        self.name = name
        self.desc = desc
        self.systemImage = systemImage
        self.isExpanded = isExpanded
        self.activeCount = activeCount
        self.totalCount = totalCount
        self.tier = tier
        self._isOn = isOn
        self.onToggleExpand = onToggleExpand
        self.onTierTap = onTierTap
    }

    private var countTint: Color {
        if activeCount == 0 { return BridgeTokens.fg5 }
        if activeCount >= totalCount { return BridgeTokens.okText }
        return BridgeTokens.warnText
    }
    private var isPartial: Bool { activeCount > 0 && activeCount < totalCount }

    public var body: some View {
        HStack(spacing: BridgeToolTableMetrics.colGap) {
            // name cell (chevron + icon + name/desc) — the fluid column
            HStack(spacing: 9) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg4)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(BridgeTokens.glassControl)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(BridgeTokens.fg2))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(BridgeTokens.Typeface.body.weight(.semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text(desc)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpand)

            // count (On column)
            Text("\(activeCount)/\(totalCount)")
                .font(BridgeTokens.Typeface.meta.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(countTint)
                .frame(width: BridgeToolTableMetrics.onCol, alignment: .leading)

            // tier pill (Tier column)
            BridgeTierPill(tier, onTap: onTierTap)
                .frame(width: BridgeToolTableMetrics.tierCol, alignment: .leading)

            // family toggle (end column)
            BridgeToggle(isOn: $isOn, isPartial: isPartial, compact: true)
                .frame(width: BridgeToolTableMetrics.endCol, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, BridgeToolTableMetrics.hPad)
        .background(hovering ? BridgeTokens.hoverFill : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// `.tool-row` — a nested tool row: a fluid name+desc cell (mono name hugs,
/// sans desc fills) · tier pill · toggle. Indented under its family.
public struct BridgeToolRow: View {
    private let name: String
    private let desc: String
    private let tier: BridgeTier
    @Binding private var isOn: Bool
    private let onTierTap: (() -> Void)?

    @State private var hovering = false

    /// - Parameters:
    ///   - name: the mono tool name (e.g. `file_read`).
    ///   - desc: the short description (fills remaining width, truncates).
    ///   - tier: per-tool tier pill.
    ///   - isOn: the tool's enabled toggle.
    ///   - onTierTap: optional handler to open the tier picker.
    public init(name: String,
                desc: String,
                tier: BridgeTier,
                isOn: Binding<Bool>,
                onTierTap: (() -> Void)? = nil) {
        self.name = name
        self.desc = desc
        self.tier = tier
        self._isOn = isOn
        self.onTierTap = onTierTap
    }

    public var body: some View {
        HStack(spacing: BridgeToolTableMetrics.colGap) {
            // tr-cell: name + desc share the fluid cell (spans name+On columns)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(name)
                    .font(BridgeTokens.Typeface.mono)
                    .foregroundStyle(BridgeTokens.fg2)
                    .fixedSize()
                Text(desc)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg5)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            BridgeTierPill(tier, onTap: onTierTap)
                .frame(width: BridgeToolTableMetrics.tierCol, alignment: .leading)
            BridgeToggle(isOn: $isOn, compact: true)
                .frame(width: BridgeToolTableMetrics.endCol, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.leading, 39)   // CSS: padding-left: 39px (clears the chevron+icon)
        .padding(.trailing, BridgeToolTableMetrics.hPad)
        .background(hovering ? BridgeTokens.hoverFill : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
        }
        .onHover { hovering = $0 }
    }
}

// ============================================================================
// MARK: - 6 · Banner (.banner)
// ============================================================================

/// `.banner` — a full-width inline banner in ok / warn / bad / info. Icon +
/// message + optional trailing action. (Counts banner, license-expired, "grant
/// access" guard, etc.)
public struct BridgeBanner<Action: View>: View {
    private let signal: BridgeSignal
    private let message: String
    private let systemImage: String?
    private let action: Action

    /// - Parameters:
    ///   - signal: ok / warn / bad / info (drives ink, fill, border, default icon).
    ///   - message: the banner text.
    ///   - systemImage: optional icon override (defaults per signal).
    ///   - action: optional trailing action (button); use `EmptyView()` for none.
    public init(signal: BridgeSignal,
                message: String,
                systemImage: String? = nil,
                @ViewBuilder action: () -> Action) {
        self.signal = signal
        self.message = message
        self.systemImage = systemImage
        self.action = action()
    }

    private var icon: String {
        if let systemImage { return systemImage }
        switch signal {
        case .bad:  return "exclamationmark.triangle"
        case .warn: return "exclamationmark.circle"
        case .ok:   return "checkmark.circle"
        default:    return "info.circle"
        }
    }

    private var fillColor: Color {
        signal == .info ? BridgeTokens.accent.opacity(0.12) : signal.base.opacity(0.12)
    }
    private var borderColor: Color {
        signal == .info ? BridgeTokens.accentBorder : signal.base.opacity(0.28)
    }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
            Text(message)
                .font(BridgeTokens.Typeface.sub.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
        .foregroundStyle(signal.text)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(fillColor)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)))
    }
}

public extension BridgeBanner where Action == EmptyView {
    /// Action-less banner convenience.
    init(signal: BridgeSignal, message: String, systemImage: String? = nil) {
        self.init(signal: signal, message: message,
                  systemImage: systemImage, action: { EmptyView() })
    }
}

// ============================================================================
// MARK: - 7 · Empty / Loading / Error states
// ============================================================================

/// `.state-empty` — the centered empty state: glyph · title · description, with
/// an optional action.
public struct BridgeEmptyStateView<Action: View>: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let action: Action

    /// - Parameters:
    ///   - systemImage: the centered glyph.
    ///   - title: the headline.
    ///   - message: supporting copy (max ~320pt wide).
    ///   - action: optional action button below the copy.
    public init(systemImage: String,
                title: String,
                message: String,
                @ViewBuilder action: () -> Action) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(BridgeTokens.fg5)
            Text(title)
                .font(BridgeTokens.Typeface.hero)
                .foregroundStyle(BridgeTokens.fg2)
            Text(message)
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            action
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 30)
    }
}

public extension BridgeEmptyStateView where Action == EmptyView {
    /// Action-less empty state.
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title,
                  message: message, action: { EmptyView() })
    }
}

/// A shimmering skeleton bar (`.skel`) honoring reduce-motion.
public struct BridgeSkeleton: View {
    private let height: CGFloat
    private let cornerRadius: CGFloat
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - height: bar height.
    ///   - cornerRadius: corner radius (default 7).
    public init(height: CGFloat = 10, cornerRadius: CGFloat = 7) {
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(BridgeTokens.hairlineFaint)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.clear, BridgeTokens.hairlineStrong, .clear],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * 0.6)
                        .offset(x: reduceMotion ? 0 : phase * w)
                        .opacity(reduceMotion ? 0 : 1))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(height: height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }
}

/// `.spin` — the accent spinner (small or large), reduce-motion aware.
public struct BridgeSpinner: View {
    private let large: Bool
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter large: the `.spin.lg` 26pt variant when true (else 14pt).
    public init(large: Bool = false) { self.large = large }

    public var body: some View {
        let size: CGFloat = large ? 26 : 14
        let lw: CGFloat = large ? 2.6 : 1.7
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(BridgeTokens.accentLink, style: StrokeStyle(lineWidth: lw, lineCap: .round))
            .background(Circle().strokeBorder(BridgeTokens.hairlineStrong, lineWidth: lw))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

/// The standard loading view: a stack of skeleton "rows" (icon tile + bar),
/// matching the `loading` card in the spec.
public struct BridgeLoadingView: View {
    private let rows: Int
    /// - Parameter rows: how many skeleton rows to show (default 3).
    public init(rows: Int = 3) { self.rows = rows }

    public var body: some View {
        VStack(spacing: 9) {
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: 9) {
                    BridgeSkeleton(height: 22, cornerRadius: 7)
                        .frame(width: 22)
                    BridgeSkeleton(height: 10)
                        .opacity(1 - Double(i) * 0.2)
                }
            }
        }
    }
}

/// The error state — a `.bad` banner with a Retry action, plus optional detail
/// copy. A thin wrapper over `BridgeBanner` for the common case.
public struct BridgeErrorView: View {
    private let message: String
    private let retryTitle: String
    private let onRetry: (() -> Void)?

    /// - Parameters:
    ///   - message: the error message.
    ///   - retryTitle: label for the retry action (default "Retry").
    ///   - onRetry: optional retry handler; omit to hide the action.
    public init(message: String,
                retryTitle: String = "Retry",
                onRetry: (() -> Void)? = nil) {
        self.message = message
        self.retryTitle = retryTitle
        self.onRetry = onRetry
    }

    public var body: some View {
        if let onRetry {
            BridgeBanner(signal: .bad, message: message) {
                Button(retryTitle, action: onRetry)
                    .buttonStyle(.plain)
                    .font(BridgeTokens.Typeface.meta.weight(.semibold))
                    .foregroundStyle(BridgeTokens.badText)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(BridgeTokens.bad.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(BridgeTokens.bad.opacity(0.32), lineWidth: 0.5))
            }
        } else {
            BridgeBanner(signal: .bad, message: message)
        }
    }
}

// ============================================================================
// MARK: - 8 · Markdown (.md)
// ============================================================================

/// `.md` — a lightweight markdown renderer for doctrine / descriptions. Handles
/// the subset the design system uses: `## headings`, `- ` / `* ` bullet lists,
/// paragraphs, **bold**, and `inline code`. Styled with the Typeface tokens
/// (sans body, display headings, mono code). NOT a full CommonMark engine — it
/// is the SwiftUI twin of the CSS `.md` block.
public struct BridgeMarkdown: View {
    private let source: String
    /// - Parameter source: the markdown string.
    public init(_ source: String) { self.source = source }

    // A parsed block (indexed by position in `ForEach`, no id needed).
    private enum Block {
        case heading(String, isFirst: Bool)
        case paragraph(AttributedString)
        case list([AttributedString])
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(text, isFirst):
                    headingView(text, isFirst: isFirst)
                case let .paragraph(attr):
                    Text(attr)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg2)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                case let .list(items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(BridgeTokens.infoText)
                                Text(item)
                                    .font(BridgeTokens.Typeface.sub)
                                    .foregroundStyle(BridgeTokens.fg2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func headingView(_ text: String, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                Rectangle().fill(BridgeTokens.hairlineFaint)
                    .frame(height: 0.5)
                    .padding(.bottom, 13)
            }
            Text(text)
                .font(BridgeTokens.Typeface.body.weight(.semibold))
                .foregroundStyle(BridgeTokens.fg1)
        }
        .padding(.top, isFirst ? 0 : 6)
    }

    // ── tiny parser ──
    private func blocks() -> [Block] {
        var result: [Block] = []
        var pendingList: [AttributedString] = []
        var firstHeadingSeen = false

        func flushList() {
            if !pendingList.isEmpty {
                result.append(.list(pendingList))
                pendingList.removeAll()
            }
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushList(); continue }
            if line.hasPrefix("## ") {
                flushList()
                let text = String(line.dropFirst(3))
                result.append(.heading(text, isFirst: !firstHeadingSeen))
                firstHeadingSeen = true
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                pendingList.append(inline(String(line.dropFirst(2))))
            } else {
                flushList()
                result.append(.paragraph(inline(line)))
            }
        }
        flushList()
        return result
    }

    /// Inline parse for **bold** + `code`, returning a styled AttributedString.
    private func inline(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)

        while let marker = rest.firstIndex(where: { $0 == "*" || $0 == "`" }) {
            // plain text before the marker
            if marker > rest.startIndex {
                out.append(AttributedString(String(rest[rest.startIndex..<marker])))
            }
            let ch = rest[marker]
            if ch == "`" {
                let after = rest.index(after: marker)
                if let close = rest[after...].firstIndex(of: "`") {
                    var code = AttributedString(String(rest[after..<close]))
                    code.font = BridgeTokens.Typeface.mono
                    code.foregroundColor = BridgeTokens.accentLink
                    out.append(code)
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            } else if ch == "*", rest.index(after: marker) < rest.endIndex,
                      rest[rest.index(after: marker)] == "*" {
                let after = rest.index(marker, offsetBy: 2)
                if let close = rest.range(of: "**", range: after..<rest.endIndex) {
                    var bold = AttributedString(String(rest[after..<close.lowerBound]))
                    bold.font = BridgeTokens.Typeface.sub.weight(.semibold)
                    bold.foregroundColor = BridgeTokens.fg1
                    out.append(bold)
                    rest = rest[close.upperBound...]
                    continue
                }
            }
            // not a real marker — emit it literally and advance
            out.append(AttributedString(String(ch)))
            rest = rest[rest.index(after: marker)...]
        }
        if !rest.isEmpty { out.append(AttributedString(String(rest))) }
        return out
    }
}

// ============================================================================
// MARK: - 9 · Peek + Float overlay (.peek / .float)
// ============================================================================

/// `.peek` — a read-only preview that fades at the bottom, with a corner expand
/// affordance (the whole peek is tappable). Used by Orders & Skills to preview
/// doctrine, opening the full `BridgeFloat` overlay on tap.
public struct BridgePeek<Content: View>: View {
    private let maxHeight: CGFloat
    private let onExpand: () -> Void
    private let content: Content

    /// - Parameters:
    ///   - maxHeight: clip height before the fade (default 120, per CSS).
    ///   - onExpand: tap handler (open the float overlay).
    ///   - content: the previewed content (typically a `BridgeMarkdown`).
    public init(maxHeight: CGFloat = 120,
                onExpand: @escaping () -> Void,
                @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.onExpand = onExpand
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            content
                .padding(.vertical, 13)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
                .clipped()
                .overlay(alignment: .bottom) { fade }   // bottom fade-out
            expandButton                                  // corner CTA
        }
        .background(shape.fill(BridgeTokens.wellFillDeep))
        .overlay(shape.strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelInset, radius: 9)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture(perform: onExpand)
    }

    private var fade: some View {
        LinearGradient(
            colors: [BridgeTokens.bgCanvas.opacity(0), BridgeTokens.bgCanvas.opacity(0.9)],
            startPoint: .top, endPoint: .bottom)
            .frame(height: 52)
            .allowsHitTesting(false)
    }

    private var expandButton: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(BridgeTokens.fg3)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(BridgeTokens.glassControl)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5)))
            .padding(8)
            .allowsHitTesting(false)   // the whole peek handles the tap
    }
}

/// `.scrim` + `.float` — the full overlay surface a peek expands into: a blurred
/// scrim with a popover-elevation floating card (header + scrollable body).
/// Present it yourself in a `ZStack` over the page (it fills its container).
public struct BridgeFloat<Header: View, Body_: View>: View {
    private let onDismiss: () -> Void
    private let header: Header
    private let floatBody: Body_

    /// - Parameters:
    ///   - onDismiss: called when the scrim is tapped.
    ///   - header: the float's header bar content (title + actions).
    ///   - body: the scrollable body content.
    public init(onDismiss: @escaping () -> Void,
                @ViewBuilder header: () -> Header,
                @ViewBuilder body: () -> Body_) {
        self.onDismiss = onDismiss
        self.header = header()
        self.floatBody = body()
    }

    public var body: some View {
        ZStack {
            // scrim
            BridgeTokens.bgCanvas.opacity(0.55)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            // float card
            VStack(spacing: 0) {
                HStack(spacing: 10) { header }
                    .padding(.vertical, 13)
                    .padding(.horizontal, 16)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)
                    }
                ScrollView {
                    floatBody
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(floatSurface)
            .clipShape(RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous)
                    .strokeBorder(BridgeTokens.edgeRaise, lineWidth: 0.5))
            .bridgeShadow(BridgeTokens.shadowE4)
            .padding(.top, 56).padding(.bottom, 44)
            .padding(.leading, 40).padding(.trailing, 28)
        }
    }

    private var floatSurface: some View {
        BridgeTokens.glassPopover.paint(
            in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous))
            .background(.ultraThinMaterial)
    }
}
