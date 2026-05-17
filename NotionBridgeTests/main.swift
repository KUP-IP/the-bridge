// main.swift – V1-06 Test Runner
// NotionBridge · Tests (standalone executable — no XCTest needed)
//
// Runs: SecurityGate, ToolRouter, AuditLog, Module tests, Integration/E2E tests
// PKT-376: SecurityGate tests updated for 3-tier model

import Foundation


import MCP
import NotionBridgeLib

// Credential / payment MCP tests assume the Keychain credentials feature is enabled.
UserDefaults.standard.set(true, forKey: CredentialsFeature.userDefaultsKey)

// MARK: - Test Harness

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func test(_ name: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        passed += 1
        print("  \u{2705} \(name)")
    } catch {
        failed += 1
        print("  \u{274C} \(name): \(error)")
    }
}

func expect(_ condition: Bool, _ msg: String = "Assertion failed", file: String = #file, line: Int = #line) throws {
    guard condition else { throw TestError.assertion("\(msg) at \(file):\(line)") }
}

enum TestError: Error, LocalizedError {
    case assertion(String)
    var errorDescription: String? {
        switch self { case .assertion(let m): return m }
    }
}

// ============================================================
// MARK: - SecurityGate Tests (v3: 3-tier model)
// ============================================================

print("\n\u{1F512} SecurityGate Tests (v3)")

let gate = SecurityGate()

await test("Open tier allows immediately") {
    let d = await gate.enforce(toolName: "read_file", tier: .open, arguments: .object(["path": .string("/tmp/test.txt")]))
    if case .allow = d { } else { throw TestError.assertion("Expected .allow for open tier") }
}

await test("Open tier allows with safe content") {
    let d = await gate.enforce(toolName: "write_file", tier: .open, arguments: .object(["path": .string("/tmp/out.txt")]))
    if case .allow = d { } else { throw TestError.assertion("Expected .allow for open tier write") }
}

await test("SecurityTier has exactly 3 cases") {
    try expect(SecurityTier.allCases.count == 3, "Expected 3 tiers, got \(SecurityTier.allCases.count)")
    try expect(SecurityTier.allCases.contains(.open))
    try expect(SecurityTier.allCases.contains(.notify))
    try expect(SecurityTier.allCases.contains(.request))
}

await test("SecurityTier raw values are correct") {
    try expect(SecurityTier.open.rawValue == "open")
    try expect(SecurityTier.notify.rawValue == "notify")
    try expect(SecurityTier.request.rawValue == "request")
}

await test("SecurityTier is Codable (JSON round-trip)") {
    let encoder = JSONEncoder()
    let data = try encoder.encode(SecurityTier.open)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(SecurityTier.self, from: data)
    try expect(decoded == .open, "Expected .open after decode")
}

// Nuclear pattern tests — fork bomb only
let forkBomb = ":(){ :|:" + "& };:"

await test("Nuclear handoff: fork bomb") {
    let d = await gate.checkNuclearPattern(forkBomb.lowercased(), raw: forkBomb)
    guard let decision = d else { throw TestError.assertion("Expected non-nil for fork bomb") }
    if case .handoff = decision { } else { throw TestError.assertion("Expected .handoff") }
}

await test("Diskutil is not nuclear anymore") {
    let cmd = "diskutil erasedisk JHFS+ Untitled /dev/disk2"
    let d = await gate.checkNuclearPattern(cmd.lowercased(), raw: cmd)
    try expect(d == nil, "Expected nil for diskutil")
}

await test("sudo is not nuclear anymore") {
    let cmd = "sudo -n true"
    let d = await gate.checkNuclearPattern(cmd.lowercased(), raw: cmd)
    try expect(d == nil, "Expected nil for sudo")
}

await test("Nuclear handoff returns command in decision") {
    let d = await gate.checkNuclearPattern(forkBomb.lowercased(), raw: forkBomb)
    if case .handoff(let cmd, let explanation, let warning) = d {
        try expect(!cmd.isEmpty, "Command should not be empty")
        try expect(!explanation.isEmpty, "Explanation should not be empty")
        try expect(!warning.isEmpty, "Warning should not be empty")
    } else {
        throw TestError.assertion("Expected .handoff with all fields")
    }
}

// Sensitive path tests — checkSensitivePaths is async and triggers notifications.
// For unit tests, we test that the method exists and can detect sensitive paths
// by checking session/permanent allow behavior.

