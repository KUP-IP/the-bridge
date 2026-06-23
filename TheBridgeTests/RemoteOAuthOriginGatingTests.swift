// RemoteOAuthOriginGatingTests.swift — PKT-810 R5 (origin split: loopback never gated)
// TheBridge · Tests (custom harness — no XCTest)
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
import NIOEmbedded
import NIOCore
import NIOHTTP1
import TheBridgeLib

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

    // MARK: - Legacy /sse + /messages are LOOPBACK-ONLY (PKT-810 R5 hardening)
    //
    // The legacy SSE transport (PKT-336: GET /sse + POST /messages) is dispatched
    // in the NIO handler BEFORE the `/mcp` connector-auth gate in
    // `handleHTTPRequest`, so the gate that protects `/mcp` does NOT cover it.
    // Without the explicit tunnel-origin refusal (R5 hardening), a Cloudflare
    // tunnel caller could open an UNAUTHENTICATED legacy session and drive the
    // full tool surface — a full bypass of the connector-auth gate. cloudflared
    // forwards every path to :9700 (no path scoping), so the server itself must
    // refuse tunnel-origin legacy requests. We prove the gate's decision inputs
    // through REAL NIO header decoding: a tunnel request decodes to the legacy
    // route AND trips the tunnel predicate (→ 403), while a loopback request
    // decodes to the same route and does NOT (→ served, unchanged).

    await test("OriginGate(legacy): HTTPHeaders discriminator mirrors the HTTPRequest one") {
        try expect(SSEServer.isRemoteTunnelRequest(headers: HTTPHeaders([("Cf-Connecting-Ip", "1.2.3.4")])),
                   "Cf-Connecting-Ip header must mark remote")
        try expect(SSEServer.isRemoteTunnelRequest(headers: HTTPHeaders([("cf-ray", "abc-123")])),
                   "Cf-Ray (any case) must mark remote")
        try expect(!SSEServer.isRemoteTunnelRequest(headers: HTTPHeaders([("Authorization", "Bearer x")])),
                   "no CF header must mark local")
        try expect(!SSEServer.isRemoteTunnelRequest(headers: HTTPHeaders()),
                   "empty headers must mark local")
    }

    func decodeHead(_ raw: String) throws -> HTTPRequestHead {
        let channel = EmbeddedChannel()
        try channel.pipeline.configureHTTPServerPipeline().wait()
        var buf = channel.allocator.buffer(capacity: raw.utf8.count)
        buf.writeString(raw)
        try channel.writeInbound(buf)
        defer { _ = try? channel.finish() }
        guard let part = try channel.readInbound(as: HTTPServerRequestPart.self),
              case .head(let head) = part else {
            throw TestError.assertion("expected a decoded .head for: \(raw)")
        }
        return head
    }

    func legacyRoute(_ head: HTTPRequestHead) -> MCPHTTPRoute {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        return MCPHTTPRoute.classify(method: head.method.rawValue, path: path, endpoint: "/mcp")
    }

    await test("OriginGate(legacy): TUNNEL GET /sse ⇒ legacySSE + tunnel predicate trips (would 403)") {
        let head = try decodeHead("GET /sse HTTP/1.1\r\nHost: 127.0.0.1:9700\r\nCf-Ray: abc-123\r\n\r\n")
        try expect(legacyRoute(head) == .legacySSE, "GET /sse must classify as legacySSE, got \(legacyRoute(head))")
        try expect(SSEServer.isRemoteTunnelRequest(headers: head.headers),
                   "a tunnel GET /sse MUST trip the loopback-only gate (→ refused)")
    }

    await test("OriginGate(legacy): LOOPBACK GET /sse ⇒ legacySSE + predicate false (served, unchanged)") {
        let head = try decodeHead("GET /sse HTTP/1.1\r\nHost: 127.0.0.1:9700\r\n\r\n")
        try expect(legacyRoute(head) == .legacySSE, "GET /sse must classify as legacySSE")
        try expect(!SSEServer.isRemoteTunnelRequest(headers: head.headers),
                   "a direct-loopback GET /sse must NOT trip the gate (older local clients keep working)")
    }

    await test("OriginGate(legacy): TUNNEL POST /messages ⇒ legacyMessages + tunnel predicate trips (would 403)") {
        let head = try decodeHead("POST /messages?sessionId=x HTTP/1.1\r\nHost: 127.0.0.1:9700\r\nCf-Connecting-Ip: 203.0.113.7\r\nContent-Length: 0\r\n\r\n")
        try expect(legacyRoute(head) == .legacyMessages, "POST /messages must classify as legacyMessages, got \(legacyRoute(head))")
        try expect(SSEServer.isRemoteTunnelRequest(headers: head.headers),
                   "a tunnel POST /messages MUST trip the loopback-only gate (→ refused)")
    }

    await test("OriginGate(legacy): LOOPBACK POST /messages ⇒ legacyMessages + predicate false (served, unchanged)") {
        let head = try decodeHead("POST /messages?sessionId=x HTTP/1.1\r\nHost: 127.0.0.1:9700\r\nContent-Length: 0\r\n\r\n")
        try expect(legacyRoute(head) == .legacyMessages, "POST /messages must classify as legacyMessages")
        try expect(!SSEServer.isRemoteTunnelRequest(headers: head.headers),
                   "a direct-loopback POST /messages must NOT trip the gate")
    }
}
