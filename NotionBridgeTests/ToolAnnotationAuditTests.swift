// ToolAnnotationAuditTests.swift — WS-B (v2.3, PKT-803)
// Enforces the packet's "100% explicit coverage — zero implicit
// defaults" contract for the tool-annotation pass, and the
// TransportRouter default/env behaviour. Mirrors EndToEndTests' static
// module surface (StripeMcpModule excluded — network-dependent, same
// exclusion the E2E static-count test applies; `stripe_reconnect` is the
// one static Stripe sentinel and is allow-listed below).

import Foundation
import MCP
import NotionBridgeLib

func runToolAnnotationAuditTests() async {
    print("\n\u{1F50E} Tool Annotation Audit (PKT-803 · WS-B)")

    // Build the static surface (no StripeMcpModule).
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await BridgeModuleRegistry.registerStaticFeatureModules(
        on: router,
        includeStripe: false,
        registerSession: { sessionRouter in
            await SessionModule.register(on: sessionRouter, auditLog: log)
        }
    )

    let regs = await router.allRegistrations()
    let liveNames = Set(regs.map(\.name))

    await test("every registered static tool has an EXPLICIT annotation entry (zero implicit defaults)") {
        let missing = liveNames.filter { ToolAnnotationCatalog.annotations(for: $0) == nil }
        try expect(missing.isEmpty,
                   "tools missing explicit annotations: \(missing.sorted())")
        try expect(!regs.isEmpty, "router registered no tools")
    }

    await test("annotation catalog has no stale entries (catalog ⊆ live ∪ {stripe_reconnect, echo})") {
        // Tools registered outside the module surface this static router
        // builds: stripe_reconnect (StripeMcpModule — network-dependent)
        // and echo (builtin, registered inline by ServerManager.setup()).
        // Both are real production tools and stay in the catalog.
        let allowedDynamic: Set<String> = ["stripe_reconnect", "echo"]
        let stale = Set(ToolAnnotationCatalog.entries.keys)
            .subtracting(liveNames)
            .subtracting(allowedDynamic)
        try expect(stale.isEmpty, "stale catalog entries (no live tool): \(stale.sorted())")
    }

    await test("all four annotation fields are present on every catalog entry") {
        // Fields are non-optional Bool — presence is type-guaranteed.
        // This asserts the catalog is non-trivial and every entry is a
        // fully-formed 4-tuple (compile-time enforced; runtime sanity).
        try expect(ToolAnnotationCatalog.entries.count >= liveNames.count,
                   "catalog (\(ToolAnnotationCatalog.entries.count)) < live (\(liveNames.count))")
        for (_, a) in ToolAnnotationCatalog.entries {
            _ = (a.readOnlyHint, a.destructiveHint, a.requiresConfirmation, a.openWorld)
        }
    }

    await test("requiresConfirmation mirrors the Bridge security model (request/neverAutoApprove)") {
        for reg in regs {
            guard let ann = ToolAnnotationCatalog.annotations(for: reg.name) else { continue }
            let shouldConfirm = reg.tier == .request || reg.neverAutoApprove
            try expect(ann.requiresConfirmation == shouldConfirm,
                       "\(reg.name): requiresConfirmation=\(ann.requiresConfirmation) but tier=\(reg.tier.rawValue) nap=\(reg.neverAutoApprove)")
        }
    }

    await test("destructive sample is annotated destructive + readOnly sample is read-only") {
        let del = ToolAnnotationCatalog.annotations(for: "snippets_delete")
        try expect(del?.destructiveHint == true && del?.requiresConfirmation == true,
                   "snippets_delete must be destructive + confirmed")
        let sh = ToolAnnotationCatalog.annotations(for: "shell_exec")
        try expect(sh?.destructiveHint == true && sh?.readOnlyHint == false,
                   "shell_exec must be destructive, not read-only")
        let rd = ToolAnnotationCatalog.annotations(for: "file_read")
        try expect(rd?.readOnlyHint == true && rd?.destructiveHint == false,
                   "file_read must be read-only, non-destructive")
    }

    // Regression guard for the 2026-05-19 security remediation (v3-hub
    // Decision row 29): notion_datasource_delete trashes an ENTIRE data
    // source. It must stay human-gated (.request) AND non-auto-approvable
    // (neverAutoApprove — wins over a user tier override), with the
    // catalog accurately mirroring that as destructive + requires
    // confirmation. The mirror-invariant test above only checks
    // annotation == (tier==.request||nap); this pins the INTENDED posture
    // so a future edit that drops neverAutoApprove (and flips the
    // annotation to keep the mirror green) is still caught.
    await test("notion_datasource_delete is human-gated + non-auto-approvable + destructive (sec remediation)") {
        guard let reg = regs.first(where: { $0.name == "notion_datasource_delete" }) else {
            throw TestError.assertion("notion_datasource_delete must be registered")
        }
        try expect(reg.tier == .request,
                   "notion_datasource_delete tier must be .request; got \(reg.tier.rawValue)")
        try expect(reg.neverAutoApprove == true,
                   "notion_datasource_delete must be neverAutoApprove (non-downgradable destructive delete)")
        let ann = ToolAnnotationCatalog.annotations(for: "notion_datasource_delete")
        try expect(ann?.destructiveHint == true && ann?.requiresConfirmation == true,
                   "notion_datasource_delete annotation must be destructive + requiresConfirmation; got \(String(describing: ann))")
    }

    await test("MCP projection drops requiresConfirmation, keeps the 3 hint fields") {
        let a = BridgeToolAnnotations(readOnlyHint: true, destructiveHint: false,
                                      requiresConfirmation: true, openWorld: false)
        let m = a.mcp
        try expect(m.readOnlyHint == true && m.destructiveHint == false && m.openWorldHint == false,
                   "mcp projection mismatch: \(m)")
    }

    await test("fail-closed annotation is most-restrictive") {
        let f = BridgeToolAnnotations.failClosed
        try expect(f.readOnlyHint == false && f.destructiveHint == true
                   && f.requiresConfirmation == true && f.openWorld == true,
                   "failClosed must be most-restrictive, got \(f)")
    }
}

func runTransportRouterTests() async {
    print("\n\u{1F50C} TransportRouter (PKT-803 · WS-B)")

    await test("default config: activeTransports == [.stdio] only") {
        let r = TransportRouter(environment: [:])
        try expect(r.activeTransports == [.stdio], "got \(r.activeTransports)")
        try expect(r.isActive(.stdio) && !r.isActive(.streamableHTTP),
                   "stdio active, http inactive by default")
    }

    await test("BRIDGE_ENABLE_HTTP=1 additively enables streamableHTTP (stdio still first)") {
        let r = TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "1"])
        try expect(r.activeTransports == [.stdio, .streamableHTTP], "got \(r.activeTransports)")
        try expect(r.isActive(.stdio) && r.isActive(.streamableHTTP),
                   "both transports active when enabled")
    }

    await test("BRIDGE_ENABLE_HTTP with non-\"1\" value stays stdio-only") {
        try expect(TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "0"]).activeTransports == [.stdio])
        try expect(TransportRouter(environment: ["BRIDGE_ENABLE_HTTP": "true"]).activeTransports == [.stdio])
    }

    await test("BridgeTransport raw values are stable") {
        try expect(BridgeTransport.stdio.rawValue == "stdio", "stdio raw drift")
        try expect(BridgeTransport.streamableHTTP.rawValue == "streamableHTTP", "http raw drift")
        try expect(BridgeTransport.allCases.count == 2, "expected 2 transports")
    }
}
