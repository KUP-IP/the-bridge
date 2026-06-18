// ReadOnlyTierAuditTests.swift
// TheBridge · Tests
//
// FB-5 (read-only tool tiering + Always-Allow scope): tier-policy audit
// asserting that strictly read-only tools execute without a confirmation
// prompt. Any tool whose name matches a read-only pattern (_list, _get,
// _read, _search) MUST be registered at tier `.open` unless it appears in
// the explicit `deliberateExceptions` allowlist below.
//
// Evidence motivating this audit: `snippets_list` (self-described read-only)
// was previously tier `.request` and got a SecurityGate confirmation prompt
// on first call. Read-only list/get/read/search tools should be `.open`.
//
// If you add a new read-only tool, register it at tier `.open`. If you must
// keep one elevated, add it to `deliberateExceptions` WITH a justification —
// this audit is the tripwire that forces that decision to be explicit.
//
// Harness: standalone executable runner (no XCTest), matching the rest of
// TheBridgeTests. Entry point `runReadOnlyTierAuditTests()` is invoked
// from main.swift. The fully-registered router is built ONCE and shared
// across the checks (mirrors BridgeModuleRegistryTests; avoids repeated
// full-registry construction).

import TheBridgeLib
import MCP

func runReadOnlyTierAuditTests() async {
    print("\n🔓 Read-Only Tier Audit Tests (FB-5)")

    // Read-only name suffixes. A tool matching one of these strictly reads
    // state and should not require pre-execution confirmation.
    let readOnlySuffixes = ["_list", "_get", "_read", "_search"]

    // Deliberate exceptions: read-only-named tools intentionally kept above
    // tier `.open`. Each entry MUST carry a justification.
    let deliberateExceptions: Set<String> = [
        // Credential tools expose secret material — confirmation is intentional.
        "credential_read",
        "credential_list",
        // standing_orders_* (PKT-931) are operator-curated config. The packet
        // DoD mandates tier .notify for ALL FOUR tools (config must not change
        // silently). list/read are read-only-named but intentionally .notify,
        // mirroring the credential_read / credential_list precedent above.
        "standing_orders_list",
        "standing_orders_read",
    ]

    func matchesReadOnlyPattern(_ name: String) -> Bool {
        readOnlySuffixes.contains { name.hasSuffix($0) }
    }

    // Build the canonical module surface ONCE (same path production uses via
    // ServerManager; includeStripe:false keeps it network-free). Reused across
    // all checks below — the registry is deterministic.
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await BridgeModuleRegistry.registerStaticFeatureModules(
        on: router,
        registerSession: { r in await SessionModule.register(on: r, auditLog: log) }
    )
    let regs = await router.allRegistrations()
    let byName = Dictionary(regs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    // FB-5: no read-only-named tool may be registered above tier `.open`
    // unless it is in the explicit allowlist.
    await test("FB-5: read-only tools (_list/_get/_read/_search) are tier .open") {
        var offenders: [String] = []
        for reg in regs where matchesReadOnlyPattern(reg.name) {
            if deliberateExceptions.contains(reg.name) { continue }
            if reg.tier != .open {
                offenders.append("\(reg.name)=\(reg.tier.rawValue)")
            }
        }
        try expect(
            offenders.isEmpty,
            "Read-only tools must be tier .open (no confirmation prompt). " +
            "Mis-tiered: \(offenders.sorted().joined(separator: ", ")). " +
            "Downgrade to .open or add to deliberateExceptions with a reason."
        )
    }

    // FB-5 regression guard: the specific tool from the packet evidence.
    await test("FB-5: snippets_list is tier .open") {
        guard let reg = byName["snippets_list"] else {
            throw TestError.assertion("snippets_list not registered")
        }
        try expect(reg.tier == .open,
                   "snippets_list must be .open, got \(reg.tier.rawValue)")
    }

    // The other read-only snippets tools must also be .open (sibling check).
    await test("FB-5: snippets_get and snippets_search are tier .open") {
        for name in ["snippets_get", "snippets_search"] {
            guard let reg = byName[name] else {
                throw TestError.assertion("\(name) not registered")
            }
            try expect(reg.tier == .open, "\(name) must be .open, got \(reg.tier.rawValue)")
        }
    }

    // Guard the allowlist itself: every deliberate exception must still be
    // registered AND actually above .open — otherwise the entry is stale.
    await test("FB-5: deliberate exceptions are still registered and elevated") {
        for name in deliberateExceptions.sorted() {
            guard let reg = byName[name] else {
                throw TestError.assertion(
                    "allowlisted '\(name)' no longer registered — remove stale exception")
            }
            try expect(reg.tier != .open,
                       "'\(name)' is in deliberateExceptions but is .open — remove stale exception")
        }
    }
}