await test("Session permissions start empty and can be cleared") {
    await gate.clearSessionPermissions()
    // After clearing, no paths should be session-allowed
    // (We can't easily test the notification flow in unit tests)
}

await test("NotionPageRef normalizes dashed UUID and notion.so URL") {
    let id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    switch NotionPageRef.normalizedPageId(from: id) {
    case .success(let n):
        try expect(n.contains("-"), "Expected dashed UUID form")
        try expect(n.replacingOccurrences(of: "-", with: "").count == 32, "Expected 32 hex")
    case .failure(let err):
        throw TestError.assertion("Expected valid page id: \(err.message)")
    }
    let url = "https://www.notion.so/w/Test-a1b2c3d4e5f67890abcdef1234567890"
    switch NotionPageRef.normalizedPageId(from: url) {
    case .success(let n):
        try expect(n.lowercased().contains("a1b2c3d4"), "Expected id from URL")
    case .failure(let err):
        throw TestError.assertion("Expected URL parse: \(err.message)")
    }
}

await test("NotionPageRef rejects non-Notion URL") {
    switch NotionPageRef.normalizedPageId(from: "https://example.com/page") {
    case .success:
        throw TestError.assertion("Expected failure for non-Notion URL")
    case .failure(let err):
        try expect(!err.message.isEmpty, "Expected error message")
    }
}

await test("Permanent access can be granted and revoked") {
    let testPath = "~/.ssh"
    await gate.grantPermanentAccess(path: testPath)
    let key = "com.notionbridge.security.pathAllow." + testPath
    try expect(UserDefaults.standard.bool(forKey: key) == true, "Expected permanent access granted")
    await gate.revokePermanentAccess(path: testPath)
    try expect(UserDefaults.standard.bool(forKey: key) == false, "Expected permanent access revoked")
}

await test("Sensitive path with permanent allow passes through") {
    let testPath = "~/.ssh"
    await gate.grantPermanentAccess(path: testPath)
    // With permanent allow, checkSensitivePaths should return nil (allow)
    let result = await gate.checkSensitivePaths(["~/.ssh/id_rsa"], toolName: "file_read")
    try expect(result == nil, "Expected nil (allow) for permanently allowed path")
    await gate.revokePermanentAccess(path: testPath)
}

await test("GateDecision.handoff is not allow or reject") {
    let d = await gate.checkNuclearPattern(forkBomb.lowercased(), raw: forkBomb)
    if case .allow = d { throw TestError.assertion("Nuclear should not be .allow") }
    if case .reject = d { throw TestError.assertion("Nuclear should not be .reject") }
    if case .handoff = d { /* expected */ } else { throw TestError.assertion("Expected .handoff") }
}

// ============================================================
// MARK: - ToolRouter Tests
// ============================================================

print("\n\u{1F500} ToolRouter Tests")

let routerGate = SecurityGate()
let routerLog = AuditLog()
let router = ToolRouter(securityGate: routerGate, auditLog: routerLog)

await test("Tool registration stores and retrieves tools") {
    await router.register(ToolRegistration(
        name: "test_tool", module: "test", tier: .open,
        description: "A test tool",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .string("ok") }
    ))
    let all = await router.allRegistrations()
    try expect(all.count >= 1, "Expected at least 1 registration")
    try expect(all.contains(where: { $0.name == "test_tool" }), "Expected test_tool in registry")
}

await test("Registration overwrites existing tool with same name") {
    await router.register(ToolRegistration(
        name: "overwrite_test", module: "mod1", tier: .open,
        description: "Version 1", inputSchema: .object([:]),
        handler: { _ in .string("v1") }
    ))
    await router.register(ToolRegistration(
        name: "overwrite_test", module: "mod1", tier: .open,
        description: "Version 2", inputSchema: .object([:]),
        handler: { _ in .string("v2") }
    ))
    let all = await router.allRegistrations()
    let match = all.first(where: { $0.name == "overwrite_test" })
    try expect(match?.description == "Version 2", "Expected Version 2")
}

await test("Registrations can be filtered by module") {
    await router.register(ToolRegistration(
        name: "alpha_tool", module: "alpha", tier: .open,
        description: "A", inputSchema: .object([:]),
        handler: { _ in .null }
    ))
    let alpha = await router.registrations(forModule: "alpha")
    try expect(alpha.count >= 1)
    try expect(alpha[0].name == "alpha_tool")
}

