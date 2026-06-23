// RemoteAccessIdentityTests.swift — Packet E (PRJCT-2754 · durable Remote-Access config)
//
// Locks the env → config.json → build-baked → fail-closed precedence for the
// cloud-connector OAuth identity (the layer that ends the launchctl-setenv
// revert). All pure: the resolver's config/baked seams are injected, so no disk
// / no ConfigManager singleton / no ProcessInfo dependency.

import Foundation
import TheBridgeLib

func runRemoteAccessIdentityTests() async {
    print("\n\u{1F3DB}\u{FE0F} Packet E — Remote-Access identity resolution precedence")
    let none: @Sendable (String) -> String? = { _ in nil }

    // ── Issuer precedence ────────────────────────────────────────────────
    await test("Packet E: issuer — env override wins over config + baked") {
        let r = ProtectedResourceMetadataProvider.resolvedIssuer(
            environment: ["BRIDGE_OAUTH_ISSUER": "https://env.example.com"],
            config: { _ in "https://config.example.com" },
            baked: "https://baked.example.com")
        try expect(r == "https://env.example.com", "env must win, got \(r)")
    }

    await test("Packet E: issuer — config wins over baked when env absent") {
        let r = ProtectedResourceMetadataProvider.resolvedIssuer(
            environment: [:],
            config: { $0 == "oauthIssuer" ? "https://config.example.com" : nil },
            baked: "https://baked.example.com")
        try expect(r == "https://config.example.com", "config must win over baked, got \(r)")
    }

    await test("Packet E: issuer — baked supplies when env+config absent (durable default)") {
        let r = ProtectedResourceMetadataProvider.resolvedIssuer(
            environment: [:], config: none, baked: "https://agile-expression-49.authkit.app")
        try expect(r == "https://agile-expression-49.authkit.app", "baked must supply, got \(r)")
    }

    await test("Packet E: issuer — fail-closed placeholder when all layers empty") {
        let r = ProtectedResourceMetadataProvider.resolvedIssuer(environment: [:], config: none, baked: "")
        try expect(r == ProtectedResourceMetadataProvider.defaultIssuer, "must fail closed, got \(r)")
    }

    await test("Packet E: committed (unbaked) build is fail-closed via default baked param") {
        // No explicit baked: → uses RemoteAccessIdentity.issuer (committed EMPTY).
        let r = ProtectedResourceMetadataProvider.resolvedIssuer(environment: [:], config: none)
        try expect(r == ProtectedResourceMetadataProvider.defaultIssuer,
                   "committed build must resolve to the fail-closed placeholder, got \(r)")
    }

    await test("Packet E: isMisconfigured — true only when resolved issuer is the placeholder") {
        try expect(ProtectedResourceMetadataProvider.isMisconfigured(environment: [:], config: none, baked: ""),
                   "all-empty must be misconfigured")
        try expect(!ProtectedResourceMetadataProvider.isMisconfigured(
            environment: [:], config: none, baked: "https://real.authkit.app"),
                   "baked identity must NOT be misconfigured")
    }

    // ── Resource precedence ──────────────────────────────────────────────
    await test("Packet E: resource — env override wins") {
        let r = ProtectedResourceMetadataProvider.resolvedResource(
            port: 9700, environment: ["BRIDGE_PUBLIC_RESOURCE": "https://env/mcp"],
            config: { _ in "https://config/mcp" }, baked: "https://baked/mcp")
        try expect(r == "https://env/mcp", "env must win, got \(r)")
    }

    await test("Packet E: resource — config then baked when env absent") {
        let c = ProtectedResourceMetadataProvider.resolvedResource(
            port: 9700, environment: [:],
            config: { $0 == "publicResource" ? "https://config/mcp" : nil }, baked: "https://baked/mcp")
        try expect(c == "https://config/mcp", "config must win over baked, got \(c)")
        let b = ProtectedResourceMetadataProvider.resolvedResource(
            port: 9700, environment: [:], config: none, baked: "https://mcp.kup.solutions/mcp")
        try expect(b == "https://mcp.kup.solutions/mcp", "baked must supply, got \(b)")
    }

    await test("Packet E: resource — fail-closed loopback derivation when all layers empty") {
        let r = ProtectedResourceMetadataProvider.resolvedResource(
            port: 9700, environment: [:], config: none, baked: "")
        try expect(r == "http://127.0.0.1:9700/mcp", "must derive loopback, got \(r)")
    }
}
