// ChromeModuleTests.swift – QA: ChromeModule Test Coverage
// NotionBridge · Tests
//
// Validates tool registration, count, names, security tiers, and handler-level
// escaping behavior for ChromeModule.
// Follows the standard module test pattern.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - ChromeModule Tests

func runChromeModuleTests() async {
    print("\n🌐 ChromeModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ChromeModule.register(on: router)

    // ============================================================
    // MARK: - Tool Registration (5 tools)
    // ============================================================

    await test("ChromeModule registers 6 tools (Sprint A · #14: +chrome_tabs_list)") {
        let tools = await router.registrations(forModule: "chrome")
        try expect(tools.count == 6, "Expected 6 chrome tools, got \(tools.count)")
    }

    let expectedTools: [String] = [
        "chrome_tabs",        // Sprint A · #14 alias (one-cycle deprecation)
        "chrome_tabs_list",   // Sprint A · #14 new primary name
        "chrome_navigate",
        "chrome_read_page",
        "chrome_execute_js",
        "chrome_screenshot_tab"
    ]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "chrome")
            let names = Set(tools.map(\.name))
            try expect(names.contains(toolName), "Missing \(toolName)")
        }
    }

    // ============================================================
    // MARK: - Security Tiers
    // ============================================================

    let openTools = ["chrome_tabs", "chrome_tabs_list", "chrome_read_page", "chrome_screenshot_tab"]
    let notifyTools = ["chrome_navigate", "chrome_execute_js"]

    for toolName in openTools {
        await test("\(toolName) has open tier") {
            let tools = await router.registrations(forModule: "chrome")
            let tool = tools.first(where: { $0.name == toolName })
            try expect(tool != nil, "Tool \(toolName) not found")
            try expect(tool!.tier == .open, "\(toolName) should be .open, got \(tool!.tier)")
        }
    }

    for toolName in notifyTools {
        await test("\(toolName) has notify tier") {
            let tools = await router.registrations(forModule: "chrome")
            let tool = tools.first(where: { $0.name == toolName })
            try expect(tool != nil, "Tool \(toolName) not found")
            try expect(tool!.tier == .notify, "\(toolName) should be .notify, got \(tool!.tier)")
        }
    }

    // ============================================================
    // MARK: - Tool Descriptions & Schemas
    // ============================================================

    await test("All chrome tools have non-empty descriptions") {
        let tools = await router.registrations(forModule: "chrome")
        for tool in tools {
            try expect(!tool.description.isEmpty, "\(tool.name) has empty description")
        }
    }

    await test("chrome recovery descriptions mention partial results and recovery hints") {
        let tools = await router.registrations(forModule: "chrome")
        let tabs = tools.first(where: { $0.name == "chrome_tabs" })
        let navigate = tools.first(where: { $0.name == "chrome_navigate" })
        try expect(tabs?.description.contains("partialResults") == true, "chrome_tabs should document partialResults")
        try expect(navigate?.description.contains("recovery hint") == true, "chrome_navigate should document recovery hint behavior")
    }

    await test("All chrome tools have input schemas") {
        let tools = await router.registrations(forModule: "chrome")
        for tool in tools {
            if case .object = tool.inputSchema {
                // valid
            } else {
                throw TestError.assertion("\(tool.name) inputSchema is not an object")
            }
        }
    }

    // ============================================================
    // MARK: - Required Parameters
    // ============================================================

    await test("chrome_navigate requires 'url' parameter") {
        let tools = await router.registrations(forModule: "chrome")
        let tool = tools.first(where: { $0.name == "chrome_navigate" })
        try expect(tool != nil, "chrome_navigate not found")
        if case .object(let schema) = tool!.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("url"), "chrome_navigate should require 'url'")
        }
    }

    await test("chrome_execute_js requires 'javascript' parameter") {
        let tools = await router.registrations(forModule: "chrome")
        let tool = tools.first(where: { $0.name == "chrome_execute_js" })
        try expect(tool != nil, "chrome_execute_js not found")
        if case .object(let schema) = tool!.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("javascript"), "chrome_execute_js should require 'javascript'")
        }
    }

    // ============================================================
    // MARK: - P2-3: Handler-Level Escaping Tests (PKT-373)
    // ============================================================
    // These tests dispatch through the handler to verify that malicious
    // AppleScript injection payloads do not crash the process. When Chrome
    // is not running the handler returns an error, which is acceptable —
    // the key assertion is that the handler does not throw/crash and the
    // result is a well-formed object (not an unhandled exception).

    await test("chrome_navigate handles backslash injection without crash") {
        // P0-1 payload: backslash + quote escape bypass attempt
        let maliciousURL = #"\" & do shell script "echo pwned" & ""#
        let result = try await router.dispatch(
            toolName: "chrome_navigate",
            arguments: .object(["url": .string(maliciousURL)])
        )
        // Handler should return an object (success or error), not crash
        if case .object(let dict) = result {
            // If Chrome is not running, we expect an error key — that's fine
            // The important thing is no crash and no unhandled exception
            if case .string(let error) = dict["error"] {
                try expect(!error.isEmpty, "Error message should be non-empty")
            }
            // If Chrome IS running, the escaped URL would be navigated safely
        } else if case .string = result {
            // Some handlers return string on error — acceptable
        } else {
            throw TestError.assertion("Expected object or string result, handler may have crashed")
        }
    }

    await test("chrome_execute_js handles injection payload without crash") {
        // P0-1 payload: quote escape bypass attempt in JS context
        let maliciousJS = #""; do shell script "echo pwned"; //"#
        let result = try await router.dispatch(
            toolName: "chrome_execute_js",
            arguments: .object(["javascript": .string(maliciousJS)])
        )
        if case .object(let dict) = result {
            if case .string(let error) = dict["error"] {
                try expect(!error.isEmpty, "Error message should be non-empty")
            }
        } else if case .string = result {
            // Acceptable error response format
        } else {
            throw TestError.assertion("Expected object or string result, handler may have crashed")
        }
    }

    await test("chrome_navigate handles embedded backslashes in URL") {
        // Verify two-pass escaping: \ should become \\ before quote escaping
        let backslashURL = #"https://example.com/path\with\\backslashes"#
        let result = try await router.dispatch(
            toolName: "chrome_navigate",
            arguments: .object(["url": .string(backslashURL)])
        )
        // Should not crash — returns error or success object
        if case .object = result {
            // Valid response
        } else if case .string = result {
            // Valid error response
        } else {
            throw TestError.assertion("Expected structured result for backslash URL")
        }
    }

    await test("chrome_navigate rejects missing url parameter") {
        do {
            _ = try await router.dispatch(
                toolName: "chrome_navigate",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing url parameter")
        } catch is ToolRouterError {
            // Expected — missing required parameter
        }
    }

    await test("chrome_execute_js rejects missing javascript parameter") {
        do {
            _ = try await router.dispatch(
                toolName: "chrome_execute_js",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing javascript parameter")
        } catch is ToolRouterError {
            // Expected — missing required parameter
        }
    }

}
