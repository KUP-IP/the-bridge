// SessionModuleTests.swift – V1-04 SessionModule Tests
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

// MARK: - SessionModule Tests

func runSessionModuleTests() async {
    print("\n🔧 SessionModule Tests")

    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await SessionModule.register(
        on: router,
        auditLog: log,
        diagnosticsProvider: { SessionModule.RuntimeDiagnostics(connections: 2, activeClients: 3) }
    )

    // Registration
    await test("SessionModule registers 5 tools") {
        let tools = await router.registrations(forModule: "session")
        try expect(tools.count == 5, "Expected 5 session tools, got \(tools.count)")
    }

    await test("SessionModule tool names match spec") {
        let tools = await router.registrations(forModule: "session")
        let names = Set(tools.map(\.name))
        try expect(names.contains("tools_list"), "Missing tools_list")
        try expect(names.contains("tools_search"), "Missing tools_search")
        try expect(names.contains("session_info"), "Missing session_info")
        try expect(names.contains("audit_recent"), "Missing audit_recent")
        try expect(names.contains("session_clear"), "Missing session_clear")
    }

    // Tier verification
    await test("SessionModule tiers match spec") {
        let tools = await router.registrations(forModule: "session")
        let tierMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.tier) })
        try expect(tierMap["tools_list"] == .open, "tools_list should be green")
        try expect(tierMap["tools_search"] == .open, "tools_search should be green")
        try expect(tierMap["session_info"] == .open, "session_info should be green")
        try expect(tierMap["audit_recent"] == .open, "audit_recent should be green")
        try expect(tierMap["session_clear"] == .notify, "session_clear should be orange")
    }

    // tools_list: returns all tools
    await test("tools_list returns all registered tools") {
        let result = try await router.dispatch(
            toolName: "tools_list",
            arguments: .object([:])
        )
        if case .array(let tools) = result {
            try expect(tools.count == 5, "Expected 5 tools from session-only router, got \(tools.count)")
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
            try expect(tools.count == 5, "Module filter should return only session tools, got \(tools.count)")
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
            try expect(dict["title"] != nil, "Missing rendered 'title' field")
            try expect(dict["inputSchema"] != nil, "Missing complete exposed 'inputSchema' field")
        } else {
            throw TestError.assertion("Expected non-empty array of objects")
        }
    }

    await test("tools_search ranks a name match, respects module, and bounds output") {
        await router.register(ToolRegistration(
            name: "ranked_schema_tool",
            module: "discovery",
            tier: .open,
            description: "Fixture used to verify ranked schema discovery.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("inspect"), .string("apply")]),
                        "description": .string("Fixture mode with an enum.")
                    ])
                ]),
                "required": .array([.string("mode")])
            ]),
            metadata: ToolMetadata(
                title: "Ranked Schema Fixture",
                whenToUse: ["Verify bounded tool discovery."],
                relatedTools: ["tools_list"]
            ),
            handler: { _ in .null }
        ))
        await router.register(ToolRegistration(
            name: "description_only_fixture",
            module: "discovery",
            tier: .open,
            description: "A schema-related fixture that should rank below a name match.",
            inputSchema: .object([:]),
            handler: { _ in .null }
        ))

        let result = try await router.dispatch(
            toolName: "tools_search",
            arguments: .object([
                "query": .string("ranked schema"),
                "module": .string("DISCOVERY"),
                "limit": .int(1)
            ])
        )
        guard case .object(let object) = result,
              case .int(let count) = object["count"],
              case .array(let matches) = object["matches"],
              case .object(let first)? = matches.first,
              case .string(let name)? = first["name"] else {
            throw TestError.assertion("Expected ranked tools_search result, got \(result)")
        }
        try expect(count == 1 && matches.count == 1, "limit must bound results")
        try expect(name == "ranked_schema_tool", "name match should rank first, got \(name)")
        try expect(first["matchReasons"] != nil, "search result should explain its match")
    }

    await test("tools_search select returns the exact exposed schema and safe miss") {
        let found = try await router.dispatch(
            toolName: "tools_search",
            arguments: .object(["query": .string("select:RANKED_SCHEMA_TOOL")])
        )
        guard case .object(let object) = found,
              object["found"] == .bool(true),
              case .object(let tool) = object["tool"],
              case .string(let toolName) = tool["name"],
              case .object(let schema) = tool["inputSchema"],
              case .object(let properties) = schema["properties"],
              case .object(let mode) = properties["mode"] else {
            throw TestError.assertion("Expected exact tools_search selection, got \(found)")
        }
        try expect(toolName == "ranked_schema_tool", "select should be case-insensitive")
        try expect(mode["enum"] != nil, "selection must preserve schema enum detail")
        try expect(tool["selection"] != nil, "selection metadata should be available for exact lookup")

        let missing = try await router.dispatch(
            toolName: "tools_search",
            arguments: .object(["select": .string("not_a_real_tool")])
        )
        guard case .object(let missingObject) = missing else {
            throw TestError.assertion("Expected safe not-found object, got \(missing)")
        }
        try expect(missingObject["found"] == .bool(false), "unknown selection should be a safe miss")
        try expect(missingObject["error"] == nil, "unknown selection should not fabricate a tool error")
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

    // session_info: PKT-1065B explicit per-field scopes
    await test("session_info includes explicit field scopes") {
        let result = try await router.dispatch(
            toolName: "session_info",
            arguments: .object([:])
        )
        guard case .object(let dict) = result,
              case .object(let scopes) = dict["scopes"] else {
            throw TestError.assertion("Expected a 'scopes' object in session_info")
        }
        for key in ["uptimeSeconds", "connections", "activeClients", "toolCalls", "auditLogSize", "note"] {
            try expect(scopes[key] != nil, "Missing scope documentation for '\(key)'")
        }
        // The scope note must explicitly disclaim conflict with bridge_status.
        if case .string(let activeScope) = scopes["activeClients"] {
            try expect(activeScope.contains("bridge_status"),
                       "activeClients scope should reference bridge_status to explain the non-conflict")
        } else {
            throw TestError.assertion("activeClients scope should be a string")
        }
    }

    // session_info: with NO diagnostics provider, network client counts are 0
    // (not a fabricated 1) — a stdio-only caller is legitimately 0 clients.
    await test("session_info reports 0 clients when no diagnostics provider is wired") {
        let localGate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let localLog = AuditLog()
        let localRouter = ToolRouter(securityGate: localGate, auditLog: localLog)
        await SessionModule.register(on: localRouter, auditLog: localLog)
        let result = try await localRouter.dispatch(
            toolName: "session_info",
            arguments: .object([:])
        )
        guard case .object(let dict) = result,
              case .int(let connections) = dict["connections"],
              case .int(let activeClients) = dict["activeClients"] else {
            throw TestError.assertion("Expected connections and activeClients ints")
        }
        try expect(connections == 0, "Expected 0 connections with no provider, got \(connections)")
        try expect(activeClients == 0, "Expected 0 activeClients with no provider, got \(activeClients)")
    }

    // audit_recent: read-only refusal trail with composable filters and no
    // caller input echo. Use a dedicated log/router so existing test traffic
    // cannot obscure ordering or filter assertions.
    await test("audit_recent returns newest entries and composes tool/status/tier filters") {
        let auditGate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let auditLog = AuditLog()
        let auditRouter = ToolRouter(securityGate: auditGate, auditLog: auditLog)
        await SessionModule.register(on: auditRouter, auditLog: auditLog)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await auditLog.append(AuditEntry(
            timestamp: base, toolName: "shell_exec", tier: .request,
            inputSummary: "secret-old", outputSummary: "denied-old",
            durationMs: 2, approvalStatus: .rejected,
            origin: .remote, transportSessionId: "session-old"))
        await auditLog.append(AuditEntry(
            timestamp: base.addingTimeInterval(1), toolName: "shell_exec", tier: .request,
            inputSummary: "secret-new", outputSummary: "denied-new",
            durationMs: 3, approvalStatus: .rejected,
            origin: .local, transportSessionId: "session-new"))
        await auditLog.append(AuditEntry(
            timestamp: base.addingTimeInterval(2), toolName: "shell_exec", tier: .request,
            inputSummary: "approved-input", outputSummary: "approved-output",
            durationMs: 4, approvalStatus: .approved))

        let result = try await auditRouter.dispatch(
            toolName: "audit_recent",
            arguments: .object([
                "tool": .string("shell_exec"),
                "status": .string("rejected"),
                "tier": .string("request"),
                "limit": .int(1)
            ]))
        guard case .object(let object) = result,
              case .array(let entries) = object["entries"], entries.count == 1,
              case .object(let newest) = entries[0] else {
            throw TestError.assertion("Expected one filtered audit entry, got \(result)")
        }
        try expect(newest["outputSummary"] == .string("denied-new"), "newest matching entry must win")
        try expect(newest["origin"] == .string("local"), "origin must be projected")
        try expect(newest["transportSessionId"] == .string("session-new"), "transport session id must be projected")
        try expect(newest["inputSummary"] == nil, "audit_recent must never expose inputSummary")
        try expect(object["inputSummaryIncluded"] == .bool(false), "response must declare input omission")
    }

    await test("audit_recent redacts credential summaries and omits secret-bearing fields") {
        let secret = "sk-proj-super-secret-value"
        let entry = AuditEntry(
            timestamp: Date(), toolName: "credential_read", tier: .request,
            inputSummary: secret, outputSummary: secret,
            durationMs: 1, approvalStatus: .approved,
            governed: true, origin: .remote,
            transportSessionId: "remote-credential-session",
            governanceNote: secret)
        let value = SessionModule.auditEntryValue(entry)
        guard case .object(let object) = value else {
            throw TestError.assertion("Expected audit projection object")
        }
        try expect(object["inputSummary"] == nil, "credential input summary must be omitted")
        try expect(object["governanceNote"] == nil, "governance note must be omitted")
        try expect(object["outputSummary"] == .string("<redacted: credential tool>"),
                   "credential output summary must be redacted")
        let encoded = String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? ""
        try expect(!encoded.contains(secret), "serialized audit projection must not contain credential material")
    }

    await test("audit_recent validates filter enums and clamps limit") {
        let invalid = try await router.dispatch(
            toolName: "audit_recent",
            arguments: .object(["status": .string("nope")]))
        guard case .object(let invalidObject) = invalid,
              case .string = invalidObject["error"] else {
            throw TestError.assertion("invalid status must return a structured error")
        }
        let clamped = try await router.dispatch(
            toolName: "audit_recent",
            arguments: .object(["limit": .int(10_000)]))
        guard case .object(let clampedObject) = clamped else {
            throw TestError.assertion("clamped response must be an object")
        }
        try expect(clampedObject["limit"] == .int(SessionModule.auditRecentMaximumLimit),
                   "limit must clamp to the documented maximum")
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

    // session_info: uptime is tracked per-registration (server-boot time), NOT
    // shared process-wide state initialized on first tool call. Regression
    // guard for a bug where `sessionStartTime` was a lazily-initialized
    // `static let` only touched inside the handler closures: two independent
    // registrations would silently share one epoch (whichever registration's
    // session_info was called first), so uptime measured "time since first
    // call" instead of "time since this server instance booted".
    await test("independent registrations track independent start times") {
        let gateA = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let logA = AuditLog()
        let routerA = ToolRouter(securityGate: gateA, auditLog: logA)
        await SessionModule.register(on: routerA, auditLog: logA)

        try await Task.sleep(nanoseconds: 300_000_000) // 300ms

        let gateB = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let logB = AuditLog()
        let routerB = ToolRouter(securityGate: gateB, auditLog: logB)
        await SessionModule.register(on: routerB, auditLog: logB)

        let resultA = try await routerA.dispatch(toolName: "session_info", arguments: .object([:]))
        let resultB = try await routerB.dispatch(toolName: "session_info", arguments: .object([:]))

        guard case .object(let dictA) = resultA, case .double(let uptimeA) = dictA["uptimeSeconds"],
              case .object(let dictB) = resultB, case .double(let uptimeB) = dictB["uptimeSeconds"] else {
            throw TestError.assertion("Expected uptimeSeconds on both routers' session_info")
        }

        // Router A was registered ~300ms before router B. If each registration
        // tracks its own start time, A's uptime should be meaningfully larger
        // than B's. A shared/lazy epoch would make them nearly identical.
        try expect(
            uptimeA - uptimeB >= 0.2,
            "Expected router A (registered ~300ms earlier) to show more uptime than B; got A=\(uptimeA) B=\(uptimeB)"
        )
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

    await test("agent documentation names the live discovery and background tools") {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let documents: [(path: String, requiredNames: [String])] = [
            (
                path: "docs/AGENT_PLAYBOOK.md",
                requiredNames: ["tools_search", "bg_run", "bg_poll", "bg_kill"]
            ),
            (
                path: "docs/mcp-transport-and-bg-process.md",
                requiredNames: ["bg_run", "bg_poll", "bg_kill"]
            )
        ]
        let staleBackgroundNames = [
            "bg_process_start",
            "bg_process_status",
            "bg_process_logs",
            "bg_process_list",
            "bg_process_kill"
        ]

        for document in documents {
            let url = repositoryRoot.appendingPathComponent(document.path)
            let content = try String(contentsOf: url, encoding: .utf8)
            for liveName in document.requiredNames {
                try expect(content.contains(liveName),
                           "\(document.path) should name \(liveName)")
            }
            for staleName in staleBackgroundNames {
                try expect(!content.contains(staleName),
                           "\(document.path) must not advertise removed \(staleName)")
            }
        }

        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        try expect(
            readme.contains("\(BridgeConstants.staticFeatureModuleToolCount) static feature-module tools"),
            "README static-tool count should match BridgeConstants"
        )
    }
}
