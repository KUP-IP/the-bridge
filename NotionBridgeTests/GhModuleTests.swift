// GhModuleTests.swift — PKT-742 (Bridge v2.2 · 2.2)
// Hermetic coverage for GhRuntime + GhModule (dev/gh_*).
//
// Tests that depend on a live `gh` binary (capabilityCheck against the real
// PATH) are written defensively: they assert known-good shape when gh IS
// authenticated, and pass cleanly with the `capability_missing` envelope
// otherwise. No live network calls; no PR/issue mutations from unit tests.

import Foundation
import MCP
import NotionBridgeLib

func runGhModuleTests() async {
    print("\n\u{1F500} GhModule Tests (PKT-742 v2.2 · 2.2)")

    // ------------------------------------------------------------------
    // 2) Auth-status parser correctness on a representative gh blob.
    // ------------------------------------------------------------------
    await test("parseAccount extracts the active account name") {
        let blob = """
        github.com
          \u{2713} Logged in to github.com account KUP-IP (keyring)
          - Active account: true
          - Git operations protocol: https
          - Token: gho_************************************
          - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
        """
        let acct = GhRuntime.parseAccount(blob)
        try expect(acct == "KUP-IP", "expected 'KUP-IP', got \(acct ?? "nil")")
    }

    await test("parseScopes returns trimmed unquoted scope list") {
        let blob = "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'\n"
        let scopes = GhRuntime.parseScopes(blob)
        try expect(scopes == ["gist", "read:org", "repo", "workflow"],
            "expected ['gist','read:org','repo','workflow'], got \(scopes)")
    }

    await test("parseScopes returns empty array when no scopes line") {
        let scopes = GhRuntime.parseScopes("no token line here\n")
        try expect(scopes.isEmpty, "expected empty, got \(scopes)")
    }

    await test("parseAccount returns nil on malformed input") {
        try expect(GhRuntime.parseAccount("") == nil)
        try expect(GhRuntime.parseAccount("random text") == nil)
    }

    // ------------------------------------------------------------------
    // 3) GitHub URL extraction
    // ------------------------------------------------------------------
    await test("firstGitHubURL extracts PR URL from gh stdout") {
        let stdout = "\nhttps://github.com/owner/repo/pull/42\n"
        let u = GhRuntime.firstGitHubURL(in: stdout)
        try expect(u == "https://github.com/owner/repo/pull/42",
            "got \(u ?? "nil")")
    }

    await test("firstGitHubURL strips trailing punctuation") {
        let stdout = "PR opened at https://github.com/owner/repo/pull/7. Have fun!"
        let u = GhRuntime.firstGitHubURL(in: stdout)
        try expect(u == "https://github.com/owner/repo/pull/7",
            "got \(u ?? "nil")")
    }

    await test("firstGitHubURL returns nil when none present") {
        try expect(GhRuntime.firstGitHubURL(in: "no url here") == nil)
    }

    // ------------------------------------------------------------------
    // 4) JSON → MCP Value round-trip
    // ------------------------------------------------------------------
    await test("parseJSONString maps types correctly") {
        let raw = """
        {"number":42,"title":"Hi","isDraft":false,"labels":["bug","v2"],"author":{"login":"alice"},"closedAt":null}
        """
        guard let v = GhModule.parseJSONString(raw),
              case .object(let d) = v else {
            throw TestError.assertion("expected object Value")
        }
        if case .int(let n) = d["number"] {
            try expect(n == 42)
        } else { throw TestError.assertion("number not int") }
        if case .string(let s) = d["title"] {
            try expect(s == "Hi")
        } else { throw TestError.assertion("title not string") }
        if case .bool(let b) = d["isDraft"] {
            try expect(b == false)
        } else { throw TestError.assertion("isDraft not bool") }
        if case .array(let arr) = d["labels"] {
            try expect(arr.count == 2)
            if case .string(let s) = arr[0] { try expect(s == "bug") }
        } else { throw TestError.assertion("labels not array") }
        if case .object(let author) = d["author"],
           case .string(let login) = author["login"] {
            try expect(login == "alice")
        } else { throw TestError.assertion("author.login missing") }
        if case .null = d["closedAt"] ?? .null {
            // ok
        } else { throw TestError.assertion("closedAt should be null") }
    }

    await test("parseJSONString returns nil on garbage") {
        try expect(GhModule.parseJSONString("not json") == nil)
        try expect(GhModule.parseJSONString("") == nil)
    }

    // ------------------------------------------------------------------
    // 5) Capability check against the live PATH — conditional assertions.
    // ------------------------------------------------------------------
    await test("capabilityCheck against live PATH: shape is valid") {
        let runtime = GhRuntime()
        let cap = await runtime.capabilityCheck()
        // Either ok with non-empty path+account, or not ok with reason.
        if cap.ok {
            try expect(cap.path != nil && !(cap.path ?? "").isEmpty,
                "ok=true should have path")
            // version + account are best-effort; don't assert.
        } else {
            try expect((cap.reason ?? "").isEmpty == false,
                "ok=false should have reason")
        }
    }

    // ------------------------------------------------------------------
    // 6) Capability missing: forced bogus path returns short-circuit.
    // ------------------------------------------------------------------
    await test("GhRuntime(ghPath: bogus) yields capability_missing on tool dispatch") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        let runtime = GhRuntime(ghPath: "/nonexistent/gh-binary-xyz")
        await GhModule.register(on: router, runtime: runtime)
        let result = try await router.dispatch(
            toolName: "gh_pr_status",
            arguments: .object(["number": .int(1)])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object result")
        }
        if case .bool(let ok) = dict["ok"] {
            try expect(ok == false, "expected ok=false")
        } else {
            throw TestError.assertion("missing ok field")
        }
        if case .string(let status) = dict["status"] {
            try expect(status == "capability_missing",
                "expected status=capability_missing, got \(status)")
        } else {
            throw TestError.assertion("missing status field")
        }
    }

    // ------------------------------------------------------------------
    // 7) Schema sanity: required fields are encoded in the input schema.
    // ------------------------------------------------------------------
    await test("gh_pr_comment schema declares number+body required") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GhModule.register(on: router)
        let regs = await router.registrations(forModule: "dev")
        guard let prComment = regs.first(where: { $0.name == "gh_pr_comment" }) else {
            throw TestError.assertion("gh_pr_comment not registered")
        }
        guard case .object(let schema) = prComment.inputSchema,
              case .array(let req) = schema["required"] else {
            throw TestError.assertion("missing required[] in schema")
        }
        let names: [String] = req.compactMap { v in
            if case .string(let s) = v { return s }
            return nil
        }
        try expect(names.contains("number"), "required missing 'number'")
        try expect(names.contains("body"),   "required missing 'body'")
    }

    await test("gh_check_status schema accepts no required fields") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GhModule.register(on: router)
        let regs = await router.registrations(forModule: "dev")
        guard let chk = regs.first(where: { $0.name == "gh_check_status" }) else {
            throw TestError.assertion("gh_check_status not registered")
        }
        guard case .object(let schema) = chk.inputSchema,
              case .array(let req) = schema["required"] else {
            throw TestError.assertion("missing required[] in schema")
        }
        try expect(req.isEmpty, "expected empty required, got \(req.count) entries")
    }

    // ------------------------------------------------------------------
    // 8) Invalid args envelope shape (missing required field).
    // ------------------------------------------------------------------
    await test("gh_pr_comment with missing body returns invalid_argument when gh is available") {
        // Only meaningful when gh is on PATH; otherwise cap_missing comes first.
        let cap = await GhRuntime.shared.capabilityCheck()
        guard cap.ok else { return }  // Skip when gh not auth'd.
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GhModule.register(on: router)
        let result = try await router.dispatch(
            toolName: "gh_pr_comment",
            arguments: .object(["number": .int(1)])
        )
        guard case .object(let dict) = result,
              case .string(let status) = dict["status"] else {
            throw TestError.assertion("expected status field")
        }
        try expect(status == "invalid_argument",
            "expected invalid_argument, got \(status)")
    }

    // ------------------------------------------------------------------
    // 9) shellQuote round-trip safety.
    // ------------------------------------------------------------------
    await test("shellQuote escapes single quotes safely") {
        let q = GhModule.shellQuote("O'Hare's Bar")
        try expect(q == "'O'\\''Hare'\\''s Bar'",
            "got \(q)")
    }

    await test("shellQuote wraps simple strings") {
        try expect(GhModule.shellQuote("plain") == "'plain'")
        try expect(GhModule.shellQuote("") == "''")
    }
}
