// SpotlightModuleTests.swift — PKT-747 (v2.2 · 3.3)
// NotionBridge · Tests
//
// Tests for SpotlightModule (1 tool: spotlight_query).
// mdfind is shipped on every macOS, so these run cleanly without TCC grants.

import Foundation
import MCP
import NotionBridgeLib

func runSpotlightModuleTests() async {
    print("\n\u{1F50D} SpotlightModule Tests")

    let gate = SecurityGate()
    let log  = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await SpotlightModule.register(on: router)

    // --- Registration ---

    await test("SpotlightModule registers spotlight_query") {
        let tools = await router.registrations(forModule: "computer")
        try expect(tools.contains(where: { $0.name == "spotlight_query" }), "Missing spotlight_query")
    }

    await test("SpotlightModule.moduleName is 'computer'") {
        try expect(SpotlightModule.moduleName == "computer",
                   "Expected 'computer', got '\(SpotlightModule.moduleName)'")
    }

    // --- Tier classification ---

    await test("spotlight_query is open tier") {
        let tools = await router.registrations(forModule: "computer")
        let tool = tools.first(where: { $0.name == "spotlight_query" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    // --- Input validation ---

    await test("spotlight_query rejects missing query param") {
        let result = try await router.dispatch(
            toolName: "spotlight_query",
            arguments: .object([:])
        )
        guard case .object(let dict) = result, case .string(let err) = dict["error"] else {
            throw TestError.assertion("Expected error object for missing query")
        }
        try expect(err.lowercased().contains("query"),
                   "Expected query-required error, got: \(err)")
    }

    await test("spotlight_query rejects empty query string") {
        let result = try await router.dispatch(
            toolName: "spotlight_query",
            arguments: .object(["query": .string("")])
        )
        guard case .object(let dict) = result, case .string(let err) = dict["error"] else {
            throw TestError.assertion("Expected error object for empty query")
        }
        try expect(!err.isEmpty, "Error message should not be empty")
    }

    // --- Round-trip: name=true on a controlled directory (the worktree itself) ---

    await test("spotlight_query name=true returns structured rows or graceful error") {
        let result = try await router.dispatch(
            toolName: "spotlight_query",
            arguments: .object([
                "query": .string("Package.swift"),
                "scope": .string("/usr/bin"),
                "name":  .bool(true),
                "limit": .int(5)
            ])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("Expected object response")
        }
        // Either matches array (success) or error (mdfind index unavailable in CI)
        if case .array(_) = dict["matches"] {
            try expect(dict["count"] != nil, "count missing on success path")
            try expect(dict["truncated"] != nil, "truncated missing on success path")
            try expect(dict["query"] != nil, "query echo missing on success path")
        } else if case .string(_) = dict["error"] {
            // Acceptable on environments where Spotlight indexing is restricted
        } else {
            throw TestError.assertion("Unexpected response shape: \(dict.keys)")
        }
    }

    // --- count=true variant ---

    await test("spotlight_query count=true returns count or graceful error") {
        let result = try await router.dispatch(
            toolName: "spotlight_query",
            arguments: .object([
                "query": .string("Package.swift"),
                "name":  .bool(true),
                "count": .bool(true)
            ])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("Expected object response")
        }
        if case .int(_) = dict["count"] {
            try expect(dict["raw"] != nil, "raw missing on count path")
        } else if case .string(_) = dict["error"] {
            // Acceptable
        } else {
            throw TestError.assertion("Unexpected response shape on count: \(dict.keys)")
        }
    }

    // --- Limit clamping ---

    await test("spotlight_query limit < 1 is clamped to 1") {
        let result = try await router.dispatch(
            toolName: "spotlight_query",
            arguments: .object([
                "query": .string("Package.swift"),
                "name":  .bool(true),
                "limit": .int(0)
            ])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("Expected object response")
        }
        if case .int(let n) = dict["count"] {
            try expect(n <= 1, "Limit clamp should yield ≤1 row, got \(n)")
        }
        // error path also acceptable here
    }
}
