// RemoteAccessConfigWave2Tests.swift — Packet E Wave 2 (PRJCT-2754 · durable Remote-Access config)
//
// Locks the env → config.json → build-baked → fail-closed precedence for the
// FOUR Wave-2 remote-access readers that previously read raw env only — the
// mechanical mirror of Wave 1's RemoteAccessIdentityTests (which covers
// `ProtectedResourceMetadataProvider.resolvedIssuer/resolvedResource`):
//
//   1. WorkOSConfig.resolved            — WORKOS_CLIENT_ID / WORKOS_BASE_URL /
//                                         WORKOS_REDIRECT_URI (env → config →
//                                         RemoteAccessIdentity.workos* baked →
//                                         placeholder), PER FIELD.
//   2. TransportRouter.init             — BRIDGE_ENABLE_HTTP (env → config
//                                         `enableHTTP` → off). No baked layer.
//   3. ConnectorBearerValidator         — BRIDGE_OAUTH_JWKS (env → config
//      .fromEnvironment                   `oauthJWKS` → fail-closed). No baked
//                                         layer (JWKS is tenant signing
//                                         material, not a build constant).
//   4. EnableCloudAccessFlow.live       — BRIDGE_CLOUD_BASE_URL (explicit arg →
//                                         env → config `cloudBaseURL` →
//                                         placeholder). No baked layer.
//
// All pure: every resolver's config / baked seam is INJECTED, so no disk, no
// ConfigManager singleton, no ProcessInfo dependency. EXPLICITLY NOT TESTED
// here (and not changed by this wave): any SecurityGate / SSETransport gate or
// the PKT-810 R5 loopback origin-split — this packet only feeds the readers.

import Foundation
import JWTKit
import TheBridgeLib

