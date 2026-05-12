// WranglerModuleTests.swift — PKT-757 (v2.2 · 0.2.2)
// NotionBridge · Tests
//
// Covers WranglerModule: TOML parser edge cases, binding resolver (single,
// not-found, ambiguous, missing database_name), tool registration / tier,
// capability_missing envelope, and a gated integration test against the
// 605-good-dog repo when reachable.

import Foundation
import MCP
import NotionBridgeLib

func runWranglerModuleTests() async {
    print("\n🌀 WranglerModule Tests")

    // MARK: registration / shape

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await WranglerModule.register(on: router)

    await test("WranglerModule registers wrangler_d1_status under dev family") {
        let tools = await router.registrations(forModule: "dev")
        let names = Set(tools.map(\.name))
        try expect(names.contains("wrangler_d1_status"), "Missing wrangler_d1_status, got \(names)")
    }

    await test("wrangler_d1_status tier is open") {
        let tools = await router.registrations(forModule: "dev")
        guard let t = tools.first(where: { $0.name == "wrangler_d1_status" }) else {
            throw TestError.assertion("wrangler_d1_status not registered")
        }
        try expect(t.tier == .open, "Expected open tier, got \(t.tier.rawValue)")
    }

    // MARK: TOML parser

    await test("parseD1Bindings: empty TOML returns no entries") {
        let entries = WranglerModule.parseD1Bindings(toml: "", configPath: "/tmp/x.toml")
        try expect(entries.isEmpty, "Expected empty, got \(entries.count)")
    }

    await test("parseD1Bindings: TOML without [[d1_databases]] returns no entries") {
        let toml = """
        name = \"foo\"
        compatibility_date = \"2026-04-28\"

        [vars]
        ENVIRONMENT = \"local\"
        """
        let entries = WranglerModule.parseD1Bindings(toml: toml, configPath: "/tmp/x.toml")
        try expect(entries.isEmpty, "Expected empty, got \(entries.count)")
    }

    await test("parseD1Bindings: single [[d1_databases]] block") {
        let toml = """
        name = \"foo\"

        [[d1_databases]]
        binding = \"DB\"
        database_name = \"foo-local\"
        database_id = \"abc-123\"
        """
        let entries = WranglerModule.parseD1Bindings(toml: toml, configPath: "/tmp/x.toml")
        try expect(entries.count == 1, "Expected 1 entry, got \(entries.count)")
        try expect(entries[0].binding == "DB", "Wrong binding: \(entries[0].binding)")
        try expect(entries[0].databaseName == "foo-local", "Wrong name: \(String(describing: entries[0].databaseName))")
        try expect(entries[0].databaseId == "abc-123", "Wrong id: \(String(describing: entries[0].databaseId))")
        try expect(entries[0].envScope == nil, "Expected nil env scope")
    }

    await test("parseD1Bindings: multiple [[d1_databases]] blocks") {
        let toml = """
        [[d1_databases]]
        binding = \"DB\"
        database_name = \"foo\"

        [[d1_databases]]
        binding = \"CACHE\"
        database_name = \"cache\"
        """
        let entries = WranglerModule.parseD1Bindings(toml: toml, configPath: "/tmp/x.toml")
        try expect(entries.count == 2, "Expected 2 entries, got \(entries.count)")
        let bindings = Set(entries.map(\.binding))
        try expect(bindings == ["DB", "CACHE"], "Wrong bindings: \(bindings)")
    }

    await test("parseD1Bindings: env-scoped [[env.preview.d1_databases]]") {
        let toml = """
        [[d1_databases]]
        binding = \"DB\"
        database_name = \"local\"

        [[env.preview.d1_databases]]
        binding = \"DB\"
        database_name = \"preview\"
        """
        let entries = WranglerModule.parseD1Bindings(toml: toml, configPath: "/tmp/x.toml")
        try expect(entries.count == 2, "Expected 2 entries, got \(entries.count)")
        let topLevel = entries.first(where: { $0.envScope == nil })
        let preview = entries.first(where: { $0.envScope == "preview" })
        try expect(topLevel?.databaseName == "local", "Wrong top-level db")
        try expect(preview?.databaseName == "preview", "Wrong preview db")
    }

    await test("parseD1Bindings: missing database_name yields entry with nil name") {
        let toml = """
        [[d1_databases]]
        binding = \"DB\"
        """
        let entries = WranglerModule.parseD1Bindings(toml: toml, configPath: "/tmp/x.toml")
        try expect(entries.count == 1, "Expected 1 entry")
        try expect(entries[0].databaseName == nil, "Expected nil database_name")
    }

    await test("parseD1Bindings: comments are stripped, comments inside quoted strings preserved") {
        let toml = """
        # leading comment
        [[d1_databases]]
        binding = \"DB\" # inline comment
        database_name = \"foo#notacomment\"
        """
        let entries = WranglerModule.parseD1Bindings(toml: toml, configPath: "/tmp/x.toml")
        try expect(entries.count == 1, "Expected 1 entry")
        try expect(entries[0].binding == "DB", "Wrong binding: \(entries[0].binding)")
        try expect(entries[0].databaseName == "foo#notacomment", "Comment-in-quote not preserved: \(String(describing: entries[0].databaseName))")
    }

    // MARK: resolver

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("nb-pkt-757-resolver-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: tmpRoot.appendingPathComponent("workers"), withIntermediateDirectories: true)
    let rootToml = tmpRoot.appendingPathComponent("wrangler.toml")
    let workersToml = tmpRoot.appendingPathComponent("workers/wrangler.toml")

    await test("resolveBinding: single binding in workers/wrangler.toml resolves cleanly") {
        try? FileManager.default.removeItem(at: rootToml)
        try """
        [[d1_databases]]
        binding = \"DB\"
        database_name = \"foo-local\"
        database_id = \"id-1\"
        """.write(to: workersToml, atomically: true, encoding: .utf8)
        let entry = try WranglerModule.resolveBinding(
            binding: "DB",
            explicitConfigPath: nil,
            repoRoot: tmpRoot.path,
            envScope: nil
        )
        try expect(entry.databaseName == "foo-local", "Wrong db name")
        try expect(entry.configPath.hasSuffix("workers/wrangler.toml"), "Wrong config path")
    }

    await test("resolveBinding: ambiguous binding (defined in both files) throws bindingAmbiguous") {
        try """
        [[d1_databases]]
        binding = \"DB\"
        database_name = \"root-db\"
        """.write(to: rootToml, atomically: true, encoding: .utf8)
        try """
        [[d1_databases]]
        binding = \"DB\"
        database_name = \"workers-db\"
        """.write(to: workersToml, atomically: true, encoding: .utf8)
        do {
            _ = try WranglerModule.resolveBinding(
                binding: "DB",
                explicitConfigPath: nil,
                repoRoot: tmpRoot.path,
                envScope: nil
            )
            throw TestError.assertion("Expected bindingAmbiguous to throw")
        } catch WranglerModule.WranglerError.bindingAmbiguous(let b, let locs) {
            try expect(b == "DB", "Wrong binding in error")
            try expect(locs.count == 2, "Expected 2 locations, got \(locs.count)")
        } catch {
            throw TestError.assertion("Wrong error: \(error)")
        }
    }

    await test("resolveBinding: not found throws bindingNotFound") {
        try? FileManager.default.removeItem(at: rootToml)
        try """
        [[d1_databases]]
        binding = \"OTHER\"
        database_name = \"x\"
        """.write(to: workersToml, atomically: true, encoding: .utf8)
        do {
            _ = try WranglerModule.resolveBinding(
                binding: "DB",
                explicitConfigPath: nil,
                repoRoot: tmpRoot.path,
                envScope: nil
            )
            throw TestError.assertion("Expected bindingNotFound to throw")
        } catch WranglerModule.WranglerError.bindingNotFound {
            // ok
        } catch {
            throw TestError.assertion("Wrong error: \(error)")
        }
    }

    await test("resolveBinding: missing database_name throws databaseNameMissing") {
        try """
        [[d1_databases]]
        binding = \"DB\"
        """.write(to: workersToml, atomically: true, encoding: .utf8)
        do {
            _ = try WranglerModule.resolveBinding(
                binding: "DB",
                explicitConfigPath: nil,
                repoRoot: tmpRoot.path,
                envScope: nil
            )
            throw TestError.assertion("Expected databaseNameMissing to throw")
        } catch WranglerModule.WranglerError.databaseNameMissing {
            // ok
        } catch {
            throw TestError.assertion("Wrong error: \(error)")
        }
    }

    await test("resolveBinding: explicit configPath honors that path only") {
        try """
        [[d1_databases]]
        binding = \"DB\"
        database_name = \"explicit-db\"
        """.write(to: workersToml, atomically: true, encoding: .utf8)
        let entry = try WranglerModule.resolveBinding(
            binding: "DB",
            explicitConfigPath: workersToml.path,
            repoRoot: "/nonexistent",
            envScope: nil
        )
        try expect(entry.databaseName == "explicit-db", "Wrong db")
    }

    // Cleanup
    try? FileManager.default.removeItem(at: tmpRoot)

    // MARK: pending parse

    await test("parsePendingFromList: extracts numbered .sql filenames from box-drawn list") {
        let stdout = """
        ┌─────────────────────────────┐
        │ name                        │
        ├─────────────────────────────┤
        │ 0001_init.sql               │
        │ 0002_add_users.sql          │
        └─────────────────────────────┘
        """
        let names = WranglerModule.parsePendingFromList(stdout: stdout)
        try expect(names.contains("0001_init.sql"), "Missing 0001_init.sql in \(names)")
        try expect(names.contains("0002_add_users.sql"), "Missing 0002_add_users.sql in \(names)")
    }

    await test("parsePendingFromList: empty / 'no migrations' output returns empty") {
        let stdout = "No migrations to apply.\n"
        let names = WranglerModule.parsePendingFromList(stdout: stdout)
        try expect(names.isEmpty, "Expected empty, got \(names)")
    }

    // MARK: applied JSON parse

    await test("extractAppliedRows: parses --json envelope shape") {
        let json: [[String: Any]] = [[
            "results": [
                ["name": "0001_init.sql", "applied_at": "2026-05-01T00:00:00Z"],
                ["name": "0002_add_users.sql", "applied_at": "2026-05-02T00:00:00Z"],
            ],
            "success": true,
        ]]
        let rows = WranglerModule.extractAppliedRows(from: json)
        try expect(rows.count == 2, "Expected 2 rows, got \(rows.count)")
    }

    await test("extractAppliedRows: object envelope shape works too") {
        let json: [String: Any] = [
            "results": [
                ["name": "0001_init.sql", "applied_at": "2026-05-01T00:00:00Z"]
            ]
        ]
        let rows = WranglerModule.extractAppliedRows(from: json)
        try expect(rows.count == 1, "Expected 1 row")
    }

    // MARK: tool dispatch — capability_missing envelope shape

    await test("wrangler_d1_status: returns binding_not_found envelope when no toml exists") {
        let result = try await router.dispatch(
            toolName: "wrangler_d1_status",
            arguments: .object([
                "binding": .string("DB"),
                "repoRoot": .string("/tmp/nb-pkt-757-no-such-dir-\(UUID().uuidString)"),
            ])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("Expected object result")
        }
        guard case .bool(let ok) = dict["ok"] else {
            throw TestError.assertion("Missing ok")
        }
        try expect(!ok, "Expected ok=false")
        guard case .string(let err) = dict["error"] else {
            throw TestError.assertion("Missing error")
        }
        // Could be capability_missing (if wrangler not on PATH on test host) or binding_not_found.
        try expect(err == "binding_not_found" || err == "capability_missing",
                   "Unexpected error: \(err)")
    }

    // MARK: integration — gated on 605-good-dog presence

    let goodDogToml = "/Users/keepup/Developer/605-good-dog/workers/wrangler.toml"
    if FileManager.default.fileExists(atPath: goodDogToml) {
        await test("resolveBinding: 605-good-dog DB binding resolves to local DB") {
            let entry = try WranglerModule.resolveBinding(
                binding: "DB",
                explicitConfigPath: nil,
                repoRoot: "/Users/keepup/Developer/605-good-dog",
                envScope: nil
            )
            try expect(entry.binding == "DB", "Wrong binding")
            try expect(entry.databaseName == "605-good-dog-local",
                       "Wrong db name: \(String(describing: entry.databaseName))")
            try expect(entry.configPath.hasSuffix("workers/wrangler.toml"),
                       "Resolved wrong config path: \(entry.configPath)")
        }

        await test("resolveBinding: 605-good-dog preview env-scoped DB resolves") {
            let entry = try WranglerModule.resolveBinding(
                binding: "DB",
                explicitConfigPath: nil,
                repoRoot: "/Users/keepup/Developer/605-good-dog",
                envScope: "preview"
            )
            try expect(entry.databaseName == "605-good-dog-preview",
                       "Wrong preview db: \(String(describing: entry.databaseName))")
        }
    } else {
        print("  ⏭  605-good-dog integration tests skipped (repo not at \(goodDogToml))")
    }
}
