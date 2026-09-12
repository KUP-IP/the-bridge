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

    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await SkillsModule.register(on: router)

    // ============================================================
    // MARK: - Tool Registration (fetch_skill, list_routing_skills, manage_skill)
    // ============================================================

    await test("SkillsModule registers 12 tools including Runtime Exposure controls") {
        let tools = await router.registrations(forModule: "skills")
        try expect(tools.count == 12, "Expected 12 skills tools, got \(tools.count)")
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

    await test("Runtime Exposure control primitives are registered with bounded tiers") {
        let tools = await router.registrations(forModule: "skills")
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        try expect(byName["skills_exposure_status"]?.tier == .open,
                   "skills_exposure_status must be open/read-only")
        try expect(byName["skills_exposure_reconcile"]?.tier == .notify,
                   "skills_exposure_reconcile must be notify")
        try expect(byName["skills_exposure_denylist"]?.tier == .notify,
                   "skills_exposure_denylist must be notify")
        try expect(byName["skills_exposure_purge_orphans"]?.tier == .notify,
                   "skills_exposure_purge_orphans must be notify")
    }

    await test("Runtime Exposure status is available before first publication") {
        let result = try await router.dispatch(
            toolName: "skills_exposure_status",
            arguments: .object([:])
        )
        guard case .object(let fields) = result,
              case .bool = fields["active"],
              case .int = fields["enabledBaselineCount"],
              fields["latestReceipt"] != nil else {
            throw TestError.assertion("Expected structured Runtime Exposure status")
        }
    }

    await test("Runtime Exposure publish stops before network work when routeReceipt is absent") {
        do {
            _ = try await router.dispatch(
                toolName: "skills_exposure_reconcile",
                arguments: .object(["mode": .string("publish")])
            )
            throw TestError.assertion("Expected missing routeReceipt error for publication")
        } catch let error as ToolRouterError {
            try expect(String(describing: error).contains("routeReceipt"),
                       "Publication should identify the missing routeReceipt")
        }
    }

    await test("Runtime Exposure denylist mutation stops when routeReceipt is absent") {
        do {
            _ = try await router.dispatch(
                toolName: "skills_exposure_denylist",
                arguments: .object([
                    "action": .string("add"),
                    "name": .string("alpha"),
                    "pageId": .string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                ])
            )
            throw TestError.assertion("Expected missing routeReceipt error for denylist mutation")
        } catch let error as ToolRouterError {
            try expect(String(describing: error).contains("routeReceipt"),
                       "Denylist mutation should identify the missing routeReceipt")
        }
    }

    await test("Runtime Exposure orphan purge stops when routeReceipt is absent") {
        do {
            _ = try await router.dispatch(
                toolName: "skills_exposure_purge_orphans",
                arguments: .object([
                    "pageIds": .array([.string("e7dddd02-c340-4515-80eb-f6a6947d3313")]),
                    "names": .array([.string("block-planning")])
                ])
            )
            throw TestError.assertion("Expected missing routeReceipt error for orphan purge")
        } catch let error as ToolRouterError {
            try expect(String(describing: error).contains("routeReceipt"),
                       "Orphan purge should identify the missing routeReceipt")
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

    await test("Tool skill_materialize_file is registered at open tier") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "skill_materialize_file" })
        try expect(tool != nil, "Missing skill_materialize_file")
        try expect(tool!.tier == .open, "skill_materialize_file should be .open, got \(tool!.tier)")
        guard case .object(let schema) = tool!.inputSchema,
              case .object(let props)? = schema["properties"] else {
            throw TestError.assertion("skill_materialize_file schema missing properties")
        }
        try expect(props["id"] != nil && props["name"] != nil, "addresses a skill like fetch_skill")
        try expect(props["fileName"] != nil && props["notionFileId"] != nil,
                   "selects a catalog entry by name or Notion file id")
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

    await test("fetch_skill accepts UUID-first or name addressing") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        if case .object(let schema) = tool!.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.isEmpty, "schema-level required list should allow id or name")
            guard case .object(let props)? = schema["properties"] else {
                throw TestError.assertion("fetch_skill schema missing properties")
            }
            try expect(props["id"] != nil, "fetch_skill should expose stable UUID 'id'")
            try expect(props["name"] != nil, "fetch_skill should preserve human/routing 'name'")
        }
    }

    // ============================================================
    // MARK: - PKT: fields Param on fetch_skill (result-projection)
    // ============================================================

    await test("fetch_skill schema declares an array-typed 'fields' param") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        guard case .object(let schema) = tool!.inputSchema,
              case .object(let props)? = schema["properties"],
              case .object(let fieldsSchema)? = props["fields"] else {
            throw TestError.assertion("fetch_skill schema missing a 'fields' property")
        }
        try expect(fieldsSchema["type"] == .string("array"), "fields must be schema-typed as an array")
        // 'fields' must NOT be in the required list — it's opt-in.
        if case .array(let required)? = schema["required"] {
            let names = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(!names.contains("fields"), "fields must be optional, not required")
        }
    }

    await test("fetch_skill: malformed 'fields' (wrong type) hard-errors via invalidArguments before any Notion work") {
        do {
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("nonexistent_skill_xyz"), "fields": .string("content")])
            )
            throw TestError.assertion("expected invalidArguments for malformed fields")
        } catch let e as ToolRouterError {
            if case .invalidArguments(let tool, _) = e {
                try expect(tool == "fetch_skill", "error should name fetch_skill")
            } else {
                throw TestError.assertion("wrong error case: \(e)")
            }
        }
    }

    await test("fetch_skill: fields array containing a non-string element hard-errors") {
        do {
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("nonexistent_skill_xyz"), "fields": .array([.string("content"), .int(1)])])
            )
            throw TestError.assertion("expected invalidArguments for non-string fields element")
        } catch is ToolRouterError {
            // expected
        }
    }

    // The mechanism-level FieldsFilter unit tests (FieldsFilterTests.swift)
    // cover project() exhaustively. Here we prove fetch_skill's OWN envelope
    // shape (as produced by the exact production builder,
    // buildSkillResultForTesting — zero network) round-trips through the
    // shared filter correctly, including fetch_skill's specific key
    // vocabulary (name/title/url/content/summary/triggerPhrases/
    // antiTriggerPhrases/properties) and its properties.X dotted-path
    // sub-selection.

    await test("fields (fetch_skill envelope): projects down to just 'content'") {
        let data = try! JSONSerialization.data(withJSONObject: ["markdown": "# Hello\n\nBody text."])
        let md = String(data: data, encoding: .utf8)!
        let envelope = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://n/demo",
            markdownJSONOrText: md, summary: "sum", triggerPhrases: ["t1"], antiTriggerPhrases: ["a1"]
        ) { _ in nil }
        let projected = FieldsFilter.project(envelope, fields: ["content"], includeIdentity: false)
        guard case .object(let dict) = projected else { throw TestError.assertion("expected object") }
        try expect(dict.count == 1, "expected exactly 1 key, got \(dict.keys.sorted())")
        guard case .string(let content)? = dict["content"] else { throw TestError.assertion("content missing") }
        try expect(content.contains("Hello"), "content value preserved")
    }

    await test("fields (fetch_skill envelope): properties.X sub-selects one property from fetch_skill's own properties map") {
        let data = try! JSONSerialization.data(withJSONObject: ["markdown": "body"])
        let md = String(data: data, encoding: .utf8)!
        let pageProps: [String: Any] = [
            "Status": ["type": "status", "status": ["name": "Stable", "id": "s1"]],
            "Domain": ["type": "select", "select": ["name": "infra", "id": "d1"]],
        ]
        let envelope = await SkillsModule.buildSkillResultForTesting(
            name: "demo2", title: "Demo2", url: "https://n/demo2",
            markdownJSONOrText: md, pageProperties: pageProps
        ) { _ in nil }
        let projected = FieldsFilter.project(envelope, fields: ["properties.status"], includeIdentity: false)
        guard case .object(let dict) = projected,
              case .object(let props)? = dict["properties"] else {
            throw TestError.assertion("expected projected properties object")
        }
        try expect(props.count == 1, "expected exactly 1 sub-selected property, got \(props.count)")
        try expect(props["Status"] == .string("Stable"), "got \(props)")
    }

    await test("fields (fetch_skill envelope): omitted fields → byte-identical envelope") {
        let data = try! JSONSerialization.data(withJSONObject: ["markdown": "unchanged body"])
        let md = String(data: data, encoding: .utf8)!
        let envelope = await SkillsModule.buildSkillResultForTesting(
            name: "demo3", title: "Demo3", url: "https://n/demo3",
            markdownJSONOrText: md, summary: "s", triggerPhrases: ["t"], antiTriggerPhrases: ["a"]
        ) { _ in nil }
        let untouched = FieldsFilter.project(envelope, fields: nil)
        try expect(untouched == envelope, "omitted fields must be a byte-identical identity projection")
        let untouchedEmpty = FieldsFilter.project(envelope, fields: [])
        try expect(untouchedEmpty == envelope, "fields:[] must also be byte-identical")
    }

    await test("fields (fetch_skill envelope): unknown key silently absent, never an error") {
        let data = try! JSONSerialization.data(withJSONObject: ["markdown": "body"])
        let md = String(data: data, encoding: .utf8)!
        let envelope = await SkillsModule.buildSkillResultForTesting(
            name: "demo4", title: "Demo4", url: "https://n/demo4", markdownJSONOrText: md
        ) { _ in nil }
        let projected = FieldsFilter.project(envelope, fields: ["ghostKey", "title"])
        guard case .object(let dict) = projected else { throw TestError.assertion("expected object") }
        // title requested; id/entity re-attached only if present on skill envelope.
        try expect(dict["title"] != nil, "title must survive")
        try expect(dict["ghostKey"] == nil, "unknown key must not survive")
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

    await test("fetch_skill rejects requests missing both id and name") {
        do {
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error when id and name are both missing")
        } catch is ToolRouterError {
            // Expected — missing required parameter
        }
    }

    await test("fetch_skill rejects an empty name when no id is present") {
        do {
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("")])
            )
            throw TestError.assertion("Expected invalidArguments for an empty identity")
        } catch is ToolRouterError {
            // expected
        }
    }

    await test("fetch_skill rejects malformed UUID before name fallback") {
        do {
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["id": .string("not-a-uuid"), "name": .string("anything")])
            )
            throw TestError.assertion("Expected invalidArguments for malformed id")
        } catch is ToolRouterError {
            // expected
        }
    }

    await test("fetch_skill rejects a 32-character non-hex id") {
        do {
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["id": .string(String(repeating: "g", count: 32))])
            )
            throw TestError.assertion("Expected invalidArguments for non-hex id")
        } catch is ToolRouterError {
            // expected
        }
    }

    await test("fetch_skill doctrine envelope exposes UUID plus Notion identity") {
        let data = try! JSONSerialization.data(withJSONObject: ["markdown": "# Body"])
        let md = String(data: data, encoding: .utf8)!
        let pageProps: [String: Any] = [
            "Slug": ["type": "rich_text", "rich_text": [["plain_text": "demo-skill"]]],
            "Version": ["type": "rich_text", "rich_text": [["plain_text": "2.0.0"]]],
            "Status": ["type": "status", "status": ["name": "Testing"]],
            "Maturity": ["type": "select", "select": ["name": "Stable"]]
        ]
        let envelope = await SkillsModule.buildSkillResultForTesting(
            name: "demo-skill", title: "Demo", url: "https://n/demo",
            markdownJSONOrText: md,
            pageId: "11111111222233334444555555555555",
            pageProperties: pageProps
        ) { _ in nil }
        guard case .object(let dict) = envelope else {
            throw TestError.assertion("expected doctrine envelope")
        }
        try expect(dict["uuid"] == .string("11111111-2222-3333-4444-555555555555"), "uuid missing")
        try expect(dict["slug"] == .string("demo-skill"), "slug missing")
        try expect(dict["version"] == .string("2.0.0"), "version missing")
        try expect(dict["status"] == .string("Testing"), "status missing")
        try expect(dict["maturity"] == .string("Stable"), "maturity missing")
    }

    await test("fetch_skill preserves resolved authority through UUID projection and fuzzy name lookup") {
        let defaultsKey = BridgeDefaults.skills
        let previousSkills = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let previousSkills {
                UserDefaults.standard.set(previousSkills, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let knownAuthorities = Set(
            ToolSkillBindingRegistry.bindings.flatMap { $0.governingSkills.map(\.slug) }
        )
        let activeGeneration = await SkillRuntimeGenerationStore.shared.activeGeneration()
        let publishedAuthority = activeGeneration?.entries.first(where: {
            knownAuthorities.contains(ToolSkillBindingRegistry.normalizeAuthoritySlug($0.slug))
        })
        if activeGeneration != nil, publishedAuthority == nil {
            throw TestError.assertion("active skill generation has no receipt-governing authority fixture")
        }
        let pageID = publishedAuthority?.notionPageUUID ?? "14614614614614614614614614614614"
        let authority = publishedAuthority.map {
            ToolSkillBindingRegistry.normalizeAuthoritySlug($0.slug)
        } ?? "people-keepr"
        let config: [[String: Any]] = [[
            "name": authority,
            "notionPageId": pageID,
            "enabled": true,
            "visibility": "routing"
        ]]
        UserDefaults.standard.set(
            try JSONSerialization.data(withJSONObject: config),
            forKey: defaultsKey
        )
        let cached = CachedSkillBody(
            pageId: pageID,
            slug: authority,
            version: "1.0.0",
            status: "Testing",
            maturity: "Stable",
            markdown: "# PEOPLE Keepr\nDoctrine fixture.",
            title: authority,
            url: "https://notion.example/\(authority)",
            properties: .object([
                "Slug": .string(authority),
                "Version": .string("1.0.0"),
                "Status": .string("Testing"),
                "Maturity": .string("Stable")
            ]),
            lastEditedTime: "2026-08-14T00:00:00.000Z",
            writtenAt: Date(),
            ttlHours: 24,
            callCount: 1
        )
        let previousBody = await SkillBodyCacheStore.shared.read(pageId: pageID)
        try await SkillBodyCacheStore.shared.write(cached)

        func restoreBodyCache() async {
            if let previousBody {
                try? await SkillBodyCacheStore.shared.write(previousBody)
            } else {
                await SkillBodyCacheStore.shared.evict(pageId: pageID)
            }
        }

        do {
            let context = ToolDispatchContext(
                transportSessionId: ToolDispatchContext.remoteConnectorJSONSessionID,
                origin: .remote,
                client: "skills-integration",
                governancePrincipal: "oauth-sub:skills-integration",
                routeAcknowledgementMode: .explicitReceipt
            )
            func authorityIDs(_ value: Value) -> Set<String> {
                guard case .object(let object) = value,
                      case .array(let receipts)? = object["routingReceipts"] else { return [] }
                return Set(receipts.flatMap { receipt -> [String] in
                    guard case .object(let object) = receipt,
                          case .array(let values)? = object["authorityIDs"] else { return [] }
                    return values.compactMap { value in
                        guard case .string(let string) = value else { return nil }
                        return string
                    }
                })
            }

            let projected = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object([
                    "id": .string(pageID),
                    "fields": .array([.string("content"), .string("uuid"), .string("version")])
                ]),
                context: context
            )
            guard case .object(let projectedObject) = projected else {
                throw TestError.assertion("UUID projection returned malformed output")
            }
            try expect(authorityIDs(projected).contains(authority),
                       "UUID projection must retain the resolved authority for receipt issuance")
            try expect(projectedObject[ToolRouter.routingAuthorityEvidenceKey] == nil,
                       "internal authority evidence must be stripped from projected output")

            let fuzzy = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object([
                    "name": .string("sk \(authority)"),
                    "fields": .array([.string("content")])
                ]),
                context: context
            )
            try expect(authorityIDs(fuzzy).contains(authority),
                       "a successful fuzzy lookup must issue authority for its resolved canonical skill")
        } catch {
            await restoreBodyCache()
            throw error
        }
        await restoreBodyCache()
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
        for name in ["skill_create", "skill_delete", "skill_update", "skill_rename", "skill_sync_notion",
                     "skills_exposure_reconcile", "skills_exposure_denylist",
                     "skills_exposure_purge_orphans"] {
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

    await test("fetch_skill slug alias resolves to the same configured skill as display name") {
        let defaultsKey = BridgeDefaults.skills
        let previousSkills = UserDefaults.standard.data(forKey: defaultsKey)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-slug-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
            if let previousSkills {
                UserDefaults.standard.set(previousSkills, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let pageID = "ef3dabbe3b4c41379cc58d89102d6046"
        let decoyID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let displayName = "SKILLS Keepr"
        let slug = "skill-keepr"
        let config: [[String: Any]] = [
            [
                "name": displayName,
                "notionPageId": pageID,
                "enabled": true,
                "visibility": "routing"
            ],
            [
                "name": "Skill",
                "notionPageId": decoyID,
                "enabled": true,
                "visibility": "standard"
            ]
        ]
        UserDefaults.standard.set(
            try JSONSerialization.data(withJSONObject: config),
            forKey: defaultsKey
        )

        let cached = CachedSkillBody(
            pageId: pageID,
            slug: slug,
            version: "6.2.0",
            status: "Testing",
            maturity: "Building",
            markdown: "# SKILLS Keepr",
            title: displayName,
            url: "https://notion.example/skills-keepr",
            properties: .object(["Slug": .string(slug)]),
            lastEditedTime: "2026-08-14T00:00:00.000Z",
            writtenAt: Date(),
            ttlHours: 24,
            callCount: 1
        )
        try await SkillBodyCacheStore.shared.write(cached)

        let byName = await SkillsModule.lookupSkillNamedForTesting(displayName)
        let bySlug = await SkillsModule.lookupSkillNamedForTesting(slug)
        let bySkPrefix = await SkillsModule.lookupSkillNamedForTesting("sk \(slug)")
        guard let byName, let bySlug, let bySkPrefix else {
            throw TestError.assertion("expected display name, slug, and sk-prefix slug to resolve")
        }
        try expect(byName.name == displayName, "display name lookup must keep the configured name")
        try expect(bySlug.name == displayName, "slug alias must return the display-name config, not a second identity")
        try expect(bySlug.pageId == byName.pageId, "slug must alias the same page id as display name")
        try expect(bySkPrefix.pageId == byName.pageId, "sk-prefix slug must resolve to the same page")
        try expect(
            CachedSkillBody.normalize(byName.pageId) == CachedSkillBody.normalize(pageID),
            "page id mismatch"
        )
    }

    await test("fetch_skill slug alias fails closed for unknown and duplicate slugs") {
        let defaultsKey = BridgeDefaults.skills
        let previousSkills = UserDefaults.standard.data(forKey: defaultsKey)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-slug-alias-failclosed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
            if let previousSkills {
                UserDefaults.standard.set(previousSkills, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let pageA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let pageB = "cccccccccccccccccccccccccccccccc"
        let config: [[String: Any]] = [
            ["name": "Alpha Keepr", "notionPageId": pageA, "enabled": true, "visibility": "routing"],
            ["name": "Beta Keepr", "notionPageId": pageB, "enabled": true, "visibility": "routing"]
        ]
        UserDefaults.standard.set(
            try JSONSerialization.data(withJSONObject: config),
            forKey: defaultsKey
        )

        func body(pageId: String, title: String) -> CachedSkillBody {
            CachedSkillBody(
                pageId: pageId,
                slug: "shared-slug",
                version: "1.0.0",
                status: "Testing",
                maturity: "Stable",
                markdown: "# \(title)",
                title: title,
                url: "https://notion.example/\(pageId)",
                properties: .object(["Slug": .string("shared-slug")]),
                lastEditedTime: "2026-08-14T00:00:00.000Z",
                writtenAt: Date(),
                ttlHours: 24,
                callCount: 1
            )
        }
        try await SkillBodyCacheStore.shared.write(body(pageId: pageA, title: "Alpha Keepr"))
        try await SkillBodyCacheStore.shared.write(body(pageId: pageB, title: "Beta Keepr"))

        let unknown = await SkillsModule.lookupSkillNamedForTesting("not-a-real-slug-xyz")
        try expect(unknown == nil, "unknown slug must fail closed")
        let duplicate = await SkillsModule.lookupSkillNamedForTesting("shared-slug")
        try expect(duplicate == nil, "duplicate cached slugs must fail closed")
        let byDisplay = await SkillsModule.lookupSkillNamedForTesting("Alpha Keepr")
        try expect(byDisplay?.name == "Alpha Keepr", "display name must still resolve when slug alias is closed")
    }

}
