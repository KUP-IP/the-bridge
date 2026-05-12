// LspModuleTests.swift — PKT-789 W3.cleanup: LspModule + LspRuntime tests
// NotionBridge · Tests
//
// Two-layer suite per packet contract:
//   (1) Probe-only mocks — always run, CI-green without LSP_LIVE.
//   (2) LSP_LIVE=1-gated live tests against real typescript-language-server
//       and sourcekit-lsp; opt-in for dev box.
//
// Path inputs use BRIDGE_REPO / KEEPUP_CLUB env vars with sensible defaults
// (worktree CWD / ~/Developer/keepup-club) for portability.
//
// Run all:  swift run NotionBridgeTests
// Run live: LSP_LIVE=1 swift run NotionBridgeTests

import Foundation
import MCP
import NotionBridgeLib

func runLspModuleTests() async {
    print("\n\u{1F50D} LspModule Tests")
    await runLspModuleProbeOnlyTests()
    await runLspModuleProbeShapeTests()
    await runLspModuleLiveTests()
    await runLspModuleRenameRefsLiveTests()
}

// MARK: - (1) Probe-only mocks

private func runLspModuleProbeOnlyTests() async {
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await LspModule.register(on: router)

    await test("LspModule registers 6 lsp_* tools under 'dev'") {
        let all = await router.registrations(forModule: "dev")
        // Filter lsp_*-prefixed — DevModule scaffold may register dev_module_info here too.
        let lspTools = all.filter { $0.name.hasPrefix("lsp_") }
        try expect(lspTools.count == 6, "Expected 6 lsp_* tools, got \(lspTools.count)")
        let names = Set(lspTools.map(\.name))
        for required in ["lsp_diagnostics", "lsp_hover", "lsp_references",
                         "lsp_definition", "lsp_rename", "lsp_session_list"] {
            try expect(names.contains(required), "Missing \(required)")
        }
    }

    await test("All lsp_* tools are tier .request") {
        let all = await router.registrations(forModule: "dev")
        for t in all where t.name.hasPrefix("lsp_") {
            try expect(t.tier == .request,
                       "\(t.name) tier should be .request, got \(t.tier.rawValue)")
        }
    }
}

private func runLspModuleProbeShapeTests() async {
    await test("probe(typescript) returns expected shape") {
        let r = LspModule.probe(language: "typescript")
        try expect(r.language == "typescript", "language should be 'typescript'")
        if r.available {
            try expect(r.path != nil, "available=true implies non-nil path")
            try expect(FileManager.default.isExecutableFile(atPath: r.path!),
                       "available=true implies executable path")
        } else {
            try expect(r.detail != nil, "available=false implies non-nil detail")
        }
    }

    await test("probe(swift) returns expected shape") {
        let r = LspModule.probe(language: "swift")
        try expect(r.language == "swift")
        if r.available {
            try expect(r.path?.hasSuffix("sourcekit-lsp") == true,
                       "swift path should end with sourcekit-lsp")
        }
    }

    await test("probe accepts ts/tsx/js/jsx/javascript aliases as typescript") {
        for alias in ["ts", "tsx", "js", "jsx", "javascript"] {
            let r = LspModule.probe(language: alias)
            try expect(r.language == "typescript",
                       "alias '\(alias)' should normalize to 'typescript'")
        }
    }

    await test("probe(unsupported) returns available=false with informative detail") {
        let r = LspModule.probe(language: "python")
        try expect(!r.available, "python should be unsupported in v2.2")
        try expect(r.path == nil)
        try expect(r.detail?.lowercased().contains("unsupported") == true,
                   "detail should mention 'unsupported'")
    }

    await test("inferLanguage maps extensions correctly") {
        for ext in ["ts", "tsx", "js", "jsx", "mjs", "cjs"] {
            try expect(LspModule.inferLanguage(fromPath: "/a/b.\(ext)") == "typescript",
                       "\(ext) should map to typescript")
        }
        try expect(LspModule.inferLanguage(fromPath: "/a/b.swift") == "swift")
        try expect(LspModule.inferLanguage(fromPath: "/a/b.py") == nil)
        try expect(LspModule.inferLanguage(fromPath: "/a/b") == nil)
    }

    await test("findWorkspaceRoot finds TS package.json") {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lsp-test-ts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let nested = tmp.appendingPathComponent("src/subdir")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "{}".write(to: tmp.appendingPathComponent("package.json"),
                       atomically: true, encoding: .utf8)
        let file = nested.appendingPathComponent("foo.ts")
        try "const x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let root = LspModule.findWorkspaceRoot(forFile: file.path, language: "typescript")
        try expect(root?.standardizedFileURL.path == tmp.standardizedFileURL.path,
                   "expected \(tmp.path), got \(root?.path ?? "nil")")
    }

    await test("findWorkspaceRoot finds Swift Package.swift") {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lsp-test-swift-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let nested = tmp.appendingPathComponent("Sources/Foo")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(
            to: tmp.appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8)
        let file = nested.appendingPathComponent("Foo.swift")
        try "import Foundation\n".write(to: file, atomically: true, encoding: .utf8)
        let root = LspModule.findWorkspaceRoot(forFile: file.path, language: "swift")
        try expect(root?.standardizedFileURL.path == tmp.standardizedFileURL.path,
                   "expected \(tmp.path), got \(root?.path ?? "nil")")
    }

    await test("findWorkspaceRoot returns nil for unsupported language") {
        let r = LspModule.findWorkspaceRoot(forFile: "/tmp/foo.py", language: "python")
        try expect(r == nil, "unsupported language should return nil root")
    }
}

