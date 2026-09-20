// RemoteOAuthHardeningS4Tests.swift — PKT-800 S4 (connector hardening)
// TheBridge · Tests (custom harness — no XCTest)
//
// Synthetic ES256 keypair only — no network, no live IdP. Covers the
// three S4 hardening axes plus their non-regression invariants:
//
//  A1 — `contacts.read` scope split. `contacts_get`/`contacts_search`
//       (contact-RECORD tools) now require the dedicated `contacts.read`
//       scope and are DENIED with only `voice.resolve`; the retained
//       voice-resolution tools (`contacts_resolve_handle`,
//       `contacts_health`) still gate on `voice.resolve` and are NOT
//       reachable with `contacts.read`. The two scopes are independent
//       (neither implies the other). PRM `scopes_supported` now advertises
//       `contacts.read`. Default-deny preserved.
//
//  A2 — TransportRouter injection seam. With an injected router whose
//       `streamableHTTP` is ACTIVE, `ServerManager.runStreamableHTTP()`
//       returns WITHOUT binding a second listener (documented gated
//       no-op) and `isStreamableHTTPActive == true`; with an inactive
//       injected router it throws `transportInactive(.streamableHTTP)`.
//       No GUI launch; production default path byte-for-byte unchanged.
//
//  A3 — step-up model hardening. A `destructiveHint:true` connector
//       `tools/call` is authorized ONLY by the AS-minted
//       `connector.step_up` scope on the VERIFIED token. The per-call
//       `_stepUp`/`stepUpToken` argument is a non-authoritative consent
//       echo and can NEVER by itself authorize a destructive call
//       (correcting the prior "scope OR non-empty token" defect).
//       Non-destructive tools are unaffected; stdio/health/legacy SSE
//       classification is unchanged.

import Foundation
import JWTKit
import MCP
import TheBridgeLib

// MARK: - Synthetic key fixture (no network)

private struct S4Keys {
    let signing: JWTKeyCollection
    let verify: JWTKeyCollection

    static func make() async -> S4Keys {
        let priv = ES256PrivateKey()
        let s = JWTKeyCollection()
        await s.add(ecdsa: priv)
        let v = JWTKeyCollection()
        await v.add(ecdsa: priv.publicKey)
        return S4Keys(signing: s, verify: v)
    }

    func sign(
        iss: String, aud: String, sub: String? = "user-1", scope: String?
    ) async throws -> String {
        try await signing.sign(BridgeAccessToken(
            iss: IssuerClaim(value: iss),
            aud: AudienceClaim(value: [aud]),
            sub: sub.map { SubjectClaim(value: $0) },
            exp: ExpirationClaim(value: Date().addingTimeInterval(300)),
            nbf: nil,
            scope: scope
        ))
    }
}

private let s4Issuer = "https://auth.kup.solutions"
private let s4Resource = "http://127.0.0.1:9700/mcp"
private let s4PRM = "http://127.0.0.1:9700/.well-known/oauth-protected-resource"

