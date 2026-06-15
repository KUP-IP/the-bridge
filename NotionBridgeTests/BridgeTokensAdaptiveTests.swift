// BridgeTokensAdaptiveTests.swift — v3.7.6 (system-tethered Light/Dark theme)
// NotionBridge · Tests (custom harness — no XCTest; see TestRunner.swift)
//
// Locks the appearance-adaptive token contract introduced in v3.7.6:
//
//   • DARK regression-free: every adaptive token's DARK branch resolves to the
//     EXACT prior literal sRGB (the carbon look must be byte-identical to
//     v3.7.5). The expected dark values below are the literals that shipped in
//     BridgeTokens before this change.
//   • LIGHT coverage: every adaptive token resolves to a DISTINCT, defined
//     light value under the aqua appearance (proving the light branch exists
//     AND is actually wired — not silently equal to dark).
//
// HOW: an adaptive token is a *dynamic* NSColor whose resolver runs against the
// current drawing appearance. We resolve it under .darkAqua and .aqua via
// `performAsCurrentDrawingAppearance`, convert to the sRGB color space, and
// compare component-wise. This is the headless proxy for "Dark→carbon,
// Light→titanium" — the on-device pixel QA is the operator's final step.

import Foundation
import SwiftUI
import AppKit
import NotionBridgeLib

private struct RGBA: Equatable, CustomStringConvertible {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    var description: String {
        String(format: "(%.3f, %.3f, %.3f, %.3f)", r, g, b, a)
    }
    /// Component-wise equality within a tiny tolerance (sRGB round-trip can
    /// introduce sub-1/255 float noise).
    func matches(_ o: RGBA, tol: CGFloat = 0.002) -> Bool {
        abs(r - o.r) <= tol && abs(g - o.g) <= tol && abs(b - o.b) <= tol && abs(a - o.a) <= tol
    }
}

/// Resolve a SwiftUI Color (backed by a dynamic NSColor) under a specific
/// appearance and read its sRGB components.
@MainActor
private func resolve(_ color: Color, under appearanceName: NSAppearance.Name) -> RGBA {
    let appearance = NSAppearance(named: appearanceName)!
    let ns = NSColor(color)
    var out = RGBA(r: -1, g: -1, b: -1, a: -1)
    appearance.performAsCurrentDrawingAppearance {
        // Re-resolve the dynamic color against the now-current appearance, then
        // pin it to sRGB so component reads are exact and color-space-stable.
        let resolved = ns.usingColorSpace(.sRGB) ?? ns
        out = RGBA(r: resolved.redComponent, g: resolved.greenComponent,
                   b: resolved.blueComponent, a: resolved.alphaComponent)
    }
    return out
}

/// Resolve a dynamic NSColor directly (for canvasNSColor).
@MainActor
private func resolve(_ ns: NSColor, under appearanceName: NSAppearance.Name) -> RGBA {
    let appearance = NSAppearance(named: appearanceName)!
    var out = RGBA(r: -1, g: -1, b: -1, a: -1)
    appearance.performAsCurrentDrawingAppearance {
        let resolved = ns.usingColorSpace(.sRGB) ?? ns
        out = RGBA(r: resolved.redComponent, g: resolved.greenComponent,
                   b: resolved.blueComponent, a: resolved.alphaComponent)
    }
    return out
}

