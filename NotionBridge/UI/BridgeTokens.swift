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
    /// Saturated edge — the typing caret.
    public static let accentStrong = Color(red: 0.227, green: 0.353, blue: 0.878) // #3A5AE0
    /// Lightened royal blue — link + jump text legible on glass.
    public static let accentLink   = Color(red: 0.616, green: 0.706, blue: 0.961) // #9DB4F5
    /// Text/glyph color that sits ON the royal-blue accent fill (primary
    /// buttons). The accent is the SAME royal blue in both appearances, so this
    /// is a fixed near-white in both — it is the legible ink for that one fill,
    /// not a system-following surface ink. Use instead of a bare `Color.white`.
    public static let onAccent     = Color(red: 0.98, green: 0.98, blue: 1.0)

    // MARK: - Secondary / neutral metals

    /// Gold — secondary / premium accent.
    public static let gold         = Color(red: 0.780, green: 0.580, blue: 0.165) // #C7942A
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
}
