// BridgeModuleRegistryTests.swift — v3.0 prep 0.4 (PKT — registrar remediation)
// Enforces that BridgeModuleRegistry is the single source of truth for the
// static feature-module surface: the count matches the canonical constant the
// rest of the suite trusts, includeStripe is the only prod/test delta, no
// module is registered twice, and every registered tool has an explicit
// annotation (the drift class WS-B's audit caught — now centrally guarded).

import Foundation
import TheBridgeLib

func runBridgeModuleRegistryTests() async {
    print("\n\u{1F9E9} BridgeModuleRegistry (PKT v3.0·0.4 · single-source)")

    func buildRouter() async -> ToolRouter {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            registerSession: { r in await SessionModule.register(on: r, auditLog: log) }
        )
        return router
    }

    await test("registry == canonical static feature count") {
        let router = await buildRouter()
        let regs = await router.allRegistrations()
        try expect(!regs.isEmpty, "registry registered no tools")
        try expect(
            regs.count == BridgeConstants.staticFeatureModuleToolCount,
            "registry count \(regs.count) != BridgeConstants.staticFeatureModuleToolCount \(BridgeConstants.staticFeatureModuleToolCount)"
        )
    }

    await test("no module registered twice (unique tool names — single-source guard)") {
        let regs = await (buildRouter()).allRegistrations()
        let names = regs.map(\.name)
        try expect(Set(names).count == names.count,
                   "duplicate registrations: \(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
    }

    await test("registry is deterministic — Stripe fully removed, no prod/test delta") {
        let a = Set(await (buildRouter()).allRegistrations().map(\.name))
        let b = Set(await (buildRouter()).allRegistrations().map(\.name))
        // Stripe was removed entirely in the v3.7.11 resurface and the includeStripe
        // build flag retired — registration is now one deterministic surface.
        try expect(a == b, "registry must build an identical surface every time; delta: \(a.symmetricDifference(b).sorted())")
        try expect(a.allSatisfy { !$0.contains("stripe") && $0 != "payment_execute" },
                   "no Stripe/payment tool may reappear in the static surface")
    }

    await test("every registry tool has an EXPLICIT annotation (centralized drift guard)") {
        let regs = await (buildRouter()).allRegistrations()
        let missing = regs.map(\.name).filter { ToolAnnotationCatalog.annotations(for: $0) == nil }
        try expect(missing.isEmpty, "registry tools missing explicit annotations: \(missing.sorted())")
    }
}
