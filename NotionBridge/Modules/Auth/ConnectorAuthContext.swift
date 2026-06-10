// ConnectorAuthContext.swift — WS-F S2 (PKT-800)
// NotionBridge · Modules · Auth
//
// Bundles the bearer validator + scope gate + the RFC 9728 PRM pointer
// for the remote `/mcp` connector path, and owns the *one* place that
// turns a failed bearer check into an RFC 6750 `401 + WWW-Authenticate`
// challenge. This is the additive-isolation boundary object: an
// `SSEServer` holds it as an Optional that is `nil` in every default
// configuration (stdio-only — `BRIDGE_ENABLE_HTTP` unset), so the
// connector-auth code path is provably unreachable for stdio, legacy SSE
// (`/sse`+`/messages`), `/health`, the job callback, and local tool
// dispatch. It is non-nil ONLY when the streamableHTTP transport is gated
// on AND a key set is configured.

import Foundation

/// Connector authentication/authorization bundle for the `/mcp` path.
public struct ConnectorAuthContext: Sendable {
    public let validator: ConnectorBearerValidator
    public let scopeGate: ConnectorScopeGate
    /// WS-F S3: step-up consent on destructive connector tools.
    public let stepUpGate: ConnectorStepUpGate
    /// WS-F S3: confused-deputy isolation — binds the verified principal
    /// to its MCP session and rejects cross-client/token substitution.
    public let sessionBinding: ConnectorSessionBinding
    /// WS-F S3: redaction-asserting connector-auth diagnostics sink. The
    /// only place the connector path emits auth events; every detail is
    /// redacted before storage so the bearer-leak sweep can prove zero
    /// secret occurrences.
    public let diagnostics: ConnectorAuthDiagnostics
    /// Absolute URL of the RFC 9728 Protected Resource Metadata document,
    /// referenced from the `WWW-Authenticate` challenge so a client knows
    /// where to discover the authorization server.
    public let resourceMetadataURL: String
    /// PKT-810 coexistence: the loopback (local desktop / stdio-proxy) static
    /// bearer. Remote (tunnel) requests are OAuth-gated via `validator`; local
    /// direct-loopback requests are gated on THIS shared secret instead, so a
    /// second macOS account on a shared Mac cannot drive the Bridge over
    /// 127.0.0.1. `nil`/empty ⇒ prior local-trust (loopback unauthenticated).
    /// The bearer is loopback-scoped: tunnel requests never take the local
    /// branch, so it can never bypass cloud OAuth.
    public let localBearer: String?

    public init(
        validator: ConnectorBearerValidator,
        scopeGate: ConnectorScopeGate = ConnectorScopeGate(),
        stepUpGate: ConnectorStepUpGate = ConnectorStepUpGate(),
        sessionBinding: ConnectorSessionBinding = ConnectorSessionBinding(),
        diagnostics: ConnectorAuthDiagnostics = ConnectorAuthDiagnostics(),
        resourceMetadataURL: String,
        localBearer: String? = nil
    ) {
        self.validator = validator
        self.scopeGate = scopeGate
        self.stepUpGate = stepUpGate
        self.sessionBinding = sessionBinding
        self.diagnostics = diagnostics
        self.resourceMetadataURL = resourceMetadataURL
        self.localBearer = localBearer
    }

    /// RFC 6750 §3 `WWW-Authenticate` header value for a rejected /
    /// missing bearer on a connector request. Always references the PRM
    /// document (RFC 9728 §5.1) so the client can bootstrap discovery.
    public func wwwAuthenticateValue(for error: BearerValidationError) -> String {
        var params = [
            "error=\"\(error.wwwAuthenticateError)\"",
            "resource_metadata=\"\(resourceMetadataURL)\"",
        ]
        if case .missingBearer = error {
            // No description for a plain missing-credentials challenge.
        } else {
            params.insert("error_description=\"\(error.challengeDescription)\"", at: 1)
        }
        return "Bearer " + params.joined(separator: ", ")
    }
}

extension BearerValidationError {
    /// Short, header-safe (no CR/LF/`"`) description for the
    /// `error_description` challenge parameter.
    var challengeDescription: String {
        let raw: String
        switch self {
        case .missingBearer: raw = "missing bearer token"
        case .malformedAuthorizationHeader: raw = "malformed Authorization header"
        case .signatureInvalid: raw = "signature verification failed"
        case .issuerMismatch: raw = "issuer not accepted"
        case .audienceMismatch: raw = "audience not accepted"
        case .expired: raw = "token expired"
        case .notYetValid: raw = "token not yet valid"
        case .misconfigured: raw = "connector key set not configured"
        case .malformedToken: raw = "malformed token"
        }
        return raw.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