// MARK: - (2) LSP_LIVE=1 gated live tests

private func runLspModuleLiveTests() async {
    guard ProcessInfo.processInfo.environment["LSP_LIVE"] == "1" else {
        print("  \u{23ED}\u{FE0F}  LSP_LIVE!=1 \u{2014} skipping live tests (set LSP_LIVE=1 to enable)")
        return
    }

    let env = ProcessInfo.processInfo.environment
    let bridgeRepo = env["BRIDGE_REPO"] ?? FileManager.default.currentDirectoryPath
    let keepupClub = env["KEEPUP_CLUB"]
        ?? "\(NSHomeDirectory())/Developer/keepup-club"

    await test("[LSP_LIVE] sourcekit-lsp hover on LspRuntime") {
        let runtimePath = "\(bridgeRepo)/NotionBridge/Modules/LspRuntime.swift"
        try expect(FileManager.default.fileExists(atPath: runtimePath),
                   "expected LspRuntime.swift at \(runtimePath); set BRIDGE_REPO to override")
        let probe = LspModule.probe(language: "swift")
        guard probe.available, let serverPath = probe.path else {
            throw TestError.assertion("sourcekit-lsp not on PATH; cannot run live test")
        }
        guard let root = LspModule.findWorkspaceRoot(forFile: runtimePath, language: "swift") else {
            throw TestError.assertion("could not locate Swift workspace root for \(runtimePath)")
        }

        let coldStart = Date()
        let session = try await LspRuntime.shared.ensureSession(
            language: "swift", workspaceRoot: root.path, serverPath: serverPath)
        let coldElapsed = Date().timeIntervalSince(coldStart)
        print("    \u{25B8} sourcekit-lsp cold-start: \(String(format: "%.3f", coldElapsed))s")

        try await session.ensureFileOpen(runtimePath)
        let content = try String(contentsOfFile: runtimePath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        guard let lineIdx = lines.firstIndex(where: { $0.contains("public actor LspRuntime") }) else {
            throw TestError.assertion("could not locate 'public actor LspRuntime' anchor in LspRuntime.swift")
        }
        let charIdx = (lines[lineIdx] as NSString).range(of: "LspRuntime").location

        let hoverBegin = Date()
        let result = try await session.sendRequest(
            method: "textDocument/hover",
            params: [
                "textDocument": ["uri": URL(fileURLWithPath: runtimePath).absoluteString],
                "position":     ["line": lineIdx, "character": charIdx]
            ],
            timeout: 30)
        let hoverElapsed = Date().timeIntervalSince(hoverBegin)
        print("    \u{25B8} sourcekit-lsp hover: \(String(format: "%.3f", hoverElapsed))s")
        try expect(result != nil, "expected non-nil hover result for LspRuntime")
    }

    await test("[LSP_LIVE] TS-LSP cold-start + idle-dispose round-trip") {
        guard FileManager.default.fileExists(atPath: keepupClub) else {
            throw TestError.assertion("\(keepupClub) not present; set KEEPUP_CLUB to override")
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: keepupClub) else {
            throw TestError.assertion("could not enumerate \(keepupClub)")
        }
        var firstTs: String?
        while let rel = enumerator.nextObject() as? String {
            let full = "\(keepupClub)/\(rel)"
            if (rel.hasSuffix(".ts") || rel.hasSuffix(".tsx"))
                && !rel.contains("node_modules/")
                && !rel.contains(".next/") {
                firstTs = full
                break
            }
        }
        guard let tsFile = firstTs else {
            throw TestError.assertion("no .ts/.tsx files found in \(keepupClub)")
        }
        let probe = LspModule.probe(language: "typescript")
        guard probe.available, let serverPath = probe.path else {
            throw TestError.assertion("typescript-language-server not on PATH")
        }
        guard let root = LspModule.findWorkspaceRoot(forFile: tsFile, language: "typescript") else {
            throw TestError.assertion("could not locate TS workspace for \(tsFile)")
        }

        await LspRuntime.shared.setIdleTimeout(3)

        let coldStart = Date()
        _ = try await LspRuntime.shared.ensureSession(
            language: "typescript", workspaceRoot: root.path, serverPath: serverPath)
        let coldElapsed = Date().timeIntervalSince(coldStart)
        print("    \u{25B8} TS-LSP cold-start: \(String(format: "%.3f", coldElapsed))s")

        var sessions = await LspRuntime.shared.listSessions()
        try expect(sessions.contains(where: { $0.language == "typescript" }),
                   "expected typescript session live after ensureSession")

        // Wait past idle timeout (3s) + slack.
        try await Task.sleep(nanoseconds: 5_000_000_000)
        sessions = await LspRuntime.shared.listSessions()
        try expect(!sessions.contains(where: { $0.language == "typescript" && $0.workspaceRoot == root.path }),
                   "expected typescript session disposed after idle timeout")

        let reColdStart = Date()
        _ = try await LspRuntime.shared.ensureSession(
            language: "typescript", workspaceRoot: root.path, serverPath: serverPath)
        let reColdElapsed = Date().timeIntervalSince(reColdStart)
        print("    \u{25B8} TS-LSP re-cold-start: \(String(format: "%.3f", reColdElapsed))s")
        sessions = await LspRuntime.shared.listSessions()
        try expect(sessions.contains(where: { $0.language == "typescript" && $0.workspaceRoot == root.path }),
                   "expected fresh typescript session after re-cold-start")

        // Restore default idle timeout.
        await LspRuntime.shared.setIdleTimeout(15 * 60)
    }

    // Final cleanup — best-effort tear down any sessions still alive.
    await LspRuntime.shared.disposeAll()
}
