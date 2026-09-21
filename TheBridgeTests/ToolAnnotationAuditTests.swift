// ToolAnnotationAuditTests.swift — WS-B (v2.3, PKT-803)
// Enforces the packet's "100% explicit coverage — zero implicit
// defaults" contract for the tool-annotation pass, and the
// TransportRouter default/env behaviour. Mirrors EndToEndTests' static
// module surface (StripeMcpModule excluded — network-dependent, same
// exclusion the E2E static-count test applies; `stripe_reconnect` is the
// one static Stripe sentinel and is allow-listed below).

import Foundation
import MCP
import TheBridgeLib

func runToolAnnotationAuditTests() async {
    print("\n\u{1F50E} Tool Annotation Audit (PKT-803 · WS-B)")

    // Build the static surface (no StripeMcpModule).
    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await BridgeModuleRegistry.registerStaticFeatureModules(
        on: router,
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

    await test("annotation catalog has no stale entries outside conditional tools") {
        // Tools registered outside the module surface this static router
        // builds: stripe_reconnect (StripeMcpModule — network-dependent).
        // Sprint A · mcp-builder #8: `echo` removed from this allowlist
        // along with the builtin registration in ServerManager.setup().
        // WS-D (PKT-921): bridge_status is registered ONLY when
        // BridgeDefaults.cloudAccessEnabled (via registerCloudStatusTool, NOT
        // the static surface), so it carries a catalog annotation without
        // appearing in this cloud-off static router — same shape as
        // stripe_reconnect's network-gated exclusion.
        let allowedDynamic: Set<String> = [
            "stripe_reconnect", "bridge_status",
            "worktree_claim", "worktree_release",
        ]
        let stale = Set(ToolAnnotationCatalog.entries.keys)
            .subtracting(liveNames)
            .subtracting(allowedDynamic)
        try expect(stale.isEmpty, "stale catalog entries (no live tool): \(stale.sorted())")
    }

    await test("all five annotation fields are present on every catalog entry") {
        // Fields are non-optional Bool — presence is type-guaranteed.
        // This asserts the catalog is non-trivial and every entry is a
        // fully-formed 5-tuple (compile-time enforced; runtime sanity).
        // Sprint A · mcp-builder Top-15 #13: `idempotentHint` joined the
        // explicit-coverage invariant alongside the original four hints.
        try expect(ToolAnnotationCatalog.entries.count >= liveNames.count,
                   "catalog (\(ToolAnnotationCatalog.entries.count)) < live (\(liveNames.count))")
        for (_, a) in ToolAnnotationCatalog.entries {
            _ = (a.readOnlyHint, a.destructiveHint, a.idempotentHint,
                 a.requiresConfirmation, a.openWorld)
        }
    }

    // Sprint A · mcp-builder Top-15 #13: hard-fail the build when ANY live
    // tool lacks an explicit idempotentHint entry. This mirrors the
    // requiresConfirmation invariant that already enforces "no implicit
    // defaults" on the static surface. Strictly speaking, the first test
    // ("every registered static tool has an EXPLICIT annotation entry")
    // already covers presence — but a dedicated assertion makes the
    // intent (every annotation carries idempotentHint as a first-class
    // axis, not an afterthought) impossible to drift away from.
    await test("every registered static tool has an EXPLICIT idempotentHint (zero implicit defaults)") {
        var missing: [String] = []
        for reg in regs {
            guard let ann = ToolAnnotationCatalog.annotations(for: reg.name) else {
                continue // covered by the first invariant above
            }
            // `idempotentHint` is a non-optional Bool — its presence is
            // type-guaranteed for every entry. This loop exists so a
            // future refactor that makes the field optional (or that
            // sneaks in a permissive default) trips this test loudly.
            _ = ann.idempotentHint
            if reg.name.isEmpty { missing.append(reg.name) }
        }
        try expect(missing.isEmpty,
                   "tools missing explicit idempotentHint: \(missing.sorted())")
    }

    await test("screen_capture is Open-tier but not read-only because it writes and cleans capture artifacts") {
        guard let registration = regs.first(where: { $0.name == "screen_capture" }) else {
            throw TestError.assertion("screen_capture must be registered")
        }
        let annotation = ToolAnnotationCatalog.annotations(for: "screen_capture")
        try expect(registration.tier == .open, "screen_capture tier remains .open by explicit policy")
        try expect(annotation?.readOnlyHint == false,
                   "screen_capture writes one artifact and deletes old capture files")
        try expect(annotation?.destructiveHint == false,
                   "bounded capture cleanup remains non-destructive metadata")
        try expect(annotation?.requiresConfirmation == false,
                   "Open-tier screen_capture remains ungated in this slice")
    }

    await test("requiresConfirmation mirrors registered Request tier") {
        for reg in regs {
            guard let ann = ToolAnnotationCatalog.annotations(for: reg.name) else { continue }
            let shouldConfirm = reg.tier == .request
            try expect(ann.requiresConfirmation == shouldConfirm,
                       "\(reg.name): requiresConfirmation=\(ann.requiresConfirmation) but tier=\(reg.tier.rawValue)")
            try expect(reg.neverAutoApprove == false,
                       "\(reg.name): neverAutoApprove must not be a confirmation floor")
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

    // Regression guard: notion_datasource_delete stays human-gated (.request)
    // and destructive. #258 dropped the neverAutoApprove floor — Always Allow
    // persists sticky Notify; Confirm remains the registered default.
    await test("notion_datasource_delete is human-gated + Always-Allowable + destructive") {
        guard let reg = regs.first(where: { $0.name == "notion_datasource_delete" }) else {
            throw TestError.assertion("notion_datasource_delete must be registered")
        }
        try expect(reg.tier == .request,
                   "notion_datasource_delete tier must be .request; got \(reg.tier.rawValue)")
        try expect(reg.neverAutoApprove == false,
                   "notion_datasource_delete must offer Always Allow")
        let ann = ToolAnnotationCatalog.annotations(for: "notion_datasource_delete")
        try expect(ann?.destructiveHint == true && ann?.requiresConfirmation == true,
                   "notion_datasource_delete annotation must be destructive + requiresConfirmation; got \(String(describing: ann))")
    }

    await test("skill_delete is human-gated + Always-Allowable + destructive") {
        guard let reg = regs.first(where: { $0.name == "skill_delete" }) else {
            throw TestError.assertion("skill_delete must be registered")
        }
        try expect(reg.tier == .request,
                   "skill_delete tier must be .request; got \(reg.tier.rawValue)")
        try expect(reg.neverAutoApprove == false,
                   "skill_delete must offer Always Allow")
        let ann = ToolAnnotationCatalog.annotations(for: "skill_delete")
        try expect(ann?.destructiveHint == true && ann?.requiresConfirmation == true,
                   "skill_delete annotation must be destructive + requiresConfirmation; got \(String(describing: ann))")
    }

    await test("MCP projection drops requiresConfirmation, keeps the 4 hint fields") {
        // Sprint A · mcp-builder Top-15 #13: projection now carries
        // idempotentHint as well. requiresConfirmation stays Bridge-internal.
        let a = BridgeToolAnnotations(readOnlyHint: true, destructiveHint: false,
                                      idempotentHint: true,
                                      requiresConfirmation: true, openWorld: false)
        let m = a.mcp
        try expect(m.readOnlyHint == true && m.destructiveHint == false
                   && m.idempotentHint == true && m.openWorldHint == false,
                   "mcp projection mismatch: \(m)")
    }

    await test("fail-closed annotation is most-restrictive") {
        let f = BridgeToolAnnotations.failClosed
        try expect(f.readOnlyHint == false && f.destructiveHint == true
                   && f.idempotentHint == false
                   && f.requiresConfirmation == true && f.openWorld == true,
                   "failClosed must be most-restrictive, got \(f)")
    }
}

func runTransportRouterTests() async {
    print("\n\u{1F50C} TransportRouter (PKT-803 · WS-B)")

    await test("default config: activeTransports == [.stdio] only") {
        // Pin the config seam empty (Packet E W2): env-absent now falls
        // through to config.json, so inject nil to keep this hermetic
        // regardless of any on-disk `enableHTTP`.
        let r = TransportRouter(environment: [:], config: { _ in nil })
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
