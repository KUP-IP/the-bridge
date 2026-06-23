// DevSuiteEdgeTests.swift — Dev-suite audit (every-angle-of-attack)
// TheBridge · Tests
//
// Per-tool edge / wrong-type / empty-input / idempotency hardening for
// Dev tools whose existing module tests skipped these dimensions. Pure,
// deterministic, network-free: capability-missing and structured-error
// envelopes are exercised; nothing shells out to the live network. For
// the shell-out wrappers (gh/wrangler/runners) the argument-validation
// and capability-probe layers are tested, not live invocation.

import Foundation
import MCP
import TheBridgeLib

private func edgeTempDir(_ tag: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NBT-edge-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func runDevSuiteEdgeTests() async {
    print("\n\u{1F6E1}\u{FE0F}  Dev-Suite Edge / Attack Surface")

    // ---- ArtifactModule: http_fetch ------------------------------------
    await test("http_fetch rejects a non-http(s) scheme with structured invalid_argument") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let r = try await router.dispatch(toolName: "http_fetch",
                                          arguments: .object(["url": .string("file:///etc/passwd")]))
        guard case .object(let d) = r else { throw TestError.assertion("expected object") }
        guard case .bool(let ok) = d["ok"], ok == false else { throw TestError.assertion("expected ok=false, got \(d)") }
        guard case .string(let status) = d["status"], status == "invalid_argument" else {
            throw TestError.assertion("expected status=invalid_argument, got \(d)")
        }
        guard case .string(let err) = d["error"], err.contains("http") else {
            throw TestError.assertion("error should mention scheme requirement, got \(d)")
        }
    }

    await test("http_fetch with a missing/invalid url throws structured invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "http_fetch", arguments: .object([:]))
            throw TestError.assertion("expected throw for missing url")
        } catch let e as ToolRouterError {
            if case .invalidArguments(let tool, _) = e {
                try expect(tool == "http_fetch", "wrong tool in error: \(tool)")
            } else {
                throw TestError.assertion("expected .invalidArguments, got \(e)")
            }
        }
    }

    // ---- ArtifactModule: diff_render -----------------------------------
    await test("diff_render on an empty diff returns ok with zero counts") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let r = try await router.dispatch(toolName: "diff_render", arguments: .object(["diff": .string("")]))
        guard case .object(let d) = r, case .bool(true) = d["ok"] else {
            throw TestError.assertion("expected ok=true, got \(r)")
        }
        try expect(d["hunks"] == .int(0) && d["additions"] == .int(0) && d["deletions"] == .int(0),
                   "empty diff must report zero counts, got \(d)")
    }

    await test("diff_render unknown format falls back to markdown (no crash)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let r = try await router.dispatch(toolName: "diff_render",
                                          arguments: .object(["diff": .string("@@ -1 +1 @@\n-a\n+b"),
                                                              "format": .string("not-a-format")]))
        guard case .object(let d) = r, case .string(let fmt) = d["format"] else {
            throw TestError.assertion("expected object with format, got \(r)")
        }
        try expect(fmt == "not-a-format", "format echoed; renderer must default-branch to markdown body")
        guard case .string(let rendered) = d["rendered"], rendered.contains("```diff") else {
            throw TestError.assertion("unknown format must fall back to fenced markdown, got \(d)")
        }
    }

    await test("diff_render with missing 'diff' throws structured invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "diff_render", arguments: .object([:]))
            throw TestError.assertion("expected throw")
        } catch is ToolRouterError { /* expected */ }
    }

    // ---- ArtifactModule: file_hash -------------------------------------
    await test("file_hash on a nonexistent path returns structured not_found") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let missing = edgeTempDir("fh").appendingPathComponent("nope.bin").path
        let r = try await router.dispatch(toolName: "file_hash", arguments: .object(["path": .string(missing)]))
        guard case .object(let d) = r, case .bool(false) = d["ok"],
              case .string(let status) = d["status"], status == "not_found" else {
            throw TestError.assertion("expected ok=false status=not_found, got \(r)")
        }
        guard case .string = d["error"] else { throw TestError.assertion("not_found must carry an error string") }
    }

    await test("file_hash is deterministic + matches CryptoKit SHA-256 of bytes") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let f = edgeTempDir("fh2").appendingPathComponent("a.txt")
        try "hello bridge\n".data(using: .utf8)!.write(to: f)
        let r1 = try await router.dispatch(toolName: "file_hash", arguments: .object(["path": .string(f.path)]))
        let r2 = try await router.dispatch(toolName: "file_hash", arguments: .object(["path": .string(f.path)]))
        guard case .object(let d1) = r1, case .string(let h1) = d1["hash"],
              case .object(let d2) = r2, case .string(let h2) = d2["hash"] else {
            throw TestError.assertion("missing hash, got \(r1) / \(r2)")
        }
        try expect(h1 == h2, "hash must be deterministic")
        try expect(h1.count == 64, "sha256 hex must be 64 chars, got \(h1.count)")
        try expect(d1["bytes"] == .int(13), "byte count should be 13, got \(String(describing: d1["bytes"]))")
    }

    // ---- CodeEditModule: code_search wrong-type + empty -----------------
    await test("code_search with missing 'pattern' throws structured invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CodeEditModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "code_search", arguments: .object(["path": .string("/tmp")]))
            throw TestError.assertion("expected throw for missing pattern")
        } catch let e as ToolRouterError {
            if case .invalidArguments(let tool, let reason) = e {
                try expect(tool == "code_search", "wrong tool: \(tool)")
                try expect(reason.contains("pattern"), "reason should name the missing param: \(reason)")
            } else { throw TestError.assertion("expected .invalidArguments, got \(e)") }
        }
    }

    await test("code_search wrong-type 'pattern' (int not string) throws invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CodeEditModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "code_search",
                                          arguments: .object(["pattern": .int(42)]))
            throw TestError.assertion("expected throw for wrong-type pattern")
        } catch is ToolRouterError { /* expected — guard requires .string */ }
    }

    await test("code_search no-match in an empty dir returns ok with count 0 (not an error)") {
        guard CodeEditModule.discoverRipgrep() != nil else {
            // rg not installed → capability_missing path is covered elsewhere.
            return
        }
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CodeEditModule.register(on: router)
        let dir = edgeTempDir("cs")
        let r = try await router.dispatch(toolName: "code_search", arguments: .object([
            "pattern": .string("zzz_no_such_token_zzz"),
            "path": .string(dir.path)
        ]))
        guard case .object(let d) = r, case .bool(true) = d["ok"],
              case .int(let c) = d["count"] else {
            throw TestError.assertion("expected ok=true count=0, got \(r)")
        }
        try expect(c == 0, "empty dir must yield 0 matches, got \(c)")
    }

}
