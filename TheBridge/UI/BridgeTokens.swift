// BridgeTokens.swift — Canonical design tokens for The Bridge.
// v3.7.2 resurface. Single source of truth for the carbon / titanium / gold /
// royal-blue "Liquid Glass" system. Mirrors the design system at
// design/design-system/project/colors_and_type.css (the locked spec); each
// constant carries its source hex in a comment. Values are sRGB.
//
// Usage: prefer these over raw Color.green/.red/.orange/.blue. Signals
// (ok/warn/bad) carry every status dot, badge, toggle, and health line;
// `accent` is the one true interactive primary (royal blue).

import SwiftUI
import AppKit

public enum BridgeTokens {

    // MARK: - Appearance-adaptive plumbing (v3.7.6 — system-tethered theme)
    //
    // The Bridge follows the macOS SYSTEM appearance (no in-app toggle):
    //   • DARK  = the carbon look (#0B0C0E canvas) — UNCHANGED from v3.7.5.
    //   • LIGHT = a titanium look (#ECEDEF canvas) with dark inks.
    //
    // Appearance-dependent tokens are built from a *dynamic* NSColor whose
    // resolver runs every time the color is drawn, so the SAME token resolves
    // correctly in BOTH SwiftUI and AppKit AND live-adapts when the user flips
    // System Settings → Appearance (no relaunch). The dark branch reproduces
    // the prior literal sRGB byte-for-byte (so dark is regression-free); the
    // light branch is the titanium tuning.
    //
    // Colors are constructed via the sRGB initializers (`NSColor(srgbRed:…)`)
    // so values are exact sRGB — no color-space round-trip through Color.
    // `Color.white.opacity(x)` is exactly sRGB white at alpha x, mirrored here
    // as `NSColor(srgbRed: 1, green: 1, blue: 1, alpha: x)`.

    /// Build a dynamic SwiftUI `Color` that resolves to `dark` under a dark
    /// appearance and `light` under a light (aqua) appearance. The closure is
    /// re-invoked by AppKit on every draw and on appearance changes, giving us
    /// free live-adaptation across both SwiftUI and AppKit consumers.
    static func adaptive(dark: @escaping @Sendable () -> NSColor,
                         light: @escaping @Sendable () -> NSColor) -> Color {
        Color(nsColor: adaptiveNSColor(dark: dark, light: light))
    }