func runBridgeTokensAdaptiveTests() async {
    print("\n\u{1F311}\u{1F313} BridgeTokens Adaptive Theme Tests (v3.7.6 — system-tethered)")

    // Each entry: token, prior-literal DARK sRGB, expected LIGHT sRGB.
    // The DARK values are the exact v3.7.5 literals (carbon regression proof).
    struct Case { let name: String; let color: Color; let dark: RGBA; let light: RGBA }

    let cases: [Case] = await MainActor.run {
        [
            // Canvas + raised surfaces
            Case(name: "bgCanvas",
                 color: BridgeTokens.bgCanvas,
                 dark:  RGBA(r: 0.043, g: 0.047, b: 0.055, a: 1),   // #0B0C0E
                 light: RGBA(r: 0.925, g: 0.929, b: 0.937, a: 1)),  // #ECEDEF
            Case(name: "bgRaised",
                 color: BridgeTokens.bgRaised,
                 dark:  RGBA(r: 0.071, g: 0.075, b: 0.090, a: 1),   // #121317
                 light: RGBA(r: 0.957, g: 0.961, b: 0.969, a: 1)),  // #F4F5F7
            // Ink ramp — DARK = white@alpha (prior literals)
            Case(name: "fg1", color: BridgeTokens.fg1,
                 dark: RGBA(r: 1, g: 1, b: 1, a: 0.95), light: RGBA(r: 0, g: 0, b: 0, a: 0.92)),
            Case(name: "fg2", color: BridgeTokens.fg2,
                 dark: RGBA(r: 1, g: 1, b: 1, a: 0.78), light: RGBA(r: 0, g: 0, b: 0, a: 0.74)),
            Case(name: "fg3", color: BridgeTokens.fg3,
                 dark: RGBA(r: 1, g: 1, b: 1, a: 0.62), light: RGBA(r: 0, g: 0, b: 0, a: 0.60)),
            Case(name: "fg4", color: BridgeTokens.fg4,
                 dark: RGBA(r: 1, g: 1, b: 1, a: 0.46), light: RGBA(r: 0, g: 0, b: 0, a: 0.48)),
            Case(name: "fg5", color: BridgeTokens.fg5,
                 dark: RGBA(r: 1, g: 1, b: 1, a: 0.34), light: RGBA(r: 0, g: 0, b: 0, a: 0.38)),
            // Glass base tints — DARK = prior literals
            Case(name: "glassWindowTint", color: BridgeTokens.glassWindowTint,
                 dark: RGBA(r: 0.086, g: 0.086, b: 0.110, a: 1),
                 light: RGBA(r: 0.502, g: 0.510, b: 0.529, a: 1)),
            Case(name: "glassCardTint", color: BridgeTokens.glassCardTint,
                 dark: RGBA(r: 0.078, g: 0.078, b: 0.094, a: 1),
                 light: RGBA(r: 0.471, g: 0.482, b: 0.502, a: 1)),
            // Signal text variants — DARK = prior literals
            Case(name: "okText", color: BridgeTokens.okText,
                 dark: RGBA(r: 0.310, g: 0.839, b: 0.627, a: 1),
                 light: RGBA(r: 0.039, g: 0.392, b: 0.259, a: 1)),
            Case(name: "warnText", color: BridgeTokens.warnText,
                 dark: RGBA(r: 0.941, g: 0.773, b: 0.471, a: 1),
                 light: RGBA(r: 0.510, g: 0.349, b: 0.063, a: 1)),
            Case(name: "badText", color: BridgeTokens.badText,
                 dark: RGBA(r: 0.898, g: 0.541, b: 0.541, a: 1),
                 light: RGBA(r: 0.580, g: 0.122, b: 0.122, a: 1)),
            Case(name: "infoText", color: BridgeTokens.infoText,
                 dark: RGBA(r: 0.616, g: 0.706, b: 0.961, a: 1),   // == accentLink #9DB4F5
                 light: RGBA(r: 0.165, g: 0.282, b: 0.753, a: 1)), // == accent #2A48C0

            // ── v4 NEW adaptive color tokens ──
            // accentLink became ADAPTIVE in v4 (was a fixed #9DB4F5): dark keeps
            // the pale link, light flips to the deep royal so it reads on titanium.
            Case(name: "accentLink", color: BridgeTokens.accentLink,
                 dark: RGBA(r: 0.616, g: 0.706, b: 0.961, a: 1),   // #9DB4F5
                 light: RGBA(r: 0.165, g: 0.282, b: 0.753, a: 1)), // #2A48C0
            // goldSoft — light gold on carbon, deep gold on titanium (`--gold-soft`).
            Case(name: "goldSoft", color: BridgeTokens.goldSoft,
                 dark: RGBA(r: 0.878, g: 0.706, b: 0.345, a: 1),   // #E0B458
                 light: RGBA(r: 0.541, g: 0.392, b: 0.063, a: 1)), // #8A6410
            // accentBorder — #3A5AE0 @.45 dark / #2A48C0 @.40 light (`--accent-border`).
            Case(name: "accentBorder", color: BridgeTokens.accentBorder,
                 dark: RGBA(r: 0.227, g: 0.353, b: 0.878, a: 0.45),   // rgba(58,90,224,.45)
                 light: RGBA(r: 0.165, g: 0.282, b: 0.753, a: 0.40)), // rgba(42,72,192,.40)
            // focusRing — #3A5AE0 @.30 dark / #2A48C0 @.22 light (`--focus` fill).
            Case(name: "focusRing", color: BridgeTokens.focusRing,
                 dark: RGBA(r: 0.227, g: 0.353, b: 0.878, a: 0.30),   // rgba(58,90,224,.30)
                 light: RGBA(r: 0.165, g: 0.282, b: 0.753, a: 0.22)), // rgba(42,72,192,.22)
        ]
    }

    // 1. DARK regression proof — every adaptive token's dark branch equals the
    //    exact v3.7.5 literal sRGB.
    for c in cases {
        await test("v3.7.6: \(c.name) DARK branch == v3.7.5 literal \(c.dark)") {
            let got = await resolve(c.color, under: .darkAqua)
            try expect(got.matches(c.dark), "\(c.name) dark resolved \(got), expected \(c.dark)")
        }
    }

    // 2. LIGHT coverage — every adaptive token resolves to its defined light
    //    value under aqua.
    for c in cases {
        await test("v3.7.6: \(c.name) LIGHT branch == defined titanium value \(c.light)") {
            let got = await resolve(c.color, under: .aqua)
            try expect(got.matches(c.light), "\(c.name) light resolved \(got), expected \(c.light)")
        }
    }

    // 3. Adaptivity proof — light != dark for every adaptive token. Guards
    //    against a token being silently non-adaptive (both branches identical).
    for c in cases {
        await test("v3.7.6: \(c.name) is genuinely adaptive (light != dark)") {
            let d = await resolve(c.color, under: .darkAqua)
            let l = await resolve(c.color, under: .aqua)
            try expect(!d.matches(l), "\(c.name) does NOT adapt — light \(l) == dark \(d)")
        }
    }

    // 4. canvasNSColor (the AppKit window-background twin) tracks bgCanvas in
    //    BOTH appearances — the window chrome adapts with the SwiftUI surface.
    await test("v3.7.6: canvasNSColor DARK == #0B0C0E carbon (window backing regression-free)") {
        let got = await resolve(BridgeTokens.canvasNSColor, under: .darkAqua)
        try expect(got.matches(RGBA(r: 0.043, g: 0.047, b: 0.055, a: 1)),
                   "canvasNSColor dark resolved \(got)")
    }
    await test("v3.7.6: canvasNSColor LIGHT == #ECEDEF titanium (window chrome adapts)") {
        let got = await resolve(BridgeTokens.canvasNSColor, under: .aqua)
        try expect(got.matches(RGBA(r: 0.925, g: 0.929, b: 0.937, a: 1)),
                   "canvasNSColor light resolved \(got)")
    }

    // 5. Appearance-agnostic tokens stay FIXED across both appearances (the
    //    spec's LEAVE-UNCHANGED list: accents, base signals, gold, titanium).
    struct Fixed { let name: String; let color: Color }
    let fixed: [Fixed] = await MainActor.run {
        [
            Fixed(name: "accent", color: BridgeTokens.accent),
            // accentStrong stays appearance-agnostic (its VALUE changed in v4:
            // #3A5AE0 → #5B7BFF — the caret color — but it's still one fixed hue).
            Fixed(name: "accentStrong", color: BridgeTokens.accentStrong),
            // accentLink moved to the ADAPTIVE `cases` list in v4 (was here) —
            // it now flips dark↔light, so it must NOT be asserted as fixed.
            Fixed(name: "gold", color: BridgeTokens.gold),
            Fixed(name: "titanium", color: BridgeTokens.titanium),
            Fixed(name: "ok", color: BridgeTokens.ok),
            Fixed(name: "warn", color: BridgeTokens.warn),
            Fixed(name: "bad", color: BridgeTokens.bad),
        ]
    }
    for f in fixed {
        await test("v3.7.6: \(f.name) is appearance-agnostic (light == dark)") {
            let d = await resolve(f.color, under: .darkAqua)
            let l = await resolve(f.color, under: .aqua)
            try expect(d.matches(l), "\(f.name) unexpectedly adapts — light \(l) != dark \(d)")
        }
    }

    // ========================================================================
    // v4 ("Liquid Glass, evolved") — token-port coverage
    // ========================================================================
    print("\n\u{1F48E} BridgeTokens v4 token-port coverage")

    // 6. accentStrong's VALUE changed to #5B7BFF (the caret). Pin it in both
    //    appearances (fixed hue) so the reconcile can't silently regress.
    await test("v4: accentStrong == #5B7BFF (caret) in both appearances") {
        let want = RGBA(r: 0.357, g: 0.482, b: 1.0, a: 1)
        let d = await resolve(BridgeTokens.accentStrong, under: .darkAqua)
        let l = await resolve(BridgeTokens.accentStrong, under: .aqua)
        try expect(d.matches(want), "accentStrong dark resolved \(d), expected \(want)")
        try expect(l.matches(want), "accentStrong light resolved \(l), expected \(want)")
    }

    // 7. Spacing — the 8-step scale (`--sp-1…8`) + sidebarW, exact values.
    await test("v4: Space 8-step scale == --sp-1…8 (4,8,10,14,18,22,32,48)") {
        try expect(BridgeTokens.Space.s1 == 4,  "s1 \(BridgeTokens.Space.s1)")
        try expect(BridgeTokens.Space.s2 == 8,  "s2 \(BridgeTokens.Space.s2)")
        try expect(BridgeTokens.Space.s3 == 10, "s3 \(BridgeTokens.Space.s3)")
        try expect(BridgeTokens.Space.s4 == 14, "s4 \(BridgeTokens.Space.s4)")
        try expect(BridgeTokens.Space.s5 == 18, "s5 \(BridgeTokens.Space.s5)")
        try expect(BridgeTokens.Space.s6 == 22, "s6 \(BridgeTokens.Space.s6)")
        try expect(BridgeTokens.Space.s7 == 32, "s7 \(BridgeTokens.Space.s7)")
        try expect(BridgeTokens.Space.s8 == 48, "s8 \(BridgeTokens.Space.s8)")
    }
    await test("v4: Space.sidebarW == 188 and named geometry preserved") {
        try expect(BridgeTokens.Space.sidebarW == 188, "sidebarW \(BridgeTokens.Space.sidebarW)")
        // regression: the pre-existing named geometry is untouched.
        try expect(BridgeTokens.Space.paneV == 18 && BridgeTokens.Space.paneH == 20, "pane padding drifted")
        try expect(BridgeTokens.Space.titleBar == 38 && BridgeTokens.Space.footBar == 30, "bar heights drifted")
        try expect(BridgeTokens.Space.trafficGutter == 78, "trafficGutter drifted")
    }

    // 8. Type — tracking constants (`--track-tight` / `--track-cap` @ 11pt).
    await test("v4: Typeface tracking constants (trackTight -.2, trackCap 1.1pt)") {
        try expect(BridgeTokens.Typeface.trackTight == -0.2, "trackTight \(BridgeTokens.Typeface.trackTight)")
        try expect(BridgeTokens.Typeface.trackCap == 1.1,    "trackCap \(BridgeTokens.Typeface.trackCap)")
    }

    // 9. Elevation/material ladder — structural sanity: the dual shadows carry
    //    two distinct layers, blur specs carry the tokens.css radius+saturation,
    //    weave step is 4px, focus-ring spread is 3px. (Per-stop color fidelity
    //    is asserted via the adaptive `cases` above for the color-bearing
    //    tokens; here we lock the non-color structure that can't regress quietly.)
    await test("v4: dual drop shadows carry two layers with tokens.css radii") {
        try expect(BridgeTokens.shadowE1.a.radius == 3   && BridgeTokens.shadowE1.b.radius == 9,   "sh-e1 radii")
        try expect(BridgeTokens.shadowE2.a.radius == 6   && BridgeTokens.shadowE2.b.radius == 33,  "sh-e2 radii")
        try expect(BridgeTokens.shadowE3.a.radius == 21  && BridgeTokens.shadowE3.b.radius == 90,  "sh-e3 radii")
        try expect(BridgeTokens.shadowE4.a.radius == 42  && BridgeTokens.shadowE4.b.radius == 156, "sh-e4 radii")
        try expect(BridgeTokens.shadowE1.a.y == 1.5 && BridgeTokens.shadowE4.b.y == 66, "shadow y-offsets")
    }
    await test("v4: blur specs == --blur-* (radius + saturation)") {
        try expect(BridgeTokens.blurWindow.radius == 12  && BridgeTokens.blurWindow.saturation == 1.18,  "blur-window")
        try expect(BridgeTokens.blurCard.radius == 8     && BridgeTokens.blurCard.saturation == 1.14,    "blur-card")
        try expect(BridgeTokens.blurPopover.radius == 10 && BridgeTokens.blurPopover.saturation == 1.17, "blur-popover")
    }
    await test("v4: weave step 4px · focus-ring spread 3px") {
        try expect(BridgeTokens.Weave.step == 4, "weave step \(BridgeTokens.Weave.step)")
        try expect(BridgeTokens.focusRingWidth == 3, "focusRingWidth \(BridgeTokens.focusRingWidth)")
    }
    // 10. Glass fills carry the right sheen-stop count (card=2, popover/window=3)
    //     and their base tints are adaptive (dark tint != light tint).
    await test("v4: glass fills — sheen-stop counts + adaptive base tints") {
        try expect(BridgeTokens.glassCard.stops.count == 2,    "card stops")
        try expect(BridgeTokens.glassRaise.stops.count == 2,   "raise stops")
        try expect(BridgeTokens.glassPopover.stops.count == 3, "popover stops")
        try expect(BridgeTokens.glassWindow.stops.count == 3,  "window stops")
        let cardBaseD = await resolve(BridgeTokens.glassCard.base, under: .darkAqua)
        let cardBaseL = await resolve(BridgeTokens.glassCard.base, under: .aqua)
        try expect(!cardBaseD.matches(cardBaseL), "glassCard base does not adapt (\(cardBaseD) == \(cardBaseL))")
    }
    // 11. Elevation ladder grouping wires the right ingredients per rung.
    await test("v4: Elevation rungs wire fill/edge/shadow/blur correctly") {
        try expect(BridgeTokens.Elevation.card.shadow != nil && BridgeTokens.Elevation.card.blur == nil,
                   "e1 card: e1 shadow, no blur")
        try expect(BridgeTokens.Elevation.window.radius == BridgeTokens.Radius.window,
                   "e4 window radius == window radius")
        try expect(BridgeTokens.Elevation.control.fill == nil && BridgeTokens.Elevation.control.controlFill != nil,
                   "control rung: flat controlFill, no glass fill")
        try expect(BridgeTokens.Elevation.inset.shadow == nil && BridgeTokens.Elevation.inset.edge == nil,
                   "inset rung: recessed, no drop shadow / edge")
    }
}
