// AuthorizationServer.swift — WS-B (v2.3, PKT-803)
// NotionBridge · Modules · Auth
//
// Scaffold only — protocol + type declarations, zero implementation.
// Implemented in WS-F (auth server + live HTTP transport). Shapes here
// follow Decision D3 (v3 hub Decision Log): OAuth 2.1 + PKCE, RFC 9728
// Protected Resource Metadata (MUST), CIMD client identity preferred
// over DCR (Nov-2025 MCP spec), WorkOS AuthKit as the managed IdP.

import Foundation

// MARK: - Model

/// RFC 9728 Protected Resource Metadata document advertised at
/// `/.well-known/oauth-protected-resource`.
public struct ProtectedResourceMetadata: Codable, Sendable, Equatable {
    public let resource: String
    public let authorizationServers: [String]
    public let scopesSupported: [String]
    public let bearerMethodsSupported: [String]

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