    /// AppKit twin of `adaptive(dark:light:)` — a dynamic `NSColor` for window
    /// backgrounds and any other AppKit chrome that must follow the system.
    static func adaptiveNSColor(dark: @escaping @Sendable () -> NSColor,
                                light: @escaping @Sendable () -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark() : light()
        }
    }

    /// sRGB convenience (matches `Color(red:green:blue:)` which is sRGB).
    static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// sRGB white at an alpha (matches `Color.white.opacity(x)`).
    static func whiteAlpha(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }

    /// sRGB black at an alpha (the light-mode ink mirror of `whiteAlpha`).
    static func blackAlpha(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }

    // MARK: - Interactive accent (the one true "primary")

    /// Royal blue — primary buttons, selected rows, links, focus ring.
    public static let accent       = Color(red: 0.165, green: 0.282, blue: 0.753) // #2A48C0
    /// Saturated edge — the typing caret (v4: brightened to read on carbon glass).
    /// CHANGED in v4 from #3A5AE0 → #5B7BFF (`--accent-strong`). The old #3A5AE0
    /// now lives on as `accentBorder` / `focusRing` (the accent border + focus halo).
    public static let accentStrong = Color(red: 0.357, green: 0.482, blue: 1.0)   // #5B7BFF
    /// Lightened royal blue — link + jump text. ADAPTIVE (v4): the pale #9DB4F5
    /// reads on carbon glass but washes out on the titanium ground, so light
    /// flips to the deep royal #2A48C0 (`--accent-link`). Mirrors `infoText`.
    public static let accentLink   = adaptive(
        dark:  { srgb(0.616, 0.706, 0.961) },   // #9DB4F5
        light: { srgb(0.165, 0.282, 0.753) }    // #2A48C0
    )
    /// The accent BORDER — #3A5AE0 @ .45 (dark) / .40 (light) (`--accent-border`).
    /// Used for the outline on `.info` badges, focused inputs, and selected chips.
    /// This is the surviving home of the pre-v4 #3A5AE0 accentStrong hue.
    public static let accentBorder = adaptive(
        dark:  { srgb(0.227, 0.353, 0.878, 0.45) },  // rgba(58,90,224,.45)
        light: { srgb(0.165, 0.282, 0.753, 0.40) }   // rgba(42,72,192,.40)
    )
    /// The focus-ring fill — a 3px halo painted behind a focused control
    /// (`--focus`: `0 0 0 3px <fill>`). #3A5AE0 @ .30 (dark) / #2A48C0 @ .22
    /// (light). Pair with `Elevation.focusRingWidth` for the spread.
    public static let focusRing = adaptive(
        dark:  { srgb(0.227, 0.353, 0.878, 0.30) },  // rgba(58,90,224,.30)
        light: { srgb(0.165, 0.282, 0.753, 0.22) }   // rgba(42,72,192,.22)
    )
    /// Text/glyph color that sits ON the royal-blue accent fill (primary
    /// buttons). The accent is the SAME royal blue in both appearances, so this
    /// is a fixed near-white in both — it is the legible ink for that one fill,
    /// not a system-following surface ink. Use instead of a bare `Color.white`.
    public static let onAccent     = Color(red: 0.98, green: 0.98, blue: 1.0)     // #FAFAFF

    // MARK: - Secondary / neutral metals

    /// Gold — secondary / premium accent (token counts).
    public static let gold         = Color(red: 0.780, green: 0.580, blue: 0.165) // #C7942A
    /// Gold TEXT — legible gold for labels on glass (`--gold-soft`). ADAPTIVE:
    /// a light gold (#E0B458) on carbon, a deep gold (#8A6410) on the bright
    /// titanium ground (the light value would glare on titanium).
    public static let goldSoft     = adaptive(
        dark:  { srgb(0.878, 0.706, 0.345) },   // #E0B458
        light: { srgb(0.541, 0.392, 0.063) }    // #8A6410
    )
    /// Titanium — neutral metal accent (and the primary surface in white mode).
    public static let titanium     = Color(red: 0.725, green: 0.745, blue: 0.769) // #B9BEC4

    // MARK: - Signals (load-bearing — every status indicator)

    /// Emerald — running / connected / valid / granted.
    public static let ok    = Color(red: 0.075, green: 0.722, blue: 0.478) // #13B87A
    /// Amber — partial / expiring / needs attention.
    public static let warn  = Color(red: 0.914, green: 0.663, blue: 0.227) // #E9A93A
    /// Red — failing / revoked / denied / danger.
    public static let bad   = Color(red: 0.761, green: 0.227, blue: 0.227) // #C23A3A

    /// Signal text variants for text inside badges/chips. ADAPTIVE: keep the
    /// lighter, glass-legible values on dark; on light use darker, titanium-
    /// legible variants (the dark values are too pale to read on #ECEDEF).
    /// DARK branches reproduce the prior literals byte-for-byte.
    public static let okText = adaptive(
        dark:  { srgb(0.310, 0.839, 0.627) },   // #4FD6A0
        light: { srgb(0.039, 0.392, 0.259) }    // #0A6442 deep emerald
    )
    public static let warnText = adaptive(
        dark:  { srgb(0.941, 0.773, 0.471) },   // #F0C578
        light: { srgb(0.510, 0.349, 0.063) }    // #825910 deep amber
    )
    public static let badText = adaptive(
        dark:  { srgb(0.898, 0.541, 0.541) },   // #E58A8A
        light: { srgb(0.580, 0.122, 0.122) }    // #941F1F deep red
    )
    /// Info/link text. DARK = accentLink (#9DB4F5, unchanged); LIGHT = the
    /// darker royal accent (#2A48C0) so links read on the titanium ground.
    public static let infoText = adaptive(
        dark:  { srgb(0.616, 0.706, 0.961) },   // #9DB4F5 (== accentLink)
        light: { srgb(0.165, 0.282, 0.753) }    // #2A48C0 (== accent)
    )

    // MARK: - The canvas (SOLID fill — no gradient)
    //
    // Per the locked design: the background is a single solid fill — carbon in
    // dark mode, titanium in light. NO aurora/gradient. Color enters ONLY via
    // small UI accents (blue/gold) + the signal colors. A faint carbon-fibre
    // weave is layered over the fill as texture, not color.

    // ── Appearance anchors (raw, non-adaptive endpoints) ──
    // Kept public for any caller that genuinely wants a fixed endpoint and as
    // the byte-exact source for the adaptive tokens below.
    public static let bgCarbon   = Color(red: 0.043, green: 0.047, blue: 0.055) // #0B0C0E dark canvas
    public static let bgCarbon2  = Color(red: 0.071, green: 0.075, blue: 0.090) // #121317 raised carbon surface
    public static let bgTitanium = Color(red: 0.925, green: 0.929, blue: 0.937) // #ECEDEF light canvas
    /// Raised titanium surface — cards / status-dot rings on the light canvas.
    /// Near-white so raised glass reads as lifted off the #ECEDEF base.
    public static let bgTitaniumRaised = Color(red: 0.957, green: 0.961, blue: 0.969) // #F4F5F7

    // ── Semantic, appearance-adaptive surfaces (use these in views) ──

    /// The BridgeStage fill: carbon in dark, titanium in light.
    public static let bgCanvas = adaptive(
        dark:  { srgb(0.043, 0.047, 0.055) },   // #0B0C0E
        light: { srgb(0.925, 0.929, 0.937) }    // #ECEDEF
    )
    /// Raised surfaces (cards, status-dot rings): carbon2 in dark, titanium-raised in light.
    public static let bgRaised = adaptive(
        dark:  { srgb(0.071, 0.075, 0.090) },   // #121317
        light: { srgb(0.957, 0.961, 0.969) }    // #F4F5F7
    )

    /// AppKit dynamic canvas color — the SAME provider as `bgCanvas`, exposed
    /// as an `NSColor` so window backgrounds adapt with the system too.
    public static let canvasNSColor: NSColor = adaptiveNSColor(
        dark:  { srgb(0.043, 0.047, 0.055) },   // #0B0C0E
        light: { srgb(0.925, 0.929, 0.937) }    // #ECEDEF
    )

    // MARK: - Ink (adaptive: white-at-alpha on carbon, black-at-alpha on titanium)
    //
    // DARK reproduces the prior `Color.white.opacity(x)` exactly. LIGHT uses
    // black-at-alpha tuned UP from a direct mirror so inks stay legible on the
    // #ECEDEF titanium canvas (a direct {.95,.78,…} mirror would leave the
    // lower ranks too faint on a light ground).

    public static let fg1 = adaptive(dark: { whiteAlpha(0.95) }, light: { blackAlpha(0.92) }) // primary text, names, values
    public static let fg2 = adaptive(dark: { whiteAlpha(0.78) }, light: { blackAlpha(0.74) }) // titlebar title, secondary headings
    public static let fg3 = adaptive(dark: { whiteAlpha(0.62) }, light: { blackAlpha(0.60) }) // body sub-text, descriptions
    public static let fg4 = adaptive(dark: { whiteAlpha(0.46) }, light: { blackAlpha(0.48) }) // labels, captions, muted hints
    public static let fg5 = adaptive(dark: { whiteAlpha(0.34) }, light: { blackAlpha(0.38) }) // placeholders, faint meta, disabled

    // MARK: - Glass base tints (the layer under the sheen)
    //
    // DARK reproduces the prior dark tints byte-for-byte. LIGHT uses a faint
    // neutral-gray tint so glass surfaces still read as a distinct material on
    // the titanium ground (a near-black tint would punch a hole on light).

    public static let glassWindowTint = adaptive(
        dark:  { srgb(0.086, 0.086, 0.110) },   // rgba(22,22,28)
        light: { srgb(0.502, 0.510, 0.529) }    // ~#808287 neutral titanium tint
    )
    public static let glassCardTint = adaptive(
        dark:  { srgb(0.078, 0.078, 0.094) },   // rgba(20,20,24)
        light: { srgb(0.471, 0.482, 0.502) }    // ~#787B80 neutral titanium tint
    )

    // MARK: - Chrome (adaptive hairlines, dividers, selection/hover/well fills)
    //
    // Completes the light-mode migration: borders, dividers, selection
    // highlights and inset "wells" were hardcoded `Color.white.opacity(x)` /
    // `Color.black.opacity(x)` and so vanished or punched dark holes on the
    // titanium ground. Each token's DARK branch reproduces the prior literal
    // byte-for-byte (dark is regression-free); the LIGHT branch mirrors it onto
    // titanium (a subtle DARK edge/fill instead of a white one).

    /// Hairline borders + dividers (card edges, column rules, separators).
    public static let hairline       = adaptive(dark: { whiteAlpha(0.10) }, light: { blackAlpha(0.10) })
    /// Stronger hairline — prominent borders / selected outlines.
    public static let hairlineStrong = adaptive(dark: { whiteAlpha(0.16) }, light: { blackAlpha(0.16) })
    /// Faint hairline — subtle inner rules where 0.10 is too much.
    public static let hairlineFaint  = adaptive(dark: { whiteAlpha(0.06) }, light: { blackAlpha(0.07) })
    /// Selected-row / active fill — the VISIBLE selection state.
    public static let selectionFill  = adaptive(dark: { whiteAlpha(0.12) }, light: { blackAlpha(0.075) })
    /// Hover fill — subtle row hover feedback.
    public static let hoverFill      = adaptive(dark: { whiteAlpha(0.05) }, light: { blackAlpha(0.045) })
    /// Inset "well" background (sunken panels: editors, stat tiles, rows).
    public static let wellFill       = adaptive(dark: { blackAlpha(0.22) }, light: { blackAlpha(0.05) })
    /// Deeper inset well (where the prior value was black@0.26).
    public static let wellFillDeep   = adaptive(dark: { blackAlpha(0.26) }, light: { blackAlpha(0.06) })
    /// Chip / pill neutral fill (small translucent backings).
    public static let chipFill       = adaptive(dark: { whiteAlpha(0.08) }, light: { blackAlpha(0.06) })

    // MARK: - Radii (macOS-soft)

    public enum Radius {
        public static let window:  CGFloat = 14
        public static let card:    CGFloat = 12
        public static let control: CGFloat = 8
        public static let input:   CGFloat = 8
        public static let pill:    CGFloat = 999
    }

    // MARK: - Spacing scale (Settings Redesign PKT-A)
    //
    // Named geometry so pane padding / gaps / chrome heights stop drifting
    // (18↔20↔22 across sections). Mirrors the values locked in the chrome
    // audit (design-audits/chrome.md §6) and the SSOT `.pane`/`.titlebar`/
    // `.footbar` kit.css rules. Use these instead of magic numbers.

    public enum Space {
        // ── v4 8-step scale (`--sp-1…8`) — the tight 4px grid, dense
        //    utility-app feel. Use these for ad-hoc padding/gaps; the named
        //    geometry below stays for chrome dimensions.
        public static let s1: CGFloat = 4   // --sp-1
        public static let s2: CGFloat = 8   // --sp-2
        public static let s3: CGFloat = 10  // --sp-3
        public static let s4: CGFloat = 14  // --sp-4
        public static let s5: CGFloat = 18  // --sp-5
        public static let s6: CGFloat = 22  // --sp-6
        public static let s7: CGFloat = 32  // --sp-7
        public static let s8: CGFloat = 48  // --sp-8

        // ── Named geometry — chrome dimensions (mirror tokens.css). ──
        /// Pane vertical padding (top/bottom of a section's content).
        public static let paneV: CGFloat = 18
        /// Pane horizontal padding (leading/trailing of a section's content).
        public static let paneH: CGFloat = 20
        /// Inter-card vertical gap within a pane.
        public static let cardGap: CGFloat = 14
        /// Sidebar nav-item row height.
        public static let navItemH: CGFloat = 30
        /// Title-bar height (trimmed from 44 — still clears the traffic lights).
        public static let titleBar: CGFloat = 38
        /// Foot-bar height.
        public static let footBar: CGFloat = 30
        /// Leading inset that clears the native traffic-light cluster.
        public static let trafficGutter: CGFloat = 78
        /// Sidebar / section-nav width (`--sidebar-w`).
        public static let sidebarW: CGFloat = 188
    }

    // MARK: - Type scale (v4 — `--t-*` + tracking)
    //
    // The discrete sizes that actually ship, as SwiftUI `Font` tokens that bake
    // in size + weight + tracking (the CSS `font:` shorthand + letter-spacing).
    // Native-first: these use the system face (SF Pro) with automatic optical
    // sizing, mirroring `-apple-system` first in the CSS stacks; `mono` uses
    // SF Mono with a "JetBrains Mono" fallback (the embedded substitute).
    //
    // Sizes (px == pt here), weights and tracking come straight from tokens.css:
    //   display 28/600/-.4 · onb 24/600/-.4 · detail 20/600/-.2 · hero 18/600/-.2
    //   name 15/600 · body 14/500 · base 13/400 (+ base600) · sub 12.5/400
    //   meta 12/400 · mono 12 · cap 11/600 UPPER .10em · micro 10.5
    //
    // NOTE: SwiftUI applies tracking via the `.tracking(_:)` view/text modifier,
    // not the `Font`. `Typeface.trackTight` / `Typeface.trackCap` expose the two
    // tracking constants; helper `Text` extensions (`.bridgeCap()`) apply cap
    // tracking + uppercasing in one call. A bare `Font` token carries size+weight
    // only. (Named `Typeface`, not `Type`, to avoid the `.Type` metatype clash.)
    public enum Typeface {
        /// Page hero (mock index). 28 / semibold / -.4 tracking.
        public static let display = Font.system(size: 28, weight: .semibold)
        /// Onboarding / detail title. 24 / semibold / -.4.
        public static let onb     = Font.system(size: 24, weight: .semibold)
        /// Skill detail name. 20 / semibold / -.2.
        public static let detail  = Font.system(size: 20, weight: .semibold)
        /// Card hero title, registry. 18 / semibold / -.2.
        public static let hero    = Font.system(size: 18, weight: .semibold)
        /// Row names, tile titles. 15 / semibold.
        public static let name    = Font.system(size: 15, weight: .semibold)
        /// Primary body. 14 / medium.
        public static let body    = Font.system(size: 14, weight: .medium)
        /// Default UI text, buttons, nav — regular weight. 13 / regular.
        public static let base    = Font.system(size: 13, weight: .regular)
        /// Default UI text at semibold (buttons, active nav). 13 / semibold.
        public static let base600 = Font.system(size: 13, weight: .semibold)
        /// Descriptions, hero-sub. 12.5 / regular.
        public static let sub     = Font.system(size: 12.5, weight: .regular)
        /// Secondary meta. 12 / regular.
        public static let meta    = Font.system(size: 12, weight: .regular)
        /// Code / tokens / endpoints. 12 / monospaced (SF Mono → JetBrains Mono).
        public static let mono    = Font.system(size: 12, weight: .regular, design: .monospaced)
        /// CARD LABELS — 11 / semibold. UPPERCASE + .10em tracking applied at the
        /// call site (use `Text.bridgeCap()` or `.tracking(Type.trackCap)`).
        public static let cap     = Font.system(size: 11, weight: .semibold)
        /// Foot meta, count pills. 10.5 / regular.
        public static let micro   = Font.system(size: 10.5, weight: .regular)

        // ── Tracking constants (SwiftUI `.tracking(_:)` is in points). ──
        /// Tight tracking for display/heading text (`--track-tight: -.2px`).
        public static let trackTight: CGFloat = -0.2
        /// Caption tracking (`--track-cap: .10em`). At the 11pt cap size, .10em
        /// ≈ 1.1pt; SwiftUI tracking is absolute points, so this is `11 * 0.10`.
        public static let trackCap: CGFloat = 1.1
    }
}

