// TokenStore.swift — WS-B (v2.3, PKT-803)
// TheBridge · Modules · Auth
//
// Scaffold only — protocol + type declarations, zero implementation.
// Implemented in WS-F. Persistence backend (Keychain vs file) is a
// WS-F decision; this file fixes only the contract + token model.

import Foundation

// MARK: - Model

/// A persisted bearer token with its scope grant and expiry.
public struct StoredToken: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let scopes: [String]
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        accessToken: String,
        refreshToken: String?,
        scopes: [String],
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// True once `expiresAt` is in the past relative to `now`.
    public func isExpired(now: Date) -> Bool { now >= expiresAt }
}

public enum TokenStoreError: Error, Equatable, Sendable {
    case notFound(String)
    case persistenceFailed(String)
}

// MARK: - Protocol

/// Storage facade for issued connector tokens, keyed by client identifier.
/// Declaration-only in WS-B; WS-F provides the conformer.
public protocol TokenStoring: Sendable {
    func save(_ token: StoredToken, for clientID: String) async throws
    func load(for clientID: String) async throws -> StoredToken
    func delete(for clientID: String) async throws
}
