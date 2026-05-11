// GitModuleTests.swift — PKT-740 W1 (Bridge v2.2 · 2.1)
// Hermetic coverage for GitRuntime + GitModule (dev/git_*).
//
// Live PATH tests are written defensively: they assert known-good shape
// when git IS available, and pass cleanly with the capability_missing
// envelope otherwise. No mutating git operations from unit tests.

import Foundation
import MCP
import NotionBridgeLib

func runGitModuleTests() async {
    print("\n\u{1F500} GitModule Tests (PKT-740 W1 v2.2 · 2.1)")

    // ------------------------------------------------------------------
    // 1) Tool registration: 3 tools, module = "dev", tier = .request
    // ------------------------------------------------------------------
    await test("GitModule registers 3 tools (W1 triumvirate) under module=\"dev\"") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GitModule.register(on: router)
        let regs = await router.registrations(forModule: "dev")
        let names = Set(regs.map { $0.name })
        let expected: Set<String> = ["git_status", "git_diff", "git_log"]
        try expect(expected.isSubset(of: names),
            "missing git_* tools — got \(names.sorted())")
    }

    await test("All git_* tools are tier .request") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GitModule.register(on: router)
        let regs = await router.registrations(forModule: "dev")
        let gitRegs = regs.filter { $0.name.hasPrefix("git_") }
        try expect(gitRegs.count >= 3, "expected >=3 git_* tools, got \(gitRegs.count)")
        for r in gitRegs {
            try expect(r.tier == .request,
                "\(r.name) tier expected .request, got \(r.tier.rawValue)")
        }
    }

    // ------------------------------------------------------------------
    // 2) Porcelain v2 parser
    // ------------------------------------------------------------------
    await test("parsePorcelainV2 extracts branch + ahead/behind") {
        let blob = """
        # branch.oid abc123def456
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -1
        1 .M N... 100644 100644 100644 abc def README.md
        ? newfile.txt
        """
        let s = GitRuntime.parsePorcelainV2(blob)
        try expect(s.branch == "main", "branch got \(s.branch ?? "nil")")
        try expect(s.upstream == "origin/main", "upstream got \(s.upstream ?? "nil")")
        try expect(s.oid == "abc123def456", "oid got \(s.oid ?? "nil")")
        try expect(s.ahead == 3, "ahead got \(s.ahead)")
        try expect(s.behind == 1, "behind got \(s.behind)")
        try expect(s.files.count == 2, "expected 2 files, got \(s.files.count)")
        try expect(s.clean == false)
    }

    await test("parsePorcelainV2 categorizes file kinds (tracked/untracked/ignored/unmerged)") {
        let blob = """
        # branch.oid abc
        # branch.head main
        # branch.ab +0 -0
        1 M. N... 100644 100644 100644 a b src/foo.swift
        2 R. N... 100644 100644 100644 a b R100 new/path.swift\told/path.swift
        ? untracked.txt
        ! ignored.log
        u UU N... 100644 100644 100644 100644 a b c conflict.md
        """
        let s = GitRuntime.parsePorcelainV2(blob)
        try expect(s.files.count == 5, "expected 5 files, got \(s.files.count)")
        let kinds = Set(s.files.map { $0.kind })
        try expect(kinds.contains("tracked"))
        try expect(kinds.contains("untracked"))
        try expect(kinds.contains("ignored"))
        try expect(kinds.contains("unmerged"))
        // Rename should populate origPath.
        if let renamed = s.files.first(where: { $0.path == "new/path.swift" }) {
            try expect(renamed.origPath == "old/path.swift",
                "rename origPath got \(renamed.origPath ?? "nil")")
        } else {
            throw TestError.assertion("rename entry missing")
        }
    }

    await test("parsePorcelainV2 reports clean on empty working tree") {
        let s = GitRuntime.parsePorcelainV2("# branch.head main\n# branch.ab +0 -0\n")
        try expect(s.clean == true, "expected clean=true")
        try expect(s.files.isEmpty)
    }

    await test("parsePorcelainV2 handles detached HEAD") {
        let s = GitRuntime.parsePorcelainV2("# branch.head (detached)\n# branch.ab +0 -0\n")
        try expect(s.branch == nil, "branch should be nil for detached, got \(s.branch ?? "nil")")
    }

    // ------------------------------------------------------------------
    // 3) Log parser (US/RS-delimited format)
    // ------------------------------------------------------------------
    await test("parseLog splits commits by RS and fields by US") {
        let us = "\u{1F}"
        let rs = "\u{1E}"
        let blob = "abc111\(us)Alice\(us)alice@example.com\(us)2026-05-11T12:00:00-05:00\(us)first commit\(rs)def222\(us)Bob\(us)bob@example.com\(us)2026-05-10T08:30:00-05:00\(us)second commit\(rs)"
        let commits = GitRuntime.parseLog(blob)
        try expect(commits.count == 2, "expected 2 commits, got \(commits.count)")
        try expect(commits[0].sha == "abc111", "sha[0] got \(commits[0].sha)")
        try expect(commits[0].author == "Alice")
        try expect(commits[0].authorEmail == "alice@example.com")
        try expect(commits[0].subject == "first commit")
        try expect(commits[1].sha == "def222")
        try expect(commits[1].subject == "second commit")
    }

    await test("parseLog returns empty array on empty input") {
        try expect(GitRuntime.parseLog("").isEmpty)
        try expect(GitRuntime.parseLog("\n\n").isEmpty)
    }

    // ------------------------------------------------------------------
    // 4) Diff --stat parser
    // ------------------------------------------------------------------
    await test("parseDiffStat extracts per-file +/- counts") {
        let blob = """
         README.md     | 12 +++++++-----
         src/Foo.swift | 30 ++++++++++++++++++++++++++++++
         3 files changed, 42 insertions(+), 5 deletions(-)
        """
        let files = GitModule.parseDiffStat(blob)
        try expect(files.count == 2, "expected 2 files, got \(files.count)")
        try expect(files[0].path == "README.md", "path[0] got \(files[0].path)")
        try expect(files[0].insertions == 7, "insertions[0] got \(files[0].insertions)")
        try expect(files[0].deletions == 5, "deletions[0] got \(files[0].deletions)")
        try expect(files[1].path == "src/Foo.swift")
        try expect(files[1].insertions == 30)
        try expect(files[1].deletions == 0)
    }

    await test("parseDiffStat handles Bin files") {
        let blob = " image.png | Bin 100 -> 200 bytes\n"
        let files = GitModule.parseDiffStat(blob)
        try expect(files.count == 1, "expected 1 file, got \(files.count)")
        try expect(files[0].path == "image.png")
        try expect(files[0].insertions == 0)
        try expect(files[0].deletions == 0)
    }

    // ------------------------------------------------------------------
    // 5) Capability check against live PATH (defensive)
    // ------------------------------------------------------------------
    await test("capabilityCheck against live PATH: shape is valid") {
        let runtime = GitRuntime()
        let cap = await runtime.capabilityCheck()
        if cap.ok {
            try expect(cap.path != nil && !(cap.path ?? "").isEmpty,
                "ok=true should have path")
        } else {
            try expect((cap.reason ?? "").isEmpty == false,
                "ok=false should have reason")
        }
    }

    // ------------------------------------------------------------------
    // 6) Capability missing → short-circuit envelope
    // ------------------------------------------------------------------
    await test("GitRuntime(gitPath: bogus) yields capability_missing on tool dispatch") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        let runtime = GitRuntime(gitPath: "/nonexistent/git-binary-xyz")
        await GitModule.register(on: router, runtime: runtime)
        let result = try await router.dispatch(
            toolName: "git_status",
            arguments: .object([:])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object result")
        }
        if case .bool(let ok) = dict["ok"] {
            try expect(ok == false, "expected ok=false")
        } else { throw TestError.assertion("missing ok field") }
        if case .string(let status) = dict["status"] {
            try expect(status == "capability_missing",
                "expected status=capability_missing, got \(status)")
        } else { throw TestError.assertion("missing status field") }
    }

    // ------------------------------------------------------------------
    // 7) Schema sanity: required fields are encoded in the input schema
    // ------------------------------------------------------------------
    await test("git_status schema declares no required fields") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GitModule.register(on: router)
        let regs = await router.registrations(forModule: "dev")
        guard let st = regs.first(where: { $0.name == "git_status" }) else {
            throw TestError.assertion("git_status not registered")
        }
        guard case .object(let schema) = st.inputSchema,
              case .array(let req) = schema["required"] else {
            throw TestError.assertion("missing required[] in schema")
        }
        try expect(req.isEmpty, "expected empty required, got \(req.count)")
    }

    // ------------------------------------------------------------------
    // 8) Live integration: git_status against a non-repo cwd should fail cleanly
    //    (skipped when git missing — capability_missing path covers that)
    // ------------------------------------------------------------------
    await test("git_status against non-repo cwd returns failed envelope when git is on PATH") {
        let runtime = GitRuntime()
        let cap = await runtime.capabilityCheck()
        guard cap.ok else { return }
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GitModule.register(on: router, runtime: runtime)
        let tmp = NSTemporaryDirectory() + "nb-git-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let result = try await router.dispatch(
            toolName: "git_status",
            arguments: .object(["cwd": .string(tmp)])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object result")
        }
        // Non-repo dir → git exits non-zero → ok=false, status="failed".
        if case .string(let status) = dict["status"] {
            try expect(status == "failed",
                "expected failed for non-repo cwd, got \(status)")
        }
        if case .string(let tool) = dict["tool"] {
            try expect(tool == "git_status")
        } else { throw TestError.assertion("missing tool field") }
    }
}