// MARK: - Type helpers (apply tracking the CSS `font:`/`letter-spacing` couples)

public extension Text {
    /// Card-label styling: `Typeface.cap` font, uppercased, with `.10em` cap
    /// tracking — the SwiftUI twin of `.card-label` / `.ds-cap`.
    func bridgeCap() -> some View {
        self.textCase(.uppercase)
            .font(BridgeTokens.Typeface.cap)
            .tracking(BridgeTokens.Typeface.trackCap)
    }
}

// ============================================================================
// MARK: - Elevation / material ladder (v4 — the 4-ingredient model)
// ============================================================================
//
// tokens.css builds depth from FOUR stacked ingredients, never one:
//   1. surface tint + sheen      (GlassFill)
//   2. directional bevel         (Bevel — rim-light top + occlusion bottom)
//   3. dual drop shadow          (BridgeShadow — ambient + contact)
//   4. refraction (blur+saturate)(BlurSpec)
// …plus the specular layer (glint / rim / sheen gradients) that sells thick
// glass, the elevation EDGE borders, and the carbon-fibre WEAVE texture.
//
// The light model is fixed: one key light, top-and-slightly-left → bright
// specular rim on TOP edges, soft occlusion on BOTTOM edges, drop shadows fall
// DOWN. Every value below is byte-exact from tokens.css — the DARK branch from
// `:root`/`[data-theme="carbon"]`, the LIGHT branch from `[data-theme="titanium"]`.
//
// Six rungs: inset (recessed) · e1 card · e2 raise · e3 popover · e4 window,
// plus the `control` rung for small interactive pieces. `BridgeTokens.Elevation`
// groups them: `.card` / `.raise` / `.popover` / `.window` / `.control` / `.inset`
// each expose the ingredients relevant to that rung.

