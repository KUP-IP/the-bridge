// CodeEditModuleTests.swift — PKT-750 (v2.2 · 1.2)
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

func runCodeEditModuleTests() async {
    print("\n\u{1F6E0}  CodeEditModule Tests (PKT-750 v2.2 · 1.2)")

    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await CodeEditModule.register(on: router)

    // ---------- Registration ----------

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

    await test("code_search clamps maxMatches and truthfully signals an extra match") {
        let f = "\(testDir)/many-matches.txt"
        try Array(repeating: "needle", count: 520)
            .joined(separator: "\n")
            .write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "code_search",
            arguments: .object([
                "pattern": .string("needle"),
                "path": .string(f),
                "fixedString": .bool(true),
                "maxMatches": .int(999)
            ])
        )
        guard case .object(let dict) = result,
              case .int(let count) = dict["count"],
              case .int(let applied) = dict["maxMatchesApplied"],
              case .bool(let truncated) = dict["truncated"],
              case .bool(let outputTruncated) = dict["outputTruncated"],
              case .bool(let resultBudgetTruncated) = dict["resultBudgetTruncated"],
              case .array(let matches) = dict["matches"] else {
            throw TestError.assertion("Expected max-match cap metadata: \(result)")
        }
        try expect(applied == 500, "Expected maxMatches to clamp at 500, got \(applied)")
        try expect(count == 500, "Expected exactly the global returned-match cap, got \(count)")
        try expect(matches.count == count, "Expected every returned match to be counted")
        try expect(truncated, "Expected the sentinel match to mark the result truncated")
        try expect(!outputTruncated, "Fixture should not depend on raw-process output truncation")
        try expect(!resultBudgetTruncated, "Fixture should not depend on the structured-result budget")
    }

    await test("code_search bounds the returned text of an oversized matching line") {
        let f = "\(testDir)/long-line.txt"
        try (String(repeating: "x", count: 20_000) + "needle\n")
            .write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "code_search",
            arguments: .object([
                "pattern": .string("needle"),
                "path": .string(f),
                "fixedString": .bool(true)
            ])
        )
        guard case .object(let dict) = result,
              case .array(let matches) = dict["matches"],
              case .object(let first) = matches.first,
              case .string(let lineText) = first["lineText"],
              case .bool(let lineTextTruncated) = first["lineTextTruncated"] else {
            throw TestError.assertion("Expected bounded line-text result: \(result)")
        }
        try expect(matches.count == 1, "Expected the single long matching line")
        try expect(lineTextTruncated, "Expected 20,000-byte line to be truncated")
        try expect(lineText.utf8.count <= 16_000, "Returned line text must stay within its byte cap")
    }

    // ---------- file_edit replace bounded diff ----------

    await test("file_edit replace preserves small preview and applied unified diffs") {
        let f = "\(testDir)/small-replace.txt"
        try "alpha\nbeta\n".write(toFile: f, atomically: true, encoding: .utf8)
        let preview = try await router.dispatch(
            toolName: "file_edit",
            arguments: .object([
                "mode": .string("replace"),
                "path": .string(f),
                "search": .string("beta"),
                "replacement": .string("gamma"),
                "preview": .bool(true)
            ])
        )
        guard case .object(let previewDict) = preview,
              case .string(let previewDiff) = previewDict["diff"],
              case .bool(let previewDiffAvailable) = previewDict["diffAvailable"] else {
            throw TestError.assertion("Expected small preview diff response: \(preview)")
        }
        try expect(previewDiffAvailable, "Small preview should retain its unified diff")
        try expect(previewDiff.contains("-beta\n") && previewDiff.contains("+gamma\n"), "Expected normal unified diff content")
        try expect(try String(contentsOfFile: f, encoding: .utf8) == "alpha\nbeta\n", "Preview must not write the file")

        let applied = try await router.dispatch(
            toolName: "file_edit",
            arguments: .object([
                "mode": .string("replace"),
                "path": .string(f),
                "search": .string("beta"),
                "replacement": .string("gamma")
            ])
        )
        guard case .object(let appliedDict) = applied,
              case .string(let appliedDiff) = appliedDict["diff"],
              case .bool(let appliedDiffAvailable) = appliedDict["diffAvailable"] else {
            throw TestError.assertion("Expected small applied diff response: \(applied)")
        }
        try expect(appliedDiffAvailable && appliedDiff == previewDiff, "Small applied edit should retain the legacy diff")
        try expect(try String(contentsOfFile: f, encoding: .utf8) == "alpha\ngamma\n", "Applied replacement should write atomically")
    }

    await test("file_edit replaces large line-count files without allocating an unbounded diff matrix") {
        let f = "\(testDir)/matrix-bounded.txt"
        let original = (0..<501).map { index in index == 250 ? "target" : "line-\(index)" }.joined(separator: "\n")
        try original.write(toFile: f, atomically: true, encoding: .utf8)
        let preview = try await router.dispatch(
            toolName: "file_edit",
            arguments: .object([
                "mode": .string("replace"),
                "path": .string(f),
                "search": .string("target"),
                "replacement": .string("updated"),
                "preview": .bool(true)
            ])
        )
        guard case .object(let previewDict) = preview,
              case .string(let previewDiff) = previewDict["diff"],
              case .bool(let previewDiffAvailable) = previewDict["diffAvailable"],
              case .string(let previewReason) = previewDict["diffOmittedReason"] else {
            throw TestError.assertion("Expected bounded matrix preview response: \(preview)")
        }
        try expect(previewDiff.isEmpty && !previewDiffAvailable, "Matrix-limited preview must not return a partial diff")
        try expect(previewReason == "matrix_cells_limit", "Expected matrix cap reason, got \(previewReason)")
        try expect(try String(contentsOfFile: f, encoding: .utf8) == original, "Bounded preview must not write")

        let applied = try await router.dispatch(
            toolName: "file_edit",
            arguments: .object([
                "mode": .string("replace"),
                "path": .string(f),
                "search": .string("target"),
                "replacement": .string("updated")
            ])
        )
        guard case .object(let appliedDict) = applied,
              case .bool(false) = appliedDict["diffAvailable"],
              case .string("matrix_cells_limit") = appliedDict["diffOmittedReason"] else {
            throw TestError.assertion("Expected bounded matrix applied response: \(applied)")
        }
        try expect(try String(contentsOfFile: f, encoding: .utf8).contains("updated"), "Applied edit must not be blocked by diff omission")
    }

    await test("file_edit omits oversized unified diffs instead of returning a partial patch") {
        let f = "\(testDir)/output-bounded.txt"
        let original = String(repeating: "a", count: 300_000)
        let replacement = String(repeating: "b", count: 300_000)
        try original.write(toFile: f, atomically: true, encoding: .utf8)
        let result = try await router.dispatch(
            toolName: "file_edit",
            arguments: .object([
                "mode": .string("replace"),
                "path": .string(f),
                "search": .string(original),
                "replacement": .string(replacement),
                "preview": .bool(true)
            ])
        )
        guard case .object(let dict) = result,
              case .string(let diff) = dict["diff"],
              case .bool(let diffAvailable) = dict["diffAvailable"],
              case .string(let reason) = dict["diffOmittedReason"] else {
            throw TestError.assertion("Expected output-bounded diff response: \(result)")
        }
        try expect(diff.isEmpty && !diffAvailable, "Oversized diff must be omitted, never partially returned")
        try expect(reason == "output_bytes_limit", "Expected output cap reason, got \(reason)")
        try expect(try String(contentsOfFile: f, encoding: .utf8) == original, "Preview must keep the huge-line file unchanged")
    }

    await test("discoverRipgrep finds rg in this environment") {
        let rg = CodeEditModule.discoverRipgrep()
        try expect(rg != nil, "rg should be discoverable (installed via brew install ripgrep in PKT-750 setup)")
    }

    // ---------- Cleanup ----------
    try? FileManager.default.removeItem(atPath: testDir)
}
