// ToolConventionTests.swift — v3.0·0.5 (PKT — agentic-usability)
// P0 remediation guards:
//  1. didYouMean alias recovery detects the AGENT_FEEDBACK offenders.
//  2. Forward-guard: every registered inputSchema property key is
//     camelCase (verified already true; this locks it so no future
//     snake_case key regresses the surface).
//  3. The MCP `instructions` carry the tool-call contract.

import Foundation
import MCP
import NotionBridgeLib

private func camelCaseOK(_ key: String) -> Bool {
    // ^[a-z][a-zA-Z0-9]*$ — lowercase first char, alphanumeric only.
    guard let first = key.first, first.isLowercase else { return false }
    return key.allSatisfy { $0.isLetter || $0.isNumber }
}

func runToolConventionTests() async {
    print("\n\u{1F9F0} Tool conventions (PKT v3.0·0.5 · P0)")

    await test("didYouMean detects AGENT_FEEDBACK offenders, deterministic") {
        let h = BridgeToolAliases.didYouMean(providedKeys: ["content", "pageId"])
        try expect(h == "did you mean: content→text", "got \(String(describing: h))")
        let h2 = BridgeToolAliases.didYouMean(providedKeys: ["data_source_id", "content"])
        try expect(h2 == "did you mean: content→text, data_source_id→dataSourceId",
                   "sorted/deterministic expected, got \(String(describing: h2))")
    }

    await test("didYouMean returns nil for clean keys") {
        try expect(BridgeToolAliases.didYouMean(providedKeys: ["pageId", "text", "dataSourceId"]) == nil,
                   "false positive on clean keys")
    }

    await test("forward-guard: every registered inputSchema property key is camelCase") {
        let gate = SecurityGate(); let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router, includeStripe: false,
            registerSession: { await SessionModule.register(on: $0, auditLog: log) })
        // Documented legacy exceptions (none at v3.0·0.5 — schema keys were
        // already consistent; list exists so a future exception is explicit).
        let legacyAllow: Set<String> = []
        var violations: [String] = []
        for reg in await router.allRegistrations() {
            guard case .object(let top) = reg.inputSchema,
                  case .object(let props)? = top["properties"] else { continue }
            for key in props.keys where !camelCaseOK(key) && !legacyAllow.contains(key) {
                violations.append("\(reg.name).\(key)")
            }
        }
        try expect(violations.isEmpty,
                   "non-camelCase schema keys (add to legacyAllow only with a recorded reason): \(violations.sorted())")
    }

    await test("MCP instructions carry the tool-call contract") {
        try expect(!SkillsModule.dispatchContract.isEmpty, "dispatchContract empty")
        let instr = SkillsModule.buildRoutingInstructions()
        try expect(instr.contains("camelCase") && instr.contains("did you mean"),
                   "dispatch contract not surfaced in instructions")
    }
}