public extension BridgeTokens {

    // ── Ingredient 1 · Glass surface fill ──────────────────────────────────
    //
    // A vertical sheen gradient painted OVER an opaque base tint. tokens.css
    // expresses this as `linear-gradient(180deg, …), <base rgba>`. We carry the
    // gradient stops + the base color; `.fillStyle` returns a paintable
    // `LinearGradient` (sheen) and `.base` the underlay. The `.paint(in:)` View
    // helper stacks base-then-sheen in a rounded rect for one-call use.

    /// A glass surface fill: a top→bottom sheen gradient over an opaque base.
    struct GlassFill: Sendable {
        /// Sheen gradient stops (top→bottom), translucent white over the base.
        public let stops: [Gradient.Stop]
        /// The opaque base tint the sheen is painted over.
        public let base: Color
        public init(stops: [Gradient.Stop], base: Color) { self.stops = stops; self.base = base }

        /// The sheen as a top→bottom `LinearGradient` (paint OVER `base`).
        public var sheen: LinearGradient {
            LinearGradient(gradient: Gradient(stops: stops), startPoint: .top, endPoint: .bottom)
        }
        /// Paint the full fill (base then sheen) clipped to `shape`.
        @ViewBuilder
        public func paint<S: InsettableShape>(in shape: S) -> some View {
            shape.fill(base).overlay(shape.fill(sheen))
        }
    }

