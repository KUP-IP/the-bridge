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
            Fixed(name: "accentStrong", color: BridgeTokens.accentStrong),
            Fixed(name: "accentLink", color: BridgeTokens.accentLink),
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
}
