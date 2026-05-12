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

    // ==================================================================
    // PKT-784 W2 (Bridge v2.2 · 2.1.1) — git_show / git_blame / git_apply_patch
    // ==================================================================

    print("\n  \u{1F4C1} W2 — git_show / git_blame / git_apply_patch")

    await test("W2 adds git_show / git_blame / git_apply_patch to module=\"dev\"") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GitModule.register(on: router)
        let regs = await router.registrations(forModule: "dev")
        let names = Set(regs.map { $0.name })
        let expected: Set<String> = ["git_show", "git_blame", "git_apply_patch"]
        try expect(expected.isSubset(of: names),
            "missing W2 tools — got \(names.sorted())")
        for r in regs where expected.contains(r.name) {
            try expect(r.tier == .request,
                "\(r.name) tier expected .request, got \(r.tier.rawValue)")
        }
    }

    await test("parseShowOutput merges --raw status with --numstat counts") {
        let us = "\u{1F}"
        let nul = "\u{0}"
        let blob = "abc123" + us + "Alice" + us + "alice@ex.com" + us +
            "2026-05-12T09:00:00-05:00" + us + "feat: thing" + us + "body line" + nul + "\n" +
            ":100644 100644 aaa bbb M\tREADME.md\n" +
            ":100644 100644 ccc ddd A\tdocs/new.md\n" +
            "5\t2\tREADME.md\n" +
            "10\t0\tdocs/new.md\n"
        guard let r = GitRuntime.parseShowOutput(blob) else {
            throw TestError.assertion("parseShowOutput returned nil")
        }
        try expect(r.sha == "abc123", "sha got \(r.sha)")
        try expect(r.author == "Alice")
        try expect(r.authorEmail == "alice@ex.com")
        try expect(r.subject == "feat: thing")
        try expect(r.body == "body line", "body got '\(r.body)'")
        try expect(r.files.count == 2, "expected 2 files, got \(r.files.count)")
        if let readme = r.files.first(where: { $0.path == "README.md" }) {
            try expect(readme.status == "M", "status got \(readme.status)")
            try expect(readme.insertions == 5, "ins got \(readme.insertions)")
            try expect(readme.deletions == 2, "del got \(readme.deletions)")
            try expect(readme.isBinary == false)
        } else { throw TestError.assertion("README.md missing") }
    }

    await test("parseShowOutput handles --raw rename (origPath populated)") {
        let us = "\u{1F}"
        let nul = "\u{0}"
        let blob = "sha" + us + "A" + us + "a@x" + us + "2026" + us + "s" + us + "b" + nul + "\n" +
            ":100644 100644 aaa bbb R092\told/p.swift\tnew/p.swift\n" +
            "3\t1\tnew/p.swift\n"
        guard let r = GitRuntime.parseShowOutput(blob) else {
            throw TestError.assertion("parse returned nil")
        }
        try expect(r.files.count == 1, "expected 1 file, got \(r.files.count)")
        let f = r.files[0]
        try expect(f.path == "new/p.swift", "path got \(f.path)")
        try expect(f.origPath == "old/p.swift", "origPath got \(f.origPath ?? "nil")")
        try expect(f.status == "R", "status got \(f.status)")
    }

    await test("parseShowOutput marks binary files via numstat '-' counts") {
        let us = "\u{1F}"
        let nul = "\u{0}"
        let blob = "sha" + us + "A" + us + "a@x" + us + "2026" + us + "s" + us + "b" + nul + "\n" +
            ":100644 100644 aaa bbb M\tlogo.png\n" +
            "-\t-\tlogo.png\n"
        guard let r = GitRuntime.parseShowOutput(blob) else {
            throw TestError.assertion("parse returned nil")
        }
        try expect(r.files.count == 1)
        try expect(r.files[0].isBinary == true, "expected isBinary=true")
        try expect(r.files[0].insertions == 0)
        try expect(r.files[0].deletions == 0)
    }

    await test("parseShowOutput returns nil when NUL header terminator is missing") {
        let blob = "sha abc def — but no NUL byte"
        try expect(GitRuntime.parseShowOutput(blob) == nil)
    }

    await test("parseBlamePorcelain emits one entry per content line + propagates author metadata") {
        let aSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let bSha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let blob =
            "\(aSha) 10 10 2\n" +
            "author Alice Author\n" +
            "author-mail <alice@ex.com>\n" +
            "author-time 1700000000\n" +
            "author-tz -0500\n" +
            "committer Alice\n" +
            "summary first\n" +
            "filename src/foo.swift\n" +
            "\tlet x = 1\n" +
            "\(aSha) 11 11\n" +
            "\tlet y = 2\n" +
            "\(bSha) 12 12 1\n" +
            "author Bob Builder\n" +
            "author-time 1700000100\n" +
            "author-tz -0500\n" +
            "summary second\n" +
            "filename src/foo.swift\n" +
            "\tlet z = 3\n"
        let entries = GitRuntime.parseBlamePorcelain(blob)
        try expect(entries.count == 3, "expected 3 lines, got \(entries.count)")
        try expect(entries[0].lineNo == 10, "lineNo[0] got \(entries[0].lineNo)")
        try expect(entries[0].author == "Alice Author", "author[0] got \(entries[0].author)")
        try expect(entries[0].authorTime == 1700000000)
        try expect(entries[0].content == "let x = 1")
        try expect(entries[1].lineNo == 11, "lineNo[1] got \(entries[1].lineNo)")
        try expect(entries[1].sha == entries[0].sha, "sha should match Alice's group")
        try expect(entries[1].author == "Alice Author", "author should propagate across group")
        try expect(entries[2].lineNo == 12)
        try expect(entries[2].author == "Bob Builder")
        try expect(entries[2].sha == bSha)
    }

    await test("parseBlamePorcelain returns empty array on empty input") {
        try expect(GitRuntime.parseBlamePorcelain("").isEmpty)
    }

    await test("parseDiffTargets extracts paths from +++ b/ headers") {
        let diff =
            "diff --git a/README.md b/README.md\n" +
            "index abc..def 100644\n" +
            "--- a/README.md\n" +
            "+++ b/README.md\n" +
            "@@ -1 +1 @@\n" +
            "-old\n" +
            "+new\n" +
            "diff --git a/src/new.swift b/src/new.swift\n" +
            "new file mode 100644\n" +
            "index 000..fff\n" +
            "--- /dev/null\n" +
            "+++ b/src/new.swift\n" +
            "@@ -0,0 +1 @@\n" +
            "+hello\n"
        let paths = GitRuntime.parseDiffTargets(diff)
        try expect(paths.count == 2, "expected 2 paths, got \(paths.count): \(paths)")
        try expect(paths.contains("README.md"))
        try expect(paths.contains("src/new.swift"))
    }

    await test("git_apply_patch yields capability_missing on bogus git binary") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        let runtime = GitRuntime(gitPath: "/nonexistent/git-binary-xyz-w2")
        await GitModule.register(on: router, runtime: runtime)
        let result = try await router.dispatch(
            toolName: "git_apply_patch",
            arguments: .object(["diff": .string("dummy")])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object result")
        }
        if case .string(let status) = dict["status"] {
            try expect(status == "capability_missing",
                "expected capability_missing, got \(status)")
        } else { throw TestError.assertion("missing status field") }
    }

    await test("git_blame schema requires 'file', git_apply_patch requires 'diff'") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GitModule.register(on: router)
        let regs = await router.registrations(forModule: "dev")

        guard let blame = regs.first(where: { $0.name == "git_blame" }),
              case .object(let bs) = blame.inputSchema,
              case .array(let breq) = bs["required"] else {
            throw TestError.assertion("git_blame schema missing")
        }
        let breqNames: [String] = breq.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }
        try expect(breqNames.contains("file"), "git_blame required missing 'file'")

        guard let ap = regs.first(where: { $0.name == "git_apply_patch" }),
              case .object(let aps) = ap.inputSchema,
              case .array(let areq) = aps["required"] else {
            throw TestError.assertion("git_apply_patch schema missing")
        }
        let areqNames: [String] = areq.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }
        try expect(areqNames.contains("diff"), "git_apply_patch required missing 'diff'")
    }

    // Live round-trip DoD: git_diff output → git_apply_patch → identical worktree.
    // Skipped cleanly when git missing (capability_missing path covers that).
    await test("W2 DoD: git_apply_patch round-trips git_diff output (mutate→reset→apply→identical)") {
        let runtime = GitRuntime()
        let cap = await runtime.capabilityCheck()
        guard cap.ok else { return }

        let tmp = NSTemporaryDirectory() + "nb-git-rt-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        _ = try? await runtime.runGit(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try? await runtime.runGit(["config", "user.email", "test@bridge.local"], cwd: tmp)
        _ = try? await runtime.runGit(["config", "user.name", "Bridge Test"], cwd: tmp)
        FileManager.default.createFile(atPath: tmp + "/a.txt", contents: "v1\n".data(using: .utf8))
        _ = try? await runtime.runGit(["add", "a.txt"], cwd: tmp)
        _ = try? await runtime.runGit(["commit", "-q", "-m", "v1"], cwd: tmp)
        FileManager.default.createFile(atPath: tmp + "/a.txt", contents: "v1\nv2\n".data(using: .utf8))
        guard let diffRun = try? await runtime.runGit(["diff", "HEAD"], cwd: tmp),
              diffRun.exitCode == 0 || diffRun.exitCode == 1,
              !diffRun.stdout.isEmpty else {
            throw TestError.assertion("expected non-empty diff vs HEAD")
        }
        _ = try? await runtime.runGit(["checkout", "--", "a.txt"], cwd: tmp)

        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GitModule.register(on: router, runtime: runtime)
        let result = try await router.dispatch(
            toolName: "git_apply_patch",
            arguments: .object([
                "cwd":  .string(tmp),
                "diff": .string(diffRun.stdout)
            ])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object result")
        }
        if case .bool(let ok) = dict["ok"] {
            try expect(ok == true, "round-trip apply failed: \(dict)")
        } else { throw TestError.assertion("missing ok field") }
        let restored = try? String(contentsOfFile: tmp + "/a.txt", encoding: .utf8)
        try expect(restored == "v1\nv2\n", "post-apply content: \(restored ?? "nil")")
    }

    await test("git_show HEAD against process cwd returns parsed envelope when git is on PATH") {
        let runtime = GitRuntime()
        let cap = await runtime.capabilityCheck()
        guard cap.ok else { return }
        let cwd = FileManager.default.currentDirectoryPath
        let isGitDir = FileManager.default.fileExists(atPath: cwd + "/.git")
        guard isGitDir else { return }
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await GitModule.register(on: router, runtime: runtime)
        let result = try await router.dispatch(
            toolName: "git_show",
            arguments: .object(["cwd": .string(cwd), "ref": .string("HEAD")])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object result")
        }
        if case .bool(let ok) = dict["ok"], ok == true {
            if case .string(let sha) = dict["sha"] {
                try expect(sha.count >= 7, "sha looks too short: \(sha)")
            } else { throw TestError.assertion("missing sha on ok result") }
        }
    }

    // ============================================================
    // MARK: - W3 — git_worktree / git_create_branch / git_merge
    // ============================================================
    print("")
    print("  📁 W3 — git_worktree / git_create_branch / git_merge")

    await test("W3 adds git_worktree / git_create_branch / git_merge to module=\"dev\"") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await GitModule.register(on: router)
        let regs = await router.registrations(forModule: "dev")
        let names = Set(regs.map { $0.name })
        try expect(names.contains("git_worktree"),       "git_worktree not registered")
        try expect(names.contains("git_create_branch"),  "git_create_branch not registered")
        try expect(names.contains("git_merge"),          "git_merge not registered")
    }

    await test("parseWorktreeList handles main + linked + detached + bare entries") {
        let porcelain = """
        worktree /Users/me/repo
        HEAD aaaaaaa1111111111111111111111111111111aa
        branch refs/heads/main

        worktree /Users/me/repo-wt1
        HEAD bbbbbbb2222222222222222222222222222222bb
        branch refs/heads/feature-x

        worktree /Users/me/repo-detached
        HEAD ccccccc3333333333333333333333333333333cc
        detached

        worktree /Users/me/repo-bare
        bare
        """
        let entries = GitRuntime.parseWorktreeList(porcelain)
        try expect(entries.count == 4, "expected 4 entries, got \(entries.count)")
        try expect(entries[0].path == "/Users/me/repo", "entry 0 path mismatch")
        try expect(entries[0].branch == "refs/heads/main", "entry 0 branch mismatch")
        try expect(entries[0].detached == false && entries[0].bare == false, "entry 0 flags wrong")
        try expect(entries[1].branch == "refs/heads/feature-x", "entry 1 branch mismatch")
        try expect(entries[2].detached == true && entries[2].branch == nil, "entry 2 should be detached, no branch")
        try expect(entries[3].bare == true && entries[3].head == nil, "entry 3 should be bare, no head")
    }

    await test("parseWorktreeList captures locked + prunable flags with optional reasons") {
        let porcelain = """
        worktree /Users/me/repo-locked
        HEAD dddddddd44444444444444444444444444444444
        branch refs/heads/feature-y
        locked needed for release

        worktree /Users/me/repo-prunable
        HEAD eeeeeeee55555555555555555555555555555555
        detached
        prunable gitdir file points to non-existent location
        """
        let entries = GitRuntime.parseWorktreeList(porcelain)
        try expect(entries.count == 2, "expected 2, got \(entries.count)")
        try expect(entries[0].locked == true, "first entry not locked")
        try expect(entries[0].lockReason == "needed for release", "lock reason mismatch: \(entries[0].lockReason ?? "nil")")
        try expect(entries[1].prunable == true, "second entry not prunable")
        try expect(entries[1].prunableReason?.hasPrefix("gitdir file points to") == true,
                   "prunable reason mismatch: \(entries[1].prunableReason ?? "nil")")
    }

    await test("parseConflictMarkers extracts a basic 2-way conflict into ours/theirs/lines") {
        let content = """
        line 1
        line 2
        <<<<<<< HEAD
        ours line A
        ours line B
        =======
        theirs line A
        >>>>>>> feature-x
        trailing line
        """
        let hunks = GitRuntime.parseConflictMarkers(in: content)
        try expect(hunks.count == 1, "expected 1 hunk, got \(hunks.count)")
        try expect(hunks[0].startLine == 3, "startLine should be 3, got \(hunks[0].startLine)")
        try expect(hunks[0].endLine == 8,   "endLine should be 8, got \(hunks[0].endLine)")
        try expect(hunks[0].ours == ["ours line A", "ours line B"], "ours mismatch: \(hunks[0].ours)")
        try expect(hunks[0].theirs == ["theirs line A"], "theirs mismatch: \(hunks[0].theirs)")
    }

    await test("parseConflictMarkers ignores diff3 base markers + returns empty on no conflict") {
        let diff3 = """
        <<<<<<< HEAD
        ours
        ||||||| base
        base
        =======
        theirs
        >>>>>>> branch
        """
        let hunks = GitRuntime.parseConflictMarkers(in: diff3)
        try expect(hunks.count == 1, "diff3 should still produce one hunk")
        try expect(hunks[0].ours == ["ours"], "diff3 ours should not include base marker")
        try expect(hunks[0].theirs == ["theirs"], "diff3 theirs mismatch")
        // No-conflict input
        let clean = GitRuntime.parseConflictMarkers(in: "just\nnormal\nfile\n")
        try expect(clean.isEmpty, "clean file should produce no hunks")
    }

    await test("git_create_branch schema requires 'branch'; git_worktree requires 'action'; git_merge needs ref or abort") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await GitModule.register(on: router)
        // git_create_branch missing 'branch'
        let cb = try await router.dispatch(toolName: "git_create_branch", arguments: .object([:]))
        if case .object(let d) = cb, case .bool(let ok) = d["ok"] {
            try expect(ok == false, "git_create_branch with no 'branch' must fail")
        } else { throw TestError.assertion("git_create_branch envelope shape unexpected") }
        // git_worktree missing 'action'
        let wt = try await router.dispatch(toolName: "git_worktree", arguments: .object([:]))
        if case .object(let d) = wt, case .bool(let ok) = d["ok"] {
            try expect(ok == false, "git_worktree with no 'action' must fail")
        } else { throw TestError.assertion("git_worktree envelope shape unexpected") }
        // git_merge missing both ref and abort
        let mg = try await router.dispatch(toolName: "git_merge", arguments: .object([:]))
        if case .object(let d) = mg, case .bool(let ok) = d["ok"] {
            try expect(ok == false, "git_merge with no ref/abort must fail")
        } else { throw TestError.assertion("git_merge envelope shape unexpected") }
    }

    await test("git_worktree list returns parsed envelope when git is on PATH (live)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await GitModule.register(on: router)
        let res = try await router.dispatch(toolName: "git_worktree", arguments: .object([
            "action": .string("list")
        ]))
        guard case .object(let d) = res else {
            throw TestError.assertion("git_worktree list did not return an object")
        }
        // capability_missing is acceptable in CI; in dev we should get ok:true
        if case .string(let st) = d["status"], st == "capability_missing" {
            return  // accept on hosts without git
        }
        guard case .bool(let ok) = d["ok"], ok else {
            throw TestError.assertion("git_worktree list expected ok:true, got \(d)")
        }
        try expect(d["action"] != nil, "missing action field")
        try expect(d["worktrees"] != nil, "missing worktrees array")
        if case .array(let arr) = d["worktrees"] {
            try expect(arr.count >= 1, "expected at least one worktree (process cwd)")
        } else { throw TestError.assertion("worktrees should be an array") }
    }

    await test("git_create_branch DoD: creates new branch + switches, then cleans up (live)") {
        // Hermetic temp git repo.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nb-w3-cb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = GitRuntime.shared
        let init1 = try await runtime.runGit(["init", "-q", "-b", "main"], cwd: tmp.path)
        guard init1.exitCode == 0 else { return }  // git missing/old — skip silently
        _ = try await runtime.runGit(["config", "user.email", "t@example.com"], cwd: tmp.path)
        _ = try await runtime.runGit(["config", "user.name", "Test"], cwd: tmp.path)
        let f = tmp.appendingPathComponent("a.txt")
        try "hello\n".write(to: f, atomically: true, encoding: .utf8)
        _ = try await runtime.runGit(["add", "a.txt"], cwd: tmp.path)
        _ = try await runtime.runGit(["commit", "-q", "-m", "init"], cwd: tmp.path)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await GitModule.register(on: router)
        let res = try await router.dispatch(toolName: "git_create_branch", arguments: .object([
            "branch": .string("w3-feature"),
            "switch": .bool(true),
            "cwd":    .string(tmp.path)
        ]))
        guard case .object(let d) = res, case .bool(let ok) = d["ok"], ok else {
            throw TestError.assertion("git_create_branch DoD failed: \(res)")
        }
        if case .string(let b) = d["branch"] { try expect(b == "w3-feature", "branch name mismatch: \(b)") }
        if case .bool(let sw) = d["switched"] { try expect(sw == true, "switch should be true") }
        // Confirm git agrees the branch is checked out.
        let head = try await runtime.runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: tmp.path)
        let curBranch = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(curBranch == "w3-feature", "HEAD should be on w3-feature, got '\(curBranch)'")
    }

    await test("W3 DoD: git_merge surfaces 2-way conflict as {file, hunks:[…]} (live)") {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nb-w3-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = GitRuntime.shared
        let init1 = try await runtime.runGit(["init", "-q", "-b", "main"], cwd: tmp.path)
        guard init1.exitCode == 0 else { return }  // skip if git unavailable
        _ = try await runtime.runGit(["config", "user.email", "t@example.com"], cwd: tmp.path)
        _ = try await runtime.runGit(["config", "user.name", "Test"], cwd: tmp.path)
        _ = try await runtime.runGit(["config", "merge.conflictstyle", "merge"], cwd: tmp.path)
        // Base commit.
        let f = tmp.appendingPathComponent("conflict.txt")
        try "base line 1\nbase line 2\nbase line 3\n".write(to: f, atomically: true, encoding: .utf8)
        _ = try await runtime.runGit(["add", "conflict.txt"], cwd: tmp.path)
        _ = try await runtime.runGit(["commit", "-q", "-m", "base"], cwd: tmp.path)
        // Feature branch with mutation on line 2.
        _ = try await runtime.runGit(["checkout", "-q", "-b", "feature"], cwd: tmp.path)
        try "base line 1\nFEATURE LINE 2\nbase line 3\n".write(to: f, atomically: true, encoding: .utf8)
        _ = try await runtime.runGit(["commit", "-q", "-am", "feature change"], cwd: tmp.path)
        // Back to main with a competing mutation on line 2.
        _ = try await runtime.runGit(["checkout", "-q", "main"], cwd: tmp.path)
        try "base line 1\nMAIN LINE 2\nbase line 3\n".write(to: f, atomically: true, encoding: .utf8)
        _ = try await runtime.runGit(["commit", "-q", "-am", "main change"], cwd: tmp.path)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await GitModule.register(on: router)
        let res = try await router.dispatch(toolName: "git_merge", arguments: .object([
            "ref":  .string("feature"),
            "mode": .string("no-ff"),
            "cwd":  .string(tmp.path)
        ]))
        guard case .object(let d) = res else {
            throw TestError.assertion("git_merge did not return an object")
        }
        // Expect ok:false + conflicted:[…]
        if case .bool(let ok) = d["ok"] { try expect(ok == false, "merge should conflict (ok=false)") }
        guard case .array(let conflicted) = d["conflicted"] else {
            throw TestError.assertion("missing conflicted[] in envelope: \(d)")
        }
        try expect(!conflicted.isEmpty, "conflicted array should be non-empty")
        guard case .object(let c0) = conflicted[0] else {
            throw TestError.assertion("conflicted[0] not an object")
        }
        if case .string(let file) = c0["file"] {
            try expect(file == "conflict.txt", "conflict file mismatch: \(file)")
        } else { throw TestError.assertion("missing file in conflicted entry") }
        guard case .array(let hunks) = c0["hunks"], !hunks.isEmpty else {
            throw TestError.assertion("hunks array missing or empty")
        }
        guard case .object(let h0) = hunks[0] else {
            throw TestError.assertion("hunks[0] not an object")
        }
        try expect(h0["startLine"] != nil, "hunk missing startLine")
        try expect(h0["endLine"]   != nil, "hunk missing endLine")
        try expect(h0["ours"]      != nil, "hunk missing ours")
        try expect(h0["theirs"]    != nil, "hunk missing theirs")
        // ours should contain MAIN LINE 2, theirs FEATURE LINE 2
        if case .array(let ours) = h0["ours"] {
            let joined = ours.compactMap { v -> String? in if case .string(let s) = v { return s } else { return nil } }.joined(separator: "\n")
            try expect(joined.contains("MAIN LINE 2"), "ours should contain 'MAIN LINE 2', got: \(joined)")
        }
        if case .array(let theirs) = h0["theirs"] {
            let joined = theirs.compactMap { v -> String? in if case .string(let s) = v { return s } else { return nil } }.joined(separator: "\n")
            try expect(joined.contains("FEATURE LINE 2"), "theirs should contain 'FEATURE LINE 2', got: \(joined)")
        }
        // Clean up via the tool's own abort path.
        let ab = try await router.dispatch(toolName: "git_merge", arguments: .object([
            "abort": .bool(true),
            "cwd":   .string(tmp.path)
        ]))
        if case .object(let ad) = ab, case .bool(let aborted) = ad["aborted"] {
            try expect(aborted == true, "git_merge --abort should set aborted:true")
        }
    }

    await test("git_worktree add+remove round-trip against a sibling worktree (live)") {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nb-w3-wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = GitRuntime.shared
        let init1 = try await runtime.runGit(["init", "-q", "-b", "main"], cwd: tmp.path)
        guard init1.exitCode == 0 else { return }
        _ = try await runtime.runGit(["config", "user.email", "t@example.com"], cwd: tmp.path)
        _ = try await runtime.runGit(["config", "user.name", "Test"], cwd: tmp.path)
        let f = tmp.appendingPathComponent("a.txt")
        try "hi\n".write(to: f, atomically: true, encoding: .utf8)
        _ = try await runtime.runGit(["add", "a.txt"], cwd: tmp.path)
        _ = try await runtime.runGit(["commit", "-q", "-m", "init"], cwd: tmp.path)
        _ = try await runtime.runGit(["branch", "feature-wt"], cwd: tmp.path)

        let wtPath = tmp.deletingLastPathComponent()
            .appendingPathComponent("nb-w3-wt-sibling-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: wtPath) }

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await GitModule.register(on: router)
        let addRes = try await router.dispatch(toolName: "git_worktree", arguments: .object([
            "action": .string("add"),
            "path":   .string(wtPath),
            "ref":    .string("feature-wt"),
            "cwd":    .string(tmp.path)
        ]))
        guard case .object(let ad) = addRes, case .bool(let aok) = ad["ok"], aok else {
            throw TestError.assertion("git_worktree add expected ok:true, got \(addRes)")
        }
        // List should now show 2 worktrees.
        let listRes = try await router.dispatch(toolName: "git_worktree", arguments: .object([
            "action": .string("list"),
            "cwd":    .string(tmp.path)
        ]))
        if case .object(let ld) = listRes, case .int(let n) = ld["count"] {
            try expect(n >= 2, "expected ≥2 worktrees after add, got \(n)")
        }
        // Remove the sibling worktree.
        let rmRes = try await router.dispatch(toolName: "git_worktree", arguments: .object([
            "action": .string("remove"),
            "path":   .string(wtPath),
            "cwd":    .string(tmp.path)
        ]))
        if case .object(let rd) = rmRes, case .bool(let rok) = rd["ok"] {
            try expect(rok == true, "git_worktree remove expected ok:true, got \(rmRes)")
        }
    }

    await test("git_worktree add background:true returns {background, jobId} envelope") {
        // Hermetic temp repo so the bg-spawned `git worktree add` doesn't touch real state.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nb-w3-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = GitRuntime.shared
        let init1 = try await runtime.runGit(["init", "-q", "-b", "main"], cwd: tmp.path)
        guard init1.exitCode == 0 else { return }
        _ = try await runtime.runGit(["config", "user.email", "t@example.com"], cwd: tmp.path)
        _ = try await runtime.runGit(["config", "user.name", "Test"], cwd: tmp.path)
        let f = tmp.appendingPathComponent("a.txt")
        try "hi\n".write(to: f, atomically: true, encoding: .utf8)
        _ = try await runtime.runGit(["add", "a.txt"], cwd: tmp.path)
        _ = try await runtime.runGit(["commit", "-q", "-m", "init"], cwd: tmp.path)
        _ = try await runtime.runGit(["branch", "feature-bg"], cwd: tmp.path)

        let wtPath = tmp.deletingLastPathComponent()
            .appendingPathComponent("nb-w3-bg-sibling-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: wtPath) }

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await GitModule.register(on: router)
        let res = try await router.dispatch(toolName: "git_worktree", arguments: .object([
            "action":     .string("add"),
            "path":       .string(wtPath),
            "ref":        .string("feature-bg"),
            "cwd":        .string(tmp.path),
            "background": .bool(true)
        ]))
        guard case .object(let d) = res else {
            throw TestError.assertion("bg worktree add did not return an object")
        }
        // Either ok:true with background:true+jobId, OR capability_missing on hosts w/o git.
        if case .string(let st) = d["status"], st == "capability_missing" { return }
        try expect(d["background"] != nil, "missing background flag")
        try expect(d["jobId"] != nil, "missing jobId")
        // Give the bg job a beat to settle and then issue cleanup.
        try? await Task.sleep(nanoseconds: 600_000_000)
        _ = try? await runtime.runGit(["worktree", "remove", "--force", wtPath], cwd: tmp.path)
    }

}