    /// Flat control fill at rest (`--glass-control`) — no sheen, a single
    /// translucent white (dark) / white (light) over whatever is behind it.
    static let glassControl = adaptive(
        dark:  { whiteAlpha(0.07) },   // rgba(255,255,255,.07)
        light: { whiteAlpha(0.70) }    // rgba(255,255,255,.70)
    )

    // LIGHT/titanium note (v4 flat-render fix): the card/raise base tints are a
    // near-white painted at .55/.62 alpha over the #ECEDEF canvas — so the card
    // surface blends ~halfway back to the canvas and the luminance STEP that
    // makes glass read as "lifted" is muted (flat read). The light base alphas
    // below are raised toward opaque so the frosted-white surface sits clearly
    // ABOVE the ground; it stays white-ish (the frosted aesthetic), just more
    // present. Sheen stops are unchanged. Carbon is byte-for-byte unchanged.

    /// e1 card fill (`--glass-card`).
    static let glassCard = GlassFill(
        stops: [
            .init(color: adaptive(dark: { whiteAlpha(0.075) }, light: { whiteAlpha(0.78) }), location: 0.0),
            .init(color: adaptive(dark: { whiteAlpha(0.018) }, light: { whiteAlpha(0.52) }), location: 1.0),
        ],
        base: adaptive(
            dark:  { srgb(0.078, 0.078, 0.094, 0.30) },  // rgba(20,20,24,.30)
            light: { srgb(0.984, 0.988, 0.996, 0.80) }   // ~#FBFCFE near-white @ .80
        )
    )
    /// e2 raised-tile fill (`--glass-raise`).
    static let glassRaise = GlassFill(
        stops: [
            .init(color: adaptive(dark: { whiteAlpha(0.11) }, light: { whiteAlpha(0.92) }), location: 0.0),
            .init(color: adaptive(dark: { whiteAlpha(0.03) }, light: { whiteAlpha(0.66) }), location: 1.0),
        ],
        base: adaptive(
            dark:  { srgb(0.094, 0.098, 0.122, 0.46) },  // rgba(24,25,31,.46)
            light: { srgb(0.988, 0.992, 1.0, 0.86) }     // ~#FCFDFF near-white @ .86
        )
    )
    /// e3 popover fill (`--glass-popover`) — a 3-stop sheen.
    static let glassPopover = GlassFill(
        stops: [
            .init(color: adaptive(dark: { whiteAlpha(0.13) },  light: { whiteAlpha(0.94) }), location: 0.0),
            .init(color: adaptive(dark: { whiteAlpha(0.04) },  light: { whiteAlpha(0.72) }), location: 0.34),
            .init(color: adaptive(dark: { whiteAlpha(0.025) }, light: { whiteAlpha(0.64) }), location: 1.0),
        ],
        base: adaptive(
            dark:  { srgb(0.086, 0.090, 0.114, 0.62) },  // rgba(22,23,29,.62)
            light: { srgb(0.973, 0.976, 0.984, 0.70) }   // rgba(248,249,251,.70)
        )
    )
    /// e4 window/modal fill (`--glass-window`) — a 3-stop sheen.
    static let glassWindow = GlassFill(
        stops: [
            .init(color: adaptive(dark: { whiteAlpha(0.15) },  light: { whiteAlpha(0.88) }), location: 0.0),
            .init(color: adaptive(dark: { whiteAlpha(0.05) },  light: { whiteAlpha(0.62) }), location: 0.28),
            .init(color: adaptive(dark: { whiteAlpha(0.028) }, light: { whiteAlpha(0.54) }), location: 1.0),
        ],
        base: adaptive(
            dark:  { srgb(0.086, 0.086, 0.110, 0.42) },  // rgba(22,22,28,.42)
            light: { srgb(0.965, 0.969, 0.976, 0.66) }   // rgba(246,247,249,.66)
        )
    )

    // ── Ingredient 2 · Directional bevel ───────────────────────────────────
    //
    // CSS: `inset 0 1px 0 <top>, inset 0 -1px 0 <bottom>` — a 1px rim-light on
    // the TOP inner edge and a 1px occlusion shade on the BOTTOM inner edge.
    // (`bevelInset` is `inset 0 1px 2px <top-shade>` — a recessed inner shadow.)
    // `.overlay(in:)` paints the two edges as 1px strokes inset into the shape.

