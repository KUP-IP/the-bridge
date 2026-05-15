// BridgeModuleRegistryTests.swift — v3.0 prep 0.4 (PKT — registrar remediation)
// Enforces that BridgeModuleRegistry is the single source of truth for the
// static feature-module surface: the count matches the canonical constant the
// rest of the suite trusts, includeStripe is the only prod/test delta, no
// module is registered twice, and every registered tool has an explicit
// annotation (the drift class WS-B's audit caught — now centrally guarded).

import Foundation
import NotionBridgeLib

func runBridgeModuleRegistryTests() async {
    print("\n\u{1F9E9} BridgeModuleRegistry (PKT v3.0·0.4 · single-source)")

    func buildRouter(includeStripe: Bool) async -> ToolRouter {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            includeStripe: includeStripe,
            registerSession: { r in await SessionModule.register(on: r, auditLog: log) }
        )
        return router
    }

    await test("registry (includeStripe:false) == canonical static feature count") {
        let router = await buildRouter(includeStripe: false)
        let regs = await router.allRegistrations()
        try expect(!regs.isEmpty, "registry registered no tools")
        try expect(
            regs.count == BridgeConstants.staticFeatureModuleToolCount,
            "registry count \(regs.count) != BridgeConstants.staticFeatureModuleToolCount \(BridgeConstants.staticFeatureModuleToolCount)"
        )
    }

    await test("no module registered twice (unique tool names — single-source guard)") {
        let regs = await (buildRouter(includeStripe: true)).allRegistrations()
        let names = regs.map(\.name)
        try expect(Set(names).count == names.count,
                   "duplicate registrations: \(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
    }

    await test("includeStripe is the ONLY prod/test delta (true ⊋ false, delta = Stripe)") {
        let falseNames = Set(await (buildRouter(includeStripe: false)).allRegistrations().map(\.name))
        let trueNames = Set(await (buildRouter(includeStripe: true)).allRegistrations().map(\.name))
        try expect(falseNames.isSubset(of: trueNames), "includeStripe:false must be a subset of true")
        let delta = trueNames.subtracting(falseNames)
        try expect(!delta.isEmpty, "includeStripe:true added no tools — StripeMcpModule not wired?")
        // Every delta tool must belong to the Stripe module surface.
        try expect(delta.allSatisfy { $0.contains("stripe") || $0.hasPrefix("stripe_") },
                   "includeStripe delta contains non-Stripe tools: \(delta.sorted())")
    }

    await test("every registry tool has an EXPLICIT annotation (centralized drift guard)") {
        let regs = await (buildRouter(includeStripe: false)).allRegistrations()
        let missing = regs.map(\.name).filter { ToolAnnotationCatalog.annotations(for: $0) == nil }
        try expect(missing.isEmpty, "registry tools missing explicit annotations: \(missing.sorted())")
    }
}