func runRemoteAccessConfigWave2Tests() async {
    print("\n\u{1F3DB}\u{FE0F} Packet E W2 — config-backed remote-access reader precedence")
    let none: @Sendable (String) -> String? = { _ in nil }

    // ── 1. WorkOSConfig.resolved — per-field env → config → baked → placeholder
    await test("Packet E W2: WorkOS — env wins over config + baked (per field)") {
        let c = WorkOSConfig.resolved(
            environment: [
                "WORKOS_CLIENT_ID": "client_env",
                "WORKOS_BASE_URL": "https://env.workos",
                "WORKOS_REDIRECT_URI": "bridge-auth://env",
            ],
            config: { _ in "CONFIG_VALUE" },
            bakedClientID: "client_baked",
            bakedBaseURL: "https://baked.workos",
            bakedRedirectURI: "bridge-auth://baked")
        try expect(c.clientID == "client_env", "env clientID must win, got \(c.clientID)")
        try expect(c.baseURL == "https://env.workos", "env baseURL must win, got \(c.baseURL)")
        try expect(c.redirectURI == "bridge-auth://env", "env redirect must win, got \(c.redirectURI)")
    }

    await test("Packet E W2: WorkOS — config wins over baked when env absent") {
        let c = WorkOSConfig.resolved(
            environment: [:],
            config: { key in
                switch key {
                case "workosClientID": return "client_config"
                case "workosBaseURL": return "https://config.workos"
                case "workosRedirectURI": return "bridge-auth://config"
                default: return nil
                }
            },
            bakedClientID: "client_baked",
            bakedBaseURL: "https://baked.workos",
            bakedRedirectURI: "bridge-auth://baked")
        try expect(c.clientID == "client_config", "config clientID must win over baked, got \(c.clientID)")
        try expect(c.baseURL == "https://config.workos", "config baseURL must win over baked, got \(c.baseURL)")
        try expect(c.redirectURI == "bridge-auth://config", "config redirect must win over baked, got \(c.redirectURI)")
    }

    await test("Packet E W2: WorkOS — baked supplies when env+config absent (durable default)") {
        let c = WorkOSConfig.resolved(
            environment: [:], config: none,
            bakedClientID: "client_baked",
            bakedBaseURL: "https://baked.workos",
            bakedRedirectURI: "bridge-auth://baked")
        try expect(c.clientID == "client_baked", "baked clientID must supply, got \(c.clientID)")
        try expect(c.baseURL == "https://baked.workos", "baked baseURL must supply, got \(c.baseURL)")
        try expect(c.redirectURI == "bridge-auth://baked", "baked redirect must supply, got \(c.redirectURI)")
        try expect(c.isConfigured, "a real baked client id must report configured")
    }

    await test("Packet E W2: WorkOS — fail-closed to placeholder when all layers empty") {
        let c = WorkOSConfig.resolved(
            environment: [:], config: none,
            bakedClientID: "", bakedBaseURL: "", bakedRedirectURI: "")
        try expect(c == .placeholder, "all-empty must equal the documented placeholder, got \(c)")
        try expect(!c.isConfigured, "placeholder must report NOT configured (fail-closed)")
    }

    await test("Packet E W2: WorkOS — committed (unbaked) build is fail-closed via default baked") {
        // No explicit baked*: → uses RemoteAccessIdentity.workos* (committed EMPTY).
        let c = WorkOSConfig.resolved(environment: [:], config: none)
        try expect(c == .placeholder,
                   "committed build must resolve to the placeholder (fail-closed), got \(c)")
    }

    // ── 2. TransportRouter — BRIDGE_ENABLE_HTTP env → config `enableHTTP` → off
    await test("Packet E W2: TransportRouter — env=1 wins over config (HTTP on)") {
        let r = TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "1"], config: { _ in "false" })
        try expect(r.activeTransports == [.stdio, .streamableHTTP], "env=1 must enable, got \(r.activeTransports)")
    }

    await test("Packet E W2: TransportRouter — env explicit non-1 wins over config (HTTP off)") {
        // Env present (even "0"/"true") is authoritative — config must NOT override it.
        try expect(TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "0"], config: { _ in "1" })
            .activeTransports == [.stdio], "env=0 must stay off despite config=1")
        try expect(TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "true"], config: { _ in "1" })
            .activeTransports == [.stdio], "env=true (non-\"1\") must stay off despite config=1")
    }

    await test("Packet E W2: TransportRouter — config enables when env absent (durable on)") {
        try expect(TransportRouter(environment: [:], config: { $0 == "enableHTTP" ? "1" : nil })
            .activeTransports == [.stdio, .streamableHTTP], "config=1 must enable HTTP")
        try expect(TransportRouter(environment: [:], config: { $0 == "enableHTTP" ? "TRUE" : nil })
            .activeTransports == [.stdio, .streamableHTTP], "config=TRUE (case-insensitive) must enable HTTP")
    }

    await test("Packet E W2: TransportRouter — fail-closed off when env+config absent/blank") {
        try expect(TransportRouter(environment: [:], config: none).activeTransports == [.stdio],
                   "no env + no config must stay stdio-only (off)")
        try expect(TransportRouter(environment: [:], config: { _ in "0" }).activeTransports == [.stdio],
                   "config=0 must stay off")
        try expect(TransportRouter(environment: [:], config: { _ in "   " }).activeTransports == [.stdio],
                   "blank config must stay off")
    }

    // ── 3. ConnectorBearerValidator.fromEnvironment — env → config `oauthJWKS` → fail-closed
    // Source-selection precedence proven without crypto: a syntactically-INVALID
    // JWKS string ("{") fails to load → key-less → `.misconfigured` on validate;
    // a VALID (empty) JWKS ("{\"keys\":[]}") loads → keyed → validate fails for a
    // DIFFERENT reason (never `.misconfigured`). So the layer whose value is used
    // is observable via the misconfigured boundary.
    let kIss = "https://auth.kup.solutions"
    let kAud = "http://127.0.0.1:9700/mcp"
    let invalidJWKS = "{"               // fails JSON decode → load fails → key-less
    let validJWKS = "{\"keys\":[]}"     // decodes to an empty JWKS → loads → keyed
    // A token whose signature can never match an empty key set (any well-formed JWT
    // string is enough to get past the missing/garbled-header branch).
    let probeTok = await { () -> String in
        let priv = ES256PrivateKey()
        let signing = JWTKeyCollection()
        await signing.add(ecdsa: priv)
        let payload = BridgeAccessToken(
            iss: IssuerClaim(value: kIss), aud: AudienceClaim(value: [kAud]),
            sub: SubjectClaim(value: "probe"),
            exp: ExpirationClaim(value: Date().addingTimeInterval(300)),
            nbf: nil, scope: nil)
        return (try? await signing.sign(payload)) ?? "a.b.c"
    }()

    func isMisconfigured(_ v: ConnectorBearerValidator) async -> Bool {
        do { _ = try await v.validate(authorizationHeader: "Bearer \(probeTok)"); return false }
        catch let e as BearerValidationError { if case .misconfigured = e { return true }; return false }
        catch { return false }
    }

    await test("Packet E W2: JWKS — env source wins over config (env invalid ⇒ key-less even if config valid)") {
        let v = await ConnectorBearerValidator.fromEnvironment(
            environment: ["BRIDGE_OAUTH_JWKS": invalidJWKS],
            config: { $0 == "oauthJWKS" ? validJWKS : nil },
            expectedIssuer: kIss, expectedAudience: kAud)
        try expect(await isMisconfigured(v),
                   "env's invalid JWKS must be the chosen source ⇒ key-less ⇒ misconfigured")
    }

    await test("Packet E W2: JWKS — env source wins (env valid loads even when config invalid)") {
        let v = await ConnectorBearerValidator.fromEnvironment(
            environment: ["BRIDGE_OAUTH_JWKS": validJWKS],
            config: { $0 == "oauthJWKS" ? invalidJWKS : nil },
            expectedIssuer: kIss, expectedAudience: kAud)
        try expect(!(await isMisconfigured(v)),
                   "env's valid JWKS must load (keyed) ⇒ not misconfigured")
    }

    await test("Packet E W2: JWKS — config supplies the source when env absent") {
        let v = await ConnectorBearerValidator.fromEnvironment(
            environment: [:],
            config: { $0 == "oauthJWKS" ? validJWKS : nil },
            expectedIssuer: kIss, expectedAudience: kAud)
        try expect(!(await isMisconfigured(v)),
                   "config's valid JWKS must be selected + load (keyed) ⇒ not misconfigured")
    }

    await test("Packet E W2: JWKS — fail-closed (key-less) when env+config absent") {
        let v = await ConnectorBearerValidator.fromEnvironment(
            environment: [:], config: none,
            expectedIssuer: kIss, expectedAudience: kAud)
        try expect(await isMisconfigured(v),
                   "no env + no config must yield a key-less, fail-closed validator")
    }

    // ── 4. EnableCloudAccessFlow base-URL resolution — arg → env → config → placeholder.
    // Drives the REAL nonisolated resolver that `.live()` delegates to, so the
    // test and the @MainActor factory cannot drift.
    let placeholder = EnableCloudAccessFlow.defaultProvisionBaseURL
    await test("Packet E W2: cloud base URL — explicit arg wins over env + config") {
        let r = EnableCloudAccessFlow.resolvedProvisionBaseURL(
            arg: "https://arg.kup", environment: ["BRIDGE_CLOUD_BASE_URL": "https://env.kup"],
            config: { _ in "https://config.kup" })
        try expect(r == "https://arg.kup", "explicit arg must win, got \(r)")
    }

    await test("Packet E W2: cloud base URL — env wins over config when no arg") {
        let r = EnableCloudAccessFlow.resolvedProvisionBaseURL(
            arg: nil, environment: ["BRIDGE_CLOUD_BASE_URL": "https://env.kup"],
            config: { _ in "https://config.kup" })
        try expect(r == "https://env.kup", "env must win over config, got \(r)")
    }

    await test("Packet E W2: cloud base URL — config supplies when arg+env absent") {
        let r = EnableCloudAccessFlow.resolvedProvisionBaseURL(
            arg: nil, environment: [:], config: { $0 == "cloudBaseURL" ? "https://config.kup" : nil })
        try expect(r == "https://config.kup", "config must supply, got \(r)")
    }

    await test("Packet E W2: cloud base URL — fail-closed placeholder when all layers absent/blank") {
        try expect(EnableCloudAccessFlow.resolvedProvisionBaseURL(arg: nil, environment: [:], config: none)
            == placeholder, "all-absent must hit the documented placeholder")
        try expect(EnableCloudAccessFlow.resolvedProvisionBaseURL(
            arg: "   ", environment: ["BRIDGE_CLOUD_BASE_URL": ""], config: { _ in "  " })
            == placeholder, "blank-at-every-layer must hit the placeholder")
    }
}
