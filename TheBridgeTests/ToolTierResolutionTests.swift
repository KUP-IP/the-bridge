// ToolTierResolutionTests.swift
// TheBridge · Tests
//
// fb-securitygate-revoke-ui — the Tool Registry now renders a tool's
// module-aware effective tier AND its source (own override vs module grant vs
// registered default), and offers a per-module revoke. `ToolTierResolution` is
// the pure helper that backs both the view and these tests, mirroring
// `ToolRouter.resolveEffectiveTier` precedence: per-tool > per-module > default.
//
// Harness: standalone executable runner (no XCTest). Entry point
// `runToolTierResolutionTests()` is invoked from TestRunner.swift.

import Foundation
import TheBridgeLib

func runToolTierResolutionTests() async {
    print("\n🎚️  ToolTierResolution Tests (fb-securitygate-revoke-ui)")

    // ============================================================
    // MARK: - effectiveTier precedence (delegates to ToolRouter)
    // ============================================================

    await test("effectiveTier: per-tool override beats module grant and default") {
        let tier = ToolTierResolution.effectiveTier(
            toolName: "snippets_delete", module: "snippets", registeredTier: "request",
            toolOverrides: ["snippets_delete": "open"],
            moduleOverrides: ["snippets": "notify"]
        )
        try expect(tier == "open", "per-tool override (open) must win; got \(tier)")
    }

    await test("effectiveTier: module grant beats registered default when no per-tool override") {
        let tier = ToolTierResolution.effectiveTier(
            toolName: "snippets_create", module: "snippets", registeredTier: "request",
            toolOverrides: [:],
            moduleOverrides: ["snippets": "notify"]
        )
        try expect(tier == "notify", "module grant (notify) must apply to a sibling tool; got \(tier)")
    }

    await test("effectiveTier: registered default when no overrides") {
        let tier = ToolTierResolution.effectiveTier(
            toolName: "snippets_create", module: "snippets", registeredTier: "request",
            toolOverrides: [:], moduleOverrides: [:]
        )
        try expect(tier == "request", "must fall back to registered default; got \(tier)")
    }

    await test("effectiveTier: malformed module override falls through to registered default") {
        let tier = ToolTierResolution.effectiveTier(
            toolName: "snippets_create", module: "snippets", registeredTier: "request",
            toolOverrides: [:], moduleOverrides: ["snippets": "bogus"]
        )
        try expect(tier == "request", "unparseable module value must not lower the tier; got \(tier)")
    }

    // ============================================================
    // MARK: - source resolution (drives the UI annotation)
    // ============================================================

    await test("source: ownOverride when per-tool override present") {
        let src = ToolTierResolution.source(
            toolName: "snippets_delete", module: "snippets",
            toolOverrides: ["snippets_delete": "open"], moduleOverrides: [:]
        )
        try expect(src == .ownOverride, "expected .ownOverride; got \(src)")
    }

    await test("source: moduleGrant when only a module grant present") {
        let src = ToolTierResolution.source(
            toolName: "snippets_create", module: "snippets",
            toolOverrides: [:], moduleOverrides: ["snippets": "notify"]
        )
        try expect(src == .moduleGrant, "expected .moduleGrant; got \(src)")
    }

    await test("source: registeredDefault when neither present") {
        let src = ToolTierResolution.source(
            toolName: "snippets_create", module: "snippets",
            toolOverrides: [:], moduleOverrides: [:]
        )
        try expect(src == .registeredDefault, "expected .registeredDefault; got \(src)")
    }

    await test("source: per-tool override wins over module grant") {
        let src = ToolTierResolution.source(
            toolName: "snippets_delete", module: "snippets",
            toolOverrides: ["snippets_delete": "request"], moduleOverrides: ["snippets": "notify"]
        )
        try expect(src == .ownOverride, "per-tool override must take precedence; got \(src)")
    }

    await test("source: empty module name is never a module grant") {
        let src = ToolTierResolution.source(
            toolName: "echo", module: "",
            toolOverrides: [:], moduleOverrides: ["": "notify"]
        )
        try expect(src == .registeredDefault, "empty module must not match a grant; got \(src)")
    }

    // ============================================================
    // MARK: - revoke outcome
    // ============================================================

    await test("revoke outcome: removing the module entry reverts a sibling to its registered default") {
        // Before revoke: sibling inherits the module grant.
        let before = ToolTierResolution.source(
            toolName: "snippets_create", module: "snippets",
            toolOverrides: [:], moduleOverrides: ["snippets": "notify"]
        )
        try expect(before == .moduleGrant, "precondition: sibling is on the module grant; got \(before)")
        // After revoke (key removed): falls back to its registered default tier.
        let after = ToolTierResolution.source(
            toolName: "snippets_create", module: "snippets",
            toolOverrides: [:], moduleOverrides: [:]
        )
        try expect(after == .registeredDefault, "after revoke the sibling reverts to default; got \(after)")
        let tierAfter = ToolTierResolution.effectiveTier(
            toolName: "snippets_create", module: "snippets", registeredTier: "request",
            toolOverrides: [:], moduleOverrides: [:]
        )
        try expect(tierAfter == "request", "after revoke the effective tier is the registered default; got \(tierAfter)")
    }
}
