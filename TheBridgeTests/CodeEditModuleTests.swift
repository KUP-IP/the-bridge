// CodeEditModuleTests.swift — PKT-750 (v2.2 · 1.2)
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

func runCodeEditModuleTests() async {
    print("\n\u{1F6E0}  CodeEditModule Tests (PKT-750 v2.2 · 1.2)")

    let gate = SecurityGate()
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

    await test("discoverRipgrep finds rg in this environment") {
        let rg = CodeEditModule.discoverRipgrep()
        try expect(rg != nil, "rg should be discoverable (installed via brew install ripgrep in PKT-750 setup)")
    }

    // ---------- Cleanup ----------
    try? FileManager.default.removeItem(atPath: testDir)
}
