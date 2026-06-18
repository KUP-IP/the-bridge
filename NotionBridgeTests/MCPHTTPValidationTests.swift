// MCPHTTPValidationTests.swift — tunnel Origin/Host allowlist parsing
import Foundation
import MCP
import NotionBridgeLib

private let tunnelURLKey = "tunnelURL"

private func withMCPHTTPDefaults(
    tunnelURL: String?,
    mcpBearer: String?,
    _ body: () throws -> Void
) rethrows {
    let ud = UserDefaults.standard
    let prevTunnel = ud.string(forKey: tunnelURLKey)
    let prevBearer = ud.string(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
    if let tunnelURL {
        ud.set(tunnelURL, forKey: tunnelURLKey)
    } else {
        ud.removeObject(forKey: tunnelURLKey)
    }
    if let mcpBearer {
        ud.set(mcpBearer, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
    } else {
        ud.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
    }
    defer {
        if let prevTunnel {
            ud.set(prevTunnel, forKey: tunnelURLKey)
        } else {
            ud.removeObject(forKey: tunnelURLKey)
        }
        if let prevBearer {
            ud.set(prevBearer, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        } else {
            ud.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        }
    }
    try body()
}

func runMCPHTTPValidationTests() async {
    print("\n\u{1F310} MCPHTTPValidation (tunnel / Streamable HTTP)")

    await test("tunnelOriginAllowlist is nil for empty URL") {
        try expect(MCPHTTPValidation.tunnelOriginAllowlist(from: "") == nil)
        try expect(MCPHTTPValidation.tunnelOriginAllowlist(from: "   ") == nil)
    }

    await test("tunnelOriginAllowlist parses https host and origin") {
        guard let r = MCPHTTPValidation.tunnelOriginAllowlist(from: "https://abc.trycloudflare.com/path")
        else {
            throw TestError.assertion("expected non-nil allowlist")
        }
        try expect(r.origins.contains("https://abc.trycloudflare.com"))
        try expect(r.hosts.contains("abc.trycloudflare.com"))
        try expect(r.hosts.contains("abc.trycloudflare.com:*"))
    }

    await test("tunnelOriginAllowlist adds scheme if omitted") {
        guard let r = MCPHTTPValidation.tunnelOriginAllowlist(from: "tunnel.example.com")
        else {
            throw TestError.assertion("expected non-nil")
        }
        try expect(r.origins.contains("https://tunnel.example.com"))
    }

    await test("tunnelOriginAllowlist handles explicit port") {
        guard let r = MCPHTTPValidation.tunnelOriginAllowlist(from: "https://h.example:8443")
        else {
            throw TestError.assertion("expected non-nil")
        }
        try expect(r.origins.contains("https://h.example:8443"))
        try expect(r.hosts.contains("h.example:8443"))
    }

    await test("tunnelOriginAllowlist supports dedicated MCP hostname") {
        guard let r = MCPHTTPValidation.tunnelOriginAllowlist(from: "https://mcp.kup.solutions")
        else {
            throw TestError.assertion("expected non-nil")
        }
        try expect(r.origins.contains("https://mcp.kup.solutions"))
        try expect(r.hosts.contains("mcp.kup.solutions"))
        try expect(r.hosts.contains("mcp.kup.solutions:*"))
    }


    await test("isRemoteTunnelActive is false when tunnel URL empty") {
        try withMCPHTTPDefaults(tunnelURL: nil, mcpBearer: nil) {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == false)
        }
    }

    await test("streamableHTTPBearerPhase is none when tunnel inactive and no token") {
        try withMCPHTTPDefaults(tunnelURL: nil, mcpBearer: nil) {
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .none)
        }
    }

    await test("remote tunnel active + empty token → remoteTunnelMissingToken") {
        try withMCPHTTPDefaults(tunnelURL: "https://bridge.example.com", mcpBearer: nil) {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == true)
            try expect(MCPHTTPValidation.resolveMCPBearerToken().isEmpty)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .remoteTunnelMissingToken)
        }
    }

    await test("remote tunnel active + token → bearerRequired") {
        try withMCPHTTPDefaults(tunnelURL: "https://t.example", mcpBearer: "secret-token") {
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .bearerRequired("secret-token"))
        }
    }

    await test("tunnel inactive + token → optional bearer (bearerRequired phase)") {
        try withMCPHTTPDefaults(tunnelURL: nil, mcpBearer: "local-only") {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == false)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .bearerRequired("local-only"))
        }
    }

    await test("invalid tunnel URL string does not activate remote (no extra allowlist)") {
        try withMCPHTTPDefaults(tunnelURL: "not a url !!!", mcpBearer: nil) {
            try expect(MCPHTTPValidation.tunnelOriginAllowlist(from: "not a url !!!") == nil)
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == false)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .none)
        }
    }

    // MARK: - Three-state remote access status tests

    await test("three-state: no URL → notConfigured (phase .none)") {
        try withMCPHTTPDefaults(tunnelURL: nil, mcpBearer: nil) {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == false)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .none)
        }
    }

    await test("three-state: URL + no token → misconfigured (phase .remoteTunnelMissingToken)") {
        try withMCPHTTPDefaults(tunnelURL: "https://mcp.example.com", mcpBearer: nil) {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == true)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .remoteTunnelMissingToken)
        }
    }

    await test("three-state: URL + token → active (phase .bearerRequired)") {
        try withMCPHTTPDefaults(tunnelURL: "https://mcp.example.com", mcpBearer: "test-token-123") {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == true)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .bearerRequired("test-token-123"))
        }
    }

    await test("three-state: empty-string token treated as missing") {
        try withMCPHTTPDefaults(tunnelURL: "https://mcp.example.com", mcpBearer: "   ") {
            try expect(MCPHTTPValidation.resolveMCPBearerToken().isEmpty)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .remoteTunnelMissingToken)
        }
    }

    await test("constant-time comparison: equal strings") {
        try expect(MCPHTTPValidation.constantTimeEqual("abc123", "abc123") == true)
    }

    await test("constant-time comparison: unequal strings") {
        try expect(MCPHTTPValidation.constantTimeEqual("abc123", "abc124") == false)
    }

    await test("constant-time comparison: different lengths") {
        try expect(MCPHTTPValidation.constantTimeEqual("short", "longer-string") == false)
    }

    // PKT-810 R5 — legacy bearer phase is origin-split too: with `tunnelURL` + a
    // static bearer configured (the cloud-connector operator install) and NO
    // connector OAuth path (connectorAuth == nil), a DIRECT-LOOPBACK /mcp request
    // is served token-free, while a REMOTE (Cloudflare-tunnel) request still 401s
    // for the missing bearer. This is the second gate behind the local Claude
    // Desktop dead-end (the first being the connector OAuth gate).
    await test("StreamableHTTP: loopback exempt from legacy static bearer; tunnel still 401") {
        let ud = UserDefaults.standard
        let prevTunnel = ud.string(forKey: tunnelURLKey)
        let prevBearer = ud.string(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        ud.set("https://mcp.example.com/mcp", forKey: tunnelURLKey)
        ud.set("legacy-static-secret", forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        defer {
            if let prevTunnel { ud.set(prevTunnel, forKey: tunnelURLKey) }
            else { ud.removeObject(forKey: tunnelURLKey) }
            if let prevBearer { ud.set(prevBearer, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey) }
            else { ud.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey) }
        }
        // No connectorAuth (BRIDGE_ENABLE_HTTP unset) — only the legacy gate is live.
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog()),
            onToolCall: {}
        )
        let initBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\(BridgeConstants.mcpProtocolVersion)","capabilities":{},"clientInfo":{"name":"legacy-loopback","version":"t"}}}
        """.utf8)
        let localHeaders = [
            "Host": "127.0.0.1:\(BridgeConstants.defaultSSEPort)",
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        ]
        // LOOPBACK (no Cf header) + NO bearer ⇒ served token-free (not 401).
        let localResp = await server.handleHTTPRequest(
            HTTPRequest(method: "POST", headers: localHeaders, body: initBody))
        try expect(localResp.statusCode != 401,
                   "loopback must be exempt from the legacy static bearer, got \(localResp.statusCode)")
        try expect(localResp.headers[HTTPHeaderName.sessionID] != nil,
                   "loopback initialize must mint a session id token-free")
        // TUNNEL (Cf header) + NO bearer ⇒ 401 (legacy gate still applies off-loopback).
        var tunnelHeaders = localHeaders
        tunnelHeaders["Cf-Connecting-Ip"] = "203.0.113.7"
        let tunnelResp = await server.handleHTTPRequest(
            HTTPRequest(method: "POST", headers: tunnelHeaders, body: initBody))
        try expect(tunnelResp.statusCode == 401,
                   "tunnel must still require the legacy bearer, got \(tunnelResp.statusCode)")
    }
}
