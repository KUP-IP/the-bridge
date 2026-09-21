// RemoteOAuthBearerTests.swift — PKT-800 S2 (remote OAuth/HTTP, slice 2)
// TheBridge · Tests (custom harness — no XCTest)
//
// Covers, all against a synthetic in-test ES256 keypair (no network, no
// live IdP, no JWKS fetch):
//   • Bearer header extraction (scheme-insensitive, malformed, empty).
//   • ConnectorBearerValidator: valid token accepted (subject + scopes carried
//     out); expired / not-yet-valid / wrong-iss / wrong-aud / bad-sig (key
//     mismatch) / malformed all rejected with the right typed error.
//   • fail-closed: a validator with no keys rejects every token.
//   • ConnectorScopeGate: read-scope token blocked from a write/delete
//     tool; correct scope passes; write implies read; non-connector tools
//     denied regardless of scope; required-scope table is exhaustive.
//   • ConnectorAuthContext: 401 + RFC 6750 WWW-Authenticate referencing
//     the RFC 9728 PRM document; missing vs invalid error codes.
//   • SSEServer connector-path helpers: unauthorizedResponse shape,
//     toolCallTarget extraction, and the additive-isolation invariant
//     (default SSEServer has connectorAuth == nil so bearer is NOT
//     required on /mcp, /health, legacy SSE — non-regression).
//   • PRM `resource` reflects NOTION_BRIDGE_PORT override + default
//     (S1 hardcoded-9700 finding fix).

import Foundation
import JWTKit
import MCP
import NIOEmbedded
import NIOCore
import NIOHTTP1
import TheBridgeLib

// MARK: - Synthetic key fixture (no network)

private struct OAuthTestKeys {
    let privateKeys: JWTKeyCollection   // signs test tokens
    let verifyKeys: JWTKeyCollection    // validator's key set (public only)
    let wrongVerifyKeys: JWTKeyCollection // a *different* keypair's public key

    static func make() async -> OAuthTestKeys {
        let priv = ES256PrivateKey()
        let signing = JWTKeyCollection()
        await signing.add(ecdsa: priv)
        let verify = JWTKeyCollection()
        await verify.add(ecdsa: priv.publicKey)

        // An unrelated keypair → its public key must NOT verify our tokens.
        let otherPriv = ES256PrivateKey()
        let wrong = JWTKeyCollection()
        await wrong.add(ecdsa: otherPriv.publicKey)

        return OAuthTestKeys(
            privateKeys: signing,
            verifyKeys: verify,
            wrongVerifyKeys: wrong
        )
    }

    func sign(
        iss: String,
        aud: String,
        sub: String? = "user-123",
        scope: String?,
        exp: Date = Date().addingTimeInterval(300),
        nbf: Date? = nil
    ) async throws -> String {
        let payload = BridgeAccessToken(
            iss: IssuerClaim(value: iss),
            aud: AudienceClaim(value: [aud]),
            sub: sub.map { SubjectClaim(value: $0) },
            exp: ExpirationClaim(value: exp),
            nbf: nbf.map { NotBeforeClaim(value: $0) },
            scope: scope
        )
        return try await privateKeys.sign(payload)
    }
}

private let kIssuer = "https://auth.kup.solutions"
private let kResource = "http://127.0.0.1:9700/mcp"