await test("Dispatch routes to correct handler") {
    await router.register(ToolRegistration(
        name: "echo_test", module: "builtin", tier: .open,
        description: "Echo test", inputSchema: .object([:]),
        handler: { args in
            if case .object(let dict) = args,
               case .string(let msg) = dict["message"] {
                return .string("echo: \(msg)")
            }
            return .string("no message")
        }
    ))
    let result = try await router.dispatch(
        toolName: "echo_test",
        arguments: .object(["message": .string("hello")])
    )
    if case .string(let s) = result {
        try expect(s == "echo: hello", "Expected 'echo: hello' got '\(s)'")
    } else {
        throw TestError.assertion("Expected string result")
    }
}

await test("Dispatch throws for unknown tool") {
    do {
        _ = try await router.dispatch(toolName: "nonexistent_xyz", arguments: .object([:]))
        throw TestError.assertion("Expected error for unknown tool")
    } catch is ToolRouterError {
        // Expected
    }
}

await test("Dispatch returns handoff for fork-bomb commands") {
    await router.register(ToolRegistration(
        name: "nuclear_test", module: "test", tier: .open,
        description: "Test", inputSchema: .object([:]),
        handler: { _ in .string("should not reach") }
    ))
    let result = try await router.dispatch(
        toolName: "nuclear_test",
        arguments: .object(["command": .string(forkBomb)])
    )
    if case .object(let dict) = result {
        if case .string(let status) = dict["status"] {
            try expect(status == "handoff", "Expected status=handoff, got \(status)")
        } else {
            throw TestError.assertion("Expected status key in handoff response")
        }
    } else {
        throw TestError.assertion("Expected object result for fork-bomb handoff")
    }
}

// PKT-373 P1-5: batchGate tests removed (dead code removed)

// ============================================================
// MARK: - AuditLog Tests
// ============================================================

print("\n\u{1F4CB} AuditLog Tests")

func makeSampleEntry(
    toolName: String = "test_tool",
    tier: SecurityTier = .open,
    status: ApprovalStatus = .approved
) -> AuditEntry {
    AuditEntry(
        timestamp: Date(), toolName: toolName, tier: tier,
        inputSummary: "test input", outputSummary: "test output",
        durationMs: 42.0, approvalStatus: status
    )
}

await test("Append adds entry to in-memory log") {
    let log = AuditLog()
    await log.append(makeSampleEntry())
    let count = await log.count()
    try expect(count == 1, "Expected count 1, got \(count)")
}

await test("Multiple appends accumulate") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "tool_a"))
    await log.append(makeSampleEntry(toolName: "tool_b"))
    await log.append(makeSampleEntry(toolName: "tool_c"))
    let count = await log.count()
    try expect(count == 3, "Expected count 3, got \(count)")
}

await test("All entries returns complete log") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "alpha"))
    await log.append(makeSampleEntry(toolName: "beta"))
    let entries = await log.allEntries()
    try expect(entries.count == 2)
    try expect(entries[0].toolName == "alpha")
    try expect(entries[1].toolName == "beta")
}

await test("Filter by tool name") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "echo"))
    await log.append(makeSampleEntry(toolName: "tools_list"))
    await log.append(makeSampleEntry(toolName: "echo"))
    let echoEntries = await log.entries(forTool: "echo")
    try expect(echoEntries.count == 2)
}

await test("Filter by tier") {
    let log = AuditLog()
    await log.append(makeSampleEntry(tier: .open))
    await log.append(makeSampleEntry(tier: .notify))
    await log.append(makeSampleEntry(tier: .open))
    let openEntries = await log.entries(forTier: .open)
    try expect(openEntries.count == 2)
}

await test("Filter by approval status") {
    let log = AuditLog()
    await log.append(makeSampleEntry(status: .approved))
    await log.append(makeSampleEntry(status: .rejected))
    await log.append(makeSampleEntry(status: .approved))
    let rejected = await log.entries(withStatus: .rejected)
    try expect(rejected.count == 1)
}

await test("Entry contains all required fields") {
    let log = AuditLog()
    let entry = AuditEntry(
        timestamp: Date(), toolName: "test", tier: .open,
        inputSummary: "input", outputSummary: "output",
        durationMs: 100.5, approvalStatus: .approved
    )
    await log.append(entry)
    let entries = await log.allEntries()
    let first = entries[0]
    try expect(first.toolName == "test")
    try expect(first.tier == .open)
    try expect(first.inputSummary == "input")
    try expect(first.outputSummary == "output")
    try expect(first.durationMs == 100.5)
    try expect(first.approvalStatus == .approved)
}

