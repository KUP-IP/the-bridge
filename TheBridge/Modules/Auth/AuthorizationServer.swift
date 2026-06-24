// AuthorizationServer.swift — WS-B (v2.3, PKT-803) · WS-F S1 (PKT-800)
// TheBridge · Modules · Auth
//
// WS-B landed scaffold only (protocol + type declarations). PKT-800 S1
// fills the RFC 9728 ProtectedResourceMetadata type with an
// env-configurable factory + canonical JSON serialization so the
// `/.well-known/oauth-protected-resource` endpoint can advertise the
// protected MCP resource. Token/bearer validation, the ScopeGate
// conformer, DCR and consent remain deferred to a later slice — there is
// NO live WorkOS tenant in S1; the authorization-server issuer is a
// documented placeholder unless overridden via `BRIDGE_OAUTH_ISSUER`.
// Shapes follow Decision D3 (v3 hub Decision Log): OAuth 2.1 + PKCE,
// RFC 9728 Protected Resource Metadata (MUST), CIMD client identity
// preferred over DCR (Nov-2025 MCP spec), WorkOS AuthKit as the managed
// IdP.

import Foundation

// MARK: - Model

/// RFC 9728 Protected Resource Metadata document advertised at
/// `/.well-known/oauth-protected-resource`.
///
/// JSON member names are the snake_case identifiers mandated by RFC 9728
/// §2 (`resource`, `authorization_servers`, `scopes_supported`,
/// `bearer_methods_supported`); the Swift properties stay camelCase via
/// `CodingKeys`, so encode/decode round-trips through the wire form.
public struct ProtectedResourceMetadata: Codable, Sendable, Equatable {
    public let resource: String
    public let authorizationServers: [String]
    public let scopesSupported: [String]
    public let bearerMethodsSupported: [String]

    private enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case bearerMethodsSupported = "bearer_methods_supported"
    }

    public init(
        resource: String,
        authorizationServers: [String],
        scopesSupported: [String],
        bearerMethodsSupported: [String]
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
        self.bearerMethodsSupported = bearerMethodsSupported
    }
}

// MARK: - Protected Resource Metadata Factory (PKT-800 S1)

/// Builds the RFC 9728 Protected Resource Metadata document for the
/// remote-MCP connector. Pure value logic computed from the environment
/// so it is deterministic under test (no live IdP, no network).
public enum ProtectedResourceMetadataProvider {

    /// Environment variable that overrides the advertised OAuth
    /// authorization-server issuer. There is no live WorkOS tenant in
    /// S1; unset falls back to `defaultIssuer` (a documented,
    /// non-resolvable placeholder per RFC 6761 `.invalid`).
    public static let issuerEnvKey = "BRIDGE_OAUTH_ISSUER"

    /// Documented placeholder issuer used when `BRIDGE_OAUTH_ISSUER` is
    /// unset. Uses the reserved `.invalid` TLD so it can never resolve
    /// to a real host — this slice ships no live authorization server.
    public static let defaultIssuer = "https://auth.example.invalid"

    /// Advertised `scopes_supported`. PKT-810 directory-connector model:
    /// EMPTY. WorkOS AuthKit rejects an authorize that requests app-custom
    /// scopes (`invalid_scope`), so the connector must not ask clients for any
    /// — Claude/ChatGPT read this list and request exactly these scopes at
    /// authorize time. Authorization moves server-side: ConnectorScopeGate
    /// grants the connector-reachable allowlist to a validly-authenticated
    /// token that carries no connector scopes, and SecurityGate tiers +
    /// step-up consent remain the per-call safety layer. The named scope
    /// identifiers still live in `ConnectorScopeName` for the scoped-token
    /// path (back-compatible).
    public static let connectorScopes: [String] = []

    /// `scopes_supported` actually advertised to OAuth clients. The empty
    /// directory-connector list above is correct in theory (request nothing →
    /// no `invalid_scope`), but ChatGPT's connector requires a non-empty,
    /// AuthKit-mintable set at authorize time — proven live (Codex, 2026-06-12):
    /// with an empty/Bridge-only list ChatGPT cannot complete authorization.
    /// WorkOS hosted AuthKit mints exactly these standard OpenID scopes, so
    /// advertising them lets Claude AND ChatGPT request a set the AS will grant.
    /// Authorization stays server-side: connector tokens default to full tool
    /// parity (`strictScopes=false`); ConnectorScopeGate (opt-in) + SecurityGate
    /// tiers + step-up consent remain the per-call guardrail.
    public static let advertisedAuthKitScopes: [String] = [
        "openid", "email", "profile", "offline_access",
    ]