func runRemoteOAuthBearerTests() async {
    print("\n\u{1F510} Remote OAuth Bearer / ScopeGate (PKT-800 S2)")

    let keys = await OAuthTestKeys.make()

    func validator(
        keys collection: JWTKeyCollection,
        hasKeys: Bool = true,
        iss: String = kIssuer,
        aud: String = kResource
    ) -> ConnectorBearerValidator {
        ConnectorBearerValidator(
            keys: collection, hasKeys: hasKeys,
            expectedIssuer: iss, expectedAudience: aud
        )
    }

    // MARK: - Bearer header extraction

    await test("Bearer: extracts token from well-formed header") {
        try expect(
            ConnectorBearerValidator.bearerToken(fromAuthorizationHeader: "Bearer abc.def.ghi") == "abc.def.ghi"
        )
    }

    await test("Bearer: scheme match is case-insensitive") {
        try expect(ConnectorBearerValidator.bearerToken(fromAuthorizationHeader: "bearer xyz") == "xyz")
        try expect(ConnectorBearerValidator.bearerToken(fromAuthorizationHeader: "BEARER xyz") == "xyz")
    }

    await test("Bearer: nil / empty / non-Bearer / empty-token → nil") {
        try expect(ConnectorBearerValidator.bearerToken(fromAuthorizationHeader: nil) == nil)
        try expect(ConnectorBearerValidator.bearerToken(fromAuthorizationHeader: "") == nil)
        try expect(ConnectorBearerValidator.bearerToken(fromAuthorizationHeader: "Basic abc") == nil)
        try expect(ConnectorBearerValidator.bearerToken(fromAuthorizationHeader: "Bearer ") == nil)
        try expect(ConnectorBearerValidator.bearerToken(fromAuthorizationHeader: "Bearer") == nil)
    }

    // MARK: - Validator: accept

    await test("Validator: valid token accepted; subject + scopes carried out") {
        let tok = try await keys.sign(
            iss: kIssuer, aud: kResource, sub: "user-xyz",
            scope: "snippets.read runners.exec"
        )
        let v = validator(keys: keys.verifyKeys)
        let claims = try await v.validate(authorizationHeader: "Bearer \(tok)")
        try expect(claims.subject == "user-xyz", "subject not carried: \(claims.subject)")
        let names = Set(claims.connectorScopes.map(\.name))
        try expect(names == ["snippets.read", "runners.exec"], "scopes drifted: \(names)")
    }

    await test("Validator: scope claim parsing de-dupes + splits on whitespace/tab") {
        let tok = try await keys.sign(
            iss: kIssuer, aud: kResource,
            scope: "snippets.read  snippets.read\trunners.exec"
        )
        let claims = try await validator(keys: keys.verifyKeys)
            .validate(authorizationHeader: "Bearer \(tok)")
        try expect(claims.connectorScopes.count == 2, "expected 2 unique, got \(claims.connectorScopes)")
    }

    await test("Validator: nil/empty scope claim → empty connector scopes") {
        let tok = try await keys.sign(iss: kIssuer, aud: kResource, scope: nil)
        let claims = try await validator(keys: keys.verifyKeys)
            .validate(authorizationHeader: "Bearer \(tok)")
        try expect(claims.connectorScopes.isEmpty, "expected no scopes")
    }

    // MARK: - Validator: reject

    await test("Validator: signed token without a usable subject is rejected") {
        for subject in [nil, "", "   "] as [String?] {
            let tok = try await keys.sign(
                iss: kIssuer, aud: kResource, sub: subject, scope: "snippets.read"
            )
            do {
                _ = try await validator(keys: keys.verifyKeys)
                    .validate(authorizationHeader: "Bearer \(tok)")
                throw TestError.assertion("sub-less token must be rejected")
            } catch let error as BearerValidationError {
                guard case .subjectMissing = error else {
                    throw TestError.assertion("expected subjectMissing, got \(error)")
                }
            }
        }
    }

    await test("Validator: expired token rejected") {
        let tok = try await keys.sign(
            iss: kIssuer, aud: kResource, scope: "snippets.read",
            exp: Date().addingTimeInterval(-3600)
        )
        do {
            _ = try await validator(keys: keys.verifyKeys).validate(authorizationHeader: "Bearer \(tok)")
            throw TestError.assertion("expired token must be rejected")
        } catch is BearerValidationError {}
    }

    await test("Validator: not-yet-valid (nbf in future) rejected") {
        let tok = try await keys.sign(
            iss: kIssuer, aud: kResource, scope: "snippets.read",
            nbf: Date().addingTimeInterval(3600)
        )
        do {
            _ = try await validator(keys: keys.verifyKeys).validate(authorizationHeader: "Bearer \(tok)")
            throw TestError.assertion("nbf-future token must be rejected")
        } catch is BearerValidationError {}
    }

    await test("Validator: wrong issuer rejected with issuerMismatch") {
        let tok = try await keys.sign(
            iss: "https://evil.example", aud: kResource, scope: "snippets.read"
        )
        do {
            _ = try await validator(keys: keys.verifyKeys).validate(authorizationHeader: "Bearer \(tok)")
            throw TestError.assertion("wrong-iss must be rejected")
        } catch let e as BearerValidationError {
            guard case .issuerMismatch = e else {
                throw TestError.assertion("expected issuerMismatch, got \(e)")
            }
        }
    }

    await test("Validator: wrong audience rejected with audienceMismatch") {
        let tok = try await keys.sign(
            iss: kIssuer, aud: "http://127.0.0.1:9999/mcp", scope: "snippets.read"
        )
        do {
            _ = try await validator(keys: keys.verifyKeys).validate(authorizationHeader: "Bearer \(tok)")
            throw TestError.assertion("wrong-aud must be rejected")
        } catch let e as BearerValidationError {
            guard case .audienceMismatch = e else {
                throw TestError.assertion("expected audienceMismatch, got \(e)")
            }
        }
    }

    await test("Validator: bad signature (key mismatch) rejected with signatureInvalid") {
        let tok = try await keys.sign(iss: kIssuer, aud: kResource, scope: "snippets.read")
        // Verify against an UNRELATED keypair's public key.
        do {
            _ = try await validator(keys: keys.wrongVerifyKeys)
                .validate(authorizationHeader: "Bearer \(tok)")
            throw TestError.assertion("token signed by other key must fail")
        } catch let e as BearerValidationError {
            guard case .signatureInvalid = e else {
                throw TestError.assertion("expected signatureInvalid, got \(e)")
            }
        }
    }

    await test("Validator: malformed JWT string rejected") {
        do {
            _ = try await validator(keys: keys.verifyKeys)
                .validate(authorizationHeader: "Bearer not-a-jwt")
            throw TestError.assertion("garbage token must be rejected")
        } catch let e as BearerValidationError {
            guard case .malformedToken = e else {
                throw TestError.assertion("expected malformedToken, got \(e)")
            }
        }
    }

    await test("Validator: missing bearer → .missingBearer") {
        do {
            _ = try await validator(keys: keys.verifyKeys).validate(authorizationHeader: nil)
            throw TestError.assertion("nil header must be missingBearer")
        } catch let e as BearerValidationError {
            guard case .missingBearer = e else {
                throw TestError.assertion("expected missingBearer, got \(e)")
            }
        }
    }

    await test("Validator: malformed Authorization header → .malformedAuthorizationHeader") {
        do {
            _ = try await validator(keys: keys.verifyKeys)
                .validate(authorizationHeader: "Token abc")
            throw TestError.assertion("non-Bearer scheme must be malformedAuthorizationHeader")
        } catch let e as BearerValidationError {
            guard case .malformedAuthorizationHeader = e else {
                throw TestError.assertion("expected malformedAuthorizationHeader, got \(e)")
            }
        }
    }

    await test("Validator: fail-closed — no keys rejects even a well-formed token") {
        let tok = try await keys.sign(iss: kIssuer, aud: kResource, scope: "snippets.read")
        let v = validator(keys: JWTKeyCollection(), hasKeys: false)
        do {
            _ = try await v.validate(authorizationHeader: "Bearer \(tok)")
            throw TestError.assertion("key-less validator must reject")
        } catch let e as BearerValidationError {
            guard case .misconfigured = e else {
                throw TestError.assertion("expected misconfigured, got \(e)")
            }
        }
    }

    await test("Validator: fromEnvironment with no BRIDGE_OAUTH_JWKS is fail-closed") {
        // Pin the config seam empty (Packet E W2): env-absent now falls
        // through to config.json (`oauthJWKS`), so inject nil to keep this
        // hermetic regardless of any on-disk key source.
        let v = await ConnectorBearerValidator.fromEnvironment(
            environment: [:], config: { _ in nil },
            expectedIssuer: kIssuer, expectedAudience: kResource
        )
        let tok = try await keys.sign(iss: kIssuer, aud: kResource, scope: "snippets.read")
        do {
            _ = try await v.validate(authorizationHeader: "Bearer \(tok)")
            throw TestError.assertion("env-less validator must be fail-closed")
        } catch let e as BearerValidationError {
            guard case .misconfigured = e else {
                throw TestError.assertion("expected misconfigured, got \(e)")
            }
        }
    }

    // MARK: - ConnectorScopeGate

    let gate = ConnectorScopeGate()

    await test("ScopeGate PKT-810: scope-less (authenticated directory) token ALLOWED on any reachable tool") {
        // The AuthKit directory token carries no connector scopes. Each
        // connector-reachable tool — across every bucket — must be allowed:
        // authentication is the grant, SecurityGate/step-up are the per-call guard.
        for tool in ["snippets_list", "snippets_create", "snippets_delete",
                     "shell_exec", "job_run", "bridge_initialize", "bridge_status",
                     "tools_list", "tools_search", "session_info", "contacts_get", "contacts_resolve_handle"] {
            let d = await gate.evaluate(toolName: tool, grantedScopes: [])
            guard case .allow = d else {
                throw TestError.assertion("scope-less token must reach reachable tool \(tool)")
            }
        }
    }

    await test("ScopeGate PKT-810: scope-less token STILL denied on a non-connector tool (allowlist intact)") {
        for tool in ["file_read", "notion_query", "messages_send", "screen_capture"] {
            let d = await gate.evaluate(toolName: tool, grantedScopes: [])
            guard case .deny = d else {
                throw TestError.assertion("scope-less token must NOT reach off-allowlist tool \(tool)")
            }
        }
    }

    await test("ScopeGate: read-scope token BLOCKED from a write tool") {
        let d = await gate.evaluate(
            toolName: "snippets_create",
            grantedScopes: [ConnectorScope(name: "snippets.read")]
        )
        guard case .deny = d else {
            throw TestError.assertion("snippets.read must NOT reach snippets_create")
        }
    }

    await test("ScopeGate: read-scope token BLOCKED from a delete (destructive) tool") {
        let d = await gate.evaluate(
            toolName: "snippets_delete",
            grantedScopes: [ConnectorScope(name: "snippets.read")]
        )
        guard case .deny = d else {
            throw TestError.assertion("snippets.read must NOT reach snippets_delete")
        }
    }

    await test("ScopeGate: read-scope token ALLOWED on a read tool") {
        let d = await gate.evaluate(
            toolName: "snippets_list",
            grantedScopes: [ConnectorScope(name: "snippets.read")]
        )
        guard case .allow = d else {
            throw TestError.assertion("snippets.read must reach snippets_list")
        }
    }

    await test("ScopeGate: write scope strictly implies read (satisfies read-only tools)") {
        let d = await gate.evaluate(
            toolName: "snippets_get",
            grantedScopes: [ConnectorScope(name: "snippets.write")]
        )
        guard case .allow = d else {
            throw TestError.assertion("snippets.write must satisfy read-only snippets_get")
        }
    }

    await test("ScopeGate: write scope ALLOWED on a write tool") {
        let d = await gate.evaluate(
            toolName: "snippets_update",
            grantedScopes: [ConnectorScope(name: "snippets.write")]
        )
        guard case .allow = d else {
            throw TestError.assertion("snippets.write must reach snippets_update")
        }
    }

    await test("ScopeGate: runners.exec gates command/exec tools") {
        for tool in ["shell_exec", "run_script", "worktree_command_run", "bg_run", "job_run"] {
            let denied = await gate.evaluate(
                toolName: tool, grantedScopes: [ConnectorScope(name: "snippets.read")]
            )
            guard case .deny = denied else {
                throw TestError.assertion("\(tool) must require runners.exec, not snippets.read")
            }
            let allowed = await gate.evaluate(
                toolName: tool, grantedScopes: [ConnectorScope(name: "runners.exec")]
            )
            guard case .allow = allowed else {
                throw TestError.assertion("runners.exec must reach \(tool)")
            }
        }
    }

    await test("ScopeGate: voice.resolve gates identity-resolution tools") {
        let allowed = await gate.evaluate(
            toolName: "contacts_resolve_handle",
            grantedScopes: [ConnectorScope(name: "voice.resolve")]
        )
        guard case .allow = allowed else {
            throw TestError.assertion("voice.resolve must reach contacts_resolve_handle")
        }
        let denied = await gate.evaluate(
            toolName: "contacts_resolve_handle",
            grantedScopes: [ConnectorScope(name: "snippets.read")]
        )
        guard case .deny = denied else {
            throw TestError.assertion("snippets.read must NOT reach contacts_resolve_handle")
        }
    }

    await test("ScopeGate: non-connector tool DENIED regardless of scopes") {
        let allScopes = ConnectorScopeName.all.map { ConnectorScope(name: $0) }
        let d = await gate.evaluate(toolName: "file_write", grantedScopes: allScopes)
        guard case .deny(let reason) = d else {
            throw TestError.assertion("file_write is not connector-reachable; must deny")
        }
        try expect(reason.contains("not exposed"), "deny reason should explain non-exposure")
    }

    await test("ScopeGate PKT-810: empty granted scopes ALLOWS a connector-reachable tool (directory model)") {
        // Superseded the pre-PKT-810 "no scopes ⇒ deny" invariant. WorkOS
        // AuthKit can't mint the connector's custom scopes, so an authenticated
        // directory token carries none; authentication is the grant for the
        // reachable allowlist (off-allowlist tools still denied — covered above).
        let d = await gate.evaluate(toolName: "snippets_list", grantedScopes: [])
        guard case .allow = d else {
            throw TestError.assertion("scope-less authenticated token must reach a reachable tool")
        }
    }

    await test("ScopeGate PKT-810: OpenID-only AuthKit token follows directory model") {
        let openIDScopes = [
            ConnectorScope(name: "openid"),
            ConnectorScope(name: "email"),
            ConnectorScope(name: "profile"),
            ConnectorScope(name: "offline_access"),
        ]
        let reachable = await gate.evaluate(toolName: "snippets_list", grantedScopes: openIDScopes)
        guard case .allow = reachable else {
            throw TestError.assertion("OpenID-only token must reach connector allowlist tools")
        }
        let bootstrap = await gate.evaluate(toolName: "bridge_initialize", grantedScopes: openIDScopes)
        guard case .allow = bootstrap else {
            throw TestError.assertion("OpenID-only token must reach bridge_initialize")
        }
        let offAllowlist = await gate.evaluate(toolName: "file_write", grantedScopes: openIDScopes)
        guard case .deny = offAllowlist else {
            throw TestError.assertion("OpenID-only token must not reach off-allowlist tools")
        }
    }

    await test("ScopeGate: requiredScopes — read tool lists BOTH read and write") {
        let req = try await gate.requiredScopes(for: "snippets_search").map(\.name)
        try expect(Set(req) == ["snippets.read", "snippets.write"], "got \(req)")
    }

    await test("ScopeGate: requiredScopes — write tool requires only write") {
        let req = try await gate.requiredScopes(for: "snippets_delete").map(\.name)
        try expect(req == ["snippets.write"], "got \(req)")
    }

    await test("ScopeGate: requiredScopes — bridge session tools accept any known connector scope") {
        // Bootstrap/session tools (bridge_initialize/bridge_status/tools_list/
        // tools_search/session_info) must be reachable by ANY authenticated connector
        // grant, not gated behind the specific bridge.session scope alone —
        // see "ScopeGate: bridge_initialize is bootstrap-reachable by any
        // connector grant" below for the reachability half of this contract.
        for tool in ["bridge_initialize", "bridge_status", "tools_list", "tools_search", "session_info"] {
            let req = try await gate.requiredScopes(for: tool).map(\.name)
            try expect(Set(req) == Set(ConnectorScopeName.all), "\(tool) got \(req)")
        }
    }

    await test("ScopeGate: requiredScopes — unknown/non-connector tool is empty") {
        let req = try await gate.requiredScopes(for: "screen_capture")
        try expect(req.isEmpty, "non-connector tool must have no required scopes")
    }

    await test("ScopeGate: bridge_initialize is bootstrap-reachable by any connector grant") {
        let req = try await gate.requiredScopes(for: "bridge_initialize").map(\.name)
        try expect(Set(req) == Set(ConnectorScopeName.all),
                   "bootstrap should accept any known connector scope, got \(req)")
        let scoped = await gate.evaluate(
            toolName: "bridge_initialize",
            grantedScopes: [ConnectorScope(name: "snippets.read")]
        )
        guard case .allow = scoped else {
            throw TestError.assertion("bridge_initialize must be reachable with any authenticated connector grant")
        }
    }

    await test("ScopeGate: connector-reachable set spans all scope buckets") {
        // S4 (PKT-800): the bucket count grew from four to five
        // (`contacts.read` split out of `voice.resolve`). Test name
        // corrected from "four" → "all"; the reachability assertions are
        // unchanged-and-still-true (rewrite for accuracy, not a weakening)
        // plus a strengthening assertion that the new contact-record tool
        // is reachable while a non-connector tool still is not.
        let reachable = ConnectorScopeGate.connectorReachableTools
        try expect(reachable.contains("snippets_list"))
        try expect(reachable.contains("snippets_create"))
        try expect(reachable.contains("shell_exec"))
        try expect(reachable.contains("bridge_initialize"))
        try expect(reachable.contains("bridge_status"))
        try expect(reachable.contains("tools_list"))
        try expect(reachable.contains("tools_search"))
        try expect(reachable.contains("session_info"))
        try expect(reachable.contains("contacts_resolve_handle"))
        try expect(reachable.contains("contacts_get"),
                   "S4: the contacts.read bucket must be connector-reachable")
        try expect(reachable.contains("contacts_search"))
        try expect(reachable.contains("bridge_initialize"),
                   "bootstrap: bridge_initialize must be connector-reachable")
        try expect(!reachable.contains("file_write"), "file_write must NOT be connector-reachable")
        try expect(!reachable.contains("notion_page_create"))
    }

    // MARK: - ConnectorAuthContext / 401 challenge

    let prmURL = "http://127.0.0.1:9700/.well-known/oauth-protected-resource"
    let authCtx = ConnectorAuthContext(
        validator: validator(keys: keys.verifyKeys),
        resourceMetadataURL: prmURL,
        strictScopes: true
    )

    let challengeCorrelationID = "corr-w2a-test"

    await test("AuthContext: coarse WWW-Authenticate references the RFC 9728 PRM doc") {
        let h = authCtx.wwwAuthenticateValue(correlationID: challengeCorrelationID)
        try expect(h.hasPrefix("Bearer "), "must be a Bearer challenge: \(h)")
        try expect(h.contains("resource_metadata=\"\(prmURL)\""), "must point at PRM: \(h)")
    }

    await test("AuthContext: challenge is coarse and carries correlation id") {
        let h = authCtx.wwwAuthenticateValue(correlationID: challengeCorrelationID)
        try expect(h.contains("error=\"invalid_token\""), "got \(h)")
        try expect(h.contains("error_description=\"auth_failed\""), "got \(h)")
        try expect(h.contains("correlation_id=\"\(challengeCorrelationID)\""), "got \(h)")
    }

    await test("AuthContext: challenge value has no CR/LF") {
        let h = authCtx.wwwAuthenticateValue(correlationID: challengeCorrelationID)
        try expect(!h.contains("\r") && !h.contains("\n"), "header must be single-line: \(h)")
    }

    await test("SSEServer.unauthorizedResponse: coarse 401 + WWW-Authenticate header set") {
        let resp = SSEServer.unauthorizedResponse(correlationID: challengeCorrelationID, auth: authCtx)
        try expect(resp.statusCode == 401, "expected 401, got \(resp.statusCode)")
        let wa = resp.headers.first { $0.key.lowercased() == "www-authenticate" }?.value
        try expect(wa != nil, "WWW-Authenticate header missing")
        try expect(wa?.contains("Bearer") == true, "challenge must be Bearer: \(wa ?? "nil")")
        try expect(wa?.contains(prmURL) == true, "challenge must reference PRM")
        let body = String(data: resp.bodyData ?? Data(), encoding: .utf8) ?? ""
        try expect(body.contains("auth_failed") && body.contains(challengeCorrelationID), "coarse body missing: \(body)")
        for forbidden in ["expired", "issuer", "audience", "revoked", "static_bearer"] {
            try expect(!body.contains(forbidden), "detailed reason leaked in tunnel body: \(body)")
        }
    }

    await test("SSEServer.remoteOAuthReadiness distinguishes inactive, misconfigured, missing keys, ready") {
        let inactive = SSEServer.remoteOAuthReadiness(connectorAuth: nil, isMisconfigured: false)
        try expect(!inactive.ready && inactive.status == "inactive",
                   "nil auth must report inactive, got \(inactive)")

        let misconfigured = SSEServer.remoteOAuthReadiness(connectorAuth: authCtx, isMisconfigured: true)
        try expect(!misconfigured.ready && misconfigured.status == "misconfigured_issuer",
                   "placeholder issuer must report misconfigured, got \(misconfigured)")

        let missingKeys = ConnectorAuthContext(
            validator: validator(keys: JWTKeyCollection(), hasKeys: false),
            resourceMetadataURL: prmURL
        )
        let missing = SSEServer.remoteOAuthReadiness(connectorAuth: missingKeys, isMisconfigured: false)
        try expect(!missing.ready && missing.status == "missing_verification_keys",
                   "key-less validator must report missing keys, got \(missing)")

        let ready = SSEServer.remoteOAuthReadiness(connectorAuth: authCtx, isMisconfigured: false)
        try expect(ready.ready && ready.status == "ready",
                   "configured auth context must report ready, got \(ready)")
    }

    // MARK: - W2A: coarse tunnel disclosure + local reason correlation

    await test("W2A taxonomy maps typed OAuth failures onto the stable local vocabulary") {
        try expect(TunnelAuthFailureReason(.expired) == .oauthExpired)
        try expect(TunnelAuthFailureReason(.issuerMismatch(expected: "a", got: "b")) == .issuerMismatch)
        try expect(TunnelAuthFailureReason(.audienceMismatch(expected: "a", got: ["b"])) == .issuerMismatch)
        try expect(TunnelAuthFailureReason(.misconfigured) == .oauthInactive)
        try expect(TunnelAuthFailureReason(.signatureInvalid) == .oauthRevoked)
        try expect(Set(TunnelAuthFailureReason.allCases.map(\.rawValue)) == Set([
            "oauth_expired", "issuer_mismatch", "oauth_inactive", "oauth_revoked", "static_bearer_mismatch"
        ]))
    }

    await test("W2A tunnel failures are indistinguishable publicly and resolve locally by correlation id") {
        let audit = TunnelAuthFailureAudit()
        let diag = ConnectorAuthDiagnostics()
        let auth = ConnectorAuthContext(
            validator: validator(keys: keys.verifyKeys),
            diagnostics: diag,
            resourceMetadataURL: prmURL
        )
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {},
            connectorAuth: auth,
            authFailureAudit: audit
        )
        let expired = try await keys.sign(
            iss: kIssuer, aud: kResource, scope: "openid",
            exp: Date().addingTimeInterval(-3600)
        )
        let wrongIssuer = try await keys.sign(
            iss: "https://wrong.example", aud: kResource, scope: "openid"
        )
        let cases: [(String, TunnelAuthFailureReason)] = [
            (expired, .oauthExpired),
            (wrongIssuer, .issuerMismatch),
            ("not-a-jwt", .oauthRevoked),
        ]
        var correlations = Set<String>()
        for (token, expectedReason) in cases {
            let response = await server.handleHTTPRequest(HTTPRequest(
                method: "POST",
                headers: ["Cf-Ray": "w2a", "Authorization": "Bearer \(token)"],
                body: nil
            ))
            try expect(response.statusCode == 401, "auth rejection must be 401, got \(response.statusCode)")
            let body = String(data: response.bodyData ?? Data(), encoding: .utf8) ?? ""
            try expect(body.contains("auth_failed") && body.contains("correlation_id="), "coarse body: \(body)")
            for forbidden in TunnelAuthFailureReason.allCases.map(\.rawValue) {
                try expect(!body.contains(forbidden), "detailed reason leaked publicly: \(body)")
            }
            guard let correlationID = body.components(separatedBy: "correlation_id=").last?
                .split(whereSeparator: { $0 == "\"" || $0 == " " || $0 == "}" }).first.map(String.init),
                  let record = audit.record(correlationID: correlationID)
            else { throw TestError.assertion("correlation id did not resolve locally: \(body)") }
            try expect(record.reason == expectedReason,
                       "correlation \(correlationID) mapped to \(record.reason), expected \(expectedReason)")
            correlations.insert(correlationID)
        }
        try expect(correlations.count == cases.count, "each rejection needs a unique correlation id")
        let localTranscript = await diag.capturedText()
        for reason in ["oauth_expired", "issuer_mismatch", "oauth_revoked"] {
            try expect(localTranscript.contains("reason=\(reason)"), "local audit missing \(reason): \(localTranscript)")
        }
        try expect(!localTranscript.contains(expired) && !localTranscript.contains(wrongIssuer),
                   "local audit must never store JWT material")
    }

    await test("W2A OAuth-authenticated tunnel request skips a configured legacy static bearer") {
        let defaults = UserDefaults.standard
        let previousTunnel = defaults.string(forKey: "tunnelURL")
        let previousBearer = defaults.string(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        defaults.set("https://mcp.example.com", forKey: "tunnelURL")
        defaults.set("legacy-static-secret", forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        defer {
            if let previousTunnel { defaults.set(previousTunnel, forKey: "tunnelURL") }
            else { defaults.removeObject(forKey: "tunnelURL") }
            if let previousBearer { defaults.set(previousBearer, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey) }
            else { defaults.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey) }
        }
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx
        )
        let oauthJWT = try await keys.sign(iss: kIssuer, aud: kResource, scope: "openid")
        let response = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Ray": "w2a", "Authorization": "Bearer \(oauthJWT)"],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        ))
        try expect(response.statusCode == 200,
                   "valid OAuth JWT must dispatch even when a different static bearer exists; got \(response.statusCode)")
    }

    await test("W2A live curl captures stay coarse and correlate to local reasons") {
        let defaults = UserDefaults.standard
        let previousTunnel = defaults.string(forKey: "tunnelURL")
        let previousBearer = defaults.string(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        defaults.set("https://mcp.example.com", forKey: "tunnelURL")
        defaults.set("legacy-static-secret", forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        defer {
            if let previousTunnel { defaults.set(previousTunnel, forKey: "tunnelURL") }
            else { defaults.removeObject(forKey: "tunnelURL") }
            if let previousBearer { defaults.set(previousBearer, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey) }
            else { defaults.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey) }
        }

        let audit = TunnelAuthFailureAudit()
        let diagnostics = ConnectorAuthDiagnostics()
        let liveAuth = ConnectorAuthContext(
            validator: validator(keys: keys.verifyKeys),
            diagnostics: diagnostics,
            resourceMetadataURL: prmURL
        )
        let liveRouter = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let port = 19_000 + Int(ProcessInfo.processInfo.processIdentifier % 500)
        let liveServer = SSEServer(
            port: port,
            router: liveRouter,
            onToolCall: {},
            connectorAuth: liveAuth,
            authFailureAudit: audit,
            sessionStore: SessionPersistenceStore(
                storeURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pkt-1122-curl-sessions-\(UUID().uuidString).json")
            )
        )
        let serverTask = Task { try await liveServer.start() }
        try await Task.sleep(for: .milliseconds(250))

        func curl(_ bearer: String, body: String) throws -> String {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--silent", "--show-error", "--include",
                "--request", "POST", "http://127.0.0.1:\(port)/mcp",
                "--header", "Cf-Ray: pkt-1122-evidence",
                "--header", "Content-Type: application/json",
                "--header", "Authorization: Bearer \(bearer)",
                "--data-binary", body,
            ]
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                throw TestError.assertion(
                    "curl failed: \(String(data: err, encoding: .utf8) ?? "unknown")"
                )
            }
            return String(data: out, encoding: .utf8) ?? ""
        }

        func correlationID(in raw: String) -> String? {
            raw.components(separatedBy: "correlation_id=").last?
                .split(whereSeparator: { $0 == "\"" || $0 == " " || $0 == "}" || $0 == "\r" || $0 == "\n" })
                .first.map(String.init)
        }

        let expiredJWT = try await keys.sign(
            iss: kIssuer,
            aud: kResource,
            scope: "openid",
            exp: Date().addingTimeInterval(-3600)
        )
        let validJWT = try await keys.sign(iss: kIssuer, aud: kResource, scope: "openid")
        let requestBody = #"{"jsonrpc":"2.0","id":1122,"method":"tools/list"}"#
        let expiredRaw = try curl(expiredJWT, body: requestBody)
        let staticRaw = try curl("wrong-static-bearer", body: requestBody)
        let validRaw = try curl(validJWT, body: requestBody)

        await liveServer.stop()
        _ = await serverTask.result

        guard let expiredCorrelation = correlationID(in: expiredRaw),
              let staticCorrelation = correlationID(in: staticRaw)
        else {
            throw TestError.assertion("curl responses did not carry correlation ids")
        }
        try expect(expiredRaw.contains("HTTP/1.1 401"))
        try expect(staticRaw.contains("HTTP/1.1 401"))
        try expect(expiredRaw.contains("auth_failed") && staticRaw.contains("auth_failed"))
        try expect(validRaw.contains("HTTP/1.1 200"), "valid OAuth curl did not dispatch: \(validRaw)")
        for publicResponse in [expiredRaw, staticRaw] {
            for forbidden in TunnelAuthFailureReason.allCases.map(\.rawValue) {
                try expect(!publicResponse.contains(forbidden), "detail leaked in curl response: \(publicResponse)")
            }
        }
        try expect(audit.record(correlationID: expiredCorrelation)?.reason == .oauthExpired)
        try expect(audit.record(correlationID: staticCorrelation)?.reason == .staticBearerMismatch)

        let evidence = """
        # PKT-1122 W2A raw tunnel-facing curl captures

        ## Expired OAuth JWT (secret omitted)
        \(expiredRaw.trimmingCharacters(in: .whitespacesAndNewlines))
        local_audit correlation_id=\(expiredCorrelation) reason=oauth_expired

        ## Bad legacy static bearer (secret omitted)
        \(staticRaw.trimmingCharacters(in: .whitespacesAndNewlines))
        local_audit correlation_id=\(staticCorrelation) reason=static_bearer_mismatch

        ## Valid OAuth JWT while legacy static bearer is configured (secret omitted)
        \(validRaw.trimmingCharacters(in: .whitespacesAndNewlines))
        local_audit no auth failure; OAuth request dispatched
        """
        let evidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkt-1122-w2a-curl-evidence.md")
        try evidence.data(using: .utf8)?.write(to: evidenceURL, options: .atomic)
        print("    raw-curl evidence: \(evidenceURL.path)")
    }

    await test("W2A refreshed OAuth token for the same principal keeps a long-lived connector session usable") {
        let binding = ConnectorSessionBinding()
        let auth = ConnectorAuthContext(
            validator: validator(keys: keys.verifyKeys),
            sessionBinding: binding,
            resourceMetadataURL: prmURL
        )
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: auth
        )
        let beforeRefresh = try await keys.sign(
            iss: kIssuer, aud: kResource, sub: "stable-user", scope: "openid"
        )
        let afterRefresh = try await keys.sign(
            iss: kIssuer, aud: kResource, sub: "stable-user", scope: "openid",
            exp: Date().addingTimeInterval(600)
        )
        let sessionID = "w2a-refresh-session"
        _ = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Ray": "w2a", "Authorization": "Bearer \(beforeRefresh)", "Mcp-Session-Id": sessionID],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        ))
        let response = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Cf-Ray": "w2a", "Authorization": "Bearer \(afterRefresh)", "Mcp-Session-Id": sessionID],
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        ))
        try expect(response.statusCode == 200,
                   "same-principal refreshed token must keep session usable; got \(response.statusCode)")
        try expect(await binding.boundPrincipal(for: sessionID)?.subject == "stable-user")
    }

    await test("SSEServer.toolCallTarget: extracts tools/call tool name") {
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete"}}"#.utf8)
        try expect(SSEServer.toolCallTarget(in: body) == "snippets_delete")
    }

    await test("SSEServer.toolCallTarget: nil for non-tools/call or absent body") {
        try expect(SSEServer.toolCallTarget(in: nil) == nil)
        let init0 = Data(#"{"method":"initialize","params":{}}"#.utf8)
        try expect(SSEServer.toolCallTarget(in: init0) == nil)
        let list = Data(#"{"method":"tools/list"}"#.utf8)
        try expect(SSEServer.toolCallTarget(in: list) == nil)
    }

    // MARK: - Additive isolation (non-regression): default SSEServer requires NO bearer

    await test("Non-regression: default SSEServer has connectorAuth == nil (no bearer on /mcp)") {
        // The default initializer (the path ServerManager takes when the
        // streamableHTTP transport is NOT gated on) must not attach a
        // connector auth context. We assert via the public surface: a
        // freshly-constructed default server accepts a /mcp request with
        // NO Authorization header without producing a 401 bearer challenge
        // (it instead reaches the pre-S2 session machinery → a 400
        // Mcp-Session-Id error, exactly as before S2).
        let r = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let server = SSEServer(router: r, onToolCall: {})
        let req = HTTPRequest(method: "POST", headers: [:], body: nil)
        let resp = await server.handleHTTPRequest(req)
        // Pre-S2 behaviour for a bodyless POST with no session id:
        // 400 "Missing Mcp-Session-Id" — crucially NOT a 401 bearer
        // challenge, proving bearer is not required by default.
        try expect(resp.statusCode == 400, "default path must be pre-S2 400, got \(resp.statusCode)")
        let wa = resp.headers.first { $0.key.lowercased() == "www-authenticate" }?.value
        try expect(wa == nil, "default server must NOT emit a bearer challenge")
    }

    await test("Non-regression: bearer NOT required on /health route classification") {
        // /health is classified BEFORE the /mcp funnel, so it never
        // reaches handleHTTPRequest / the bearer gate at all.
        let route = MCPHTTPRoute.classify(method: "GET", path: "/health", endpoint: "/mcp")
        try expect(route == .health, "GET /health must classify as .health")
    }

    await test("Non-regression: bearer NOT required on legacy SSE route classification") {
        try expect(
            MCPHTTPRoute.classify(method: "GET", path: "/sse", endpoint: "/mcp") == .legacySSE
        )
        try expect(
            MCPHTTPRoute.classify(method: "POST", path: "/messages", endpoint: "/mcp") == .legacyMessages
        )
    }

    await test("Non-regression: connector-gated server with valid bearer reaches session path") {
        // With an auth context AND a valid bearer, a bodyless POST with no
        // session id must fall through to the SAME pre-S2 400 (proving the
        // bearer gate is transparent to authorized traffic — it does not
        // alter the underlying session contract).
        let r = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let server = SSEServer(
            router: r, onToolCall: {}, connectorAuth: authCtx
        )
        let tok = try await keys.sign(iss: kIssuer, aud: kResource, scope: "snippets.read")
        let req = HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)"],
            body: nil
        )
        let resp = await server.handleHTTPRequest(req)
        try expect(resp.statusCode == 400, "authorized bodyless POST must reach pre-S2 400, got \(resp.statusCode)")
    }

    await test("Connector-gated server: missing bearer on /mcp → 401 + WWW-Authenticate") {
        let r = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let server = SSEServer(router: r, onToolCall: {}, connectorAuth: authCtx)
        // PKT-810 R5: the OAuth bearer gate applies to REMOTE (tunnel) requests
        // only — mark this a tunnel request so the missing-bearer challenge fires.
        let req = HTTPRequest(method: "POST", headers: ["Cf-Connecting-Ip": "203.0.113.7"], body: nil)
        let resp = await server.handleHTTPRequest(req)
        try expect(resp.statusCode == 401, "missing bearer on gated /mcp must be 401, got \(resp.statusCode)")
        let wa = resp.headers.first { $0.key.lowercased() == "www-authenticate" }?.value
        try expect(wa?.contains("Bearer") == true, "must carry Bearer challenge")
        try expect(wa?.contains("oauth-protected-resource") == true, "must reference PRM")
    }

    await test("Connector-gated server: scope-insufficient tools/call → 403, no dispatch") {
        let r = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let server = SSEServer(router: r, onToolCall: {}, connectorAuth: authCtx)
        // read-only scope, calling a write tool.
        let tok = try await keys.sign(iss: kIssuer, aud: kResource, scope: "snippets.read")
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{}}}"#.utf8)
        let req = HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)", "Mcp-Session-Id": "nope"],
            body: body
        )
        let resp = await server.handleHTTPRequest(req)
        try expect(resp.statusCode == 403, "scope-insufficient call must be 403, got \(resp.statusCode)")
    }

    await test("ConnectorAuthContext strictScopes=true (opt-in): OpenID-only destructive call requires step-up") {
        // 2026-07-09: default flipped to false (full-parity revert of the
        // v3.9.8-era default). strictScopes must now be requested explicitly
        // to exercise the connector-layer scope/step-up gate — see the
        // ConnectorAuthContext.strictScopes doc comment.
        let r = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let explicitStrictAuth = ConnectorAuthContext(
            validator: validator(keys: keys.verifyKeys),
            resourceMetadataURL: prmURL,
            strictScopes: true
        )
        let server = SSEServer(router: r, onToolCall: {}, connectorAuth: explicitStrictAuth)
        let tok = try await keys.sign(
            iss: kIssuer,
            aud: kResource,
            scope: "openid email profile offline_access"
        )
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{}}}"#.utf8)
        let req = HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)", "Mcp-Session-Id": "explicit-strict"],
            body: body
        )
        let resp = await server.handleHTTPRequest(req)
        try expect(resp.statusCode == 403,
                   "explicit strict auth must require step-up for destructive connector tools, got \(resp.statusCode)")
        let text = String(data: resp.bodyData ?? Data(), encoding: .utf8) ?? ""
        try expect(text.contains("step_up_required"),
                   "403 body must carry step_up_required, got: \(text)")
    }

    await test("ConnectorAuthContext default (strictScopes=false): connector-layer scope/step-up gate skipped") {
        // Full-parity default: the connector-layer scope gate and step-up gate
        // are bypassed entirely, so an insufficiently-scoped bearer is never
        // rejected AT THIS LAYER for a destructive tool call — dispatch falls
        // through to the tool router / SecurityGate tier, which is the sole
        // remaining guardrail. This test only proves the connector-layer skip;
        // it does not assert the eventual dispatch outcome (SecurityGate's
        // `.request` tier is exercised by SecurityGate's own test suite).
        let auth = ConnectorAuthContext(
            validator: validator(keys: keys.verifyKeys),
            resourceMetadataURL: prmURL
        )
        try expect(auth.strictScopes == false, "default strictScopes must be false (full parity)")
    }

    await test("Connector-gated server: strict tools/list hides non-callable Messages tools") {
        let r = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        await r.register(ToolRegistration(
            name: "snippets_list",
            module: "snippets",
            tier: .open,
            description: "Allowed connector read probe.",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .array([]) }
        ))
        await r.register(ToolRegistration(
            name: "messages_recent",
            module: "messages",
            tier: .open,
            description: "Local-only Messages probe.",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .array([]) }
        ))
        await r.markModulesRegistrationComplete()

        let server = SSEServer(router: r, onToolCall: {}, connectorAuth: authCtx)
        let tok = try await keys.sign(iss: kIssuer, aud: kResource, scope: "snippets.read")
        let body = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
        let req = HTTPRequest(
            method: "POST",
            headers: ["Cf-Connecting-Ip": "203.0.113.7", "Authorization": "Bearer \(tok)"],
            body: body
        )
        let resp = await server.handleHTTPRequest(req)
        try expect(resp.statusCode == 200, "tools/list must succeed, got \(resp.statusCode)")
        guard case .data(let data, _) = resp else {
            throw TestError.assertion("strict connector tools/list must be compact JSON data")
        }
        let obj = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let result = obj["result"] as? [String: Any] ?? [:]
        let tools = result["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        try expect(names.contains("snippets_list"), "allowed connector tool missing from tools/list: \(names.sorted())")
        try expect(!names.contains("messages_recent"),
                   "tools/list must not advertise a tool the same bearer will 403: \(names.sorted())")
    }

    // MARK: - S1 fix: PRM resource reflects NOTION_BRIDGE_PORT

    await test("PRM fix: resource reflects NOTION_BRIDGE_PORT override") {
        let m = ProtectedResourceMetadataProvider.metadata(
            environment: ["NOTION_BRIDGE_PORT": "8123"], config: { _ in nil }, baked: ""
        )
        try expect(m.resource == "http://127.0.0.1:8123/mcp", "got \(m.resource)")
    }

    await test("PRM fix: resolvedResource honors explicit port arg") {
        let r = ProtectedResourceMetadataProvider.resolvedResource(port: 5555, environment: [:], config: { _ in nil }, baked: "")
        try expect(r == "http://127.0.0.1:5555/mcp", "got \(r)")
    }

    await test("PKT-810 Model B: BRIDGE_PUBLIC_RESOURCE overrides the localhost derivation") {
        // The public tunnel URL must be the advertised resource + expected
        // audience for the directory OAuth connector — even when an explicit
        // local port is passed (ServerManager passes ssePort).
        let env = ["BRIDGE_PUBLIC_RESOURCE": "https://mcp.kup.solutions/mcp"]
        let withPort = ProtectedResourceMetadataProvider.resolvedResource(port: 9700, environment: env)
        try expect(withPort == "https://mcp.kup.solutions/mcp", "public override must win over port; got \(withPort)")
        let noPort = ProtectedResourceMetadataProvider.resolvedResource(environment: env)
        try expect(noPort == "https://mcp.kup.solutions/mcp", "public override must win in PRM path; got \(noPort)")
        // PRM document carries it through to the resource field.
        let md = ProtectedResourceMetadataProvider.metadata(environment: env)
        try expect(md.resource == "https://mcp.kup.solutions/mcp", "PRM resource must be the public URL; got \(md.resource)")
    }

    await test("PKT-810 Model B: blank/whitespace BRIDGE_PUBLIC_RESOURCE falls through to local") {
        let r = ProtectedResourceMetadataProvider.resolvedResource(port: 9700, environment: ["BRIDGE_PUBLIC_RESOURCE": "   "], config: { _ in nil }, baked: "")
        try expect(r == "http://127.0.0.1:9700/mcp", "blank override must not poison; got \(r)")
    }

    await test("PRM fix: invalid NOTION_BRIDGE_PORT ignored (falls through resolver)") {
        // Non-numeric / out-of-range env value must NOT poison the URL;
        // resolver falls through to ConfigManager (default 9700 in test env).
        let r = ProtectedResourceMetadataProvider.resolvedResource(
            environment: ["NOTION_BRIDGE_PORT": "not-a-port"], config: { _ in nil }, baked: ""
        )
        try expect(r.hasPrefix("http://127.0.0.1:"), "got \(r)")
        try expect(r.hasSuffix("/mcp"), "got \(r)")
        try expect(!r.contains("not-a-port"), "invalid port leaked: \(r)")
    }

    await test("PRM fix: explicit resource override still wins over port resolution") {
        let m = ProtectedResourceMetadataProvider.metadata(
            resource: "https://mcp.kup.solutions/mcp",
            environment: ["NOTION_BRIDGE_PORT": "8123"]
        )
        try expect(m.resource == "https://mcp.kup.solutions/mcp", "explicit override must win: \(m.resource)")
    }

    await test("PRM fix: jsonBody resource reflects port override end-to-end") {
        let data = ProtectedResourceMetadataProvider.jsonBody(
            environment: ["NOTION_BRIDGE_PORT": "7001"], config: { _ in nil }, baked: ""
        )
        let obj = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        try expect(obj["resource"] as? String == "http://127.0.0.1:7001/mcp", "got \(String(describing: obj["resource"]))")
    }
}
