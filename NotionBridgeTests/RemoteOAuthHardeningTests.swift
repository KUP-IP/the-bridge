// RemoteOAuthHardeningTests.swift — PKT-800 S3 (remote OAuth/HTTP, slice 3, final)
// NotionBridge · Tests (custom harness — no XCTest)
//
// All against a synthetic in-test ES256 keypair (no network, no live IdP).
// Covers, exhaustively:
//   • Step-up authorization on a `destructiveHint: true` connector tool:
//     required when absent, satisfied ONLY by the AS-minted
//     `connector.step_up` scope (S4 PKT-800 correction — the per-call
//     `_stepUp`/`stepUpToken` argument is a non-authoritative consent
//     echo and can NEVER authorize on its own); a non-destructive
//     connector tool is unaffected; stdio/local dispatch has no step-up.
//   • Confused-deputy isolation: a session is bound to its first verified
//     principal; a different principal on that session is rejected; same
//     principal is matched; sessionless requests cannot be cross-bound.
//   • Bearer-leak sweep: drive valid / invalid / expired / scope-deny /
//     step-up through the connector path and assert the captured
//     diagnostics transcript (and the redactor itself) contain ZERO
//     bearer / code_verifier / client_secret occurrences.
//   • Connector gating decision (single-bind invariant): connector auth
//     is constructed ONLY when the transport router has streamableHTTP
//     active (env on/off) — proven via the pure
//     `ServerManager.isStreamableHTTPActive` gate, no GUI launch. There is
//     NO second listener bind: `/mcp` is served by the unconditional
//     `runSSE()` listener and `runStreamableHTTP()` is a non-binding gated
//     guard (throws when inactive, NO-OP when active).
//   • S2 hardening nit: explicit `alg:none` and `alg:HS256`
//     (asymmetric→symmetric confusion) literal token vectors are rejected.
//   • Non-regression: stdio / health / legacy SSE classification needs no
//     bearer or step-up; default SSEServer attaches no connector auth.

import Foundation
import JWTKit
import MCP
import NotionBridgeLib

// MARK: - Synthetic key fixture (no network)

private struct HardeningKeys {
    let signing: JWTKeyCollection
    let verify: JWTKeyCollection

    static func make() async -> HardeningKeys {
        let priv = ES256PrivateKey()
        let s = JWTKeyCollection()
        await s.add(ecdsa: priv)
        let v = JWTKeyCollection()
        await v.add(ecdsa: priv.publicKey)
        return HardeningKeys(signing: s, verify: v)
    }

    func sign(
        iss: String, aud: String, sub: String = "user-1", scope: String?
    ) async throws -> String {
        try await signing.sign(BridgeAccessToken(
            iss: IssuerClaim(value: iss),
            aud: AudienceClaim(value: [aud]),
            sub: SubjectClaim(value: sub),
            exp: ExpirationClaim(value: Date().addingTimeInterval(300)),
            nbf: nil,
            scope: scope
        ))
    }
}

private let hIssuer = "https://auth.kup.solutions"
private let hResource = "http://127.0.0.1:9700/mcp"
private let hPRM = "http://127.0.0.1:9700/.well-known/oauth-protected-resource"

