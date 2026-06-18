// MCPHTTPValidation.swift — Streamable HTTP validation pipeline for MCP over HTTP
// The Bridge · Server
//
// When Remote Access has a tunnel URL configured (UserDefaults `tunnelURL`), extends
// Origin/Host allowlists beyond localhost so cloudflared / Tailscale / HTTPS clients can
// complete initialize without 403/421. When the tunnel URL parses (remote access active),
// `POST /mcp` requires a configured bearer token (fail closed). Keychain preferred; UserDefaults legacy.

import Foundation
import MCP

/// Builds the `StandardValidationPipeline` for StatefulHTTPServerTransport (Streamable HTTP `/mcp`).
public enum MCPHTTPValidation {
    private static let tunnelURLKey = "tunnelURL"
    /// Legacy / mirror; prefer `KeychainManager.Key.mcpBearerToken` for app-bundled runs.
    public static let mcpBearerTokenUserDefaultsKey = "com.notionbridge.mcpBearerToken"

    /// How Streamable HTTP `/mcp` applies bearer validation (single source of truth for pipeline + tests).
    public enum StreamableHTTPBearerPhase: Equatable, Sendable {
        /// Remote tunnel URL is active but no token is configured — all `POST /mcp` get 401.
        case remoteTunnelMissingToken
        /// Require `Authorization: Bearer` matching the given secret (remote mandatory or optional local hardening).
        case bearerRequired(String)
        /// No bearer validator (local-only remote access).
        case none
    }

    public static func streamableHTTPBearerPhase() -> StreamableHTTPBearerPhase {
        let remoteActive = isRemoteTunnelActive()
        let token = resolveMCPBearerToken()
        if remoteActive {
            return token.isEmpty ? .remoteTunnelMissingToken : .bearerRequired(token)
        }
        if !token.isEmpty {
            return .bearerRequired(token)
        }
        return .none
    }

    /// Validation pipeline for new MCP sessions (`initialize` on `POST /mcp`).
    ///
    /// - Parameter connectorAuthed: when true, this request was ALREADY
    ///   authenticated upstream by the connector bearer gate
    ///   (`ConnectorAuthContext` — a verified OAuth JWT, or a loopback-scoped
    ///   local static bearer). The legacy static-bearer / remote-tunnel-missing
    ///   phase MUST be skipped for these sessions: a connector OAuth JWT is not
    ///   the loopback static bearer, so re-comparing the `Authorization` header
    ///   against the static token would 403 every valid connector token (the
    ///   local↔cloud coexistence collision). Origin/Accept/Content-Type/
    ///   protocol/session checks still apply.
    static func streamableHTTPPipeline(ssePort: Int, connectorAuthed: Bool = false) -> StandardValidationPipeline {
        var validators: [any HTTPRequestValidator] = []

        if !connectorAuthed {
            switch streamableHTTPBearerPhase() {
            case .remoteTunnelMissingToken:
                validators.append(MCPRemoteTunnelMissingBearerValidator())
            case .bearerRequired(let secret):
                validators.append(MCPBearerTokenValidator(expectedToken: secret))
            case .none:
                break
            }
        }

        validators.append(originValidator(ssePort: ssePort))
        validators.append(AcceptHeaderValidator(mode: .sseRequired))
        validators.append(ContentTypeValidator())
        validators.append(ProtocolVersionValidator())
        validators.append(SessionValidator())

        return StandardValidationPipeline(validators: validators)
    }

