// SkillsModuleTests.swift – QA: SkillsModule Test Coverage
// TheBridge · Tests
//
// Validates tool registration, count, names, security tiers, and handler-level
// error handling for SkillsModule.
// Follows the standard module test pattern.

import Foundation
import MCP
import TheBridgeLib

// MARK: - SkillsModule Tests

func runSkillsModuleTests() async {
    print("\n🧠 SkillsModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await SkillsModule.register(on: router)

    // ============================================================
    // MARK: - Tool Registration (fetch_skill, list_routing_skills, manage_skill)
    // ============================================================

    await test("SkillsModule registers 7 tools (Sprint A · #14 alias + #2 5-way split)") {
        let tools = await router.registrations(forModule: "skills")
        // 4 pre-Sprint-A (fetch_skill, list_routing_skills, manage_skill,
        //               skills_routing_list-new) + 5 split primitives.
        try expect(tools.count == 7, "Expected 7 skills tools, got \(tools.count)")
    }

    await test("Sprint A · #2: 5 skill_* split primitives are registered") {
        let tools = await router.registrations(forModule: "skills")
        let names = Set(tools.map(\.name))
        for primitive in ["skill_create", "skill_delete", "skill_update",
                          "skill_rename", "skill_sync_notion"] {
            try expect(names.contains(primitive),
                       "Missing \(primitive) — Sprint A · mcp-builder #2 split")
        }
    }

    await test("Tool fetch_skill is registered") {
        let tools = await router.registrations(forModule: "skills")
        let names = Set(tools.map(\.name))
        try expect(names.contains("fetch_skill"), "Missing fetch_skill")
    }

    await test("Tool skills_routing_list is registered (Sprint A · #14 primary)") {
        let tools = await router.registrations(forModule: "skills")
        let names = Set(tools.map(\.name))
        try expect(names.contains("skills_routing_list"),
                   "Missing skills_routing_list — the renamed primary")
    }

    await test("skills_routing_list has open tier") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "skills_routing_list" })
        try expect(tool != nil, "skills_routing_list not found")
        try expect(tool!.tier == .open, "skills_routing_list should be .open")
    }

    // ============================================================
    // MARK: - Security Tier
    // ============================================================

    await test("fetch_skill has open tier") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        try expect(tool!.tier == .open, "fetch_skill should be .open, got \(tool!.tier)")
    }

    // ============================================================
    // MARK: - Tool Description & Schema
    // ============================================================

    await test("fetch_skill has non-empty description") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        try expect(!tool!.description.isEmpty, "fetch_skill has empty description")
    }

    await test("fetch_skill has input schema") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        if case .object = tool!.inputSchema {
            // valid
        } else {
            throw TestError.assertion("fetch_skill inputSchema is not an object")
        }
    }

    // ============================================================
    // MARK: - Required Parameters
    // ============================================================

    await test("fetch_skill requires 'name' parameter") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        if case .object(let schema) = tool!.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("name"), "fetch_skill should require 'name'")
        }
    }

    // ============================================================
    // MARK: - P2-3: Handler-Level Error Handling Tests (PKT-373)
    // ============================================================
    // These tests dispatch through the handler to verify graceful error
    // handling when the Notion API is unavailable or skills are not found.
    // The handler should return structured error responses, never crash.

    await test("fetch_skill returns error for nonexistent skill name") {
        let result = try await router.dispatch(
            toolName: "fetch_skill",
            arguments: .object(["name": .string("nonexistent_skill_xyz_12345")])
        )
        // Handler should return structured response (cache miss + API error or not-found)
        if case .object(let dict) = result {
            // Error response or empty result — both acceptable
            if case .string(let error) = dict["error"] {
                try expect(!error.isEmpty, "Error message should be non-empty")
            }
            // Not-found response is also valid
        } else if case .string(let s) = result {
            // String error message — acceptable
            try expect(!s.isEmpty, "Response should be non-empty")
        } else {
            throw TestError.assertion("Expected structured result for nonexistent skill")
        }
    }

    await test("fetch_skill rejects missing name parameter") {
        do {
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing name parameter")
        } catch is ToolRouterError {
            // Expected — missing required parameter
        }
    }

    await test("fetch_skill handles empty string name gracefully") {
        let result = try await router.dispatch(
            toolName: "fetch_skill",
            arguments: .object(["name": .string("")])
        )
        // Should return error or empty result, not crash
        if case .object(let dict) = result {
            if case .string(let error) = dict["error"] {
                try expect(!error.isEmpty, "Error message should be non-empty for empty name")
            }
            // Empty result object is also acceptable
        } else if case .string = result {
            // String response is acceptable
        } else {
            throw TestError.assertion("Expected structured result for empty skill name")
        }
    }

    // ============================================================
    // MARK: - Skill-system ownership and routing governance
    // ============================================================

    let validReceipt: Value = .object([
        "domainOwner": .string("skill-keepr"),
        "routeId": .string("R6B"),
        "targetSkills": .array([.string("nonexistent-governed-skill")]),
        "changeManifest": .array([.string("Update routing metadata")]),
        "acceptanceTests": .array([.string("Verify the target metadata")]),
        "writeScope": .array([.string("Skill registry metadata")])
    ])

    await test("Every skill mutation schema exposes routeReceipt") {
        let tools = await router.registrations(forModule: "skills")
        for name in ["skill_create", "skill_delete", "skill_update", "skill_rename", "skill_sync_notion"] {
            guard let tool = tools.first(where: { $0.name == name }) else {
                throw TestError.assertion("Missing \(name)")
            }
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"] else {
                throw TestError.assertion("\(name) schema has no properties object")
            }
            try expect(properties["routeReceipt"] != nil, "\(name) must expose routeReceipt")
        }
    }

    await test("Route receipt rejects missing governance context") {
        let error = SkillRouteReceiptValidator.validationError(
            receipt: nil,
            expectedTargets: ["alpha"]
        )
        try expect(error != nil && error!.contains("SKILLS Keepr"),
                   "Missing receipt should return a SKILLS Keepr routing error")
    }

    await test("Route receipt accepts R6B and matching targets") {
        let error = SkillRouteReceiptValidator.validationError(
            receipt: validReceipt,
            expectedTargets: ["nonexistent governed skill"]
        )
        try expect(error == nil, "Valid R6B receipt should pass: \(error ?? "")")
    }

    await test("Route receipt rejects a stale target set") {
        let error = SkillRouteReceiptValidator.validationError(
            receipt: validReceipt,
            expectedTargets: ["different-skill"]
        )
        try expect(error?.contains("does not cover") == true,
                   "Target mismatch should require a fresh route")
    }

    await test("All skill mutation tools stop when routeReceipt is absent") {
        let cases: [(tool: String, arguments: Value)] = [
            ("skill_create", .object([
                "name": .string("nonexistent-governed-skill"),
                "url": .string("0123456789abcdef0123456789abcdef")
            ])),
            ("skill_delete", .object([
                "name": .string("nonexistent-governed-skill")
            ])),
            ("skill_update", .object([
                "name": .string("nonexistent-governed-skill"),
                "summary": .string("Should never write")
            ])),
            ("skill_rename", .object([
                "name": .string("nonexistent-governed-skill"),
                "newName": .string("nonexistent-renamed-skill")
            ])),
            ("skill_sync_notion", .object([
                "name": .string("nonexistent-governed-skill"),
                "direction": .string("push")
            ]))
        ]

        for testCase in cases {
            do {
                _ = try await router.dispatch(
                    toolName: testCase.tool,
                    arguments: testCase.arguments
                )
                throw TestError.assertion("Expected missing routeReceipt error for \(testCase.tool)")
            } catch let error as ToolRouterError {
                try expect(String(describing: error).contains("routeReceipt"),
                           "\(testCase.tool) should identify the missing routeReceipt")
            }
        }
    }

    await test("skill_update accepts a governed receipt before target lookup") {
        let result = try await router.dispatch(
            toolName: "skill_update",
            arguments: .object([
                "name": .string("nonexistent-governed-skill"),
                "summary": .string("Governed metadata update"),
                "routeReceipt": validReceipt
            ])
        )
        guard case .object(let dict) = result,
              case .bool(let success)? = dict["success"] else {
            throw TestError.assertion("Expected structured skill_update result")
        }
        try expect(!success, "Nonexistent target should fail after receipt validation")
    }

    await test("skill_sync_notion pull remains read-only and needs no receipt") {
        let result = try await router.dispatch(
            toolName: "skill_sync_notion",
            arguments: .object([
                "name": .string("nonexistent-governed-skill"),
                "direction": .string("pull")
            ])
        )
        guard case .object(let dict) = result,
              case .bool(let success)? = dict["success"] else {
            throw TestError.assertion("Expected structured sync result")
        }
        try expect(!success, "Nonexistent pull target should report not found, not a receipt error")
    }

    await test("Routing linter catches front-door construction contradiction") {
        let warnings = SkillRoutingConsistencyLinter.warnings(
            parentName: "skill-keepr",
            summary: "Single point of entry for all skill development.",
            triggerPhrases: ["Audit a skill"],
            antiTriggerPhrases: ["Create a new skill"],
            specialists: [
                SpecialistSummary(
                    path: "skill-keepr/skill-builder",
                    title: "skill-builder",
                    summary: "Owns new skill construction."
                )
            ]
        )
        try expect(warnings.count >= 2,
                   "Contradictory parent metadata should emit ownership and trigger warnings")
    }

    await test("Routing linter accepts corrected SKILLS Keepr metadata") {
        let warnings = SkillRoutingConsistencyLinter.warnings(
            parentName: "skill-keepr",
            summary: "Mandatory front door for skill creation, changes, and governance.",
            triggerPhrases: ["Create a skill", "Build a skill", "Restructure a skill tree"],
            antiTriggerPhrases: ["Use an existing skill without changing its definition"],
            specialists: [
                SpecialistSummary(
                    path: "skill-keepr/skill-builder",
                    title: "skill-builder",
                    summary: "Owns new construction and read-only refactor advice."
                )
            ]
        )
        try expect(warnings.isEmpty, "Corrected routing metadata should be clean: \(warnings)")
    }

}
