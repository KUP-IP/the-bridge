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

public enum BridgeTokens {

    // MARK: - Interactive accent (the one true "primary")

    /// Royal blue — primary buttons, selected rows, links, focus ring.
    public static let accent       = Color(red: 0.165, green: 0.282, blue: 0.753) // #2A48C0
    /// Saturated edge — the typing caret.
    public static let accentStrong = Color(red: 0.227, green: 0.353, blue: 0.878) // #3A5AE0
    /// Lightened royal blue — link + jump text legible on glass.
    public static let accentLink   = Color(red: 0.616, green: 0.706, blue: 0.961) // #9DB4F5

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

    /// Lighter signal variants for text inside badges/chips (legible on glass).
    public static let okText   = Color(red: 0.310, green: 0.839, blue: 0.627) // #4FD6A0
    public static let warnText = Color(red: 0.941, green: 0.773, blue: 0.471) // #F0C578
    public static let badText  = Color(red: 0.898, green: 0.541, blue: 0.541) // #E58A8A
    public static let infoText = accentLink                                   // #9DB4F5

    // MARK: - The canvas (SOLID fill — no gradient)
    //
    // Per the locked design: the background is a single solid fill — carbon in
    // dark mode, titanium in light. NO aurora/gradient. Color enters ONLY via
    // small UI accents (blue/gold) + the signal colors. A faint carbon-fibre
    // weave is layered over the fill as texture, not color.

    public static let bgCarbon   = Color(red: 0.043, green: 0.047, blue: 0.055) // #0B0C0E dark canvas
    public static let bgCarbon2  = Color(red: 0.071, green: 0.075, blue: 0.090) // #121317 raised carbon surface
    public static let bgTitanium = Color(red: 0.925, green: 0.929, blue: 0.937) // #ECEDEF light canvas

    // MARK: - Ink (text is always white-at-alpha, never opaque gray)

    public static let fg1 = Color.white.opacity(0.95) // primary text, names, values
    public static let fg2 = Color.white.opacity(0.78) // titlebar title, secondary headings
    public static let fg3 = Color.white.opacity(0.62) // body sub-text, descriptions
    public static let fg4 = Color.white.opacity(0.46) // labels, captions, muted hints
    public static let fg5 = Color.white.opacity(0.34) // placeholders, faint meta, disabled

    // MARK: - Glass base tints (the dark layer under the white sheen)

    public static let glassWindowTint = Color(red: 0.086, green: 0.086, blue: 0.110) // rgba(22,22,28)
    public static let glassCardTint   = Color(red: 0.078, green: 0.078, blue: 0.094) // rgba(20,20,24)

    // MARK: - Radii (macOS-soft)

    public enum Radius {
        public static let window:  CGFloat = 14
        public static let card:    CGFloat = 12
        public static let control: CGFloat = 8
        public static let input:   CGFloat = 8
        public static let pill:    CGFloat = 999
    }
}
