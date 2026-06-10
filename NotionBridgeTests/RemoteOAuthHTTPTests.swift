// RemoteOAuthHTTPTests.swift — PKT-800 S1 (remote OAuth/HTTP, slice 1)
// NotionBridge · Tests (custom harness — no XCTest)
//
// Covers:
//   • RFC 9728 Protected Resource Metadata document: required members,
//     non-empty authorization_servers, BRIDGE_OAUTH_ISSUER override +
//     documented default, JSON round-trip through ProtectedResourceMetadata.
//   • Transport gating: TransportRouter default = [.stdio] only;
//     BRIDGE_ENABLE_HTTP=1 adds .streamableHTTP AND keeps .stdio
//     (stdio non-regression invariant).
//   • PRM route resolution via the single-source MCPHTTPRoute classifier:
//     resolves for GET /.well-known/oauth-protected-resource and does NOT
//     shadow /health, /sse, /messages, /jobs/*/run, or /mcp. Plus an
//     end-to-end NIOEmbedded drive of an HTTP request part to prove the
//     route survives real NIO request decoding.

import Foundation
import NIOEmbedded
import NIOCore
import NIOHTTP1
import NotionBridgeLib

func runRemoteOAuthHTTPTests() async {
    print("\n\u{1F510} Remote OAuth / HTTP (PKT-800 S1)")

    // MARK: - RFC 9728 Protected Resource Metadata document

    await test("PRM: all required RFC 9728 members present and non-empty") {
        let m = ProtectedResourceMetadataProvider.metadata(environment: [:])
        try expect(!m.resource.isEmpty, "resource must be non-empty")
        try expect(!m.authorizationServers.isEmpty, "authorization_servers must be non-empty")
        // PKT-810: scopes_supported is intentionally EMPTY (directory model —
        // WorkOS AuthKit rejects app-custom scopes; auth is server-side).
        try expect(m.bearerMethodsSupported == ["header"], "bearer_methods_supported must be [header]")
    }

    await test("PRM: authorization_servers reflects documented default when env unset") {
        let m = ProtectedResourceMetadataProvider.metadata(environment: [:])
        try expect(
            m.authorizationServers == [ProtectedResourceMetadataProvider.defaultIssuer],
            "expected default issuer, got \(m.authorizationServers)"
        )
        try expect(
            ProtectedResourceMetadataProvider.defaultIssuer == "https://auth.example.invalid",
            "default issuer drifted: \(ProtectedResourceMetadataProvider.defaultIssuer)"
        )
    }

    await test("PRM: BRIDGE_OAUTH_ISSUER override is reflected in authorization_servers") {
        let env = ["BRIDGE_OAUTH_ISSUER": "https://auth.kup.solutions"]
        let m = ProtectedResourceMetadataProvider.metadata(environment: env)
        try expect(
            m.authorizationServers == ["https://auth.kup.solutions"],
            "expected override issuer, got \(m.authorizationServers)"
        )
    }

    await test("PRM: blank / whitespace BRIDGE_OAUTH_ISSUER falls back to default") {
        let m1 = ProtectedResourceMetadataProvider.metadata(environment: ["BRIDGE_OAUTH_ISSUER": "   "])
        try expect(m1.authorizationServers == [ProtectedResourceMetadataProvider.defaultIssuer])
        let m2 = ProtectedResourceMetadataProvider.metadata(environment: ["BRIDGE_OAUTH_ISSUER": ""])
        try expect(m2.authorizationServers == [ProtectedResourceMetadataProvider.defaultIssuer])
    }

    await test("PRM: resolvedIssuer trims surrounding whitespace") {
        let v = ProtectedResourceMetadataProvider.resolvedIssuer(
            environment: ["BRIDGE_OAUTH_ISSUER": "  https://issuer.example  "]
        )
        try expect(v == "https://issuer.example", "expected trimmed issuer, got '\(v)'")
    }

    await test("PRM: scopes_supported is empty (PKT-810 directory model)") {
        // PKT-810: WorkOS AuthKit rejects an authorize that requests app-custom
        // scopes (`invalid_scope`), proven by a live authorize probe. The
        // connector therefore advertises NO scopes; Claude/ChatGPT request none
        // and the authorize proceeds. Authorization moves server-side
        // (ConnectorScopeGate grants the reachable allowlist to an authenticated
        // scope-less token; SecurityGate + step-up consent guard each call).
        let m = ProtectedResourceMetadataProvider.metadata(environment: [:])
        try expect(m.scopesSupported.isEmpty, "scopes_supported must be empty; got \(m.scopesSupported)")
        try expect(
            ProtectedResourceMetadataProvider.connectorScopes == m.scopesSupported,
            "provider constant must match emitted scopes"
        )
    }

    await test("PRM: resource defaults to localhost Streamable HTTP endpoint") {
        let m = ProtectedResourceMetadataProvider.metadata(environment: [:])
        try expect(m.resource.contains("/mcp"), "resource should target /mcp endpoint")
        try expect(m.resource.contains("127.0.0.1"), "resource should be localhost in S1")
    }

    await test("PRM: custom resource identifier is honored") {
        let m = ProtectedResourceMetadataProvider.metadata(
            resource: "https://mcp.kup.solutions/mcp",
            environment: [:]
        )
        try expect(m.resource == "https://mcp.kup.solutions/mcp")
    }

    // MARK: - JSON serialization / round-trip

    await test("PRM: JSON body uses RFC 9728 snake_case member names") {
        let data = ProtectedResourceMetadataProvider.jsonBody(environment: [:])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let json = try (obj ?? [:])
        try expect(json["resource"] != nil, "missing 'resource'")
        try expect(json["authorization_servers"] != nil, "missing 'authorization_servers'")
        try expect(json["scopes_supported"] != nil, "missing 'scopes_supported'")
        try expect(json["bearer_methods_supported"] != nil, "missing 'bearer_methods_supported'")
        // camelCase Swift names must NOT leak onto the wire
        try expect(json["authorizationServers"] == nil, "camelCase 'authorizationServers' leaked")
        try expect(json["scopesSupported"] == nil, "camelCase 'scopesSupported' leaked")
        try expect(json["bearerMethodsSupported"] == nil, "camelCase 'bearerMethodsSupported' leaked")
    }

    await test("PRM: JSON body round-trips back through ProtectedResourceMetadata") {
        let env = ["BRIDGE_OAUTH_ISSUER": "https://rt.example"]
        let data = ProtectedResourceMetadataProvider.jsonBody(environment: env)
        let decoded = try JSONDecoder().decode(ProtectedResourceMetadata.self, from: data)
        let expected = ProtectedResourceMetadataProvider.metadata(environment: env)
        try expect(decoded == expected, "decoded PRM did not equal source document")
        try expect(decoded.authorizationServers == ["https://rt.example"])
    }

    await test("PRM: ProtectedResourceMetadata encode→decode is identity") {
        let original = ProtectedResourceMetadata(
            resource: "https://r.example/mcp",
            authorizationServers: ["https://a.example", "https://b.example"],
            scopesSupported: ["x.read", "y.write"],
            bearerMethodsSupported: ["header"]
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(original)
        let back = try JSONDecoder().decode(ProtectedResourceMetadata.self, from: data)
        try expect(back == original, "Codable round-trip lost data")
    }

    await test("PRM: jsonBody is deterministic (sorted keys, stable bytes)") {
        let a = ProtectedResourceMetadataProvider.jsonBody(environment: [:])
        let b = ProtectedResourceMetadataProvider.jsonBody(environment: [:])
        try expect(a == b, "PRM JSON body must be byte-stable for caching")
    }

    // MARK: - Transport gating (stdio non-regression invariant)

    await test("TransportRouter: default (no env) is [.stdio] only") {
        let r = TransportRouter(environment: [:])
        try expect(r.activeTransports == [.stdio], "default must be stdio-only, got \(r.activeTransports)")
        try expect(r.isActive(.stdio), "stdio must always be active")
        try expect(!r.isActive(.streamableHTTP), "streamableHTTP must be inactive by default")
    }

    await test("TransportRouter: BRIDGE_ENABLE_HTTP=1 adds streamableHTTP AND keeps stdio") {
        let r = TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "1"])
        try expect(r.activeTransports == [.stdio, .streamableHTTP], "got \(r.activeTransports)")
        try expect(r.isActive(.stdio), "stdio non-regression invariant: stdio must remain active")
        try expect(r.isActive(.streamableHTTP), "streamableHTTP must be active with env=1")
    }

    await test("TransportRouter: non-\"1\" BRIDGE_ENABLE_HTTP stays stdio-only") {
        for v in ["0", "true", "yes", "on", " 1", "1 "] {
            let r = TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": v])
            try expect(r.activeTransports == [.stdio], "value '\(v)' must not enable HTTP")
        }
    }

    await test("TransportRouter: ProcessInfo default is stdio-only (no test env leak)") {
        // The harness must not set BRIDGE_ENABLE_HTTP; the production
        // default path must resolve to stdio-only.
        let r = TransportRouter()
        try expect(r.isActive(.stdio), "stdio always active")
        try expect(!r.isActive(.streamableHTTP), "default env must keep streamableHTTP off")
    }

    // MARK: - PRM route classification (single-source, non-shadowing)

    await test("Route: GET /.well-known/oauth-protected-resource → protectedResourceMetadata") {
        let route = MCPHTTPRoute.classify(
            method: "GET",
            path: "/.well-known/oauth-protected-resource",
            endpoint: "/mcp"
        )
        try expect(route == .protectedResourceMetadata, "got \(route)")
    }

    await test("Route: PRM path does NOT shadow /health, /sse, /messages, jobs, /mcp") {
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/health", endpoint: "/mcp") == .health)
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/sse", endpoint: "/mcp") == .legacySSE)
        try expect(MCPHTTPRoute.classify(method: "POST", path: "/messages", endpoint: "/mcp") == .legacyMessages)
        try expect(MCPHTTPRoute.classify(method: "POST", path: "/jobs/abc/run", endpoint: "/mcp") == .jobsRun("abc"))
        try expect(MCPHTTPRoute.classify(method: "POST", path: "/mcp", endpoint: "/mcp") == .mcpEndpoint)
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/mcp", endpoint: "/mcp") == .mcpEndpoint)
        // None of the above is the PRM route.
        for (mth, pth) in [("GET","/health"),("GET","/sse"),("POST","/messages"),("POST","/jobs/x/run"),("POST","/mcp")] {
            try expect(
                MCPHTTPRoute.classify(method: mth, path: pth, endpoint: "/mcp") != .protectedResourceMetadata,
                "\(mth) \(pth) wrongly classified as PRM"
            )
        }
    }

    await test("Route: PRM is GET-only (POST to well-known is notFound, not PRM)") {
        let post = MCPHTTPRoute.classify(
            method: "POST",
            path: "/.well-known/oauth-protected-resource",
            endpoint: "/mcp"
        )
        try expect(post == .notFound, "POST to PRM path must not resolve PRM, got \(post)")
    }

    await test("Route: OPTIONS short-circuits to corsPreflight regardless of path") {
        try expect(
            MCPHTTPRoute.classify(method: "OPTIONS", path: "/.well-known/oauth-protected-resource", endpoint: "/mcp") == .corsPreflight
        )
        try expect(MCPHTTPRoute.classify(method: "OPTIONS", path: "/mcp", endpoint: "/mcp") == .corsPreflight)
    }

    await test("Route: unknown path is notFound") {
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/nope", endpoint: "/mcp") == .notFound)
        try expect(MCPHTTPRoute.classify(method: "GET", path: "/.well-known/openid-configuration", endpoint: "/mcp") == .notFound)
    }

    await test("Route: method matching is case-insensitive") {
        try expect(
            MCPHTTPRoute.classify(method: "get", path: "/.well-known/oauth-protected-resource", endpoint: "/mcp") == .protectedResourceMetadata
        )
    }

    // MARK: - End-to-end NIO request-part decode → route survives

    await test("NIOEmbedded: a real GET request part decodes to the PRM route") {
        // Drive an actual NIO HTTP request HEAD through an EmbeddedChannel
        // configured with the HTTP server pipeline, then classify the
        // decoded head with the same single-source function the live
        // handler uses. Proves the route holds after real NIO decoding.
        let channel = EmbeddedChannel()
        try channel.pipeline.configureHTTPServerPipeline().wait()

        var buf = channel.allocator.buffer(capacity: 128)
        buf.writeString(
            "GET /.well-known/oauth-protected-resource HTTP/1.1\r\nHost: 127.0.0.1:9700\r\n\r\n"
        )
        try channel.writeInbound(buf)

        guard let part = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            throw TestError.assertion("expected a decoded HTTPServerRequestPart")
        }
        guard case .head(let head) = part else {
            throw TestError.assertion("expected .head, got \(part)")
        }

        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let route = MCPHTTPRoute.classify(
            method: head.method.rawValue,
            path: path,
            endpoint: "/mcp"
        )
        try expect(route == .protectedResourceMetadata, "decoded route was \(route)")
        try expect(head.method == .GET, "expected GET")

        _ = try? channel.finish()
    }

    await test("NIOEmbedded: a real GET /mcp part still decodes to mcpEndpoint (non-regression)") {
        let channel = EmbeddedChannel()
        try channel.pipeline.configureHTTPServerPipeline().wait()

        var buf = channel.allocator.buffer(capacity: 64)
        buf.writeString("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:9700\r\n\r\n")
        try channel.writeInbound(buf)

        guard let part = try channel.readInbound(as: HTTPServerRequestPart.self),
              case .head(let head) = part else {
            throw TestError.assertion("expected decoded .head")
        }
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        try expect(
            MCPHTTPRoute.classify(method: head.method.rawValue, path: path, endpoint: "/mcp") == .mcpEndpoint,
            "/mcp must remain the MCP endpoint route"
        )
        _ = try? channel.finish()
    }
}
