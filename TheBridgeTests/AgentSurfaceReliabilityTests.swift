// AgentSurfaceReliabilityTests.swift — deterministic discovery + safe miss telemetry
// The Bridge · Tests

import Foundation
import MCP
import TheBridgeLib

func runAgentSurfaceReliabilityTests() async {
    print("\n\u{1F9ED} Agent Surface Reliability")

    func registration(
        _ name: String,
        module: String = "test",
        tier: SecurityTier = .open,
        description: String = "description"
    ) -> ToolRegistration {
        ToolRegistration(
            name: name,
            module: module,
            tier: tier,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["probe": .object(["type": .string("string")])])
            ]),
            handler: { _ in .object(["ok": .bool(true)]) }
        )
    }

    func names(from value: Value) throws -> [String] {
        guard case .array(let rows) = value else {
            throw TestError.assertion("expected tool array, got \(value)")
        }
        return rows.compactMap { row in
            guard case .object(let fields) = row,
                  case .string(let name)? = fields["name"] else { return nil }
            return name
        }
    }

    func streamText(from response: HTTPResponse) async throws -> String {
        guard case .stream(let stream, _) = response else {
            throw TestError.assertion("expected SSE stream, got HTTP \(response.statusCode)")
        }
        var text = ""
        for try await data in stream {
            text += String(decoding: data, as: UTF8.self)
        }
        return text
    }

    func rpcObject(from text: String) throws -> [String: Any] {
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("data: {") else { continue }
            let payload = line.dropFirst("data: ".count)
            guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                continue
            }
            return object
        }
        throw TestError.assertion("SSE response did not contain a JSON-RPC data event: \(text)")
    }

    let shuffled: [ToolRegistration] = [
        registration("zulu"),
        registration("session_info", module: "session"),
        registration("alpha"),
        registration("bridge_initialize", module: "standing_orders"),
        registration("tools_list", module: "session"),
        registration("tools_search", module: "session"),
        registration("middle"),
        registration("bridge_status", module: "cloud"),
    ]
    let expected = [
        "bridge_initialize", "bridge_status", "tools_list", "session_info", "tools_search",
        "alpha", "middle", "zulu",
    ]

    await test("agent surface: canonical order is bootstrap-first then alphabetical") {
        let ordered = BrokerBootstrapToolOrdering.prioritize(shuffled)
        try expect(ordered.map(\.name) == expected)

        let before = Dictionary(uniqueKeysWithValues: shuffled.map { ($0.name, $0) })
        for after in ordered {
            guard let original = before[after.name] else {
                throw TestError.assertion("ordering introduced unknown registration \(after.name)")
            }
            try expect(after.module == original.module, "module changed for \(after.name)")
            try expect(after.tier == original.tier, "tier changed for \(after.name)")
            try expect(after.description == original.description, "description changed for \(after.name)")
            try expect(after.inputSchema == original.inputSchema, "schema changed for \(after.name)")
        }
    }

    await test("agent surface: router snapshots are atomic, revisioned, filtered, and ordered") {
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        for item in shuffled { await router.register(item) }
        await router.markModulesRegistrationComplete()

        let first = await router.toolManifestSnapshot(disabledNames: ["middle"])
        try expect(first.registrations.map(\.name) == expected.filter { $0 != "middle" })

        await router.register(registration("beta"))
        let second = await router.toolManifestSnapshot(disabledNames: ["middle"])
        try expect(second.revision > first.revision, "dynamic registration must advance manifest revision")
        try expect(second.registrations.map(\.name) == [
            "bridge_initialize", "bridge_status", "tools_list", "session_info", "tools_search",
            "alpha", "beta", "zulu",
        ])
    }

    await test("agent surface: tools_list uses the canonical order") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            licenseStatusProvider: { .trial(daysRemaining: 5) }
        )
        await SessionModule.register(on: router, auditLog: AuditLog())
        for item in shuffled where !["tools_list", "session_info", "tools_search"].contains(item.name) {
            await router.register(item)
        }
        let result = try await router.dispatch(toolName: "tools_list", arguments: .object([:]))
        let listed = try names(from: result)
        try expect(Array(listed.prefix(5)) == [
            "bridge_initialize", "bridge_status", "tools_list", "session_info", "tools_search",
        ])
        try expect(Array(listed.dropFirst(5)) == Array(listed.dropFirst(5)).sorted(),
                   "tools_list remainder must be alphabetical: \(listed)")
    }

    await test("agent surface: stateful HTTP tools/list uses the canonical router snapshot") {
        let log = AuditLog()
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: log)
        for item in shuffled { await router.register(item) }
        await router.markModulesRegistrationComplete()

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-surface-sessions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let server = SSEServer(
            router: router,
            onToolCall: {},
            sessionStore: SessionPersistenceStore(storeURL: storeURL)
        )
        let headers = [
            "Host": "127.0.0.1:\(BridgeConstants.defaultSSEPort)",
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        ]
        let initialize = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\(BridgeConstants.mcpProtocolVersion)","capabilities":{},"clientInfo":{"name":"agent-surface-test","version":"1"}}}
        """.utf8)
        let initResponse = await server.handleHTTPRequest(
            HTTPRequest(method: "POST", headers: headers, body: initialize)
        )
        guard let sessionID = initResponse.headers[HTTPHeaderName.sessionID] else {
            throw TestError.assertion("initialize did not return MCP session id")
        }
        _ = try await streamText(from: initResponse)

        var listHeaders = headers
        listHeaders[HTTPHeaderName.sessionID] = sessionID
        let listResponse = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: listHeaders,
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        ))
        let rpc = try rpcObject(from: try await streamText(from: listResponse))
        guard let result = rpc["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw TestError.assertion("tools/list response missing result.tools: \(rpc)")
        }
        try expect(tools.compactMap { $0["name"] as? String } == expected)

        let missResponse = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: listHeaders,
            body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"stateful_unknown","arguments":{"token":"never-log-me"}}}"#.utf8)
        ))
        _ = try await streamText(from: missResponse)
        let misses = await log.allEntries().filter { $0.eventType == "dispatch_miss" }
        try expect(misses.count == 1)
        try expect(misses[0].transportSessionId == sessionID)
        try expect(misses[0].reportedClientName == "agent-surface-test")
        try expect(misses[0].reportedClientVersion == "1")
        try expect(misses[0].inputSummary.isEmpty)
    }

    await test("agent surface: unknown calls audit one safe dispatch_miss without arguments") {
        let log = AuditLog()
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: log,
            licenseStatusProvider: { .trial(daysRemaining: 5) }
        )
        let context = ToolDispatchContext(
            transportSessionId: "miss-session",
            origin: .remote,
            client: "agent-client",
            clientVersion: "7.2"
        )
        let secret = "TOP-SECRET-ARGUMENT"
        for _ in 0..<2 {
            do {
                _ = try await router.dispatch(
                    toolName: "not_a_real_tool",
                    arguments: .object(["token": .string(secret)]),
                    context: context
                )
                throw TestError.assertion("unknown tool unexpectedly dispatched")
            } catch let error as ToolRouterError {
                guard case .unknownTool = error else { throw error }
            }
        }
        do {
            _ = try await router.dispatch(
                toolName: "sk-proj-THIS-MUST-NOT-LEAK",
                arguments: .object([:]),
                context: context
            )
            throw TestError.assertion("secret-shaped tool name unexpectedly dispatched")
        } catch let error as ToolRouterError {
            guard case .unknownTool = error else { throw error }
        }

        let entries = await log.allEntries()
        try expect(entries.count == 2, "duplicate misses must be rate-limited; got \(entries.count)")
        try expect(entries.allSatisfy { $0.eventType == "dispatch_miss" })
        try expect(entries[0].toolName == "not_a_real_tool")
        try expect(entries[0].reportedClientName == "agent-client")
        try expect(entries[0].reportedClientVersion == "7.2")
        try expect(entries[0].origin == .remote)
        try expect(entries[0].transportSessionId == "miss-session")
        try expect(entries[0].inputSummary.isEmpty)
        try expect(entries[1].toolName.hasPrefix("<invalid-name:"),
                   "secret-shaped names must be replaced by a digest: \(entries[1].toolName)")
        let encoded = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        try expect(!encoded.contains(secret), "dispatch miss leaked call arguments")
        try expect(!encoded.contains("THIS-MUST-NOT-LEAK"), "dispatch miss leaked invalid tool name")

        // Persisted audit logs predate the optional miss/client fields. Keep
        // decoding backward-compatible so startup never rejects old JSONL.
        let legacyEntry = AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1),
            toolName: "legacy_tool",
            tier: .open,
            inputSummary: "{}",
            outputSummary: "ok",
            durationMs: 1,
            approvalStatus: .approved
        )
        let legacyData = try JSONEncoder().encode(legacyEntry)
        var legacyObject = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        legacyObject.removeValue(forKey: "eventType")
        legacyObject.removeValue(forKey: "reportedClientName")
        legacyObject.removeValue(forKey: "reportedClientVersion")
        let decoded = try JSONDecoder().decode(
            AuditEntry.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        try expect(decoded.eventType == nil && decoded.reportedClientName == nil
            && decoded.reportedClientVersion == nil,
            "legacy audit entries must decode without the additive telemetry fields")
    }
}
