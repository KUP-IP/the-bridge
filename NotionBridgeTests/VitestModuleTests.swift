// VitestModuleTests.swift — PKT-781 (Bridge v2.2 · 3.2a)
// Probe-only mock coverage. Per Reflow #21 vitest is uninstalled on this host —
// capability_missing is the live-default state; probeOverride pins both branches.

import Foundation
import MCP
import NotionBridgeLib

private func tempDir(_ tag: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NBT-vt-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func runVitestModuleTests() async {
    print("\n\u{1F9EA} VitestModule Tests (PKT-781 v2.2 · 3.2a)")

    await test("VitestModule registers vitest_run under module=\"dev\"") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VitestModule.register(on: router, bgRuntime: BgProcessRuntime(baseDir: tempDir("reg")), probeOverride: { true })
        let names = Set((await router.registrations(forModule: "dev")).map { $0.name })
        try expect(names.contains("vitest_run"), "missing vitest_run — got \(names.sorted())")
    }

    await test("vitest_run is tier .request") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VitestModule.register(on: router, bgRuntime: BgProcessRuntime(baseDir: tempDir("tier")), probeOverride: { true })
        let regs = (await router.registrations(forModule: "dev")).filter { $0.name == "vitest_run" }
        try expect(regs.count == 1, "expected 1 registration, got \(regs.count)")
        try expect(regs[0].tier == .request, "expected .request tier, got \(regs[0].tier)")
    }

    await test("vitest_run returns capability_missing when probe fails") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VitestModule.register(on: router, bgRuntime: BgProcessRuntime(baseDir: tempDir("cap")), probeOverride: { false })
        let result = try await router.dispatch(toolName: "vitest_run", arguments: .object([:]))
        guard case .object(let d) = result else { throw TestError.assertion("expected object result") }
        guard case .string(let status) = d["status"] else { throw TestError.assertion("missing status") }
        try expect(status == "capability_missing", "expected capability_missing, got \(status)")
        if case .string(let tool) = d["tool"] { try expect(tool == "vitest_run", "wrong tool: \(tool)") }
    }

    await test("vitest_run returns jobId envelope when probe passes") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VitestModule.register(on: router, bgRuntime: BgProcessRuntime(baseDir: tempDir("spawn")), probeOverride: { true })
        let result = try await router.dispatch(toolName: "vitest_run", arguments: .object([
            "args": .array([.string("--version")])
        ]))
        guard case .object(let d) = result else { throw TestError.assertion("expected object result") }
        guard case .bool(let ok) = d["ok"] else { throw TestError.assertion("missing ok") }
        try expect(ok == true, "expected ok=true, got \(d)")
        guard case .string(let jobId) = d["jobId"] else { throw TestError.assertion("missing jobId") }
        try expect(!jobId.isEmpty, "empty jobId")
    }
}