func runRemoteOAuthHardeningS4Tests() async {
    print("\n\u{1F510} Remote OAuth Hardening (PKT-800 S4 — connector hardening)")

    let keys = await S4Keys.make()
    let gate = ConnectorScopeGate()
    let stepUp = ConnectorStepUpGate()

    // NB: Previously these were nested `func`s with default arguments.
    // Swift 6.2.1 -O -strict-concurrency=complete crashes during type-
    // checking that pattern when the enclosing function is `async` and
    // the nested fn captures locals (compiler assertion
    // "IsolationCrossing should not be set twice"). Closures with no
    // default args avoid the crash. All 6 call sites use authCtx() with
    // no arguments, so dropping the defaults is functionally a no-op.
    let validator: @Sendable () -> ConnectorBearerValidator = {
        ConnectorBearerValidator(
            keys: keys.verify, hasKeys: true,
            expectedIssuer: s4Issuer, expectedAudience: s4Resource
        )
    }
    let authCtx: @Sendable () -> ConnectorAuthContext = {
        ConnectorAuthContext(
            validator: validator(),
            sessionBinding: ConnectorSessionBinding(),
            diagnostics: ConnectorAuthDiagnostics(),
            resourceMetadataURL: s4PRM,
            strictScopes: true
        )
    }
    let unscopedAuthCtx: @Sendable () -> ConnectorAuthContext = {
        ConnectorAuthContext(
            validator: validator(),
            sessionBinding: ConnectorSessionBinding(),
            diagnostics: ConnectorAuthDiagnostics(),
            resourceMetadataURL: s4PRM,
            strictScopes: false
        )
    }

    await test("GH #146 E2E: signed connector tokens without a usable subject are rejected before dispatch") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await router.register(ToolRegistration(
            name: "skills_routing_list", module: "skills", tier: .open,
            description: "must not run for a subject-less token",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in
                throw TestError.assertion("subject-less bearer reached tool dispatch")
            }
        ))
        let server = SSEServer(router: router, onToolCall: {}, connectorAuth: unscopedAuthCtx())
        let body = Data(#"{"jsonrpc":"2.0","id":146,"method":"tools/call","params":{"name":"skills_routing_list","arguments":{}}}"#.utf8)

        for subject in [nil, "", "   "] as [String?] {
            let token = try await keys.sign(
                iss: s4Issuer, aud: s4Resource, sub: subject, scope: "openid"
            )
            let response = await server.handleHTTPRequest(HTTPRequest(
                method: "POST",
                headers: [
                    "Cf-Connecting-Ip": "203.0.113.146",
                    "Authorization": "Bearer \(token)",
                    "Mcp-Session-Id": "subless-\(UUID().uuidString)"
                ],
                body: body
            ))
            try expect(response.statusCode == 401,
                       "subject-less connector token must be rejected with 401, got \(response.statusCode)")
            let challenge = response.headers.first { $0.key.lowercased() == "www-authenticate" }?.value ?? ""
            try expect(challenge.contains("auth_failed") && !challenge.contains("subject"),
                       "public challenge must remain coarse: \(challenge)")
        }
    }

    // MARK: - A1: contacts.read scope split (pure gate logic)

    await test("A1: contacts_get DENIED with only voice.resolve") {
        let d = await gate.evaluate(
            toolName: "contacts_get",
            grantedScopes: [ConnectorScope(name: "voice.resolve")]
        )
        guard case .deny(let reason) = d else {
            throw TestError.assertion("voice.resolve must NOT reach contacts_get, got \(d)")
        }
        try expect(reason.contains("contacts.read"),
                   "deny reason should name the required contacts.read scope: \(reason)")
    }

    await test("A1: contacts_search DENIED with only voice.resolve") {
        let d = await gate.evaluate(
            toolName: "contacts_search",
            grantedScopes: [ConnectorScope(name: "voice.resolve")]
        )
        guard case .deny = d else {
            throw TestError.assertion("voice.resolve must NOT reach contacts_search, got \(d)")
        }
    }

    await test("A1: contacts_get ALLOWED with contacts.read") {
        let d = await gate.evaluate(
            toolName: "contacts_get",
            grantedScopes: [ConnectorScope(name: "contacts.read")]
        )
        guard case .allow = d else {
            throw TestError.assertion("contacts.read must reach contacts_get, got \(d)")
        }
    }

    await test("A1: contacts_search ALLOWED with contacts.read") {
        let d = await gate.evaluate(
            toolName: "contacts_search",
            grantedScopes: [ConnectorScope(name: "contacts.read")]
        )
        guard case .allow = d else {
            throw TestError.assertion("contacts.read must reach contacts_search, got \(d)")
        }
    }

    await test("A1: voice.resolve STILL allows its retained voice-resolution tools") {
        for tool in ["contacts_resolve_handle", "contacts_health"] {
            let d = await gate.evaluate(
                toolName: tool,
                grantedScopes: [ConnectorScope(name: "voice.resolve")]
            )
            guard case .allow = d else {
                throw TestError.assertion("voice.resolve must still reach \(tool), got \(d)")
            }
        }
    }

    await test("A1: contacts.read does NOT reach voice-resolution tools (scopes independent)") {
        for tool in ["contacts_resolve_handle", "contacts_health"] {
            let d = await gate.evaluate(
                toolName: tool,
                grantedScopes: [ConnectorScope(name: "contacts.read")]
            )
            guard case .deny = d else {
                throw TestError.assertion("contacts.read must NOT reach \(tool) (no superset), got \(d)")
            }
        }
    }

    await test("A1: voice.resolve does NOT reach contact-record tools (scopes independent)") {
        for tool in ["contacts_get", "contacts_search"] {
            let req = try await gate.requiredScopes(for: tool).map(\.name)
            try expect(req == ["contacts.read"],
                       "\(tool) must require exactly [contacts.read], got \(req)")
        }
    }

    await test("A1: requiredScopes — retained voice tools require exactly [voice.resolve]") {
        for tool in ["contacts_resolve_handle", "contacts_health"] {
            let req = try await gate.requiredScopes(for: tool).map(\.name)
            try expect(req == ["voice.resolve"],
                       "\(tool) must require exactly [voice.resolve], got \(req)")
        }
    }

    await test("A1: contacts.read is in the canonical scope name list") {
        try expect(ConnectorScopeName.contactsRead == "contacts.read",
                   "wire string drifted: \(ConnectorScopeName.contactsRead)")
        try expect(ConnectorScopeName.all.contains("contacts.read"),
                   "contacts.read missing from ConnectorScopeName.all")
    }

    await test("A1 → v3.7.10: PRM scopes_supported advertises the AuthKit OpenID scopes (ChatGPT authorize)") {
        // PKT-810's empty list is correct in theory but ChatGPT's connector
        // could not complete authorize against it (proven live 2026-06-12);
        // WorkOS AuthKit also rejects app-custom scopes (`invalid_scope`). So
        // PRM now advertises exactly the standard OpenID scopes AuthKit mints,
        // which both Claude AND ChatGPT can request. The Bridge-specific scope
        // names still exist in ConnectorScopeName for the scoped-token path;
        // authorization stays server-side (ConnectorScopeGate + SecurityGate).
        let expected = ProtectedResourceMetadataProvider.advertisedAuthKitScopes
        try expect(expected == ["openid", "email", "profile", "offline_access"],
                   "advertisedAuthKitScopes drifted: \(expected)")
        let m = ProtectedResourceMetadataProvider.metadata(environment: [:])
        try expect(m.scopesSupported == expected,
                   "PRM scopes_supported must advertise the AuthKit OpenID scopes: \(m.scopesSupported)")
        // Wire form must carry the scopes_supported array verbatim.
        let body = ProtectedResourceMetadataProvider.jsonBody(environment: [:])
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        try expect(json?["scopes_supported"] != nil,
                   "serialized PRM must still include the scopes_supported key")
        let scopes = json?["scopes_supported"] as? [String] ?? ["<missing>"]
        try expect(scopes == expected, "serialized scopes_supported must match advertised set: \(scopes)")
    }

    await test("A1: default-deny preserved — a non-connector tool is still denied with all scopes") {
        let allScopes = ConnectorScopeName.all.map { ConnectorScope(name: $0) }
        let d = await gate.evaluate(toolName: "file_write", grantedScopes: allScopes)
        guard case .deny(let reason) = d else {
            throw TestError.assertion("non-connector tool must still deny under all scopes")
        }
        try expect(reason.contains("not exposed"), "deny reason: \(reason)")
    }

    await test("A1 E2E: contacts_get with voice.resolve bearer → 403 insufficient_scope, no dispatch") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx()
        )
        let tok = try await keys.sign(iss: s4Issuer, aud: s4Resource, scope: "voice.resolve")
        let body = Data(#"{"method":"tools/call","params":{"name":"contacts_get","arguments":{"id":"x"}}}"#.utf8)
        let resp = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)", "Mcp-Session-Id": "A1-s1"],
            body: body))
        try expect(resp.statusCode == 403,
                   "voice.resolve→contacts_get must be 403, got \(resp.statusCode)")
        if let bd = resp.bodyData, let s = String(data: bd, encoding: .utf8) {
            try expect(s.contains("insufficient_scope"),
                       "machine-readable scope reason in body: \(s)")
        } else {
            throw TestError.assertion("403 must carry a body")
        }
    }

    await test("A1 E2E: contacts_get with contacts.read bearer reaches session path (not 401/403)") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx()
        )
        let tok = try await keys.sign(iss: s4Issuer, aud: s4Resource, scope: "contacts.read")
        let body = Data(#"{"method":"tools/call","params":{"name":"contacts_get","arguments":{"id":"x"}}}"#.utf8)
        let resp = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)", "Mcp-Session-Id": "A1-s2"],
            body: body))
        // Scope satisfied (contacts_get is not destructive ⇒ no step-up) ⇒ the
        // request is authorized. v3.7.10: connector tools/call is served by
        // processConnectorJSONRPC (compact JSON for ChatGPT), so it executes and
        // returns 200, crucially NOT a 401/403 auth refusal.
        try expect(resp.statusCode == 200,
                   "authorized contacts.read call must be dispatched (200), got \(resp.statusCode)")
    }

    await test("GH #146: compact connector requires principal-bound, exact-scope, single-use route receipts") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-receipt-s4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let advisoryKey = BridgeDefaults.brokerAdvisoryAnnotation
        let previousAdvisory = UserDefaults.standard.object(forKey: advisoryKey)
        UserDefaults.standard.set(true, forKey: advisoryKey)
        defer {
            if let previousAdvisory {
                UserDefaults.standard.set(previousAdvisory, forKey: advisoryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: advisoryKey)
            }
        }

        let audit = AuditLog()
        let custody = RoutingCustodyStore(root: root.appendingPathComponent("routing-custody", isDirectory: true))
        let sessionRegistry = SessionRegistry(
            path: root.appendingPathComponent("sessions/sessions.sqlite", isDirectory: false)
        )
        try await sessionRegistry.resetForTesting()
        _ = try custody.recordBootstrap(
            snapshotID: "compact-receipt-snapshot",
            source: "test",
            count: 2,
            verifiedAt: Date()
        )
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: audit,
            sessionRegistry: sessionRegistry,
            routingCustodyStore: custody
        )
        await router.register(ToolRegistration(
            name: "skills_routing_list", module: "skills", tier: .open,
            description: "routing discovery fixture",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in
                .object([
                    "status": .string("healthy"), "source": .string("test"),
                    "snapshot": .string("compact-receipt-snapshot"), "count": .int(2),
                    "skills": .array([])
                ])
            }
        ))
        await router.register(ToolRegistration(
            name: "fetch_skill", module: "skills", tier: .open,
            description: "route authority fixture",
            inputSchema: .object(["type": .string("object")]),
            handler: { arguments in
                guard case .object(let object) = arguments,
                      case .string(let name)? = object["name"] else {
                    return .object(["error": .string("missing name")])
                }
                return .object([
                    "slug": .string(name),
                    "content": .string("fixture"),
                    ToolRouter.routingAuthorityEvidenceKey: .object(["name": .string(name)])
                ])
            }
        ))
        await router.register(ToolRegistration(
            name: "messages_recent", module: "messages", tier: .open,
            description: "bounded messages fixture",
            inputSchema: .object(["type": .string("object")]),
            handler: { arguments in
                if case .object(let object) = arguments,
                   object["_routingReceipt"] != nil || object["_routingReceipts"] != nil {
                    throw TestError.assertion("routing control metadata reached messages_recent")
                }
                return .object(["ok": .bool(true), "messages": .array([])])
            }
        ))
        let server = SSEServer(router: router, onToolCall: {}, connectorAuth: unscopedAuthCtx())
        let token = try await keys.sign(
            iss: s4Issuer, aud: s4Resource, sub: "route-user", scope: "openid"
        )
        let otherToken = try await keys.sign(
            iss: s4Issuer, aud: s4Resource, sub: "other-route-user", scope: "openid"
        )

        let roster = try await s4CompactToolCall(
            server: server, token: token, sessionID: "conversation-a",
            tool: "skills_routing_list", arguments: [:], id: 1
        )
        let rosterPayload = try s4CompactPayload(roster)
        try expect(rosterPayload["routingReceipts"] == nil,
                   "routing discovery must not issue route authority")

        let beforeFetch = try await s4CompactToolCall(
            server: server, token: token, sessionID: "conversation-a",
            tool: "messages_recent", arguments: [:], id: 2
        )
        try expect(try s4CompactIsError(beforeFetch))
        try expect(try s4CompactText(beforeFetch).contains("route_ack_required"))

        let peopleFetch = try await s4CompactToolCall(
            server: server, token: token, sessionID: "conversation-a",
            tool: "fetch_skill", arguments: ["name": "people-keepr"], id: 3
        )
        let macFetch = try await s4CompactToolCall(
            server: server, token: token, sessionID: "churned-header",
            tool: "fetch_skill", arguments: ["name": "mac-message"], id: 4
        )
        let peopleReceipt = try s4CompactReceipt(peopleFetch, scopeID: "tool:messages_recent")
        let macReceipt = try s4CompactReceipt(macFetch, scopeID: "tool:messages_recent")
        let receiptArguments = ["_routingReceipts": [peopleReceipt, macReceipt]]

        let secondConversation = try await s4CompactToolCall(
            server: server, token: token, sessionID: "conversation-b",
            tool: "messages_recent", arguments: [:], id: 5
        )
        try expect(try s4CompactIsError(secondConversation),
                   "same principal in a fresh conversation must not inherit authority")

        let wrongPrincipal = try await s4CompactToolCall(
            server: server, token: otherToken, sessionID: "conversation-other",
            tool: "messages_recent", arguments: receiptArguments, id: 6
        )
        try expect(try s4CompactIsError(wrongPrincipal),
                   "a receipt must reject a different authenticated principal")

        let accepted = try await s4CompactToolCall(
            server: server, token: token, sessionID: nil,
            tool: "messages_recent", arguments: receiptArguments, id: 7
        )
        try expect(!(try s4CompactIsError(accepted)),
                   "valid receipts must survive header omission and authorize exactly once")
        try expect((try s4CompactPayload(accepted))["ok"] as? Bool == true)

        let replay = try await s4CompactToolCall(
            server: server, token: token, sessionID: "another-header",
            tool: "messages_recent", arguments: receiptArguments, id: 8
        )
        try expect(try s4CompactIsError(replay), "receipt replay must fail closed")

        let entries = await audit.entries(forSessionID: ToolDispatchContext.remoteConnectorJSONSessionID)
        let receiptNotes = Set(entries
            .compactMap(\.governanceNote)
            .flatMap { $0.split(separator: ";").map(String.init) }
            .filter { $0.hasPrefix("route_receipt_") })
        try expect(receiptNotes.contains("route_receipt_issued"))
        try expect(receiptNotes.contains("route_receipt_consumed"))
        try expect(receiptNotes.contains("route_receipt_rejected_wrong_principal"))
        try expect(receiptNotes.contains("route_receipt_rejected_replayed_or_unknown"))
        let auditText = entries.map { "\($0.inputSummary) \($0.outputSummary)" }.joined(separator: "\n")
        try expect(!auditText.contains("principalDigest") && !auditText.contains("nonce"),
                   "audit summaries must not persist receipt secrets: \(auditText)")
    }

    // MARK: - A2: TransportRouter injection seam

    await test("A2: injected ACTIVE router → isStreamableHTTPActive == true (no env, no GUI)") {
        let activeRouter = TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "1"])
        let m = ServerManager(onToolCall: {}, transportRouter: activeRouter)
        try expect(m.isStreamableHTTPActive,
                   "injected active router must report streamableHTTP active")
        // stdio non-regression: stdio is still active alongside HTTP.
        try expect(activeRouter.isActive(.stdio),
                   "stdio invariant: stdio must remain active with HTTP on")
    }

    await test("A2: injected INACTIVE router → isStreamableHTTPActive == false (production default shape)") {
        let inactiveRouter = TransportRouter(environment: [:], config: { _ in nil })
        let m = ServerManager(onToolCall: {}, transportRouter: inactiveRouter)
        try expect(!m.isStreamableHTTPActive,
                   "injected inactive router must report streamableHTTP inactive")
        // Default (no transportRouter arg) must behave identically to an
        // explicitly-inactive injection in a harness with BRIDGE_ENABLE_HTTP
        // unset — proving the default param is byte-for-byte the prior `let`.
        let defaultMgr = ServerManager(onToolCall: {})
        try expect(!defaultMgr.isStreamableHTTPActive,
                   "default ServerManager must keep the gate off in the harness")
    }

    await test("A2: injected ACTIVE router → runStreamableHTTP() is a NON-binding no-op that returns") {
        // The documented gated no-op: `/mcp` is served by the shared
        // `runSSE()` listener, so the active-path runStreamableHTTP() must
        // RETURN without calling sseServer.start() (which would bind a
        // second listener on the SSE port). setup() builds the SSEServer
        // but binds nothing; runStreamableHTTP() must complete normally.
        let activeRouter = TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "1"])
        let m = ServerManager(onToolCall: {}, transportRouter: activeRouter)
        _ = await m.setup()
        // Must NOT throw and must NOT hang on a bind — a normal return is
        // the entire contract of the active gated seam.
        do {
            try await m.runStreamableHTTP()
        } catch {
            throw TestError.assertion(
                "active runStreamableHTTP() must be a no-op return, threw: \(error)")
        }
        // Idempotent: calling it again is still a no-op (still no bind).
        do {
            try await m.runStreamableHTTP()
        } catch {
            throw TestError.assertion(
                "active runStreamableHTTP() must remain a no-op on repeat, threw: \(error)")
        }
        try expect(m.isStreamableHTTPActive,
                   "gate must still read active after the no-op return")
    }

    await test("A2: injected INACTIVE router → runStreamableHTTP() throws transportInactive(.streamableHTTP)") {
        let inactiveRouter = TransportRouter(environment: [:], config: { _ in nil })
        let m = ServerManager(onToolCall: {}, transportRouter: inactiveRouter)
        _ = await m.setup()
        do {
            try await m.runStreamableHTTP()
            throw TestError.assertion("inactive router must make runStreamableHTTP() throw, not bind")
        } catch let e as ServerManagerError {
            guard case .transportInactive(let t) = e, t == .streamableHTTP else {
                throw TestError.assertion("expected transportInactive(.streamableHTTP), got \(e)")
            }
        }
    }

    await test("A2: runStreamableHTTP() before setup() throws notSetUp regardless of router activity") {
        let activeRouter = TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "1"])
        let m = ServerManager(onToolCall: {}, transportRouter: activeRouter)
        do {
            try await m.runStreamableHTTP()
            throw TestError.assertion("must throw notSetUp before setup()")
        } catch let e as ServerManagerError {
            guard case .notSetUp = e else {
                throw TestError.assertion("expected notSetUp, got \(e)")
            }
        }
    }

    // MARK: - A3: step-up model hardening (scope = sole security boundary)

    await test("A3: destructive tool DENIED with bearer+capability-scope but NO connector.step_up") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx()
        )
        let tok = try await keys.sign(iss: s4Issuer, aud: s4Resource, scope: "snippets.write")
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"id":"s1"}}}"#.utf8)
        let resp = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)", "Mcp-Session-Id": "A3-noscope"],
            body: body))
        try expect(resp.statusCode == 403,
                   "destructive w/o connector.step_up must be 403, got \(resp.statusCode)")
        if let bd = resp.bodyData, let s = String(data: bd, encoding: .utf8) {
            try expect(s.contains("step_up_required"),
                       "stable machine-readable reason in body: \(s)")
        } else {
            throw TestError.assertion("403 must carry a body")
        }
    }

    await test("A3: destructive tool ALLOWED (reaches session path) WITH connector.step_up scope") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx()
        )
        let tok = try await keys.sign(
            iss: s4Issuer, aud: s4Resource,
            scope: "snippets.write \(ConnectorStepUpGate.stepUpScopeName)")
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"id":"s1"}}}"#.utf8)
        let resp = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)", "Mcp-Session-Id": "A3-scoped"],
            body: body))
        // Scope + step-up satisfied ⇒ authorized. v3.7.10: connector tools/call
        // is dispatched by processConnectorJSONRPC → 200, NOT a 401/403 refusal.
        try expect(resp.statusCode == 200,
                   "step-up scope must be dispatched (200), got \(resp.statusCode)")
    }

    await test("A3: per-call _stepUp token ALONE does NOT authorize a destructive call (E2E)") {
        // The corrected threat model: an automated client supplying
        // `{"_stepUp":"anything"}` with NO connector.step_up scope must
        // STILL be refused. (Prior S3 logic would have let this through.)
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx()
        )
        let tok = try await keys.sign(iss: s4Issuer, aud: s4Resource, scope: "snippets.write")
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"id":"s1","_stepUp":"i-promise-i-confirmed"}}}"#.utf8)
        let resp = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)", "Mcp-Session-Id": "A3-tokenonly"],
            body: body))
        try expect(resp.statusCode == 403,
                   "per-call token alone must NOT authorize a destructive call, got \(resp.statusCode)")
        if let bd = resp.bodyData, let s = String(data: bd, encoding: .utf8) {
            try expect(s.contains("step_up_required"),
                       "must still report step_up_required: \(s)")
        }
    }

    await test("A3: pure gate — token alone never satisfies; only the AS-minted scope does") {
        // Exhaustive value sweep proving the token's value is irrelevant.
        for tok in ["", " ", "x", "confirmed", "{\"nested\":true}"] {
            let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"_stepUp":"\#(tok)"}}}"#.utf8)
            let d = stepUp.evaluate(
                toolName: "snippets_delete",
                grantedScopes: [ConnectorScope(name: "snippets.write")],
                body: body)
            guard case .required(let reason, let msg) = d else {
                throw TestError.assertion("token '\(tok)' must NOT authorize, got \(d)")
            }
            try expect(reason == .stepUpRequired, "stable reason")
            try expect(msg.contains("consent signal only"),
                       "refusal message must state the token is non-authoritative: \(msg)")
        }
        // The AS-minted scope (and only it) authorizes.
        guard case .satisfied = stepUp.evaluate(
            toolName: "snippets_delete",
            grantedScopes: [
                ConnectorScope(name: "snippets.write"),
                ConnectorScope(name: ConnectorStepUpGate.stepUpScopeName),
            ],
            body: nil) else {
            throw TestError.assertion("connector.step_up scope must authorize")
        }
    }

    await test("A3: non-destructive connector tool is unaffected by the corrected gate") {
        let d = stepUp.evaluate(
            toolName: "snippets_list",
            grantedScopes: [ConnectorScope(name: "snippets.read")],
            body: Data(#"{"method":"tools/call","params":{"name":"snippets_list","arguments":{}}}"#.utf8))
        guard case .satisfied = d else {
            throw TestError.assertion("non-destructive tool must not require step-up, got \(d)")
        }
        // contacts_get (the A1 tool) is non-destructive ⇒ also unaffected.
        let d2 = stepUp.evaluate(
            toolName: "contacts_get",
            grantedScopes: [ConnectorScope(name: "contacts.read")],
            body: nil)
        guard case .satisfied = d2 else {
            throw TestError.assertion("contacts_get is non-destructive; no step-up, got \(d2)")
        }
    }

    await test("A3: hasConfirmationToken still recognizes the echo (consent trail) but it is non-authoritative") {
        // The echo MUST remain detectable for the diagnostics/UX trail —
        // it is just decoupled from authorization.
        let yes = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"_stepUp":"abc"}}}"#.utf8)
        try expect(ConnectorStepUpGate.hasConfirmationToken(in: yes),
                   "echo must still be recognized for the consent trail")
        let no = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{}}}"#.utf8)
        try expect(!ConnectorStepUpGate.hasConfirmationToken(in: no),
                   "no echo present")
        // But recognition != authorization: with the echo and no scope the
        // gate still refuses.
        guard case .required = stepUp.evaluate(
            toolName: "snippets_delete",
            grantedScopes: [ConnectorScope(name: "snippets.write")],
            body: yes) else {
            throw TestError.assertion("recognized echo must NOT authorize")
        }
    }

    // MARK: - Non-regression: stdio / health / legacy SSE unaffected by S4

    await test("S4 non-regression: default SSEServer attaches NO connector auth (no scope/step-up gating)") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {})
        // A contacts_get tools/call with NO Authorization on the default
        // (connectorAuth==nil) server must NOT be 401/403 — the A1 split
        // is confined to the connector path.
        let body = Data(#"{"method":"tools/call","params":{"name":"contacts_get","arguments":{}}}"#.utf8)
        let resp = await server.handleHTTPRequest(
            HTTPRequest(method: "POST", headers: [:], body: body))
        try expect(resp.statusCode != 401 && resp.statusCode != 403,
                   "default path must not gate contacts_get on scope, got \(resp.statusCode)")
        let wa = resp.headers.first { $0.key.lowercased() == "www-authenticate" }?.value
        try expect(wa == nil, "default server must not emit a bearer challenge")
    }

    await test("S4 non-regression: health / legacy SSE / messages route classification unchanged") {
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/health", endpoint: "/mcp") == .health)
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/sse", endpoint: "/mcp") == .legacySSE)
        try expect(MCPHTTPRoute.classify(method: "POST", path: "/messages", endpoint: "/mcp") == .legacyMessages)
        try expect(MCPHTTPRoute.classify(method: "POST", path: "/jobs/x/run", endpoint: "/mcp") == .notFound)
    }

    await test("S4 non-regression: stdio remains active in every router configuration") {
        try expect(TransportRouter(environment: [:]).isActive(.stdio),
                   "stdio must be active with env unset")
        try expect(TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "1"]).isActive(.stdio),
                   "stdio must remain active with HTTP on")
        try expect(!TransportRouter(environment: [:]).isActive(.streamableHTTP),
                   "streamableHTTP must stay off with env unset")
    }
}