    /// DNS rebinding policy: localhost always; if `tunnelURL` is set and parses, allow that host/origin too.
    static func originValidator(ssePort: Int) -> OriginValidator {
        let tunnel = UserDefaults.standard.string(forKey: tunnelURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let portStr = String(ssePort)
        var hosts: [String] = [
            "127.0.0.1:\(portStr)",
            "localhost:\(portStr)",
            "[::1]:\(portStr)",
        ]
        var origins: [String] = [
            "http://127.0.0.1:\(portStr)",
            "http://localhost:\(portStr)",
            "http://[::1]:\(portStr)",
        ]

        if let extra = tunnelOriginAllowlist(from: tunnel) {
            hosts.append(contentsOf: extra.hosts)
            origins.append(contentsOf: extra.origins)
        }

        return OriginValidator(allowedHosts: uniqued(hosts), allowedOrigins: uniqued(origins))
    }

    /// Parses a tunnel base URL → extra `Host` / `Origin` allowlist entries (merged with localhost lists).
    public static func tunnelOriginAllowlist(from tunnelURL: String) -> (hosts: [String], origins: [String])? {
        let trimmed = tunnelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }

        let scheme = (url.scheme ?? "https").lowercased()
        var hosts: [String] = [host, "\(host):*"]
        var origins: [String] = []

        if let p = url.port {
            hosts.append("\(host):\(p)")
            origins.append("\(scheme)://\(host):\(p)")
        } else {
            origins.append("\(scheme)://\(host)")
        }

        return (uniqued(hosts), uniqued(origins))
    }

    private static func uniqued(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(arr.count)
        for s in arr {
            if seen.insert(s).inserted {
                out.append(s)
            }
        }
        return out
    }

    /// `tunnelURL` is set and parses to a host allowlist (same predicate as extra Origin/Host entries).
    public static func isRemoteTunnelActive() -> Bool {
        let tunnel = UserDefaults.standard.string(forKey: tunnelURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !tunnel.isEmpty else { return false }
        return tunnelOriginAllowlist(from: tunnel) != nil
    }

    /// Keychain (`mcp_bearer_token`) first, then UserDefaults `com.notionbridge.mcpBearerToken`.
    public static func resolveMCPBearerToken() -> String {
        if let k = KeychainManager.shared.read(key: KeychainManager.Key.mcpBearerToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        return UserDefaults.standard.string(forKey: mcpBearerTokenUserDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Constant-time string comparison (SEC-01)

    /// Constant-time string comparison to prevent timing attacks.
    /// Returns true only if both strings are identical.
    /// Compares every byte position regardless of mismatch to avoid timing leaks.
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let lengthMatch = aBytes.count == bBytes.count
        let maxLen = max(aBytes.count, bBytes.count)
        var mismatch: UInt8 = 0
        for i in 0..<maxLen {
            let x = i < aBytes.count ? aBytes[i] : 0
            let y = i < bBytes.count ? bBytes[i] : 0
            mismatch |= x ^ y
        }
        return lengthMatch && mismatch == 0
    }
}

    // MARK: - Remote tunnel requires bearer (fail closed)

private struct MCPRemoteTunnelMissingBearerValidator: HTTPRequestValidator {
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard context.httpMethod == "POST" else { return nil }
        return .error(
            statusCode: 401,
            .invalidRequest(
                "Unauthorized: remote tunnel is configured but no MCP bearer token is set. Add a token in Settings → Connections → Remote Access and set Authorization: Bearer in your MCP client."
            ),
            sessionID: context.sessionID
        )
    }
}

// MARK: - Bearer token (optional)

private struct MCPBearerTokenValidator: HTTPRequestValidator {
    let expectedToken: String

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard context.httpMethod == "POST" else { return nil }

        guard let auth = request.header("Authorization"),
              auth.hasPrefix("Bearer ")
        else {
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized: missing Bearer token for MCP HTTP"),
                sessionID: context.sessionID
            )
        }

        let token = auth.dropFirst("Bearer ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // SEC-01: Constant-time comparison to prevent timing attacks on bearer token
        guard MCPHTTPValidation.constantTimeEqual(String(token), expectedToken) else {
            return .error(
                statusCode: 403,
                .invalidRequest("Forbidden: invalid MCP bearer token"),
                sessionID: context.sessionID
            )
        }

        return nil
    }
}
