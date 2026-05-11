// LighthouseModuleTests.swift — PKT-781 (Bridge v2.2 · 3.2a)
// Probe-only mock coverage. Hermetic: per-test temp baseDir + probeOverride.

import Foundation
import MCP
import NotionBridgeLib

private func tempDir(_ tag: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NBT-lh-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func runLighthouseModuleTests() async {
    print("\n\u{1F4A1} LighthouseModule Tests (PKT-781 v2.2 · 3.2a)")

    await test("LighthouseModule registers lighthouse_run under module=\"dev\"") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await LighthouseModule.register(on: router, bgRuntime: BgProcessRuntime(baseDir: tempDir("reg")), probeOverride: { true })
        let names = Set((await router.registrations(forModule: "dev")).map { $0.name })
        try expect(names.contains("lighthouse_run"), "missing lighthouse_run — got \(names.sorted())")
    }

    await test("lighthouse_run is tier .request") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await LighthouseModule.register(on: router, bgRuntime: BgProcessRuntime(baseDir: tempDir("tier")), probeOverride: { true })
        let regs = (await router.registrations(forModule: "dev")).filter { $0.name == "lighthouse_run" }
        try expect(regs.count == 1, "expected 1 registration, got \(regs.count)")
        try expect(regs[0].tier == .request, "expected .request tier, got \(regs[0].tier)")
    }

    await test("lighthouse_run returns capability_missing when probe fails") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await LighthouseModule.register(on: router, bgRuntime: BgProcessRuntime(baseDir: tempDir("cap")), probeOverride: { false })
        let result = try await router.dispatch(toolName: "lighthouse_run", arguments: .object([:]))
        guard case .object(let d) = result else { throw TestError.assertion("expected object result") }
        guard case .string(let status) = d["status"] else { throw TestError.assertion("missing status") }
        try expect(status == "capability_missing", "expected capability_missing, got \(status)")
        if case .string(let tool) = d["tool"] { try expect(tool == "lighthouse_run", "wrong tool: \(tool)") }
    }

    await test("lighthouse_run returns jobId envelope when probe passes") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await LighthouseModule.register(on: router, bgRuntime: BgProcessRuntime(baseDir: tempDir("spawn")), probeOverride: { true })
        let result = try await router.dispatch(toolName: "lighthouse_run", arguments: .object([
            "args": .array([.string("--version")])
        ]))
        guard case .object(let d) = result else { throw TestError.assertion("expected object result") }
        guard case .bool(let ok) = d["ok"] else { throw TestError.assertion("missing ok") }
        try expect(ok == true, "expected ok=true, got \(d)")
        guard case .string(let jobId) = d["jobId"] else { throw TestError.assertion("missing jobId") }
        try expect(!jobId.isEmpty, "empty jobId")
    }
}
