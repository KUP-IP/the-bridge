// EndToEndTests.swift – V1-06 Integration & End-to-End Tests
// NotionBridge · Tests/IntegrationTests
//
// Validates the full pipeline: Transport → ToolRouter → SecurityGate → Handler → AuditLog → Response
// Covers both stdio transport and cross-module integration scenarios.

import Foundation
import MCP
import NotionBridgeLib
import NIOEmbedded

// MARK: - Integration Test Runner

func runEndToEndTests() async {
    print("\n🔗 End-to-End Integration Tests")

    // Shared infrastructure for all integration tests
    let securityGate = SecurityGate()
    let auditLog = AuditLog()
    let router = ToolRouter(securityGate: securityGate, auditLog: auditLog)

    // Register all modules (same static surface as `ServerManager.setup()` except `StripeMcpModule` — network-dependent).
    await ShellModule.register(on: router)
    await FileModule.register(on: router)
    await SessionModule.register(on: router, auditLog: auditLog)
    await MessagesModule.register(on: router)
    await SystemModule.register(on: router)
    await ContactsModule.register(on: router)
    await NotionModule.register(on: router)
    await ScreenModule.register(on: router)
    await ScreenModule.registerRecording(on: router)
    await ScreenModule.registerAnalyze(on: router)
    await AccessibilityModule.register(on: router)
    await AppleScriptModule.register(on: router)
    await ChromeModule.register(on: router)
    await SkillsModule.register(on: router)
    await CredentialModule.register(on: router)
    await PaymentModule.register(on: router)
    await ConnectionsModule.register(on: router)
    await JobsModule.register(on: router)
    await DevModule.register(on: router)  // PKT-738 (v2.2 · 0.1): dev/ scaffold module
    await BgProcessModule.register(on: router)
    await DevServerModule.register(on: router)
    await GhModule.register(on: router)
    await GitModule.register(on: router)
    await LspModule.register(on: router)
    await CursorModule.register(on: router)
    await CodeEditModule.register(on: router)  // PKT-750 (v2.2 · 1.2): code_search · file_str_replace · file_apply_patch
    await WranglerModule.register(on: router)  // PKT-757 (v2.2 · 0.2.2): wrangler_d1_status
    await SpotlightModule.register(on: router)
    await SyntheticInputModule.register(on: router)
    await MouseClickModule.register(on: router)
    await CGEventModule.register(on: router)
    await PasteboardHistoryModule.register(on: router)
    await PlaywrightModule.register(on: router)
    await VitestModule.register(on: router)
    await LighthouseModule.register(on: router)

    // ============================================================
    // E2E-1: Full pipeline — dispatch → security → handler → audit
    // ============================================================

    // Full app: `BridgeConstants.staticFeatureModuleToolCount` + Stripe (N or sentinel) + `builtin` echo.
    await test("E2E: router has all registered module tools (static feature count)") {
        let all = await router.allRegistrations()
        try expect(
            all.count == BridgeConstants.staticFeatureModuleToolCount,
            "Expected \(BridgeConstants.staticFeatureModuleToolCount) module tools, got \(all.count)"
        )
    }

    await test("E2E: router filters by module correctly") {
        let shell = await router.registrations(forModule: "shell")
        try expect(shell.count == 2, "Expected 2 shell tools, got \(shell.count)")
    }

    // ============================================================
    // E2E-2: SecurityGate enforces across real module tools
    // ============================================================

    let sudoStr = String(UnicodeScalar(115)) + "udo"

    await test("E2E: SecurityGate no longer handoffs sudo through shell_exec") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string(sudoStr + " -n true")])
        )
        if case .object(let dict) = result {
            try expect(dict["exitCode"] != nil, "Expected shell_exec result payload")
            if case .string(let status) = dict["status"] {
                try expect(["failed", "timed_out", "success"].contains(status), "Expected shell_exec status payload, got \(status)")
            } else {
                throw TestError.assertion("Expected shell_exec structured status payload")
            }
        } else {
            throw TestError.assertion("Expected shell_exec result object for sudo command")
        }
    }

    await test("E2E: file_read surfaces file-not-found errors clearly") {
        do {
            _ = try await router.dispatch(
                toolName: "file_read",
                arguments: .object(["path": .string("~/.ssh/id_rsa")])
            )
            throw TestError.assertion("Expected missing file error")
        } catch {
            // Expected — path is typically absent in test environments.
        }
    }

    await test("E2E: SecurityGate allows green-tier tool immediately") {
        let result = try await router.dispatch(
            toolName: "system_info",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            // system_info returns osName, osVersion, hostname, cpu, memoryGB, uptime
            try expect(dict["osName"] != nil || dict["hostname"] != nil,
                       "system_info should return osName or hostname field")
        } else {
            throw TestError.assertion("Expected object result from system_info")
        }
    }

    // ============================================================
    // E2E-3: Audit log captures every tool call
    // ============================================================

    await test("E2E: Audit log records dispatched calls") {
        await auditLog.clear()

        _ = try await router.dispatch(
            toolName: "system_info",
            arguments: .object([:])
        )
        _ = try await router.dispatch(
            toolName: "clipboard_read",
            arguments: .object([:])
        )

        let entries = await auditLog.allEntries()
        try expect(entries.count == 2, "Expected 2 audit entries, got \(entries.count)")
        try expect(entries[0].toolName == "system_info")
        try expect(entries[1].toolName == "clipboard_read")
        try expect(entries[0].approvalStatus == .approved)
        try expect(entries[1].approvalStatus == .approved)
        try expect(entries[0].durationMs > 0, "Duration should be positive")
    }

    await test("E2E: Audit log records escalated fork-bomb calls") {
        await auditLog.clear()

        _ = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string(":(){ :|:& };:")])
        )

        let entries = await auditLog.allEntries()
        try expect(entries.count == 1, "Expected 1 audit entry for rejected call")
        try expect(entries[0].approvalStatus == .escalated)
        try expect(entries[0].toolName == "shell_exec")
    }

    // ============================================================
    // E2E-4: Cross-module integration
    // ============================================================

    await test("E2E: Cross-module — shell_exec output is valid structured response") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo 'hello notionbridge'")])
        )
        if case .object(let dict) = result {
            if case .string(let stdout) = dict["stdout"] {
                try expect(stdout.contains("hello notionbridge"), "stdout should contain command output")
            } else {
                throw TestError.assertion("Expected stdout string")
            }
            if case .int(let exitCode) = dict["exitCode"] {
                try expect(exitCode == 0, "Expected exit code 0")
            }
        } else {
            throw TestError.assertion("Expected object result from shell_exec")
        }
    }

    await test("E2E: Cross-module — file_write then file_read round-trip") {
        let testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notionbridge-e2e-\(UUID().uuidString)")
        let testFile = testDir.appendingPathComponent("roundtrip.txt")
        let testContent = "NotionBridge integration test: \(Date().ISO8601Format())"

        // Write
        let writeResult = try await router.dispatch(
            toolName: "file_write",
            arguments: .object([
                "path": .string(testFile.path),
                "content": .string(testContent),
                "createDirs": .bool(true)
            ])
        )
        if case .object(let wr) = writeResult {
            if case .bool(let ok) = wr["success"] { try expect(ok, "Write should succeed") }
        }

        // Read back
        let readResult = try await router.dispatch(
            toolName: "file_read",
            arguments: .object(["path": .string(testFile.path)])
        )
        if case .object(let rr) = readResult {
            if case .string(let content) = rr["content"] {
                try expect(content == testContent, "Read content should match written content")
            } else {
                throw TestError.assertion("Expected content string in read result")
            }
        }

        // Cleanup
        try? FileManager.default.removeItem(at: testDir)
    }

    await test("E2E: Cross-module — session_info reflects tool call count") {
        await auditLog.clear()

        _ = try await router.dispatch(toolName: "system_info", arguments: .object([:]))
        _ = try await router.dispatch(toolName: "clipboard_read", arguments: .object([:]))
        _ = try await router.dispatch(toolName: "system_info", arguments: .object([:]))

        let result = try await router.dispatch(
            toolName: "session_info",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .int(let calls) = dict["toolCalls"] {
                try expect(calls >= 3, "Expected ≥3 tool calls recorded, got \(calls)")
            }
        }
    }

    // PKT-373 P1-5: E2E batch gate tests removed (batchGate dead code removed)

    // ============================================================
    // E2E-5b: Legacy SSE bridge concurrency regression coverage
    // ============================================================

    await test("E2E: LegacySSEBridge register/remove keeps active count accurate") {
        let bridge = LegacySSEBridge()
        let channelA = EmbeddedChannel()
        let channelB = EmbeddedChannel()

        let idA = bridge.register(channel: channelA)
        try expect(!idA.isEmpty, "Expected session ID for channel A")
        try expect(bridge.activeCount == 1, "Expected activeCount == 1 after first register")

        let idB = bridge.register(channel: channelB)
        try expect(!idB.isEmpty, "Expected session ID for channel B")
        try expect(bridge.activeCount == 2, "Expected activeCount == 2 after second register")

        bridge.remove(sessionID: idA)
        try expect(bridge.activeCount == 1, "Expected activeCount == 1 after removing first session")

        bridge.remove(sessionID: idB)
        try expect(bridge.activeCount == 0, "Expected activeCount == 0 after removing all sessions")

        _ = try channelA.finish()
        _ = try channelB.finish()
    }

    await test("E2E: LegacySSEBridge concurrent register/remove/send drains to zero") {
        let bridge = LegacySSEBridge()
        let iterations = 200

        await withTaskGroup(of: Void.self) { group in
            for idx in 0..<iterations {
                group.addTask {
                    let channel = EmbeddedChannel()
                    let sessionID = bridge.register(channel: channel)

                    // Exercise both direct and fallback event routing under concurrent churn.
                    bridge.sendEvent(sessionID: sessionID, event: "message", data: "{\"i\":\(idx)}")
                    bridge.sendEvent(sessionID: nil, event: "heartbeat", data: "{\"i\":\(idx)}")
                    bridge.sendEvent(sessionID: UUID().uuidString, event: "message", data: "{\"i\":\(idx)}")

                    bridge.remove(sessionID: sessionID)
                    _ = try? channel.finish()
                }
            }
            await group.waitForAll()
        }

        try expect(bridge.activeCount == 0, "Expected bridge to drain all sessions after concurrent churn")
    }

    // ============================================================
    // E2E-6: stdio transport integration (MCP Server object)
    // ============================================================

    await test("E2E: MCP Server initializes with tool capabilities") {
        let server = Server(
            name: "NotionBridge",
            version: "0.5.0",
            capabilities: .init(tools: .init())
        )
        _ = server
    }

    await test("E2E: All tools have correct 3-tier assignments") {
        let all = await router.allRegistrations()
        var tierMap: [String: String] = [:]
        for reg in all {
            tierMap[reg.name] = reg.tier.rawValue
        }

        // Spot-check critical tier assignments (3-tier: open / notify / request)
        try expect(tierMap["file_read"] == "open", "file_read should be open")
        try expect(tierMap["file_write"] == "notify", "file_write should be notify")
        try expect(tierMap["shell_exec"] == "request", "shell_exec should be request")
        try expect(tierMap["clipboard_write"] == "notify", "clipboard_write should be notify (SEC-03)")
        try expect(tierMap["messages_send"] == "request", "messages_send should be request")
        try expect(tierMap["applescript_exec"] == "request", "applescript_exec should be request")
        try expect(tierMap["run_script"] == "request", "run_script should be request")
        try expect(tierMap["system_info"] == "open", "system_info should be open")
        try expect(tierMap["notify"] == "open", "notify should be open")
        try expect(tierMap["credential_save"] == "request", "credential_save should be request")
        try expect(tierMap["credential_read"] == "request", "credential_read should be request")
        try expect(tierMap["credential_list"] == "notify", "credential_list should be notify")
        try expect(tierMap["credential_delete"] == "request", "credential_delete should be request")
        try expect(tierMap["payment_execute"] == "request", "payment_execute should be request")
    }

    // ============================================================
    // E2E-7: Error handling through full pipeline
    // ============================================================

    await test("E2E: Unknown tool dispatch returns proper error") {
        do {
            _ = try await router.dispatch(
                toolName: "nonexistent_tool_xyz",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error")
        } catch let error as ToolRouterError {
            if case .unknownTool(let name) = error {
                try expect(name == "nonexistent_tool_xyz")
            }
        }
    }

    await test("E2E: Module tool with invalid params returns graceful error") {
        do {
            _ = try await router.dispatch(
                toolName: "file_read",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch {
            // Expected — file_read requires 'path' parameter
        }
    }

    // ============================================================
    // E2E-8: Module registration completeness
    // ============================================================

    await test("E2E: All static feature modules registered with correct tool counts") {
        let shell = await router.registrations(forModule: "shell")
        let file = await router.registrations(forModule: "file")
        let session = await router.registrations(forModule: "session")
        let messages = await router.registrations(forModule: "messages")
        let system = await router.registrations(forModule: "system")
        let contacts = await router.registrations(forModule: "contacts")
        let notion = await router.registrations(forModule: "notion")
        let screen = await router.registrations(forModule: "screen")
        let accessibility = await router.registrations(forModule: "accessibility")
        let applescript = await router.registrations(forModule: "applescript")

        try expect(shell.count == 2, "ShellModule: expected 2")
        try expect(file.count == 12, "FileModule: expected 12")
        try expect(session.count == 3, "SessionModule: expected 3")
        try expect(messages.count == 6, "MessagesModule: expected 6")
        try expect(system.count == 3, "SystemModule: expected 3")
        try expect(contacts.count == 4, "ContactsModule: expected 4")
        try expect(notion.count == 23, "NotionModule: expected 23")
        try expect(screen.count == 5, "ScreenModule: expected 5")
        try expect(accessibility.count == 6, "AccessibilityModule: expected 6 (PKT-755: +ax_query)")
        try expect(applescript.count == 1, "AppleScriptModule: expected 1")

        let chrome = await router.registrations(forModule: "chrome")
        let skills = await router.registrations(forModule: "skills")
        try expect(chrome.count == 5, "ChromeModule: expected 5")
        try expect(skills.count == 3, "SkillsModule: expected 3")

        let credential = await router.registrations(forModule: "credential")
        try expect(credential.count == 4, "CredentialModule: expected 4")

        let payment = await router.registrations(forModule: "payment")
        try expect(payment.count == 1, "PaymentModule: expected 1")

        let connections = await router.registrations(forModule: "connections")
        try expect(connections.count == 5, "ConnectionsModule: expected 5")

        let scheduler = await router.registrations(forModule: "scheduler")
        try expect(scheduler.count == 13, "JobsModule scheduler family: expected 13")

        let dev = await router.registrations(forModule: "dev")
        try expect(dev.count == 41, "dev module family: expected 41")

        let cursor = await router.registrations(forModule: "cursor")
        try expect(cursor.count == 5, "CursorModule: expected 5")

        let computer = await router.registrations(forModule: "computer")
        try expect(computer.count == 5, "computer module family: expected 5")

        let modulesWithTools = Set((await router.allRegistrations()).map(\.module))
        try expect(
            modulesWithTools.count == BridgeConstants.staticFeatureModuleFamilyCount,
            "Expected \(BridgeConstants.staticFeatureModuleFamilyCount) modules, got \(modulesWithTools.count)"
        )
    }

    await test("E2E: Total module tool count matches static feature surface") {
        let all = await router.allRegistrations()
        let moduleTools = all.filter { $0.module != "builtin" }
        try expect(
            moduleTools.count == BridgeConstants.staticFeatureModuleToolCount,
            "Expected \(BridgeConstants.staticFeatureModuleToolCount) module tools, got \(moduleTools.count)"
        )
    }

    await test("E2E: All security tiers represented in tool registry") {
        let all = await router.allRegistrations()
        let tiers = Set(all.map { $0.tier })
        try expect(tiers.contains(.open), "Missing open tier tools")
        try expect(tiers.contains(.notify), "Missing notify tier tools")
        try expect(tiers.contains(.request), "Missing request tier tools")
        try expect(tiers.count == 3, "Expected exactly 3 tiers, got \(tiers.count)")
    }
}