func runRemoteOAuthHardeningTests() async {
    print("\n\u{1F510} Remote OAuth Hardening (PKT-800 S3)")

    let keys = await HardeningKeys.make()

    // Same Swift 6.2.1 -O -strict-concurrency crash workaround as
    // RemoteOAuthHardeningS4Tests.swift — nested `func authCtx(...)` with
    // default arguments inside an async body crashes the type-checker.
    // Closures route through a different isolation-analysis path.
    let validator: @Sendable () -> ConnectorBearerValidator = {
        ConnectorBearerValidator(
            keys: keys.verify, hasKeys: true,
            expectedIssuer: hIssuer, expectedAudience: hResource
        )
    }
    let authCtx: @Sendable (ConnectorAuthDiagnostics, ConnectorSessionBinding) -> ConnectorAuthContext = { diagnostics, binding in
        ConnectorAuthContext(
            validator: validator(),
            sessionBinding: binding,
            diagnostics: diagnostics,
            resourceMetadataURL: hPRM,
            strictScopes: true
        )
    }

    // MARK: - Step-up: pure gate logic

    let stepUp = ConnectorStepUpGate()

    await test("StepUp: snippets_delete is recognized as a destructive connector tool") {
        try expect(stepUp.isDestructive(toolName: "snippets_delete"),
                   "snippets_delete must be destructiveHint:true")
        try expect(!stepUp.isDestructive(toolName: "snippets_list"),
                   "snippets_list must not be destructive")
    }

    await test("StepUp: destructive tool with NO step-up signal → required") {
        let d = stepUp.evaluate(
            toolName: "snippets_delete",
            grantedScopes: [ConnectorScope(name: "snippets.write")],
            body: Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{}}}"#.utf8)
        )
        guard case .required(let reason, _) = d else {
            throw TestError.assertion("expected .required, got \(d)")
        }
        try expect(reason == .stepUpRequired, "machine-readable reason drifted: \(reason.rawValue)")
        try expect(reason.rawValue == "step_up_required", "stable rawValue contract")
    }

    await test("StepUp: destructive tool satisfied by the step-up SCOPE") {
        let d = stepUp.evaluate(
            toolName: "snippets_delete",
            grantedScopes: [
                ConnectorScope(name: "snippets.write"),
                ConnectorScope(name: ConnectorStepUpGate.stepUpScopeName),
            ],
            body: nil
        )
        guard case .satisfied = d else {
            throw TestError.assertion("step-up scope must satisfy, got \(d)")
        }
    }

    await test("StepUp: a per-call confirmation token alone does NOT authorize (S4 corrected invariant)") {
        // S4 (PKT-800) THREAT-MODEL CORRECTION. The prior S3 test asserted
        // the WEAKER invariant "a non-empty `_stepUp`/`stepUpToken`
        // satisfies step-up". That was a security defect: the token has no
        // nonce/binding/server verification, so any automated client could
        // forge `{"_stepUp":"x"}` and bypass step-up entirely. This test
        // is REWRITTEN to assert the STRONGER, corrected invariant — the
        // AS-minted `connector.step_up` scope is the SOLE security factor;
        // a per-call echo (any value, either accepted key) NEVER
        // authorizes a destructive call on its own. (Rewritten, not
        // deleted — net `test()` count preserved; order-inversion rule.)
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"_stepUp":"confirmed-abc"}}}"#.utf8)
        let d = stepUp.evaluate(
            toolName: "snippets_delete",
            grantedScopes: [ConnectorScope(name: "snippets.write")],
            body: body
        )
        guard case .required(let reason, _) = d else {
            throw TestError.assertion("token alone must NOT authorize a destructive call, got \(d)")
        }
        try expect(reason == .stepUpRequired, "must still report step_up_required")
        // The alternate key must be equally non-authoritative.
        let body2 = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"stepUpToken":"x"}}}"#.utf8)
        guard case .required = stepUp.evaluate(
            toolName: "snippets_delete",
            grantedScopes: [ConnectorScope(name: "snippets.write")],
            body: body2
        ) else {
            throw TestError.assertion("stepUpToken key must also be non-authoritative")
        }
        // Sanity: the echo IS still detectable (diagnostics/UX trail) —
        // it is recognized, just not an authorization input.
        try expect(ConnectorStepUpGate.hasConfirmationToken(in: body),
                   "echo must still be recognizable for the consent trail")
    }

    await test("StepUp: a confirmation token does NOT rescue a call lacking the step-up scope, regardless of value (S4)") {
        // Companion to the rewrite above: the prior S3 suite had a test
        // whose premise was "blank token does NOT satisfy but a non-blank
        // one DOES". Under the corrected model NEITHER authorizes — the
        // token's value is irrelevant to authorization. Rewritten to
        // assert that corrected stronger invariant across blank,
        // whitespace, and a long non-empty value (count preserved).
        for tok in ["", "   ", "a-very-long-but-still-forgeable-token-zzzzzzzzzz"] {
            let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"_stepUp":"\#(tok)"}}}"#.utf8)
            let d = stepUp.evaluate(
                toolName: "snippets_delete",
                grantedScopes: [ConnectorScope(name: "snippets.write")],
                body: body
            )
            guard case .required = d else {
                throw TestError.assertion("token value '\(tok)' must NOT authorize without the step-up scope, got \(d)")
            }
        }
        // With the AS-minted scope present it IS authorized — proving the
        // scope (not the token) is the boundary.
        guard case .satisfied = stepUp.evaluate(
            toolName: "snippets_delete",
            grantedScopes: [
                ConnectorScope(name: "snippets.write"),
                ConnectorScope(name: ConnectorStepUpGate.stepUpScopeName),
            ],
            body: nil
        ) else {
            throw TestError.assertion("the AS-minted step-up scope must authorize")
        }
    }

    await test("StepUp: NON-destructive connector tool is unaffected (always satisfied)") {
        let d = stepUp.evaluate(
            toolName: "snippets_list",
            grantedScopes: [ConnectorScope(name: "snippets.read")],
            body: Data(#"{"method":"tools/call","params":{"name":"snippets_list"}}"#.utf8)
        )
        guard case .satisfied = d else {
            throw TestError.assertion("non-destructive tool must not require step-up, got \(d)")
        }
    }

    // MARK: - Step-up: end-to-end through the connector funnel

    await test("StepUp E2E: destructive tools/call without step-up → 403 step_up_required, NO dispatch") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx(ConnectorAuthDiagnostics(), ConnectorSessionBinding())
        )
        let tok = try await keys.sign(iss: hIssuer, aud: hResource, scope: "snippets.write")
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"id":"s1"}}}"#.utf8)
        let req = HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(tok)", "Mcp-Session-Id": "sess-A"],
            body: body
        )
        let resp = await server.handleHTTPRequest(req)
        try expect(resp.statusCode == 403, "destructive w/o step-up must be 403, got \(resp.statusCode)")
        if let bd = resp.bodyData, let s = String(data: bd, encoding: .utf8) {
            try expect(s.contains("step_up_required"), "machine-readable reason must be in body: \(s)")
        } else {
            throw TestError.assertion("403 must carry a body")
        }
    }

    await test("StepUp E2E: destructive tools/call WITH step-up scope reaches session machinery") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx(ConnectorAuthDiagnostics(), ConnectorSessionBinding())
        )
        let tok = try await keys.sign(
            iss: hIssuer, aud: hResource,
            scope: "snippets.write \(ConnectorStepUpGate.stepUpScopeName)"
        )
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{"id":"s1"}}}"#.utf8)
        let req = HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(tok)", "Mcp-Session-Id": "sess-OK"],
            body: body
        )
        let resp = await server.handleHTTPRequest(req)
        // Scope + step-up pass ⇒ falls through to pre-S2 session contract.
        // The session id is unknown ⇒ pre-S2 404 "Session not found",
        // crucially NOT a 401/403 auth refusal (step-up was satisfied).
        try expect(resp.statusCode == 404,
                   "satisfied step-up must reach session path (404 unknown session), got \(resp.statusCode)")
    }

    await test("StepUp E2E: non-destructive tools/call needs no step-up (reaches session path)") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx(ConnectorAuthDiagnostics(), ConnectorSessionBinding())
        )
        let tok = try await keys.sign(iss: hIssuer, aud: hResource, scope: "snippets.read")
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_list","arguments":{}}}"#.utf8)
        let req = HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(tok)", "Mcp-Session-Id": "sess-ND"],
            body: body
        )
        let resp = await server.handleHTTPRequest(req)
        try expect(resp.statusCode == 404,
                   "non-destructive authorized call must reach session path, got \(resp.statusCode)")
    }

    // MARK: - Confused-deputy isolation

    await test("ConfusedDeputy: first principal binds; same principal matches") {
        let b = ConnectorSessionBinding()
        let p = ConnectorPrincipal(subject: "user-A", clientID: "user-A")
        let a1 = await b.admit(sessionID: "S1", principal: p)
        try expect(a1 == .bound, "first admit must bind, got \(a1)")
        let a2 = await b.admit(sessionID: "S1", principal: p)
        try expect(a2 == .matched, "same principal must match, got \(a2)")
        let got = await b.boundPrincipal(for: "S1")
        try expect(got == p, "binding must persist")
    }

    await test("ConfusedDeputy: different principal on a bound session → rejected") {
        let b = ConnectorSessionBinding()
        _ = await b.admit(sessionID: "S1",
                          principal: ConnectorPrincipal(subject: "A", clientID: "A"))
        let a = await b.admit(sessionID: "S1",
                              principal: ConnectorPrincipal(subject: "B", clientID: "B"))
        guard case .rejected(let r) = a else {
            throw TestError.assertion("cross-principal must be rejected, got \(a)")
        }
        try expect(r == .principalMismatch, "stable reason")
        try expect(r.rawValue == "session_principal_mismatch", "rawValue contract")
    }

    await test("ConfusedDeputy: sessionless request cannot be cross-bound") {
        let b = ConnectorSessionBinding()
        let a1 = await b.admit(sessionID: nil,
                               principal: ConnectorPrincipal(subject: "A", clientID: "A"))
        try expect(a1 == .matched, "nil session admits without binding, got \(a1)")
        let a2 = await b.admit(sessionID: "",
                               principal: ConnectorPrincipal(subject: "B", clientID: "B"))
        try expect(a2 == .matched, "empty session admits without binding, got \(a2)")
        try expect(await b.boundPrincipal(for: "") == nil, "no binding created for sessionless")
    }

    await test("ConfusedDeputy: release drops the binding (session teardown)") {
        let b = ConnectorSessionBinding()
        _ = await b.admit(sessionID: "S1",
                          principal: ConnectorPrincipal(subject: "A", clientID: "A"))
        await b.release(sessionID: "S1")
        try expect(await b.boundPrincipal(for: "S1") == nil, "release must clear binding")
        // After release a new principal may bind the same id afresh.
        let a = await b.admit(sessionID: "S1",
                              principal: ConnectorPrincipal(subject: "B", clientID: "B"))
        try expect(a == .bound, "post-release re-bind, got \(a)")
    }

    await test("ConfusedDeputy E2E: token substitution across a bound /mcp session → 403, no dispatch") {
        let binding = ConnectorSessionBinding()
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx(ConnectorAuthDiagnostics(), binding)
        )
        // Client A binds session "shared" with a non-tools/call request.
        let tokA = try await keys.sign(iss: hIssuer, aud: hResource, sub: "client-A", scope: "snippets.read")
        let reqA = HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(tokA)", "Mcp-Session-Id": "shared"],
            body: Data(#"{"method":"ping"}"#.utf8)
        )
        _ = await server.handleHTTPRequest(reqA)
        try expect(await binding.boundPrincipal(for: "shared")?.subject == "client-A",
                   "session must bind to client-A")
        // Client B presents its OWN valid bearer on A's session id.
        let tokB = try await keys.sign(iss: hIssuer, aud: hResource, sub: "client-B", scope: "snippets.read")
        let reqB = HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(tokB)", "Mcp-Session-Id": "shared"],
            body: Data(#"{"method":"tools/call","params":{"name":"snippets_list","arguments":{}}}"#.utf8)
        )
        let resp = await server.handleHTTPRequest(reqB)
        try expect(resp.statusCode == 403,
                   "cross-client token substitution must be 403, got \(resp.statusCode)")
        if let bd = resp.bodyData, let s = String(data: bd, encoding: .utf8) {
            try expect(s.contains("session_principal_mismatch"),
                       "machine-readable confused-deputy reason in body: \(s)")
        }
    }

    // MARK: - Bearer-leak sweep (0 hits)

    await test("LeakSweep: redactor strips Bearer / JWS-triple / secret-key values") {
        let raw = "Authorization: Bearer aaaaaa.bbbbbb.cccccc "
            + #"{"client_secret":"shhh-1234","code_verifier":"v-9999"} "#
            + "access_token=tok_abcdef refresh_token: rt_zzz"
        let red = ConnectorAuthDiagnostics.redactSecrets(raw)
        for needle in ["aaaaaa.bbbbbb.cccccc", "shhh-1234", "v-9999", "tok_abcdef", "rt_zzz"] {
            try expect(!red.contains(needle), "secret '\(needle)' leaked through redactor: \(red)")
        }
        try expect(red.contains("‹redacted›"), "redactor must mark redactions: \(red)")
    }

    await test("LeakSweep: every auth path captured — transcript has 0 token/secret occurrences") {
        let diag = ConnectorAuthDiagnostics()
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}, connectorAuth: authCtx(diag, ConnectorSessionBinding())
        )
        // The actual secret material we will look for in the transcript.
        let validTok = try await keys.sign(iss: hIssuer, aud: hResource, scope: "snippets.read")
        let expiredPayload = BridgeAccessToken(
            iss: IssuerClaim(value: hIssuer), aud: AudienceClaim(value: [hResource]),
            sub: SubjectClaim(value: "u"), exp: ExpirationClaim(value: Date().addingTimeInterval(-3600)),
            nbf: nil, scope: "snippets.read"
        )
        let expiredTok = try await keys.signing.sign(expiredPayload)
        let secrets = [validTok, expiredTok, "not-a-jwt-garbage"]

        // 1. valid bearer (non-tools/call → bearer accepted path)
        _ = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(validTok)", "Mcp-Session-Id": "L1"],
            body: Data(#"{"method":"ping"}"#.utf8)))
        // 2. invalid bearer (garbage)
        _ = await server.handleHTTPRequest(HTTPRequest(
            method: "POST", headers: ["Authorization": "Bearer not-a-jwt-garbage"], body: nil))
        // 3. expired bearer
        _ = await server.handleHTTPRequest(HTTPRequest(
            method: "POST", headers: ["Authorization": "Bearer \(expiredTok)"], body: nil))
        // 4. scope-deny (read scope → write tool)
        _ = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(validTok)", "Mcp-Session-Id": "L1"],
            body: Data(#"{"method":"tools/call","params":{"name":"snippets_update","arguments":{}}}"#.utf8)))
        // 5. step-up required (write scope → destructive tool, no step-up)
        let wtok = try await keys.sign(iss: hIssuer, aud: hResource, scope: "snippets.write")
        _ = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(wtok)", "Mcp-Session-Id": "L2"],
            body: Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{}}}"#.utf8)))

        let transcript = await diag.capturedText()
        try expect(!transcript.isEmpty, "diagnostics must have captured the auth path events")
        for secret in secrets {
            try expect(!transcript.contains(secret),
                       "BEARER LEAK: token/secret material found in diagnostics transcript")
        }
        // No raw "Bearer <jwt>" header value survived either.
        try expect(!transcript.lowercased().contains("bearer ey"),
                   "a raw JWT (ey…) leaked into the transcript")
        // Sanity: the sweep really exercised ≥5 outcomes.
        let outcomes = Set((await diag.captured()).map(\.outcome))
        try expect(outcomes.contains("bearer.accepted"), "missing bearer.accepted outcome")
        try expect(outcomes.contains("bearer.rejected"), "missing bearer.rejected outcome")
        try expect(outcomes.contains("scope.denied"), "missing scope.denied outcome")
        try expect(outcomes.contains("step-up.required"), "missing step-up.required outcome")
    }

    await test("LeakSweep: diagnostics.record cannot store an unredacted secret even if asked") {
        let diag = ConnectorAuthDiagnostics()
        await diag.record(outcome: "test", detail: "leak attempt Bearer zzzzzz.yyyyyy.xxxxxx and client_secret=topsecret")
        let txt = await diag.capturedText()
        try expect(!txt.contains("zzzzzz.yyyyyy.xxxxxx"), "JWS triple stored unredacted")
        try expect(!txt.contains("topsecret"), "client_secret stored unredacted")
    }

    // MARK: - Connector gating decision (no GUI launch, single-bind invariant)

    await test("Gating: streamableHTTP is active ONLY when transport enabled (env=1)") {
        // CORRECTED (S3 fix): there is NO second AppDelegate task and NO
        // second listener bind. `/mcp` is served by the single
        // unconditional `runSSE()` listener; this gate decides only
        // whether connector AUTH is constructed (in `ServerManager.setup`,
        // `connectorAuth != nil` iff streamableHTTP active). This test
        // proves the pure gating read — both arms — without binding.
        let m = ServerManager(onToolCall: {})
        // The harness must not set BRIDGE_ENABLE_HTTP → default off.
        try expect(!m.isStreamableHTTPActive,
                   "default config must keep the connector gate off")
        let off = TransportRouter(environment: [:])
        try expect(!off.isActive(.streamableHTTP), "env-unset must keep connector gate off")
        let on = TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "1"])
        try expect(on.isActive(.streamableHTTP), "env=1 must open the connector gate")
        try expect(on.isActive(.stdio), "stdio non-regression: stdio still active with HTTP on")
    }

    await test("Gating: runStreamableHTTP() is a non-binding gated guard (throws when inactive, never a 2nd bind)") {
        // CORRECTED INVARIANT (S3 fix): `/mcp` is served by the shared
        // `runSSE()` listener. `runStreamableHTTP()` is ONLY the gated
        // seam/guard — it MUST NOT call `sseServer.start()` (a second bind
        // on the SSE port). When inactive it throws transportInactive;
        // when active it is a non-binding NO-OP that returns. The default
        // (harness) config is inactive, so we assert the throw arm here —
        // the assertion message records that the contract is "throw, not
        // bind", which is exactly the single-bind invariant.
        let m = ServerManager(onToolCall: {})
        _ = await m.setup()
        do {
            try await m.runStreamableHTTP()
            throw TestError.assertion("inactive streamableHTTP must throw, not bind a 2nd listener")
        } catch let e as ServerManagerError {
            guard case .transportInactive(let t) = e, t == .streamableHTTP else {
                throw TestError.assertion("expected transportInactive(.streamableHTTP), got \(e)")
            }
        }
    }

    // MARK: - S2 hardening nit: alg:none + HS256-confusion literal vectors

    await test("AlgConfusion: alg:none literal token is rejected (never accepted unsigned)") {
        // {"alg":"none","typ":"JWT"} . {iss,aud,exp...} . (empty sig)
        let header = #"{"alg":"none","typ":"JWT"}"#
        let payload = #"{"iss":"\#(hIssuer)","aud":"\#(hResource)","sub":"x","exp":9999999999,"scope":"snippets.read"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let algNone = "\(b64url(header)).\(b64url(payload))."
        do {
            _ = try await validator().validate(authorizationHeader: "Bearer \(algNone)")
            throw TestError.assertion("alg:none token MUST be rejected")
        } catch let e as BearerValidationError {
            // Any structural/signature rejection is acceptable — the
            // invariant is "not accepted", never a thrown success.
            switch e {
            case .malformedToken, .signatureInvalid, .misconfigured:
                break
            default:
                throw TestError.assertion("alg:none rejected, but with unexpected error \(e)")
            }
        }
    }

    await test("AlgConfusion: HS256 token (asymmetric→symmetric confusion) is rejected") {
        // Forge an HS256 JWT whose MAC key is the (public) verification
        // material an attacker could know. The ES256-only validator must
        // not accept an HMAC token regardless.
        let hmac = JWTKeyCollection()
        await hmac.add(hmac: "this-is-a-public-ish-symmetric-guess", digestAlgorithm: .sha256)
        let forged = try await hmac.sign(BridgeAccessToken(
            iss: IssuerClaim(value: hIssuer),
            aud: AudienceClaim(value: [hResource]),
            sub: SubjectClaim(value: "attacker"),
            exp: ExpirationClaim(value: Date().addingTimeInterval(300)),
            nbf: nil,
            scope: "snippets.write \(ConnectorStepUpGate.stepUpScopeName)"
        ))
        do {
            _ = try await validator().validate(authorizationHeader: "Bearer \(forged)")
            throw TestError.assertion("HS256-confusion token MUST be rejected by an ES256 validator")
        } catch let e as BearerValidationError {
            switch e {
            case .malformedToken, .signatureInvalid:
                break
            default:
                throw TestError.assertion("HS256 token rejected, but unexpected error \(e)")
            }
        }
    }

    // MARK: - Non-regression: stdio / health / legacy need no bearer or step-up

    await test("Non-regression: default SSEServer attaches NO connector auth (no step-up, no bearer)") {
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}
        )
        // A destructive tools/call with NO Authorization header on the
        // default (connectorAuth==nil) server must NOT be 401/403 — it
        // reaches the unchanged pre-S2 session contract.
        let body = Data(#"{"method":"tools/call","params":{"name":"snippets_delete","arguments":{}}}"#.utf8)
        let resp = await server.handleHTTPRequest(
            HTTPRequest(method: "POST", headers: [:], body: body))
        try expect(resp.statusCode != 401 && resp.statusCode != 403,
                   "default path must not gate on bearer/step-up, got \(resp.statusCode)")
        let wa = resp.headers.first { $0.key.lowercased() == "www-authenticate" }?.value
        try expect(wa == nil, "default server must not emit a bearer challenge")
    }

    await test("Non-regression: health / legacy SSE route classification is unchanged by S3") {
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/health", endpoint: "/mcp") == .health)
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/sse", endpoint: "/mcp") == .legacySSE)
        try expect(MCPHTTPRoute.classify(method: "POST", path: "/messages", endpoint: "/mcp") == .legacyMessages)
        try expect(MCPHTTPRoute.classify(method: "POST", path: "/jobs/x/run", endpoint: "/mcp") == .jobsRun("x"))
    }
}
