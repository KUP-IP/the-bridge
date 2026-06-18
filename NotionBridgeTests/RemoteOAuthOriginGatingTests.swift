// RemoteOAuthOriginGatingTests.swift — PKT-810 R5 (origin split: loopback never gated)
// NotionBridge · Tests (custom harness — no XCTest)
//
// The connector `/mcp` path serves TWO callers, split purely on origin:
//   • REMOTE (Cloudflare tunnel — `Cf-Connecting-Ip` / `Cf-Ray` present) → must
//     present a valid AuthKit OAuth JWT, else 401 + RFC 9728 challenge.
//   • LOCAL (direct loopback — no tunnel header) → TOKEN-FREE. The documented
//     contract (ConnectionsSection UI): "Local clients on this Mac connect with
//     no token — the bearer applies only off-loopback." A loopback request is a
//     local process on 127.0.0.1 and is served as already-authorized; it is
//     NEVER pushed into a cloud OAuth discovery (the WorkOS Dynamic Client
//     Registration dead-end the R5 fix removes).
//
// Security invariant under test: the OAuth bearer gate applies to REMOTE
// requests ONLY — a tunnel request can never be served without a valid JWT, and
// the prior PKT-810 "loopback static bearer" (which gated loopback behind a
// secret the OAuth desktop client never sends) is gone.

import Foundation
import JWTKit
import MCP
import NotionBridgeLib

private let ogIssuer = "https://auth.kup.solutions"
private let ogResource = "http://127.0.0.1:9700/mcp"
private let ogPRM = "http://127.0.0.1:9700/.well-known/oauth-protected-resource"

private struct OGKeys {
    let signing: JWTKeyCollection
    let verify: JWTKeyCollection
    static func make() async -> OGKeys {
        let priv = ES256PrivateKey()
        let s = JWTKeyCollection(); await s.add(ecdsa: priv)
        let v = JWTKeyCollection(); await v.add(ecdsa: priv.publicKey)
        return OGKeys(signing: s, verify: v)
    }
    func sign(scope: String?) async throws -> String {
        try await signing.sign(BridgeAccessToken(
            iss: IssuerClaim(value: ogIssuer),
            aud: AudienceClaim(value: [ogResource]),
            sub: SubjectClaim(value: "user-og"),
            exp: ExpirationClaim(value: Date().addingTimeInterval(300)),
            nbf: nil,
            scope: scope
        ))
    }
}