    /// A directional bevel: a top inner rim-light + a bottom inner occlusion.
    struct Bevel: Sendable {
        /// Top inner-edge rim-light color.
        public let top: Color
        /// Bottom inner-edge occlusion color.
        public let bottom: Color
        /// Edge thickness in points (1 for the standard rim; `inset` uses 2).
        public let width: CGFloat
        public init(top: Color, bottom: Color, width: CGFloat = 1) {
            self.top = top; self.bottom = bottom; self.width = width
        }
        /// Overlay the top + bottom inner edges onto `shape` (an inset bevel).
        @ViewBuilder
        public func overlay<S: InsettableShape>(in shape: S) -> some View {
            shape
                .strokeBorder(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: top, location: 0.0),
                            .init(color: .clear, location: 0.5),
                            .init(color: bottom, location: 1.0),
                        ]),
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: width)
        }
    }

    // LIGHT/titanium note (v4 flat-render fix): the CSS `--bevel-*` values are
    // two HARD 1px insets (top rim + bottom occlusion). The Swift `Bevel` bakes
    // both into ONE vertical gradient stroke (top→clear@.5→bottom), so each
    // edge is only full-strength at the extreme row and ramps to clear by the
    // mid-line — a soft fade, not CSS's crisp 1px line. On carbon the dark base
    // tint + hard shadows carry the depth so the dilution is invisible; on the
    // bright titanium ground the bevel IS the primary depth cue, so the literal
    // CSS opacities wash out to flat white. The light branches below are raised
    // (rim-light and cool occlusion both ~2×) so the gradient-diluted edge still
    // READS as a bright top rim + cool bottom shade. Carbon is byte-for-byte
    // unchanged. The cool occlusion stays the same blue-gray hue (15,18,28).
    static let bevelCard = Bevel(
        top:    adaptive(dark: { whiteAlpha(0.048) }, light: { whiteAlpha(0.85) }),
        bottom: adaptive(dark: { blackAlpha(0.30) },  light: { srgb(0.059, 0.071, 0.110, 0.20) }) // rgba(15,18,28,.20)
    )
    static let bevelRaise = Bevel(
        top:    adaptive(dark: { whiteAlpha(0.056) }, light: { whiteAlpha(0.92) }),
        bottom: adaptive(dark: { blackAlpha(0.42) },  light: { srgb(0.059, 0.071, 0.110, 0.24) }) // rgba(15,18,28,.24)
    )
    static let bevelWindow = Bevel(
        top:    adaptive(dark: { whiteAlpha(0.072) }, light: { whiteAlpha(0.92) }),
        bottom: adaptive(dark: { blackAlpha(0.45) },  light: { srgb(0.059, 0.071, 0.110, 0.24) }) // rgba(15,18,28,.24)
    )
    static let bevelControl = Bevel(
        top:    adaptive(dark: { whiteAlpha(0.18) },  light: { whiteAlpha(0.95) }),
        bottom: adaptive(dark: { blackAlpha(0.12) },  light: { srgb(0.059, 0.071, 0.110, 0.12) }) // rgba(15,18,28,.12)
    )
    /// Recessed inset bevel (`--bevel-inset`): top inner SHADE (not light) +
    /// bottom inner light — the inverse of a raised bevel, for wells/inputs.
    /// LIGHT raised (top shade .10→.22, bottom light .60→.85) so the recessed
    /// well still reads as sunken on the bright titanium ground; carbon untouched.
    static let bevelInset = Bevel(
        top:    adaptive(dark: { blackAlpha(0.45) },  light: { srgb(0.059, 0.071, 0.110, 0.22) }), // rgba(15,18,28,.22)
        bottom: adaptive(dark: { whiteAlpha(0.04) },  light: { whiteAlpha(0.85) }),
        width: 2
    )

    // ── Ingredient 3 · Elevation EDGE borders ──────────────────────────────
    //
    // The hairline border at each elevation (`--edge-card/raise/window`).

    // LIGHT/titanium note: at 0.5px over a near-white glass / light-gray canvas
    // pairing the literal CSS .10–.13 hairline has too little luminance contrast
    // to define the card boundary, so cards bleed into the canvas (flat read).
    // The light branches are raised (~.16–.20) so the edge reads as a crisp
    // boundary; the hue stays the cool blue-gray (15,18,28). Carbon unchanged.
    static let edgeCard = adaptive(
        dark:  { whiteAlpha(0.10) },
        light: { srgb(0.059, 0.071, 0.110, 0.16) }   // rgba(15,18,28,.16)
    )
    static let edgeRaise = adaptive(
        dark:  { whiteAlpha(0.16) },
        light: { srgb(0.059, 0.071, 0.110, 0.20) }   // rgba(15,18,28,.20)
    )
    static let edgeWindow = adaptive(
        dark:  { whiteAlpha(0.18) },
        light: { srgb(0.059, 0.071, 0.110, 0.18) }   // rgba(15,18,28,.18)
    )

    // ── Ingredient 4 · Dual drop shadow (ambient + contact) ─────────────────
    //
    // CSS `box-shadow: 0 <y1> <blur1> <c1>, 0 <y2> <blur2> <c2>` — two stacked
    // shadows: an AMBIENT (large/soft) + a CONTACT (tighter/darker). x is always
    // 0 (light is directly above). We carry both layers; `.bridgeShadow(_:)`
    // applies both. NOTE: CSS blur-radius ≈ 2× SwiftUI's `radius`; we keep the
    // CSS values verbatim as `radius` (they ARE the SSOT) — tune in a later wave
    // if the optical match needs it.

    struct ShadowLayer: Sendable {
        public let color: Color; public let radius: CGFloat; public let y: CGFloat
        public init(_ color: Color, radius: CGFloat, y: CGFloat) {
            self.color = color; self.radius = radius; self.y = y
        }
    }
    /// A dual drop shadow: the first (`a`) layer is ambient, the second (`b`)
    /// is the tighter contact shadow. Apply with `.bridgeShadow(_:)`.
    struct BridgeShadow: Sendable {
        public let a: ShadowLayer; public let b: ShadowLayer
        public init(_ a: ShadowLayer, _ b: ShadowLayer) { self.a = a; self.b = b }
    }

    // LIGHT/titanium note (v4 flat-render fix): SwiftUI's `.shadow(radius:)`
    // spreads the SAME alpha over a Gaussian (no spread, lighter falloff) and
    // CSS blur-radius ≈ 2× SwiftUI's radius — so the literal cool CSS alphas
    // (.075–.125 on the load-bearing card/raise rungs) cast essentially NO
    // visible shadow on the #ECEDEF ground, a primary cause of the flat read.
    // The light-branch alphas below are raised (the tight CONTACT layer most, so
    // cards get a crisp lift) to register against the bright canvas; the hue
    // stays the cool blue-gray (18,22,34). Carbon (dark) is byte-for-byte
    // unchanged. (Could not lower radius without changing the soft ambient
    // character, so alpha carries the legibility.)

    /// e1 dual shadow (`--sh-e1`).
    static let shadowE1 = BridgeShadow(
        ShadowLayer(adaptive(dark: { blackAlpha(0.375) }, light: { srgb(0.071, 0.086, 0.133, 0.16) }), radius: 3,  y: 1.5),
        ShadowLayer(adaptive(dark: { blackAlpha(0.275) }, light: { srgb(0.071, 0.086, 0.133, 0.20) }), radius: 9,  y: 3)
    )
    /// e2 dual shadow (`--sh-e2`).
    static let shadowE2 = BridgeShadow(
        ShadowLayer(adaptive(dark: { blackAlpha(0.375) }, light: { srgb(0.071, 0.086, 0.133, 0.18) }), radius: 6,  y: 3),
        ShadowLayer(adaptive(dark: { blackAlpha(0.425) }, light: { srgb(0.071, 0.086, 0.133, 0.22) }), radius: 33, y: 15)
    )
    /// e3 dual shadow (`--sh-e3`).
    static let shadowE3 = BridgeShadow(
        ShadowLayer(adaptive(dark: { blackAlpha(0.50) }, light: { srgb(0.071, 0.086, 0.133, 0.20) }), radius: 21, y: 9),
        ShadowLayer(adaptive(dark: { blackAlpha(0.65) }, light: { srgb(0.071, 0.086, 0.133, 0.30) }), radius: 90, y: 39)
    )
    /// e4 dual shadow (`--sh-e4`).
    static let shadowE4 = BridgeShadow(
        ShadowLayer(adaptive(dark: { blackAlpha(0.575) }, light: { srgb(0.071, 0.086, 0.133, 0.24) }), radius: 42,  y: 18),
        ShadowLayer(adaptive(dark: { blackAlpha(0.80) },  light: { srgb(0.071, 0.086, 0.133, 0.36) }), radius: 156, y: 66)
    )

    // ── Specular layer (glint · rim · sheen gradients) ──────────────────────
    //
    // The light events that sell thick glass on raised+ surfaces. Each is a
    // Gradient + the geometry tokens.css positions it with. Components paint
    // these as overlays (see materials.css `.glass-raise::before` etc.).

    /// Top-left specular glint (`--glint`) — a radial highlight at 14% / -16%.
    /// Returns a `RadialGradient`; tokens.css sizes it `150% 85%`, so the
    /// radius is generous and the center sits just off the top-left corner.
    /// (The fade-out stop is .46 dark / .48 light in tokens.css; the ~2% delta
    /// is below the perceptual floor for a fading specular, so a single .47
    /// stop is used for both — the alpha at the origin is what reads.)
    static var glint: RadialGradient {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: adaptive(dark: { whiteAlpha(0.056) }, light: { whiteAlpha(0.328) }), location: 0.0),
                .init(color: .white.opacity(0), location: 0.47),
            ]),
            center: UnitPoint(x: 0.14, y: -0.16),
            startRadius: 0,
            endRadius: 220)
    }
    /// Directional top-edge specular RIM (`--rim`) — a 101° linear sweep,
    /// brightest at the top-left, faded out by ~56%. Paint as a thin top strip.
    static var rim: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: adaptive(dark: { whiteAlpha(0.16) },  light: { whiteAlpha(0.392) }), location: 0.0),
                .init(color: adaptive(dark: { whiteAlpha(0.048) }, light: { whiteAlpha(0.20) }),  location: 0.24),
                .init(color: .white.opacity(0), location: 0.56),
            ]),
            startPoint: .topLeading, endPoint: .topTrailing)
    }
    /// Diagonal sheen sweep across large glass (`--sheen`) — a 118° whisper.
    static var sheen: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .white.opacity(0), location: 0.0),
                .init(color: adaptive(dark: { whiteAlpha(0.018) }, light: { whiteAlpha(0.152) }), location: 0.16),
                .init(color: .white.opacity(0), location: 0.34),
            ]),
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // ── Refraction · Blur (radius + saturation) ─────────────────────────────
    //
    // `--blur-*: blur(Npx) saturate(M%)`. SwiftUI lacks a single backdrop-blur
    // primitive; expose the radius + saturation so a `.background(.ultraThin…)`
    // or custom material picks them up. Shared across themes.

    struct BlurSpec: Sendable {
        /// Gaussian blur radius in points.
        public let radius: CGFloat
        /// Backdrop saturation multiplier (1.0 == 100%).
        public let saturation: CGFloat
        public init(radius: CGFloat, saturation: CGFloat) {
            self.radius = radius; self.saturation = saturation
        }
    }
    static let blurWindow  = BlurSpec(radius: 12, saturation: 1.18)  // --blur-window
    static let blurCard    = BlurSpec(radius: 8,  saturation: 1.14)  // --blur-card
    static let blurPopover = BlurSpec(radius: 10, saturation: 1.17)  // --blur-popover

    // ── Carbon-fibre WEAVE texture ──────────────────────────────────────────
    //
    // tokens.css `--weave` is two crosshatch repeating-linear-gradients. The
    // existing `BridgeShell.BridgeCarbonWeave` hardcodes these; this exposes the
    // values as tokens (do NOT rewrite BridgeShell — it may adopt these later).
    // DARK: white@.02 light hairline + black@.22 shade, 4px step.
    // LIGHT: white@.45 highlight + rgba(15,18,28,.022) shade.

    enum Weave {
        /// Diagonal step between hatch lines, in points.
        public static let step: CGFloat = 4
        /// The lighter (highlight) hairline.
        public static let highlight = adaptive(dark: { whiteAlpha(0.02) }, light: { whiteAlpha(0.45) })
        /// The darker (shade) hairline.
        public static let shadow    = adaptive(dark: { blackAlpha(0.22) }, light: { srgb(0.059, 0.071, 0.110, 0.022) }) // rgba(15,18,28,.022)
    }

    // ── Focus ring spread ────────────────────────────────────────────────────
    /// The focus-ring spread radius (`--focus`: `0 0 0 3px`). Pair with the
    /// `focusRing` color (above) to paint a 3px halo behind a focused control.
    static let focusRingWidth: CGFloat = 3

    // ── The 6-rung ladder — grouped accessor ─────────────────────────────────
    //
    // Each rung bundles the ingredients it actually uses, so a component can
    // write `let e = BridgeTokens.Elevation.raise` and pull `.fill/.bevel/.edge
    // /.shadow/.blur`. Mirrors materials.css `.glass-card/-raise/-popover/-window`.

    struct ElevationRung: Sendable {
        public let fill: GlassFill?       // nil for the flat control rung
        public let controlFill: Color?    // set for the control rung only
        public let bevel: Bevel
        public let edge: Color?
        public let shadow: BridgeShadow?
        public let blur: BlurSpec?
        public let radius: CGFloat
    }

    enum Elevation {
        /// e1 — the workhorse card (rests in a window): bevel + hairline, e1 shadow.
        public static let card = ElevationRung(
            fill: glassCard, controlFill: nil, bevel: bevelCard,
            edge: edgeCard, shadow: shadowE1, blur: nil, radius: Radius.card)
        /// e2 — raised tile / interactive panel: brighter edge, glint, e2 shadow, card blur.
        public static let raise = ElevationRung(
            fill: glassRaise, controlFill: nil, bevel: bevelRaise,
            edge: edgeRaise, shadow: shadowE2, blur: blurCard, radius: Radius.card)
        /// e3 — floating popover: full popover blur + glint + sweep, e3 shadow.
        public static let popover = ElevationRung(
            fill: glassPopover, controlFill: nil, bevel: bevelRaise,
            edge: edgeRaise, shadow: shadowE3, blur: blurPopover, radius: Radius.card)
        /// e4 — the window / modal shell: max elevation, window blur, e4 shadow.
        public static let window = ElevationRung(
            fill: glassWindow, controlFill: nil, bevel: bevelWindow,
            edge: edgeWindow, shadow: shadowE4, blur: blurWindow, radius: Radius.window)
        /// control — small interactive pieces at rest (buttons, chips). Flat
        /// fill + control bevel, no elevation shadow (the e1 shadow is opt-in).
        public static let control = ElevationRung(
            fill: nil, controlFill: glassControl, bevel: bevelControl,
            edge: nil, shadow: nil, blur: nil, radius: Radius.control)
        /// inset — recessed BELOW the surface (inputs, code wells, stat tiles).
        public static let inset = ElevationRung(
            fill: nil, controlFill: nil, bevel: bevelInset,
            edge: nil, shadow: nil, blur: nil, radius: Radius.input)
    }
}

// MARK: - View helpers (apply the elevation ingredients in one call)

public extension View {
    /// Apply a `BridgeTokens.BridgeShadow` (the dual ambient+contact drop shadow).
    func bridgeShadow(_ s: BridgeTokens.BridgeShadow) -> some View {
        self.shadow(color: s.a.color, radius: s.a.radius, x: 0, y: s.a.y)
            .shadow(color: s.b.color, radius: s.b.radius, x: 0, y: s.b.y)
    }

    /// Apply a directional `BridgeTokens.Bevel` as an inset top+bottom edge
    /// overlay, clipped to a rounded rect of `radius`.
    func bridgeBevel(_ b: BridgeTokens.Bevel, radius: CGFloat) -> some View {
        self.overlay(b.overlay(in: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }
}
