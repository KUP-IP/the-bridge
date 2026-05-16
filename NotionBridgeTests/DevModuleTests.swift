// DevModuleTests.swift — Dev-suite audit (every-angle-of-attack)
// NotionBridge · Tests
//
// DevModule (`dev_module_info`) shipped with ZERO test coverage and was
// absent from the test runner. This file closes that gap and exercises
// the scaffold tool across the full attack surface: registration,
// tier, happy path, extra-args tolerance, wrong-shape args, annotation
// presence, and rendered-description quality.

import Foundation
import MCP
import NotionBridgeLib

func runDevModuleTests() async {
    print("\n\u{1F9F0} DevModule Tests (dev-suite audit)")

    await test("DevModule registers dev_module_info under module=\"dev\"") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevModule.register(on: router)
        let names = Set((await router.registrations(forModule: "dev")).map { $0.name })
        try expect(names == ["dev_module_info"],
                   "expected exactly [dev_module_info], got \(names.sorted())")
    }

    await test("dev_module_info is tier .open (read-only metadata)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevModule.register(on: router)
        let regs = (await router.registrations(forModule: "dev")).filter { $0.name == "dev_module_info" }
        try expect(regs.count == 1, "expected 1 registration, got \(regs.count)")
        try expect(regs[0].tier == .open, "expected .open tier, got \(regs[0].tier)")
        try expect(regs[0].neverAutoApprove == false, "scaffold metadata must not force confirm")
    }

    await test("dev_module_info happy path returns the documented envelope") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevModule.register(on: router)
        let result = try await router.dispatch(toolName: "dev_module_info", arguments: .object([:]))
        guard case .object(let d) = result else { throw TestError.assertion("expected object result") }
        guard case .string(let module) = d["module"] else { throw TestError.assertion("missing module") }
        try expect(module == "dev", "expected module=dev, got \(module)")
        guard case .string(let status) = d["status"] else { throw TestError.assertion("missing status") }
        try expect(status == "scaffold", "expected status=scaffold, got \(status)")
        guard case .string(let version) = d["version"] else { throw TestError.assertion("missing version") }
        try expect(!version.isEmpty, "version must be a non-empty marketing string")
        // purpose + introduced must be present and informative.
        guard case .string(let purpose) = d["purpose"], !purpose.isEmpty else {
            throw TestError.assertion("missing/empty purpose")
        }
        guard case .string(let introduced) = d["introduced"], !introduced.isEmpty else {
            throw TestError.assertion("missing/empty introduced")
        }
    }

    await test("dev_module_info tolerates extra/unexpected args (no required schema)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevModule.register(on: router)
        // Schema declares no required fields; junk args must not error.
        let result = try await router.dispatch(
            toolName: "dev_module_info",
            arguments: .object(["bogus": .string("x"), "n": .int(7)])
        )
        guard case .object(let d) = result, case .string = d["module"] else {
            throw TestError.assertion("extra args must be ignored, got \(result)")
        }
    }

    await test("dev_module_info tolerates a non-object argument value") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevModule.register(on: router)
        // Handler ignores arguments entirely (`{ _ in ... }`); a non-object
        // value must still yield the metadata envelope, not a crash/throw.
        let result = try await router.dispatch(toolName: "dev_module_info", arguments: .string("oops"))
        guard case .object(let d) = result, case .string(let m) = d["module"], m == "dev" else {
            throw TestError.assertion("non-object args must be ignored, got \(result)")
        }
    }

    await test("dev_module_info has an explicit annotation entry (read-only, closed-world)") {
        guard let ann = ToolAnnotationCatalog.annotations(for: "dev_module_info") else {
            throw TestError.assertion("dev_module_info missing explicit ToolAnnotationCatalog entry")
        }
        try expect(ann.readOnlyHint == true, "metadata scaffold must be read-only")
        try expect(ann.destructiveHint == false, "scaffold cannot be destructive")
        try expect(ann.requiresConfirmation == false, "open tier → no confirm")
        try expect(ann.openWorld == false, "scaffold touches no external world")
    }

    await test("dev_module_info rendered MCP description is substantive (selection guidance)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevModule.register(on: router)
        let reg = (await router.allRegistrations()).first { $0.name == "dev_module_info" }!
        let rendered = BridgeToolDescriptionRenderer.render(reg)
        try expect(rendered.count >= 24, "description too thin to guide selection: \"\(rendered)\"")
        try expect(rendered.count <= BridgeToolDescriptionRenderer.charBudget,
                   "description exceeds char budget")
        let title = BridgeToolDescriptionRenderer.title(reg)
        try expect(title == "Dev Module Info", "title derivation drift: \(title)")
    }
}
