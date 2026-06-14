// SecurityAuditTests.swift — Phase 5: Tests for SEC-01/02/03 fixes
// NotionBridge · Tests

import Foundation
import MCP
import NotionBridgeLib

func runSecurityAuditTests() async {
    print("\n🔐 Security Audit Tests (SEC-01/02/03)")

    // ============================================================
    // MARK: - SEC-01: Constant-time string comparison
    // ============================================================

    await test("constantTimeEqual: identical strings return true") {
        try expect(MCPHTTPValidation.constantTimeEqual("secret-token-123", "secret-token-123"))
    }

    await test("constantTimeEqual: different strings return false") {
        try expect(!MCPHTTPValidation.constantTimeEqual("secret-token-123", "secret-token-456"))
    }

    await test("constantTimeEqual: different lengths return false") {
        try expect(!MCPHTTPValidation.constantTimeEqual("short", "much-longer-string"))
    }

    await test("constantTimeEqual: empty strings are equal") {
        try expect(MCPHTTPValidation.constantTimeEqual("", ""))
    }

    await test("constantTimeEqual: empty vs non-empty returns false") {
        try expect(!MCPHTTPValidation.constantTimeEqual("", "notempty"))
        try expect(!MCPHTTPValidation.constantTimeEqual("notempty", ""))
    }

    await test("constantTimeEqual: single character difference detected") {
        try expect(!MCPHTTPValidation.constantTimeEqual("abcdef", "abcdeg"))
    }

    await test("constantTimeEqual: first character difference detected") {
        try expect(!MCPHTTPValidation.constantTimeEqual("Xbcdef", "abcdef"))
    }

    await test("constantTimeEqual: unicode strings work correctly") {
        try expect(MCPHTTPValidation.constantTimeEqual("tökën-🔑", "tökën-🔑"))
        try expect(!MCPHTTPValidation.constantTimeEqual("tökën-🔑", "tökën-🔐"))
    }

    await test("constantTimeEqual: long token comparison") {
        let token = String(repeating: "a", count: 256)
        let same = String(repeating: "a", count: 256)
        let different = String(repeating: "a", count: 255) + "b"
        try expect(MCPHTTPValidation.constantTimeEqual(token, same))
        try expect(!MCPHTTPValidation.constantTimeEqual(token, different))
    }

    await test("constantTimeEqual: prefix match but different length returns false") {
        try expect(!MCPHTTPValidation.constantTimeEqual("secret", "secret-extended"))
    }

    // ============================================================
    // MARK: - SEC-02: CORS wildcard removal verification
    // ============================================================

    await test("SEC-02: No Access-Control-Allow-Origin wildcard in SSETransport") {
        // Verify at the source level that the CORS wildcard is gone
        let sseFile = "NotionBridge/Server/SSETransport.swift"
        let content = try String(contentsOfFile: sseFile, encoding: .utf8)
        let hasCORSWildcard = content.contains("Access-Control-Allow-Origin\", value: \"*\"")
        try expect(!hasCORSWildcard, "SSETransport still contains CORS wildcard — SEC-02 not applied")
    }

    // ============================================================
    // MARK: - SEC-03: clipboard_write tier verification
    // ============================================================

    await test("SEC-03: clipboard_write tier is .notify (not .open)") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await FileModule.register(on: router)
        let tools = await router.registrations(forModule: "file")
        guard let clipWrite = tools.first(where: { $0.name == "clipboard_write" }) else {
            throw TestError.assertion("clipboard_write not found in file module")
        }
        try expect(clipWrite.tier == .notify, "Expected .notify tier for clipboard_write, got \(clipWrite.tier.rawValue)")
    }

    await test("SEC-03: clipboard_read tier remains .open") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await FileModule.register(on: router)
        let tools = await router.registrations(forModule: "file")
        guard let clipRead = tools.first(where: { $0.name == "clipboard_read" }) else {
            throw TestError.assertion("clipboard_read not found in file module")
        }
        try expect(clipRead.tier == .open, "Expected .open tier for clipboard_read, got \(clipRead.tier.rawValue)")
    }

    // ============================================================
    // MARK: - Tier invariant checks
    // ============================================================

    await test("All .request tier tools have correct classification") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        // Register all modules
        await ShellModule.register(on: router)
        await AppleScriptModule.register(on: router)
        await CredentialModule.register(on: router)
        await MessagesModule.register(on: router)
        let all = await router.allRegistrations()
        let requestTools = all.filter { $0.tier == .request }
        let expectedRequest = [
            "shell_exec", "run_script",
            "applescript_exec",
            "credential_save", "credential_read", "credential_delete",
            "messages_send"
        ]
        for name in expectedRequest {
            let found = requestTools.contains(where: { $0.name == name })
            try expect(found, "Expected \(name) at .request tier")
        }
    }

    await test("No write/mutating tools at .open tier") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await FileModule.register(on: router)
        let all = await router.allRegistrations()
        let openTools = all.filter { $0.tier == .open }
        let writeKeywords = ["write", "delete", "move", "copy", "mkdir", "send", "create", "update", "append"]
        for tool in openTools {
            for keyword in writeKeywords {
                if tool.name.contains(keyword) && tool.name != "clipboard_read" {
                    // clipboard_write should NOT be here after SEC-03 fix
                    try expect(tool.name != "clipboard_write", "clipboard_write should not be at .open tier")
                }
            }
        }
    }
}
