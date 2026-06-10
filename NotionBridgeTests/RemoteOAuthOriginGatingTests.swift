// RemoteOAuthOriginGatingTests.swift — PKT-810 (local↔cloud coexistence)
// NotionBridge · Tests (custom harness — no XCTest)
//
// The connector `/mcp` path serves TWO callers after PKT-810:
//   • REMOTE (Cloudflare tunnel, Cf-Connecting-Ip / Cf-Ray present) → must
//     present a valid AuthKit OAuth JWT.
//   • LOCAL (direct loopback, no tunnel header) → a valid JWT still OAuth-
//     validates; otherwise the loopback STATIC bearer is accepted as a
//     fallback so the local desktop stdio-proxy keeps working.
//
// Security invariant under test: the static bearer is LOOPBACK-SCOPED — it can
// NEVER authorize a tunnel request (no cloud OAuth bypass). And the fallback is
// inert when no local bearer is configured (zero impact on the OAuth-only path).

import Foundation
import JWTKit
import MCP
import NotionBridgeLib

private let ogIssuer = "https://auth.kup.solutions"
private let ogResource = "http://127.0.0.1:9700/mcp"
private let ogPRM = "http://127.0.0.1:9700/.well-known/oauth-protected-resource"
private let ogLocalBearer = "loopback-static-secret-DEADBEEF"

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
    print("\n\u{1F510} Remote OAuth Origin Gating (PKT-810 coexistence)")

    let keys = await OGKeys.make()
    let validator: @Sendable () -> ConnectorBearerValidator = {
        ConnectorBearerValidator(
            keys: keys.verify, hasKeys: true,
            expectedIssuer: ogIssuer, expectedAudience: ogResource
        )
    }
    // Connector context WITH a loopback static bearer configured.
    let authWithLocal: @Sendable () -> ConnectorAuthContext = {
        ConnectorAuthContext(
            validator: validator(),
            resourceMetadataURL: ogPRM,
            localBearer: ogLocalBearer
        )
    }
    // Connector context WITHOUT a local bearer (pure OAuth-only — proves the
    // fallback is inert by default).
    let authNoLocal: @Sendable () -> ConnectorAuthContext = {
        ConnectorAuthContext(validator: validator(), resourceMetadataURL: ogPRM)
    }

    func server(_ ctx: ConnectorAuthContext) -> SSEServer {
        SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: ctx
        )
    }

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

    // MARK: - Loopback static-bearer fallback

    await test("OriginGate: LOCAL + correct static bearer ⇒ passes auth (not 401)") {
        let resp = await server(authWithLocal()).handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(ogLocalBearer)"],
            body: Data(#"{"method":"tools/list"}"#.utf8)
        ))
        // Auth passed → falls through to session machinery (pre-S2 contract);
        // the point is it is NOT an auth rejection.
        try expect(resp.statusCode != 401, "local+correct-bearer must not 401, got \(resp.statusCode)")
        try expect(resp.statusCode != 403, "local+correct-bearer must not 403, got \(resp.statusCode)")
    }

    await test("OriginGate: LOCAL + wrong static bearer ⇒ 401") {
        let resp = await server(authWithLocal()).handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer not-the-secret"],
            body: nil
        ))
        try expect(resp.statusCode == 401, "local+wrong-bearer must 401, got \(resp.statusCode)")
    }

    // MARK: - Security invariant: static bearer is loopback-scoped

    await test("OriginGate: REMOTE + static bearer ⇒ 401 (no cloud OAuth bypass)") {
        let resp = await server(authWithLocal()).handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: [
                "Authorization": "Bearer \(ogLocalBearer)",
                "Cf-Connecting-Ip": "203.0.113.7",
            ],
            body: nil
        ))
        try expect(resp.statusCode == 401,
                   "static bearer over the tunnel MUST be rejected, got \(resp.statusCode)")
    }

    // MARK: - OAuth path is origin-agnostic for valid JWTs

    await test("OriginGate: REMOTE + valid JWT ⇒ OAuth-validated (not 401)") {
        let tok = try await keys.sign(scope: "offline_access")
        let resp = await server(authWithLocal()).handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(tok)", "Cf-Connecting-Ip": "203.0.113.7"],
            body: Data(#"{"method":"tools/list"}"#.utf8)
        ))
        try expect(resp.statusCode != 401, "remote+valid-JWT must pass OAuth, got \(resp.statusCode)")
    }

    await test("OriginGate: LOCAL + valid JWT ⇒ still OAuth-validated (not 401)") {
        let tok = try await keys.sign(scope: "offline_access")
        let resp = await server(authWithLocal()).handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(tok)"],
            body: Data(#"{"method":"tools/list"}"#.utf8)
        ))
        try expect(resp.statusCode != 401, "local+valid-JWT must pass OAuth, got \(resp.statusCode)")
    }

    // MARK: - Fallback inert when no local bearer configured

    await test("OriginGate: no localBearer ⇒ LOCAL + static bearer still 401 (pure OAuth-only)") {
        let resp = await server(authNoLocal()).handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(ogLocalBearer)"],
            body: nil
        ))
        try expect(resp.statusCode == 401,
                   "with no local bearer, a non-JWT must 401 even on loopback, got \(resp.statusCode)")
    }
}
