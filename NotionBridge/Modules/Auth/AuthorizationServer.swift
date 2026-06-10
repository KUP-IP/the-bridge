// AuthorizationServer.swift — WS-B (v2.3, PKT-803) · WS-F S1 (PKT-800)
// NotionBridge · Modules · Auth
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

    /// Resolves the authorization-server issuer: `BRIDGE_OAUTH_ISSUER`
    /// (trimmed, non-empty) if set, else the documented default.
    public static func resolvedIssuer(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let raw = environment[issuerEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultIssuer : raw
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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let pub = environment[publicResourceEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pub.isEmpty {
            return pub
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
            scopesSupported: connectorScopes,
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
