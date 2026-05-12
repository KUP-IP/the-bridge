// CodeEditModuleTests.swift — PKT-750 (v2.2 · 1.2)
// NotionBridge · Tests

import Foundation
import MCP
import NotionBridgeLib

func runCodeEditModuleTests() async {
    print("\n\u{1F6E0}  CodeEditModule Tests (PKT-750 v2.2 · 1.2)")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await CodeEditModule.register(on: router)

    // ---------- Registration ----------

    await test("CodeEditModule registers code_search, file_str_replace, file_apply_patch on dev/") {
        let tools = await router.registrations(forModule: "dev")
        let names = Set(tools.map(\.name))
        try expect(names.contains("code_search"), "missing code_search")
        try expect(names.contains("file_str_replace"), "missing file_str_replace")
        try expect(names.contains("file_apply_patch"), "missing file_apply_patch")
    }

    await test("Tier assignments: code_search=open, file_str_replace=notify, file_apply_patch=notify") {
        let tools = await router.registrations(forModule: "dev")
        let map = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.tier) })
        try expect(map["code_search"] == .open, "code_search should be .open")
        try expect(map["file_str_replace"] == .notify, "file_str_replace should be .notify")
        try expect(map["file_apply_patch"] == .notify, "file_apply_patch should be .notify")
    }

    // ---------- Test directory setup ----------

    let testDir = "/tmp/codeedit_tests_\(ProcessInfo.processInfo.processIdentifier)"
    try? FileManager.default.removeItem(atPath: testDir)
    try? FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

    // ---------- code_search ----------

    await test("code_search returns structured matches with line numbers + submatches") {
        let f = "\(testDir)/sample.swift"
        let content = """
        import Foundation

        func hello() {
            print("Hello, world!")
        }

        func goodbye() {
            print("Goodbye")
        }
        """
        try content.write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "code_search",
            arguments: .object([
                "pattern": .string("func "),
                "path": .string(testDir),
                "fixedString": .bool(true)
            ])
        )
        guard case .object(let dict) = result,
              case .bool(true) = dict["ok"],
              case .int(let count) = dict["count"],
              case .array(let matches) = dict["matches"] else {
            throw TestError.assertion("Unexpected result shape: \(result)")
        }
        try expect(count >= 2, "Expected ≥2 matches (hello, goodbye), got \(count)")
        try expect(matches.count == count, "matches.count should equal count")
        guard case .object(let m0) = matches[0] else {
            throw TestError.assertion("first match not object")
        }
        try expect(m0["lineNumber"] != nil, "missing lineNumber")
        try expect(m0["lineText"] != nil, "missing lineText")
        try expect(m0["submatches"] != nil, "missing submatches")
        try expect(m0["absoluteOffset"] != nil, "missing absoluteOffset")
    }

    await test("code_search supports glob filter") {
        let result = try await router.dispatch(
            toolName: "code_search",
            arguments: .object([
                "pattern": .string("func"),
                "path": .string(testDir),
                "fixedString": .bool(true),
                "globs": .array([.string("*.swift")])
            ])
        )
        guard case .object(let dict) = result, case .bool(true) = dict["ok"] else {
            throw TestError.assertion("glob search failed: \(result)")
        }
        try expect(dict["count"] != nil, "missing count")
    }

    await test("code_search elapsedMs is reported") {
        let result = try await router.dispatch(
            toolName: "code_search",
            arguments: .object([
                "pattern": .string("hello"),
                "path": .string(testDir),
                "fixedString": .bool(true)
            ])
        )
        guard case .object(let dict) = result,
              case .int(let elapsed) = dict["elapsedMs"] else {
            throw TestError.assertion("elapsedMs missing")
        }
        try expect(elapsed >= 0, "elapsedMs should be non-negative")
    }

    await test("discoverRipgrep finds rg in this environment") {
        let rg = CodeEditModule.discoverRipgrep()
        try expect(rg != nil, "rg should be discoverable (installed via brew install ripgrep in PKT-750 setup)")
    }

    // ---------- file_str_replace ----------

    await test("file_str_replace replaces unique match and writes atomically") {
        let f = "\(testDir)/replace_unique.txt"
        try "alpha beta gamma".write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_str_replace",
            arguments: .object([
                "path": .string(f),
                "search": .string("beta"),
                "replacement": .string("BETA")
            ])
        )
        guard case .object(let dict) = result, case .bool(true) = dict["ok"] else {
            throw TestError.assertion("Unexpected result: \(result)")
        }
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "alpha BETA gamma", "Got: \(after)")
    }

    await test("file_str_replace rejects ambiguous match (>1 occurrence) and leaves file untouched") {
        let f = "\(testDir)/ambig.txt"
        try "x x x".write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_str_replace",
            arguments: .object([
                "path": .string(f),
                "search": .string("x"),
                "replacement": .string("y")
            ])
        )
        guard case .object(let dict) = result, case .bool(false) = dict["ok"] else {
            throw TestError.assertion("Expected ok=false for ambiguous match")
        }
        guard case .string(let status) = dict["status"] else {
            throw TestError.assertion("missing status")
        }
        try expect(status == "failed", "Expected status=failed, got \(status)")
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "x x x", "File modified despite ambiguous match: \(after)")
    }

    await test("file_str_replace replaceAllMatches=true replaces all and reports count") {
        let f = "\(testDir)/all.txt"
        try "x x x".write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_str_replace",
            arguments: .object([
                "path": .string(f),
                "search": .string("x"),
                "replacement": .string("y"),
                "replaceAllMatches": .bool(true)
            ])
        )
        guard case .object(let dict) = result,
              case .bool(true) = dict["ok"],
              case .int(let replaced) = dict["occurrencesReplaced"] else {
            throw TestError.assertion("Unexpected: \(result)")
        }
        try expect(replaced == 3, "Expected 3 replacements, got \(replaced)")
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "y y y", "Got: \(after)")
    }

    await test("file_str_replace preview returns unified diff and does NOT write") {
        let f = "\(testDir)/preview.txt"
        try "line one\nline two\nline three\n".write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_str_replace",
            arguments: .object([
                "path": .string(f),
                "search": .string("line two"),
                "replacement": .string("LINE TWO"),
                "preview": .bool(true)
            ])
        )
        guard case .object(let dict) = result,
              case .bool(true) = dict["ok"],
              case .bool(let isPreview) = dict["preview"],
              case .string(let diff) = dict["diff"] else {
            throw TestError.assertion("Unexpected: \(result)")
        }
        try expect(isPreview == true, "preview flag should be true")
        try expect(diff.contains("-line two"), "diff missing -line two: \(diff)")
        try expect(diff.contains("+LINE TWO"), "diff missing +LINE TWO: \(diff)")
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "line one\nline two\nline three\n", "Preview must not write")
    }

    await test("file_str_replace handles unicode and trailing newline") {
        let f = "\(testDir)/unicode.txt"
        try "Hello \u{1F30D} world\n".write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_str_replace",
            arguments: .object([
                "path": .string(f),
                "search": .string("\u{1F30D}"),
                "replacement": .string("\u{1F30E}")
            ])
        )
        guard case .object(let dict) = result, case .bool(true) = dict["ok"] else {
            throw TestError.assertion("Unicode replace failed: \(result)")
        }
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "Hello \u{1F30E} world\n", "Got: \(after)")
    }

    await test("file_str_replace preserves trailing whitespace exactly") {
        let f = "\(testDir)/trailing_ws.txt"
        try "alpha   \nbeta\n".write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_str_replace",
            arguments: .object([
                "path": .string(f),
                "search": .string("beta"),
                "replacement": .string("BETA")
            ])
        )
        guard case .object(let dict) = result, case .bool(true) = dict["ok"] else {
            throw TestError.assertion("trailing-ws replace failed: \(result)")
        }
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "alpha   \nBETA\n", "trailing whitespace mangled: \(after.debugDescription)")
    }

    await test("file_str_replace rejects no-match and leaves file untouched") {
        let f = "\(testDir)/nomatch.txt"
        try "alpha".write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_str_replace",
            arguments: .object([
                "path": .string(f),
                "search": .string("zeta"),
                "replacement": .string("ZETA")
            ])
        )
        guard case .object(let dict) = result, case .bool(false) = dict["ok"] else {
            throw TestError.assertion("Expected ok=false for no match")
        }
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "alpha", "File should be unchanged on no-match")
    }

    await test("file_str_replace returns not_found for missing file") {
        let result = try await router.dispatch(
            toolName: "file_str_replace",
            arguments: .object([
                "path": .string("\(testDir)/does_not_exist.txt"),
                "search": .string("x"),
                "replacement": .string("y")
            ])
        )
        guard case .object(let dict) = result,
              case .bool(false) = dict["ok"],
              case .string(let status) = dict["status"] else {
            throw TestError.assertion("Unexpected result: \(result)")
        }
        try expect(status == "not_found", "Expected status=not_found, got \(status)")
    }

    // ---------- file_apply_patch ----------

    await test("file_apply_patch applies a clean hunk") {
        let f = "\(testDir)/patch_clean.txt"
        try "line1\nline2\nline3\nline4\n".write(toFile: f, atomically: true, encoding: .utf8)
        let patch = """
        @@ -1,4 +1,4 @@
         line1
        -line2
        +LINE2
         line3
         line4
        """
        let result = try await router.dispatch(
            toolName: "file_apply_patch",
            arguments: .object([
                "path": .string(f),
                "patch": .string(patch)
            ])
        )
        guard case .object(let dict) = result,
              case .bool(true) = dict["ok"],
              case .int(let hunks) = dict["hunksApplied"] else {
            throw TestError.assertion("Patch failed: \(result)")
        }
        try expect(hunks == 1, "Expected 1 hunk applied, got \(hunks)")
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "line1\nLINE2\nline3\nline4\n", "Got: \(after.debugDescription)")
    }

    await test("file_apply_patch rejects on context drift and leaves file untouched") {
        let f = "\(testDir)/patch_drift.txt"
        try "line1\nDIFFERENT\nline3\n".write(toFile: f, atomically: true, encoding: .utf8)
        let patch = """
        @@ -1,3 +1,3 @@
         line1
        -line2
        +LINE2
         line3
        """
        let result = try await router.dispatch(
            toolName: "file_apply_patch",
            arguments: .object([
                "path": .string(f),
                "patch": .string(patch)
            ])
        )
        guard case .object(let dict) = result,
              case .bool(false) = dict["ok"],
              case .string(let status) = dict["status"],
              case .string(let err) = dict["error"] else {
            throw TestError.assertion("Expected drift rejection: \(result)")
        }
        try expect(status == "failed", "Expected status=failed for drift")
        try expect(err.contains("context drift") || err.contains("context mismatch"), "Error should mention context drift: \(err)")
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "line1\nDIFFERENT\nline3\n", "File should be unchanged after drift rejection: \(after.debugDescription)")
    }

    await test("file_apply_patch preview validates without writing") {
        let f = "\(testDir)/patch_preview.txt"
        let original = "a\nb\nc\n"
        try original.write(toFile: f, atomically: true, encoding: .utf8)
        let patch = """
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        """
        let result = try await router.dispatch(
            toolName: "file_apply_patch",
            arguments: .object([
                "path": .string(f),
                "patch": .string(patch),
                "preview": .bool(true)
            ])
        )
        guard case .object(let dict) = result,
              case .bool(true) = dict["ok"],
              case .bool(let isPreview) = dict["preview"] else {
            throw TestError.assertion("Preview failed: \(result)")
        }
        try expect(isPreview == true)
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == original, "Preview must not write: \(after.debugDescription)")
    }

    await test("file_apply_patch handles multiple hunks in order") {
        let f = "\(testDir)/patch_multi.txt"
        try "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n".write(toFile: f, atomically: true, encoding: .utf8)
        let patch = """
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        @@ -7,3 +7,3 @@
         g
        -h
        +H
         i
        """
        let result = try await router.dispatch(
            toolName: "file_apply_patch",
            arguments: .object([
                "path": .string(f),
                "patch": .string(patch)
            ])
        )
        guard case .object(let dict) = result,
              case .bool(true) = dict["ok"],
              case .int(let hunks) = dict["hunksApplied"] else {
            throw TestError.assertion("Multi-hunk apply failed: \(result)")
        }
        try expect(hunks == 2, "Expected 2 hunks, got \(hunks)")
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "a\nB\nc\nd\ne\nf\ng\nH\ni\nj\n", "Got: \(after.debugDescription)")
    }

    await test("file_apply_patch returns not_found for missing file") {
        let patch = "@@ -1,1 +1,1 @@\n-x\n+y\n"
        let result = try await router.dispatch(
            toolName: "file_apply_patch",
            arguments: .object([
                "path": .string("\(testDir)/missing.txt"),
                "patch": .string(patch)
            ])
        )
        guard case .object(let dict) = result,
              case .bool(false) = dict["ok"],
              case .string(let status) = dict["status"] else {
            throw TestError.assertion("Expected not_found")
        }
        try expect(status == "not_found", "Got status=\(status)")
    }

    await test("file_apply_patch rejects malformed patch (no @@ header)") {
        let f = "\(testDir)/patch_malformed.txt"
        try "hello\n".write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_apply_patch",
            arguments: .object([
                "path": .string(f),
                "patch": .string("this is not a patch")
            ])
        )
        guard case .object(let dict) = result,
              case .bool(false) = dict["ok"] else {
            throw TestError.assertion("Expected failure for malformed patch")
        }
        let after = try String(contentsOfFile: f, encoding: .utf8)
        try expect(after == "hello\n", "File must be unchanged on malformed patch")
    }

    // ---------- Cleanup ----------
    try? FileManager.default.removeItem(atPath: testDir)
}