func runRemoteOAuthOriginGatingTests() async {
    print("\n\u{1F510} Remote OAuth Origin Gating (PKT-810 R5 — loopback token-free, tunnel OAuth-gated)")

    let keys = await OGKeys.make()
    let validator: @Sendable () -> ConnectorBearerValidator = {
        ConnectorBearerValidator(
            keys: keys.verify, hasKeys: true,
            expectedIssuer: ogIssuer, expectedAudience: ogResource
        )
    }
    let auth: @Sendable () -> ConnectorAuthContext = {
        ConnectorAuthContext(validator: validator(), resourceMetadataURL: ogPRM)
    }

    func server() -> SSEServer {
        SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: auth()
        )
    }

    func streamText(from response: HTTPResponse) async throws -> String {
        guard case .stream(let stream, _) = response else {
            throw TestError.assertion("expected SSE stream response, got status \(response.statusCode)")
        }
        var text = ""
        for try await data in stream {
            text += String(decoding: data, as: UTF8.self)
        }
        return text
    }

    func initBody() -> Data {
        Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\(BridgeConstants.mcpProtocolVersion)","capabilities":{},"clientInfo":{"name":"origin-gating-check","version":"test"}}}
        """.utf8)
    }
    let localHeaders = [
        "Host": "127.0.0.1:9700",
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
    ]

    // MARK: - Pure discriminator

    await test("OriginGate: Cf-Connecting-Ip OR Cf-Ray ⇒ remote; neither ⇒ local") {
        try expect(SSEServer.isRemoteTunnelRequest(
            HTTPRequest(method: "POST", headers: ["Cf-Connecting-Ip": "1.2.3.4"], body: nil)),
            "Cf-Connecting-Ip must mark remote")
        try expect(SSEServer.isRemoteTunnelRequest(
            HTTPRequest(method: "POST", headers: ["cf-ray": "abc-123"], body: nil)),
            "Cf-Ray (any case) must mark remote")
        try expect(!SSEServer.isRemoteTunnelRequest(
            HTTPRequest(method: "POST", headers: ["Authorization": "Bearer x"], body: nil)),
            "no CF header must mark local")
    }

    // MARK: - LOCAL (loopback) is token-free

    await test("OriginGate: LOCAL + NO Authorization ⇒ served (not 401), session minted") {
        let resp = await server().handleHTTPRequest(HTTPRequest(
            method: "POST", headers: localHeaders, body: initBody()
        ))
        try expect(resp.statusCode != 401, "loopback with no token must not 401, got \(resp.statusCode)")
        try expect(resp.headers[HTTPHeaderName.sessionID] != nil,
                   "loopback initialize must mint a session id (token-free)")
    }

    await test("OriginGate: LOCAL + arbitrary non-JWT bearer ⇒ still served (loopback never gated)") {
        var headers = localHeaders
        headers["Authorization"] = "Bearer not-a-jwt-and-not-a-secret"
        let resp = await server().handleHTTPRequest(HTTPRequest(
            method: "POST", headers: headers, body: initBody()
        ))
        try expect(resp.statusCode != 401, "loopback must not 401 regardless of bearer, got \(resp.statusCode)")
        try expect(resp.statusCode != 403, "loopback must not 403 regardless of bearer, got \(resp.statusCode)")
    }

    await test("OriginGate: LOCAL keeps full local tool surface (token-free init + tools/call)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await router.register(ToolRegistration(
            name: "local_probe",
            module: "test",
            tier: .open,
            description: "Local-only probe for token-free loopback sessions.",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .string("local-ok") }
        ))
        let s = SSEServer(
            router: router,
            onToolCall: {},
            toolAllowlist: ConnectorScopeGate.connectorReachableTools,
            connectorAuth: auth()
        )
        let initResp = await s.handleHTTPRequest(HTTPRequest(
            method: "POST", headers: localHeaders, body: initBody()
        ))
        guard let sessionID = initResp.headers[HTTPHeaderName.sessionID] else {
            throw TestError.assertion("token-free loopback initialize must return a session id")
        }
        _ = try await streamText(from: initResp)

        var callHeaders = localHeaders
        callHeaders[HTTPHeaderName.sessionID] = sessionID
        let callBody = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"local_probe","arguments":{}}}"#.utf8)
        let callResp = await s.handleHTTPRequest(HTTPRequest(
            method: "POST", headers: callHeaders, body: callBody
        ))
        let callText = try await streamText(from: callResp)
        try expect(!callText.contains("not allowed in this session"),
                   "loopback session must not inherit the connector allowlist: \(callText)")
        try expect(callText.contains("local-ok"),
                   "local-only tool must dispatch on token-free loopback sessions: \(callText)")
    }

    await test("OriginGate: LOCAL + valid JWT ⇒ also served (not 401)") {
        let tok = try await keys.sign(scope: "offline_access")
        var headers = localHeaders
        headers["Authorization"] = "Bearer \(tok)"
        let resp = await server().handleHTTPRequest(HTTPRequest(
            method: "POST", headers: headers, body: initBody()
        ))
        try expect(resp.statusCode != 401, "local+valid-JWT must be served, got \(resp.statusCode)")
    }

    // MARK: - REMOTE (tunnel) stays fully OAuth-gated

    await test("OriginGate: REMOTE + NO token ⇒ 401 (tunnel must authenticate)") {
        let resp = await server().handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Ray": "abc-123", "Host": "127.0.0.1:9700"],
            body: nil
        ))
        try expect(resp.statusCode == 401, "tunnel with no token must 401, got \(resp.statusCode)")
    }

    await test("OriginGate: REMOTE + arbitrary non-JWT bearer ⇒ 401 (no static-bearer bypass)") {
        let resp = await server().handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Authorization": "Bearer loopback-static-secret-DEADBEEF",
                "Cf-Connecting-Ip": "203.0.113.7",
            ],
            body: nil
        ))
        try expect(resp.statusCode == 401,
                   "a non-JWT bearer over the tunnel MUST be rejected, got \(resp.statusCode)")
    }

    await test("OriginGate: REMOTE + valid JWT ⇒ OAuth-validated (not 401)") {
        let tok = try await keys.sign(scope: "offline_access")
        let resp = await server().handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(tok)", "Cf-Connecting-Ip": "203.0.113.7"],
            body: Data(#"{"method":"tools/list"}"#.utf8)
        ))
        try expect(resp.statusCode != 401, "remote+valid-JWT must pass OAuth, got \(resp.statusCode)")
    }
}