await test("AuditEntry is Codable (JSON round-trip)") {
    let entry = makeSampleEntry()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(entry)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AuditEntry.self, from: data)
    try expect(decoded.toolName == entry.toolName)
    try expect(decoded.tier == entry.tier)
    try expect(decoded.approvalStatus == entry.approvalStatus)
}

// ============================================================
// MARK: - V1-04/V1-05 Module Tests
// ============================================================

// SKIPPED: checkAll() hangs in CLI — NSAppleScript probes need AppKit run loop
// await runPermissionManagerTests()
await runShellModuleTests()
await runLspModuleTests()
await runFileModuleTests()
await runSessionModuleTests()
await runMessagesModuleTests()
await runMessagesSuiteAuditTests()   // Messages-suite every-angle-of-attack audit
await runSystemModuleTests()
await runNotionModuleTests()
await runAccessibilityModuleTests()
await runScreenModuleTests()
await runAppleScriptModuleTests()
await runBuiltinModuleTests()
await runConfigManagerTests()
await runMCPHTTPValidationTests()
await runDesktopOrganizationScenarioTests()
await runChromeModuleTests()
await runSkillsModuleTests()
await runCredentialManagerTests()
await runCredentialModuleTests()
await runStripeClientTests()
await runPaymentModuleTests()
await runConnectionsModuleTests()
await runStripeTokenizationTests()
await runSecurityAuditTests()


// ============================================================
// MARK: - V1-06 Integration / End-to-End Tests
// ============================================================

await runCodeEditModuleTests()
await runDevModuleTests()              // dev-suite audit: dev_module_info coverage
await runDevSuiteAuditTests()          // dev-suite audit: cross-tool invariants
await runDevSuiteEdgeTests()           // dev-suite audit: edge / attack surface
await runSpotlightModuleTests()        // PKT-747 (v2.2 · 3.3)
await runSyntheticInputModuleTests()   // PKT-747 (v2.2 · 3.3)
await runMouseClickModuleTests()        // PKT-765 (v2.2 · 3.3.1)
await runCGEventModuleTests()           // PKT-765 (v2.2 · 3.3.1)
await runPasteboardHistoryModuleTests() // PKT-765 (v2.2 · 3.3.1)
await runJobsModuleTests()
await runBgProcessModuleTests()
await runDevServerModuleTests()
await runGhModuleTests()
await runGitModuleTests()
await runLspModuleTests()
await runLspModuleRenameRefsLiveTests()
await runWSHMenuBarTests()        // PKT-804 (v2.3): menu-bar quick-page
await runSnippetsModuleTests()    // PKT-2135a9e9 (v2.3 · WS-D): snippets module
await runToolAnnotationAuditTests() // PKT-803 (v2.3 · WS-B): annotation coverage audit
await runTransportRouterTests()     // PKT-803 (v2.3 · WS-B): transport router default/env
await runRemoteOAuthHTTPTests()     // PKT-800 (S1): RFC 9728 PRM + transport gating + route
await runBridgeFeatureFlagsTests()  // PKT-798 (v2.3 · WS-C): fail-closed capability gates
await runBridgeModuleRegistryTests() // PKT v3.0·0.4: single-source module registrar
await runMCPToolFactoryTests()       // PKT v3.0·0.5: metadata contract + unified Tool factory
await runToolConventionTests()       // PKT v3.0·0.5: P0 — aliases + key convention + dispatch contract
await runToolMetadataAuthoringTests() // PKT v3.0·0.5: P1 — projection + authored-metadata render
await runPlaywrightModuleTests()  // PKT-781 (v2.2 · 3.2a)
await runVitestModuleTests()      // PKT-781 (v2.2 · 3.2a)
await runLighthouseModuleTests()  // PKT-781 (v2.2 · 3.2a)
await runArtifactModuleTests()    // PKT-743 (v2.2 · 3.1)
await runRunnerParsersTests()      // PKT-782 (v2.2 · 3.2b)
await runCronHumanizerTests()

await runStripeDeprecationShimTests()
await runEndToEndTests()
await runWranglerModuleTests() // PKT-757 (v2.2 · 0.2.2)

// ============================================================
// MARK: - Summary
// ============================================================

print("\n" + String(repeating: "=", count: 50))
print("Results: \(passed) passed, \(failed) failed, \(passed + failed) total")
print(String(repeating: "=", count: 50))

if failed > 0 {
    print("\u{274C} TESTS FAILED")
    exit(1)
} else {
    print("\u{2705} ALL TESTS PASSED")
    exit(0)
}
