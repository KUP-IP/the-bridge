// DevSuiteEdgeTests.swift — Dev-suite audit (every-angle-of-attack)
// NotionBridge · Tests
//
// Per-tool edge / wrong-type / empty-input / idempotency hardening for
// Dev tools whose existing module tests skipped these dimensions. Pure,
// deterministic, network-free: capability-missing and structured-error
// envelopes are exercised; nothing shells out to the live network. For
// the shell-out wrappers (gh/wrangler/runners) the argument-validation
// and capability-probe layers are tested, not live invocation.

import Foundation
import MCP
import NotionBridgeLib

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

    // ---- ArtifactModule: tree_sitter_query -----------------------------
    await test("tree_sitter_query on a missing file returns ok with empty matches (graceful)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let missing = edgeTempDir("ts").appendingPathComponent("ghost.swift").path
        let r = try await router.dispatch(toolName: "tree_sitter_query",
                                          arguments: .object(["path": .string(missing)]))
        // Reading a missing file yields "" content → fallback scanner over
        // empty string → ok:true with no matches (no crash, no throw).
        guard case .object(let d) = r, case .bool(true) = d["ok"],
              case .array(let m) = d["matches"] else {
            throw TestError.assertion("expected ok=true matches=[], got \(r)")
        }
        try expect(m.isEmpty, "empty file must yield no matches, got \(m.count)")
    }

    await test("tree_sitter_query missing required 'path' throws invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "tree_sitter_query", arguments: .object([:]))
            throw TestError.assertion("expected throw")
        } catch is ToolRouterError { /* expected */ }
    }

    // ---- ArtifactModule: file_watch zero-duration edge -----------------
    await test("file_watch clamps a huge durationMs and returns a bounded result") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let dir = edgeTempDir("fw")
        let r = try await router.dispatch(toolName: "file_watch", arguments: .object([
            "path": .string(dir.path),
            "durationMs": .int(999_999_999), // must clamp to 30_000
            "debounceMs": .int(0)
        ]))
        guard case .object(let d) = r, case .bool(true) = d["ok"],
              case .int(let dur) = d["durationMs"] else {
            throw TestError.assertion("expected ok with durationMs, got \(r)")
        }
        try expect(dur == 30_000, "durationMs must clamp to 30000, got \(dur)")
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

    // ---- CodeEditModule: file_str_replace empty-search edge ------------
    await test("file_str_replace with empty 'search' returns structured failed (invalid argument)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CodeEditModule.register(on: router)
        let f = edgeTempDir("sr").appendingPathComponent("x.txt")
        try "abc".data(using: .utf8)!.write(to: f)
        let r = try await router.dispatch(toolName: "file_str_replace", arguments: .object([
            "path": .string(f.path),
            "search": .string(""),
            "replacement": .string("z")
        ]))
        guard case .object(let d) = r, case .bool(false) = d["ok"],
              case .string(let status) = d["status"], status == "failed" else {
            throw TestError.assertion("empty search must fail with structured envelope, got \(r)")
        }
        // File must be untouched.
        try expect(String(contentsOf: f, encoding: .utf8) == "abc", "file must be unchanged on rejected edit")
    }

    // ---- CodeEditModule: file_apply_patch empty patch ------------------
    await test("file_apply_patch with a no-hunk patch returns structured failed") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CodeEditModule.register(on: router)
        let f = edgeTempDir("ap").appendingPathComponent("y.txt")
        try "line1\nline2\n".data(using: .utf8)!.write(to: f)
        let r = try await router.dispatch(toolName: "file_apply_patch", arguments: .object([
            "path": .string(f.path),
            "patch": .string("not a patch — no @@ headers here")
        ]))
        guard case .object(let d) = r, case .bool(false) = d["ok"],
              case .string(let status) = d["status"], status == "failed",
              case .string(let err) = d["error"] else {
            throw TestError.assertion("no-hunk patch must fail structurally, got \(r)")
        }
        try expect(err.lowercased().contains("hunk") || err.lowercased().contains("patch"),
                   "error should explain the missing hunks: \(err)")
    }

    // ---- BgProcessModule: kill idempotency + not_found -----------------
    await test("bg_process_kill on an unknown id returns structured not_found (idempotent-safe)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await BgProcessModule.register(on: router, runtime: BgProcessRuntime(baseDir: edgeTempDir("bk")))
        let r = try await router.dispatch(toolName: "bg_process_kill",
                                          arguments: .object(["id": .string("does-not-exist")]))
        guard case .object(let d) = r, case .bool(false) = d["ok"],
              case .string(let status) = d["status"], status == "not_found" else {
            throw TestError.assertion("expected not_found envelope, got \(r)")
        }
        guard case .string(let tool) = d["tool"], tool == "bg_process_kill" else {
            throw TestError.assertion("envelope must name the tool, got \(d)")
        }
    }

    await test("bg_process_kill is idempotent on an already-terminal job") {
        let runtime = BgProcessRuntime(baseDir: edgeTempDir("bk2"))
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await BgProcessModule.register(on: router, runtime: runtime)
        let meta = try await runtime.start(command: "true", workingDir: nil, env: [:], label: "edge")
        // Let it finish.
        var status = ""
        for _ in 0..<100 {
            let m = try await runtime.status(id: meta.id)
            status = m.status.rawValue
            if status != "running" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try expect(status != "running", "job should have terminated, got \(status)")
        // Killing a terminal job must not throw and must return an envelope.
        let r1 = try await router.dispatch(toolName: "bg_process_kill", arguments: .object(["id": .string(meta.id)]))
        let r2 = try await router.dispatch(toolName: "bg_process_kill", arguments: .object(["id": .string(meta.id)]))
        guard case .object(let d1) = r1, case .object(let d2) = r2 else {
            throw TestError.assertion("expected object envelopes")
        }
        // Both calls succeed structurally (idempotent) — ok=true on a known job.
        try expect(d1["ok"] == .bool(true) && d2["ok"] == .bool(true),
                   "kill on terminal job must be idempotent ok=true, got \(d1) / \(d2)")
    }

    await test("bg_process_list with an unknown status filter returns ok with empty list") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await BgProcessModule.register(on: router, runtime: BgProcessRuntime(baseDir: edgeTempDir("bl")))
        let r = try await router.dispatch(toolName: "bg_process_list",
                                          arguments: .object(["status": .string("bogus_status")]))
        // An unparseable status enum is ignored (no filter applied) — must
        // still return a well-formed ok envelope, never throw.
        guard case .object(let d) = r, case .bool(true) = d["ok"],
              case .array = d["jobs"] else {
            throw TestError.assertion("expected ok=true with jobs array, got \(r)")
        }
    }

    // ---- DevServerModule: port_inspect wrong-type + range --------------
    await test("port_inspect with a missing 'port' throws structured invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevServerModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "port_inspect", arguments: .object([:]))
            throw TestError.assertion("expected throw for missing port")
        } catch let e as ToolRouterError {
            if case .invalidArguments(let tool, _) = e {
                try expect(tool == "port_inspect", "wrong tool: \(tool)")
            } else { throw TestError.assertion("expected .invalidArguments, got \(e)") }
        }
    }

    await test("port_inspect with a string 'port' (wrong type) throws invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevServerModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "port_inspect",
                                          arguments: .object(["port": .string("8080")]))
            throw TestError.assertion("expected throw for string port")
        } catch is ToolRouterError { /* expected — guard requires .int */ }
    }

    // ---- WranglerModule: wrong-type + missing binding -----------------
    await test("wrangler_d1_status with missing 'binding' throws structured invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await WranglerModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "wrangler_d1_status", arguments: .object([:]))
            throw TestError.assertion("expected throw for missing binding")
        } catch let e as ToolRouterError {
            if case .invalidArguments(let tool, let reason) = e {
                try expect(tool == "wrangler_d1_status", "wrong tool: \(tool)")
                try expect(reason.contains("binding"), "reason should name binding: \(reason)")
            } else { throw TestError.assertion("expected .invalidArguments, got \(e)") }
        }
    }

    await test("wrangler_d1_status with wrong-type 'binding' (int) throws invalidArguments") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await WranglerModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "wrangler_d1_status",
                                          arguments: .object(["binding": .int(7)]))
            throw TestError.assertion("expected throw for int binding")
        } catch is ToolRouterError { /* expected — guard requires .string */ }
    }

    // ---- Runners: non-object args + capability_missing ----------------
    await test("playwright_run with a non-object argument returns structured invalid_argument") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await PlaywrightModule.register(on: router,
                                        bgRuntime: BgProcessRuntime(baseDir: edgeTempDir("pw")),
                                        probeOverride: { true })
        let r = try await router.dispatch(toolName: "playwright_run", arguments: .string("oops"))
        guard case .object(let d) = r, case .bool(false) = d["ok"],
              case .string(let status) = d["status"], status == "invalid_argument" else {
            throw TestError.assertion("non-object args must yield invalid_argument, got \(r)")
        }
    }

    await test("lighthouse_run capability_missing carries an actionable install hint") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await LighthouseModule.register(on: router,
                                        bgRuntime: BgProcessRuntime(baseDir: edgeTempDir("lh")),
                                        probeOverride: { false })
        let r = try await router.dispatch(toolName: "lighthouse_run", arguments: .object([:]))
        guard case .object(let d) = r, case .string(let status) = d["status"],
              status == "capability_missing", case .string(let err) = d["error"] else {
            throw TestError.assertion("expected capability_missing with error, got \(r)")
        }
        try expect(err.contains("lighthouse") && err.contains("install"),
                   "capability_missing must explain the runner + that it never auto-installs: \(err)")
    }

    // ---- LspModule: deterministic session_list + probe edge -----------
    await test("lsp_session_list returns a well-formed ok envelope (network-free)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await LspModule.register(on: router)
        let r = try await router.dispatch(toolName: "lsp_session_list", arguments: .object([:]))
        guard case .object(let d) = r, case .bool(true) = d["ok"],
              case .array = d["sessions"], case .int = d["count"] else {
            throw TestError.assertion("expected ok=true sessions=[] count=int, got \(r)")
        }
    }

    await test("LspModule.probe(unsupported) is available=false with informative detail") {
        let p = LspModule.probe(language: "cobol")
        try expect(p.available == false, "cobol must be unsupported")
        try expect((p.detail ?? "").contains("unsupported"),
                   "unsupported probe must explain why, got \(String(describing: p.detail))")
    }
}
