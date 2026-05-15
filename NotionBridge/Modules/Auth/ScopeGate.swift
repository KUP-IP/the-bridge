// ScopeGate.swift — WS-B (v2.3, PKT-803)
// NotionBridge · Modules · Auth
//
// Scaffold only — protocol + type declarations, zero implementation.
// Implemented in WS-F. Maps connector OAuth scopes onto the existing
// Bridge tool surface so a remote caller's grant bounds which tools it
// may dispatch (complements, does not replace, SecurityGate tiers).

import Foundation

// MARK: - Model

/// A coarse capability scope requested/granted to a remote connector
/// client. Concrete scope→tool mapping is a WS-F decision.
public struct ConnectorScope: Codable, Sendable, Equatable, Hashable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// Outcome of a scope check for a single tool dispatch.
public enum ScopeDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

public enum ScopeGateError: Error, Equatable, Sendable {
    case unknownTool(String)
    case scopeNotGranted(ConnectorScope)
}

// MARK: - Protocol

/// Gate that authorizes a tool dispatch against a connector client's
/// granted scopes. Declaration-only in WS-B; WS-F provides the conformer.
public protocol ScopeGating: Sendable {
    /// Scopes required to dispatch `toolName`.
    func requiredScopes(for toolName: String) async throws -> [ConnectorScope]

    /// Decide whether `grantedScopes` satisfy `toolName`'s requirement.
    func evaluate(
        toolName: String,
        grantedScopes: [ConnectorScope]
    ) async -> ScopeDecision
}