    /// Resolves the authorization-server issuer with a durable precedence
    /// (Packet E): `BRIDGE_OAUTH_ISSUER` env override → config.json
    /// (`oauthIssuer`, per-install) → the build-baked operator default
    /// (`RemoteAccessIdentity.issuer`, present at every launch) → the
    /// documented fail-closed placeholder. The baked layer is what ends the
    /// launchctl-setenv revert: it needs no runtime env and survives reboots.
    /// `config` / `baked` are injectable so this stays pure under test.
    public static func resolvedIssuer(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: (String) -> String? = { ConfigManager.shared.value(forKey: $0) as? String },
        baked: String? = nil
    ) -> String {
        if let e = environment[issuerEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
            return e
        }
        if let c = config("oauthIssuer")?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            return c
        }
        let b = (baked ?? RemoteAccessIdentity.issuer).trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? defaultIssuer : b
    }

    /// True when the resolved issuer is still the fail-closed placeholder —
    /// i.e. the build was never baked and no env/config override is present.
    /// Wave 3 uses this to fail loud (refuse to advertise a placeholder AS)
    /// instead of silently serving a broken cloud-connector identity.
    public static func isMisconfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: (String) -> String? = { ConfigManager.shared.value(forKey: $0) as? String },
        baked: String? = nil
    ) -> Bool {
        resolvedIssuer(environment: environment, config: config, baked: baked) == defaultIssuer
    }

    /// PKT-800 S2 (fix S1 finding #4a): the resource identifier must
    /// reflect the *resolved* SSE port — config.json → `NOTION_BRIDGE_PORT`
    /// → default 9700 — not a hardcoded 9700. Mirrors `ConfigManager`'s
    /// resolution order so the advertised PRM `resource` matches the port
    /// the connector actually listens on. `port` is injectable so tests
    /// can drive the `NOTION_BRIDGE_PORT` override + default deterministically
    /// without touching `ConfigManager`'s shared singleton.
    /// Env key for the canonical PUBLIC resource identifier (PKT-810 / Model B
    /// directory connector). When the connector is reached over a public tunnel
    /// (e.g. `https://mcp.kup.solutions/mcp`), the advertised PRM `resource` and
    /// the bearer-validator's expected audience must be that public URL — NOT
    /// the local `http://127.0.0.1:<port>/mcp`, which is meaningless to a remote
    /// OAuth client. Absent ⇒ fall back to the local-port derivation (stdio /
    /// loopback dev).
    public static let publicResourceEnvKey = "BRIDGE_PUBLIC_RESOURCE"

    public static func resolvedResource(
        port: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: (String) -> String? = { ConfigManager.shared.value(forKey: $0) as? String },
        baked: String? = nil
    ) -> String {
        // Durable precedence (Packet E): env override → config.json
        // (`publicResource`, per-install / multi-tenant) → build-baked operator
        // default → fail-closed local-origin derivation (loopback dev).
        if let pub = environment[publicResourceEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pub.isEmpty {
            return pub
        }
        if let c = config("publicResource")?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            return c
        }
        let b = (baked ?? RemoteAccessIdentity.publicResource).trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty {
            return b
        }
        let resolvedPort: Int
        if let port {
            resolvedPort = port
        } else if let envValue = environment["NOTION_BRIDGE_PORT"],
                  let envPort = Int(envValue),
                  (1...65535).contains(envPort) {
            resolvedPort = envPort
        } else {
            resolvedPort = ConfigManager.shared.ssePort
        }
        return "http://127.0.0.1:\(resolvedPort)/mcp"
    }

    /// Builds the metadata document.
    ///
    /// - Parameters:
    ///   - resource: an explicit canonical resource identifier override.
    ///     `nil` (the default) ⇒ derive it from the resolved SSE port via
    ///     `resolvedResource` (config.json → `NOTION_BRIDGE_PORT` → 9700),
    ///     fixing the S1 hardcoded-9700 finding.
    ///   - port: optional explicit port (test seam for the
    ///     `NOTION_BRIDGE_PORT`-override / default cases) — ignored when
    ///     `resource` is supplied explicitly.
    ///   - environment: process environment (injectable for tests).
    public static func metadata(
        resource: String? = nil,
        port: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProtectedResourceMetadata {
        let resolved = resource ?? resolvedResource(port: port, environment: environment)
        return ProtectedResourceMetadata(
            resource: resolved,
            authorizationServers: [resolvedIssuer(environment: environment)],
            scopesSupported: advertisedAuthKitScopes,
            bearerMethodsSupported: ["header"]
        )
    }

    /// Canonical JSON body for the `/.well-known/oauth-protected-resource`
    /// response (sorted keys, RFC 9728 snake_case members).
    public static func jsonBody(
        resource: String? = nil,
        port: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Data {
        let doc = metadata(resource: resource, port: port, environment: environment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(doc)) ?? Data("{}".utf8)
    }

    /// Packet E Wave 3 — fail-loud PRM serving decision.
    ///
    /// What the `/.well-known/oauth-protected-resource` route should emit:
    ///   • `.serve(body)` — the build is configured (env / config.json / baked
    ///     identity present), so advertise the normal RFC 9728 document. The
    ///     body is exactly `jsonBody(...)`, so a configured deployment is
    ///     byte-identical to the pre-Wave-3 behaviour (a normal 200 PRM).
    ///   • `.refuseMisconfigured` — `isMisconfigured()` is true: the resolved
    ///     issuer is still the fail-closed `auth.example.invalid` placeholder.
    ///     The caller MUST NOT serve a 200 advertising a placeholder
    ///     authorization server (a client would be sent into a dead OAuth
    ///     discovery against a non-resolvable host). Fail loud instead.
    ///
    /// Pure + injectable (env / config / baked seams) so the serving-path
    /// decision is hermetically testable; the live serving path calls it with
    /// the defaults (real environment, ConfigManager, baked identity), so the
    /// gate fires off exactly the same signal that `isMisconfigured()` reports.
    public enum PRMServingDecision: Sendable, Equatable {
        case serve(Data)
        case refuseMisconfigured
    }

    public static func prmServingDecision(
        resource: String? = nil,
        port: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: (String) -> String? = { ConfigManager.shared.value(forKey: $0) as? String },
        baked: String? = nil
    ) -> PRMServingDecision {
        if isMisconfigured(environment: environment, config: config, baked: baked) {
            return .refuseMisconfigured
        }
        return .serve(jsonBody(resource: resource, port: port, environment: environment))
    }

    /// Short human-readable error message for the 503 the PRM route returns
    /// when the build is misconfigured (placeholder issuer). The 503 body
    /// deliberately advertises NO `authorization_servers` — it signals "remote
    /// access is not configured" rather than handing out the `.invalid`
    /// placeholder authorization server.
    public static let misconfiguredPRMErrorMessage =
        "remote access not configured: no authorization server is advertised "
        + "until BRIDGE_OAUTH_ISSUER / config / a baked identity is set"
}

/// PKCE challenge pair (RFC 7636). `method` is `S256` for OAuth 2.1.
public struct PKCEChallenge: Sendable, Equatable {
    public let codeChallenge: String
    public let codeChallengeMethod: String

    public init(codeChallenge: String, codeChallengeMethod: String) {
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
    }
}

/// Result of an authorization-code exchange.
public struct AuthorizationGrant: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let scopes: [String]
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, scopes: [String], expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.expiresAt = expiresAt
    }
}

public enum AuthorizationError: Error, Equatable, Sendable {
    case invalidClient
    case invalidGrant
    case invalidScope(String)
    case pkceVerificationFailed
    case unsupportedResponseType(String)
}

// MARK: - Protocol

/// OAuth 2.1 authorization server facade for the remote-MCP connector.
/// All members are declaration-only in WS-B; WS-F provides the conformer.
public protocol AuthorizationServing: Sendable {
    /// RFC 9728 metadata for the protected MCP resource.
    func protectedResourceMetadata() async -> ProtectedResourceMetadata

    /// Exchange an authorization code (+ PKCE verifier) for tokens.
    func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> AuthorizationGrant

    /// Refresh an access token using a refresh token.
    func refresh(refreshToken: String) async throws -> AuthorizationGrant
}