private func s4CompactToolCall(
    server: SSEServer,
    token: String,
    sessionID: String?,
    tool: String,
    arguments: [String: Any],
    id: Int
) async throws -> [String: Any] {
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": ["name": tool, "arguments": arguments] as [String: Any],
    ] as [String: Any])
    var headers = [
        "Cf-Connecting-Ip": "203.0.113.146",
        "Authorization": "Bearer \(token)",
    ]
    if let sessionID { headers["Mcp-Session-Id"] = sessionID }
    let response = await server.handleHTTPRequest(HTTPRequest(
        method: "POST", headers: headers, body: body
    ))
    guard response.statusCode == 200, let responseBody = response.bodyData,
          let object = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else {
        throw TestError.assertion("compact connector call \(tool) returned malformed HTTP \(response.statusCode)")
    }
    return object
}

private func s4CompactResult(_ response: [String: Any]) throws -> [String: Any] {
    guard let result = response["result"] as? [String: Any] else {
        throw TestError.assertion("compact response is missing result: \(response)")
    }
    return result
}

private func s4CompactText(_ response: [String: Any]) throws -> String {
    let result = try s4CompactResult(response)
    guard let content = result["content"] as? [[String: Any]],
          let text = content.first?["text"] as? String else {
        throw TestError.assertion("compact response is missing text content: \(result)")
    }
    return text
}

private func s4CompactIsError(_ response: [String: Any]) throws -> Bool {
    let result = try s4CompactResult(response)
    guard let isError = result["isError"] as? Bool else {
        throw TestError.assertion("compact response is missing isError: \(result)")
    }
    return isError
}

private func s4CompactPayload(_ response: [String: Any]) throws -> [String: Any] {
    let text = try s4CompactText(response)
    guard let data = text.data(using: .utf8),
          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestError.assertion("tool text is not a JSON object: \(text)")
    }
    return payload
}

private func s4CompactReceipt(_ response: [String: Any], scopeID: String) throws -> [String: Any] {
    let payload = try s4CompactPayload(response)
    guard let receipts = payload["routingReceipts"] as? [[String: Any]],
          let receipt = receipts.first(where: { $0["scopeID"] as? String == scopeID }) else {
        throw TestError.assertion("fetch_skill did not issue receipt for \(scopeID): \(payload)")
    }
    return receipt
}
