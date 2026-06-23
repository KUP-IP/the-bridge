// SessionModuleTests.swift – V1-04 SessionModule Tests
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

// MARK: - SessionModule Tests

func runSessionModuleTests() async {
    print("\n🔧 SessionModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await SessionModule.register(
        on: router,
        auditLog: log,
        diagnosticsProvider: { SessionModule.RuntimeDiagnostics(connections: 2, activeClients: 3) }
    )

    // Registration
    await test("SessionModule registers 3 tools") {
        let tools = await router.registrations(forModule: "session")
        try expect(tools.count == 3, "Expected 3 session tools, got \(tools.count)")
    }

    await test("SessionModule tool names match spec") {
        let tools = await router.registrations(forModule: "session")
        let names = Set(tools.map(\.name))
        try expect(names.contains("tools_list"), "Missing tools_list")
        try expect(names.contains("session_info"), "Missing session_info")
        try expect(names.contains("session_clear"), "Missing session_clear")
    }

    // Tier verification
    await test("SessionModule tiers match spec") {
        let tools = await router.registrations(forModule: "session")
        let tierMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.tier) })
        try expect(tierMap["tools_list"] == .open, "tools_list should be green")
        try expect(tierMap["session_info"] == .open, "session_info should be green")
        try expect(tierMap["session_clear"] == .notify, "session_clear should be orange")
    }

    // tools_list: returns all tools
    await test("tools_list returns all registered tools") {
        let result = try await router.dispatch(
            toolName: "tools_list",
            arguments: .object([:])
        )
        if case .array(let tools) = result {
            try expect(tools.count == 3, "Expected 3 tools from session-only router, got \(tools.count)")
        } else {
            throw TestError.assertion("Expected array result from tools_list")
        }
    }

    // tools_list: module filter
    await test("tools_list filters by module") {
        // Register a tool from another module to test filtering
        await router.register(ToolRegistration(
            name: "other_tool", module: "other", tier: .open,
            description: "A tool from another module",
            inputSchema: .object([:]),
            handler: { _ in .null }
        ))

        let result = try await router.dispatch(
            toolName: "tools_list",
            arguments: .object(["module": .string("session")])
        )
        if case .array(let tools) = result {
            try expect(tools.count == 3, "Module filter should return only session tools, got \(tools.count)")
            for tool in tools {
                if case .object(let dict) = tool,
                   case .string(let mod) = dict["module"] {
                    try expect(mod == "session", "All returned tools should be session module, got \(mod)")
                }
            }
        } else {
            throw TestError.assertion("Expected array result")
        }
    }

    // tools_list: tool entry format
    await test("tools_list entries contain required fields") {
        let result = try await router.dispatch(
            toolName: "tools_list",
            arguments: .object(["module": .string("session")])
        )
        if case .array(let tools) = result, let first = tools.first,
           case .object(let dict) = first {
            try expect(dict["name"] != nil, "Missing 'name' field")
            try expect(dict["module"] != nil, "Missing 'module' field")
            try expect(dict["tier"] != nil, "Missing 'tier' field")
            try expect(dict["description"] != nil, "Missing 'description' field")
            try expect(dict["inputs"] != nil, "Missing 'inputs' field")
        } else {
            throw TestError.assertion("Expected non-empty array of objects")
        }
    }

    // session_info: returns expected fields
    await test("session_info returns uptime and audit log size") {
        let result = try await router.dispatch(
            toolName: "session_info",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            try expect(dict["uptime"] != nil, "Missing uptime")
            try expect(dict["uptimeSeconds"] != nil, "Missing uptimeSeconds")
            try expect(dict["connections"] != nil, "Missing connections")
            try expect(dict["toolCalls"] != nil, "Missing toolCalls")
            try expect(dict["activeClients"] != nil, "Missing activeClients")
            try expect(dict["auditLogSize"] != nil, "Missing auditLogSize")
        } else {
            throw TestError.assertion("Expected object result from session_info")
        }
    }

    // session_info: uptime is positive
    await test("session_info uptime is positive") {
        let result = try await router.dispatch(
            toolName: "session_info",
            arguments: .object([:])
        )
        if case .object(let dict) = result,
           case .double(let uptime) = dict["uptimeSeconds"] {
            try expect(uptime >= 0, "Uptime should be non-negative, got \(uptime)")
        } else {
            throw TestError.assertion("Expected uptimeSeconds field")
        }
    }

    // session_info: diagnostics provider values
    await test("session_info reflects injected runtime diagnostics") {
        let result = try await router.dispatch(
            toolName: "session_info",
            arguments: .object([:])
        )
        if case .object(let dict) = result,
           case .int(let connections) = dict["connections"],
           case .int(let activeClients) = dict["activeClients"] {
            try expect(connections == 2, "Connections should match diagnostics provider, got \(connections)")
            try expect(activeClients == 3, "Active clients should match diagnostics provider, got \(activeClients)")
        } else {
            throw TestError.assertion("Expected connections and activeClients fields")
        }
    }

    // session_clear: requires confirm = true
    await test("session_clear rejects without confirm") {
        let result = try await router.dispatch(
            toolName: "session_clear",
            arguments: .object([:])
        )
        if case .object(let dict) = result,
           case .bool(let cleared) = dict["cleared"] {
            try expect(cleared == false, "Should not clear without confirm")
        } else {
            throw TestError.assertion("Expected cleared: false")
        }
    }

    // session_clear: rejects confirm = false
    await test("session_clear rejects confirm: false") {
        let result = try await router.dispatch(
            toolName: "session_clear",
            arguments: .object(["confirm": .bool(false)])
        )
        if case .object(let dict) = result,
           case .bool(let cleared) = dict["cleared"] {
            try expect(cleared == false, "Should not clear with confirm=false")
        } else {
            throw TestError.assertion("Expected cleared: false")
        }
    }

    // session_clear: actually clears with confirm = true
    await test("session_clear clears audit log when confirmed") {
        // Add some entries first
        await log.append(AuditEntry(
            timestamp: Date(), toolName: "test", tier: .open,
            inputSummary: "", outputSummary: "",
            durationMs: 1.0, approvalStatus: .approved
        ))
        let beforeCount = await log.count()
        try expect(beforeCount > 0, "Should have entries before clear")

        let result = try await router.dispatch(
            toolName: "session_clear",
            arguments: .object(["confirm": .bool(true)])
        )
        if case .object(let dict) = result,
           case .bool(let cleared) = dict["cleared"] {
            try expect(cleared == true, "Should clear with confirm=true")
        } else {
            throw TestError.assertion("Expected cleared: true")
        }

        let afterCount = await log.count()
        try expect(afterCount <= 1, "Audit log should be 0 or 1 after clear (session_clear itself gets logged), got \(afterCount)")
    }

    // session_clear: returns previous uptime
    await test("session_clear returns previous uptime seconds") {
        let result = try await router.dispatch(
            toolName: "session_clear",
            arguments: .object(["confirm": .bool(true)])
        )
        if case .object(let dict) = result,
           case .double(let prevUptime) = dict["previousUptimeSeconds"] {
            try expect(prevUptime >= 0, "Previous uptime should be non-negative")
        } else {
            throw TestError.assertion("Expected previousUptimeSeconds field")
        }
    }
}
