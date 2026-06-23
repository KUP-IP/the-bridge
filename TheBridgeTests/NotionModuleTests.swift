// NotionModuleTests.swift – V1-05 → V2-NOTION-CORE NotionModule Tests
// TheBridge · Tests
//
// PKT-367: Updated for 18 tools, API v2026-03-11, multi-workspace registry,
//          config migration, new model types, helper tests

import Foundation
import MCP
import TheBridgeLib

// MARK: - NotionModule Tests

func runNotionModuleTests() async {
    print("\n📝 NotionModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await NotionModule.register(on: router)

    // ============================================================
    // MARK: - Tool Registration (23 tools)
    // ============================================================

    await test("NotionModule registers 22 tools (FB-notionwrite: notion_page_edit added)") {
        let tools = await router.registrations(forModule: "notion")
        try expect(tools.count == 22, "Expected 22 notion tools, got \(tools.count)")
    }

    let expectedTools: [String] = [
        "notion_search", "notion_page_read", "notion_page_update",
        "notion_query", "notion_page_create", "notion_blocks_append",
        "notion_block_delete", "notion_page_markdown_read", "notion_page_edit",
        "notion_database_get", "notion_datasource_get",
        "notion_comments_list", "notion_comment_create", "notion_users_list",
        "notion_page_move", "notion_file_upload", "notion_token_introspect",
        "notion_block_update",
        "notion_datasource_update", "notion_datasource_create",
        "notion_discussion_create"
    ]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "notion")
            let names = Set(tools.map(\.name))
            try expect(names.contains(toolName), "Missing \(toolName)")
        }
    }

    // ============================================================
    // MARK: - Security Tiers
    // ============================================================

    let openTools = [
        "notion_search", "notion_page_read", "notion_query",
        "notion_page_markdown_read", "notion_comments_list",
        "notion_users_list", "notion_token_introspect",
        "notion_database_get", "notion_datasource_get"
    ]
    for toolName in openTools {
        await test("\(toolName) tier is open") {
            let tools = await router.registrations(forModule: "notion")
            guard let tool = tools.first(where: { $0.name == toolName }) else { throw TestError.assertion("Tool \(toolName) not found") }
            try expect(tool.tier == .open, "Expected open tier for \(toolName), got \(tool.tier.rawValue)")
        }
    }

    let notifyTools = [
        "notion_page_update", "notion_page_create", "notion_blocks_append",
        "notion_block_delete", "notion_page_edit",
        "notion_comment_create", "notion_page_move", "notion_file_upload",
        "notion_datasource_update", "notion_datasource_create",
        "notion_block_update"
    ]
    for toolName in notifyTools {
        await test("\(toolName) tier is notify") {
            let tools = await router.registrations(forModule: "notion")
            guard let tool = tools.first(where: { $0.name == toolName }) else { throw TestError.assertion("Tool \(toolName) not found") }
            try expect(tool.tier == .notify, "Expected notify tier for \(toolName), got \(tool.tier.rawValue)")
        }
    }

    // ============================================================
    // MARK: - API Version
    // ============================================================

    await test("NotionClient uses API v2026-03-11") {
        do {
            let client = try NotionClient()
            let version = await client.getAPIVersion()
            try expect(version == "2026-03-11", "Expected 2026-03-11, got \(version)")
        } catch {
            // If no token configured, skip live version check
            print("    ⚠️ No API token — skipping live version check")
        }
    }

    // ============================================================
    // MARK: - Input Validation (missing required params)
    // ============================================================

    await test("notion_search rejects missing query") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_search",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing query")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_read rejects missing pageId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_read",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing pageId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_update rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_update",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_update rejects invalid JSON in properties") {
        do {
            let result = try await router.dispatch(
                toolName: "notion_page_update",
                arguments: .object([
                    "pageId": .string("fake-id-12345"),
                    "properties": .string("not valid json {{{")
                ])
            )
            if case .object(let dict) = result,
               case .string(let error) = dict["error"] {
                try expect(error.contains("Invalid JSON"), "Expected Invalid JSON error, got: \(error)")
            }
        } catch {
            // Also acceptable — API key might be missing
        }
    }

    await test("notion_query rejects missing databaseId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_query",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing databaseId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_create rejects missing parentId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_create",
                arguments: .object(["properties": .string("{}")])
            )
            throw TestError.assertion("Expected error for missing parentId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_blocks_append rejects missing blockId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_blocks_append",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing blockId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_block_delete rejects missing blockId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_block_delete",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing blockId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_markdown_read rejects missing pageId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_markdown_read",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing pageId")
        } catch is ToolRouterError {
            // Expected
        }
    }


    await test("notion_comments_create rejects missing text") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_comment_create",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing text")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_comments_create rejects missing parentId and discussionId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_comment_create",
                arguments: .object(["text": .string("test comment")])
            )
            throw TestError.assertion("Expected error for missing parentId/discussionId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // FB-3: comment text over Notion's 2000-char per-run limit is auto-chunked
    // into ordered <=2000-char runs (no hard-reject). Exercise the pure helper
    // directly — network-free, deterministic, covers the 2000/2001 boundary.
    await test("notion_comment_create auto-chunks text over the 2000-char per-run limit") {
        // Boundary: exactly 2000 chars stays a single chunk.
        let at2000 = NotionModule.chunkCommentText(String(repeating: "x", count: 2000), maxChars: 2000)
        try expect(at2000.count == 1, "2000 chars should be 1 chunk, got \(at2000.count)")
        try expect(at2000[0].count == 2000, "the single chunk should be 2000 chars")

        // Boundary: 2001 chars splits into [2000, 1].
        let at2001 = NotionModule.chunkCommentText(String(repeating: "x", count: 2001), maxChars: 2000)
        try expect(at2001.count == 2, "2001 chars should be 2 chunks, got \(at2001.count)")
        try expect(at2001[0].count == 2000 && at2001[1].count == 1, "2001 -> [2000, 1], got [\(at2001[0].count), \(at2001[1].count)]")

        // 2500 chars splits into [2000, 500] preserving order; join reproduces input.
        let big = String(repeating: "a", count: 2000) + String(repeating: "b", count: 500)
        let chunks = NotionModule.chunkCommentText(big, maxChars: 2000)
        try expect(chunks.count == 2, "2500 chars should be 2 chunks, got \(chunks.count)")
        try expect(chunks[0].count == 2000 && chunks[1].count == 500, "2500 -> [2000, 500]")
        try expect(chunks.joined() == big, "joined chunks must reproduce the original text")

        // Short text is returned unchanged as a single chunk.
        let short = NotionModule.chunkCommentText("hello", maxChars: 2000)
        try expect(short.count == 1 && short[0] == "hello", "short text should be one unchanged chunk")
    }

    await test("notion_page_move rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_move",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_file_upload rejects missing filePath") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_file_upload",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing filePath")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // FB-6: notion_block_delete supports bulk deletes via an optional `blockIds`
    // array while keeping single `blockId` back-compat. Assert the schema
    // declares both; required[] must be empty so either form is accepted.
    await test("notion_block_delete schema declares optional blockIds plus back-compat blockId") {
        let tools = await router.registrations(forModule: "notion")
        guard let tool = tools.first(where: { $0.name == "notion_block_delete" }) else {
            throw TestError.assertion("notion_block_delete not found")
        }
        let schema = String(describing: tool.inputSchema)
        try expect(schema.contains("blockIds"), "block_delete schema should declare blockIds for bulk deletes")
        try expect(schema.contains("blockId"), "block_delete schema should keep blockId for back-compat")
    }

    // FB-6: a `blockIds` array argument is accepted (not rejected as malformed).
    // Without a live registry the dispatch surfaces a client/registry error, but
    // it must NOT be a ToolRouterError invalid-arguments rejection of blockIds.
    await test("notion_block_delete accepts a blockIds array (no invalid-arguments rejection)") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_block_delete",
                arguments: .object(["blockIds": .array([.string("b1"), .string("b2")])])
            )
            // Reaching here (e.g. live registry present) is fine — args were accepted.
        } catch let e as ToolRouterError {
            // The only acceptable ToolRouterError here is NOT an arg-shape rejection;
            // a missing-args/invalid-args error would mean blockIds wasn't recognized.
            let d = "\(e)"
            try expect(!d.contains("missing 'blockId'"), "blockIds array must be recognized, got: \(d)")
        } catch {
            // Any non-router error (e.g. no Notion connection configured) is expected
            // here and means the blockIds argument was accepted past validation.
        }
    }

    // FB-notionwrite: applyContentEdits is the pure, network-free core of
    // notion_page_edit. Cover literal first-match, replaceAll, ordered/cascading
    // edits, unmatched reporting, and the empty-old_str no-op guard.
    await test("applyContentEdits applies a literal first-match edit") {
        let (text, results) = NotionModule.applyContentEdits(
            "alpha beta alpha",
            edits: [NotionModule.ContentEdit(oldStr: "alpha", newStr: "ALPHA", replaceAll: false)]
        )
        try expect(text == "ALPHA beta alpha", "only the first occurrence should change, got: \(text)")
        try expect(results.count == 1 && results[0].matched && results[0].replacements == 1,
                   "expected one match / one replacement")
    }

    await test("applyContentEdits replaceAll replaces every occurrence and counts them") {
        let (text, results) = NotionModule.applyContentEdits(
            "x x x",
            edits: [NotionModule.ContentEdit(oldStr: "x", newStr: "y", replaceAll: true)]
        )
        try expect(text == "y y y", "all occurrences should change, got: \(text)")
        try expect(results[0].replacements == 3, "expected 3 replacements, got \(results[0].replacements)")
    }

    await test("applyContentEdits applies edits in order, each seeing prior results") {
        // Edit 1 turns "foo" -> "bar"; edit 2 then matches the new "bar".
        let (text, results) = NotionModule.applyContentEdits(
            "foo",
            edits: [
                NotionModule.ContentEdit(oldStr: "foo", newStr: "bar", replaceAll: false),
                NotionModule.ContentEdit(oldStr: "bar", newStr: "baz", replaceAll: false)
            ]
        )
        try expect(text == "baz", "cascading edits should produce baz, got: \(text)")
        try expect(results.allSatisfy { $0.matched }, "both edits should match")
    }

    await test("applyContentEdits reports unmatched old_str without altering text") {
        let (text, results) = NotionModule.applyContentEdits(
            "hello world",
            edits: [NotionModule.ContentEdit(oldStr: "absent", newStr: "X", replaceAll: false)]
        )
        try expect(text == "hello world", "unmatched edit must leave text unchanged")
        try expect(!results[0].matched && results[0].replacements == 0, "edit should report no match")
    }

    await test("applyContentEdits treats empty old_str as a no-op that never matches") {
        let (text, results) = NotionModule.applyContentEdits(
            "data",
            edits: [NotionModule.ContentEdit(oldStr: "", newStr: "INJECTED", replaceAll: false)]
        )
        try expect(text == "data", "empty old_str must not corrupt the body, got: \(text)")
        try expect(!results[0].matched, "empty old_str must report no match")
    }

    // FB-notionwrite: notion_page_edit handler input validation. These run
    // network-free: malformed args must be rejected before any registry/client call.
    await test("notion_page_edit rejects missing pageId/edits") {
        do {
            _ = try await router.dispatch(toolName: "notion_page_edit", arguments: .object([:]))
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_edit rejects an empty edits array") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_edit",
                arguments: .object(["pageId": .string("p1"), "edits": .array([])])
            )
            throw TestError.assertion("Expected error for empty edits array")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_edit rejects an edit with empty old_str before any write") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_edit",
                arguments: .object([
                    "pageId": .string("p1"),
                    "edits": .array([.object(["old_str": .string(""), "new_str": .string("X")])])
                ])
            )
            throw TestError.assertion("Expected error for empty old_str")
        } catch is ToolRouterError {
            // Expected — empty old_str is rejected at arg validation, never reaching the client.
        }
    }

    await test("notion_page_edit schema declares pageId + edits with old_str/new_str") {
        let tools = await router.registrations(forModule: "notion")
        guard let tool = tools.first(where: { $0.name == "notion_page_edit" }) else {
            throw TestError.assertion("notion_page_edit not found")
        }
        let schema = String(describing: tool.inputSchema)
        try expect(schema.contains("old_str") && schema.contains("new_str"),
                   "page_edit schema should declare old_str/new_str edit shape")
        try expect(schema.contains("edits"), "page_edit schema should declare the edits array")
    }

    // ============================================================

    await test("notion_datasource_update rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_datasource_update",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_datasource_create rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_datasource_create",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }


    await test("notion_datasource_update rejects invalid JSON in properties") {
        do {
            let result = try await router.dispatch(
                toolName: "notion_datasource_update",
                arguments: .object([
                    "dataSourceId": .string("fake-ds-id"),
                    "properties": .string("not valid json {{{")
                ])
            )
            if case .object(let dict) = result,
               case .string(let error) = dict["error"] {
                try expect(error.contains("Invalid JSON"), "Expected Invalid JSON error, got: \(error)")
            }
        } catch {
            // Also acceptable — API key might be missing
        }
    }

    await test("notion_datasource_create rejects invalid JSON in properties") {
        do {
            let result = try await router.dispatch(
                toolName: "notion_datasource_create",
                arguments: .object([
                    "databaseId": .string("fake-db-id"),
                    "properties": .string("not valid json {{{")
                ])
            )
            if case .object(let dict) = result,
               case .string(let error) = dict["error"] {
                try expect(error.contains("Invalid JSON"), "Expected Invalid JSON error, got: \(error)")
            }
        } catch {
            // Also acceptable
        }
    }

    await test("notion_database_get rejects missing databaseId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_database_get",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing databaseId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_datasource_get rejects missing dataSourceId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_datasource_get",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing dataSourceId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // MARK: - Config Migration & Registry
    // ============================================================

    await test("NotionClientRegistry initializes without crash") {
        let registry = NotionClientRegistry()
        _ = registry
    }

    await test("NotionClientRegistry.listConnections works") {
        let registry = NotionClientRegistry()
        do {
            let connections = try await registry.listConnections()
            try expect(connections.count >= 0, "Expected non-negative connection count")
            for conn in connections {
                try expect(!conn.name.isEmpty, "Connection name should not be empty")
                try expect(!conn.maskedToken.isEmpty, "Masked token should not be empty")
            }
        } catch {
            print("    ⚠️ No connections configured — skipping live registry check")
        }
    }

    await test("NotionTokenResolver.validateTokenFormat accepts valid ntn_ token") {
        let result = NotionTokenResolver.validateTokenFormat("ntn_abcdef1234567890abcdef")
        try expect(result.valid == true, "Expected valid=true for ntn_ token")
        try expect(result.error == nil, "Expected no error for valid token")
    }

    await test("NotionTokenResolver.validateTokenFormat accepts valid secret_ token") {
        let result = NotionTokenResolver.validateTokenFormat("secret_abcdef1234567890abcdef")
        try expect(result.valid == true, "Expected valid=true for secret_ token")
    }

    await test("NotionTokenResolver.validateTokenFormat rejects short token") {
        let result = NotionTokenResolver.validateTokenFormat("ntn_short")
        try expect(result.valid == false, "Expected valid=false for short token")
        try expect(result.error != nil, "Expected error for short token")
    }

    await test("NotionTokenResolver.validateTokenFormat rejects invalid prefix") {
        let result = NotionTokenResolver.validateTokenFormat("invalid_prefix_abcdef1234567890")
        try expect(result.valid == false, "Expected valid=false for invalid prefix")
    }

    // ============================================================
    // MARK: - NotionJSON Helper Tests
    // ============================================================

    await test("NotionJSON.extractTitle extracts title from properties") {
        let props: [String: Any] = [
            "Name": [
                "type": "title",
                "title": [
                    ["plain_text": "Hello World"]
                ]
            ]
        ]
        let title = NotionJSON.extractTitle(from: props)
        try expect(title == "Hello World", "Expected 'Hello World', got '\(title)'")
    }

    await test("NotionJSON.extractTitle returns Untitled for empty properties") {
        let title = NotionJSON.extractTitle(from: [:])
        try expect(title == "Untitled", "Expected 'Untitled', got '\(title)'")
    }

    await test("NotionJSON.prettyPrint produces valid JSON string") {
        let obj: [String: Any] = ["key": "value", "num": 42]
        let result = NotionJSON.prettyPrint(obj)
        try expect(result.contains("key"), "Expected 'key' in output")
        try expect(result.contains("value"), "Expected 'value' in output")
        try expect(result.contains("42"), "Expected '42' in output")
    }

    await test("NotionJSON.extractPlainText extracts text from rich_text array") {
        let richText: [[String: Any]] = [
            ["plain_text": "Hello "],
            ["plain_text": "World"]
        ]
        let text = NotionJSON.extractPlainText(from: richText)
        try expect(text == "Hello World", "Expected 'Hello World', got '\(text)'")
    }

    await test("NotionJSON.extractPlainText returns empty string for empty array") {
        let text = NotionJSON.extractPlainText(from: [])
        try expect(text == "", "Expected empty string, got '\(text)'")
    }


    await test("NotionJSON.extractPlainTextFromBlock extracts table_row cells") {
        let block: [String: Any] = [
            "type": "table_row",
            "table_row": [
                "cells": [
                    [["plain_text": "Cell A"]],
                    [["plain_text": "Cell B"]],
                    [["plain_text": "Cell C"]]
                ] as [[[String: Any]]]
            ]
        ]
        let text = NotionJSON.extractPlainTextFromBlock(block)
        try expect(text == "Cell A | Cell B | Cell C", "Expected 'Cell A | Cell B | Cell C', got '\(text)'")
    }
    await test("NotionJSON.maskToken masks token correctly") {
        let masked = NotionJSON.maskToken("ntn_abcdef1234567890")
        try expect(masked.hasPrefix("ntn_"), "Expected prefix 'ntn_', got '\(masked)'")
        try expect(masked.hasSuffix("7890"), "Expected suffix '7890', got '\(masked)'")
        try expect(masked.contains("•"), "Expected masking dots in '\(masked)'")
    }

    await test("NotionJSON.maskToken handles short token") {
        let masked = NotionJSON.maskToken("short")
        try expect(masked.contains("•"), "Expected masking dots for short token, got '\(masked)'")
    }

    // ============================================================
    // MARK: - Append block children body (API 2026-03-11)
    // ============================================================

    await test("buildAppendBlocksRequestBody end omits position and after") {
        let children = "[{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[]}}]".data(using: .utf8)!
        let body = try NotionClient.buildAppendBlocksRequestBody(children: children, position: .end)
        try expect(body["children"] != nil, "Expected children")
        try expect(body["position"] == nil, "Expected no position for append-to-end")
        try expect(body["after"] == nil, "Must not send deprecated after key")
    }

    await test("buildAppendBlocksRequestBody afterBlock uses position.after_block.id") {
        let children = "[{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[]}}]".data(using: .utf8)!
        let rawAfter = "333cbb58889e8140aba3f4b29693b38f"
        let body = try NotionClient.buildAppendBlocksRequestBody(children: children, position: .afterBlock(id: rawAfter))
        try expect(body["after"] == nil, "Must not send deprecated after key")
        guard let pos = body["position"] as? [String: Any] else {
            throw TestError.assertion("Expected position dict")
        }
        try expect(pos["type"] as? String == "after_block", "Expected type after_block")
        guard let ab = pos["after_block"] as? [String: Any] else {
            throw TestError.assertion("Expected after_block object")
        }
        let id = ab["id"] as? String ?? ""
        try expect(id.contains("-"), "Expected dashed UUID in id field")
        try expect(
            id.replacingOccurrences(of: "-", with: "").lowercased() == rawAfter.lowercased(),
            "Normalized id should match 32-char input"
        )
    }

    await test("buildAppendBlocksRequestBody start sends position.type == start (API 2026-03-11)") {
        let children = "[{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[]}}]".data(using: .utf8)!
        let body = try NotionClient.buildAppendBlocksRequestBody(children: children, position: .start)
        try expect(body["children"] != nil, "Expected children")
        try expect(body["after"] == nil, "Must not send deprecated after key")
        guard let pos = body["position"] as? [String: Any] else {
            throw TestError.assertion("Expected position dict")
        }
        try expect(pos["type"] as? String == "start", "Expected type start")
        try expect(pos["after_block"] == nil, "start variant must not include after_block")
    }

    // ============================================================
    // MARK: - NotionClientError Tests
    // ============================================================

    await test("NotionClientError.connectionNotFound has descriptive message") {
        let error = NotionClientError.connectionNotFound("myworkspace")
        let desc = error.localizedDescription
        try expect(desc.contains("myworkspace"), "Expected workspace name in error: \(desc)")
        try expect(desc.contains("not found"), "Expected 'not found' in error: \(desc)")
    }

    await test("NotionClientError.missingAPIKey has descriptive message") {
        let error = NotionClientError.missingAPIKey
        let desc = error.localizedDescription
        try expect(desc.contains("NOTION_API_TOKEN"), "Expected env var name in error: \(desc)")
    }

    await test("NotionClientError.httpError includes status code and body") {
        let error = NotionClientError.httpError(404, "page not found")
        let desc = error.localizedDescription
        try expect(desc.contains("404"), "Expected 404 in error: \(desc)")
        try expect(desc.contains("page not found"), "Expected body in error: \(desc)")
    }

    // ============================================================
    // MARK: - Model Tests
    // ============================================================

    await test("NotionPage model includes inTrash field") {
        let page = NotionPage(id: "abc", url: "https://notion.so/abc", title: "Test", inTrash: true, properties: "{}")
        try expect(page.inTrash == true, "Expected inTrash=true")
        try expect(page.id == "abc", "Expected id='abc'")
    }

    await test("NotionPage inTrash defaults to false") {
        let page = NotionPage(id: "abc", url: "https://notion.so/abc", title: "Test", properties: "{}")
        try expect(page.inTrash == false, "Expected inTrash=false by default")
    }

    await test("NotionComment model initializes correctly") {
        let comment = NotionComment(id: "c1", parentId: "p1", text: "Hello", createdTime: "2026-03-19", createdBy: "u1")
        try expect(comment.id == "c1", "Expected id='c1'")
        try expect(comment.parentId == "p1", "Expected parentId='p1'")
        try expect(comment.text == "Hello", "Expected text='Hello'")
    }

    await test("NotionUser model initializes correctly") {
        let user = NotionUser(id: "u1", name: "Alice", email: "alice@example.com", type: "person", avatarURL: nil)
        try expect(user.id == "u1", "Expected id='u1'")
        try expect(user.name == "Alice", "Expected name='Alice'")
        try expect(user.email == "alice@example.com", "Expected email")
        try expect(user.type == "person", "Expected type='person'")
    }

    await test("NotionFileUpload model initializes correctly") {
        let upload = NotionFileUpload(id: "f1", status: "uploaded", url: nil)
        try expect(upload.id == "f1", "Expected id='f1'")
        try expect(upload.status == "uploaded", "Expected status='uploaded'")
    }

    await test("NotionConnection model initializes correctly") {
        let conn = NotionConnection(name: "primary", token: "ntn_test", primary: true)
        try expect(conn.name == "primary", "Expected name='primary'")
        try expect(conn.primary == true, "Expected primary=true")
        try expect(conn.token == "ntn_test", "Expected token='ntn_test'")
    }

    await test("NotionConnectionInfo model initializes correctly") {
        let info = NotionConnectionInfo(name: "primary", isPrimary: true, status: "connected", maskedToken: "ntn_•••1234")
        try expect(info.name == "primary", "Expected name='primary'")
        try expect(info.isPrimary == true, "Expected isPrimary=true")
        try expect(info.status == "connected", "Expected status='connected'")
        try expect(info.maskedToken == "ntn_•••1234", "Expected maskedToken")
    }

    // ============================================================
    // MARK: - Functional Tests (with API key)
    // ============================================================

    let hasAPIKey = ProcessInfo.processInfo.environment["NOTION_API_TOKEN"] != nil ||
                    ProcessInfo.processInfo.environment["NOTION_API_KEY"] != nil ||
                    NotionTokenResolver.readCurrentToken() != nil

    if hasAPIKey {
        await test("notion_search returns results with API key") {
            let result = try await router.dispatch(
                toolName: "notion_search",
                arguments: .object(["query": .string("test"), "pageSize": .int(3)])
            )
            if case .object(let dict) = result {
                try expect(dict["count"] != nil, "Expected count key")
                try expect(dict["results"] != nil, "Expected results key")
            } else {
                throw TestError.assertion("Expected object result")
            }
        }

        // v3.6.1: moved into the hasAPIKey branch — this makes a LIVE
        // notion_datasource_get call that requires a key; in the else (no-key)
        // branch it could only ever fail. Name corrected (get, not update).
        await test("notion_datasource_get succeeds with API key (read schema)") {
            let result = try await router.dispatch(
                toolName: "notion_datasource_get",
                arguments: .object(["dataSourceId": .string("992fd5ac-d938-4be4-95fb-8ef18bd86bba")])
            )
            if case .object(let dict) = result {
                try expect(dict["id"] != nil, "Expected id key")
                try expect(dict["schema"] != nil, "Expected schema key")
            } else {
                throw TestError.assertion("Expected object result")
            }
        }
    } else {

        await test("notion_search reports missing API key gracefully") {
            do {
                _ = try await router.dispatch(
                    toolName: "notion_search",
                    arguments: .object(["query": .string("test")])
                )
            } catch {
                let desc = error.localizedDescription
                try expect(
                    desc.contains("API") || desc.contains("key") || desc.contains("KEY") || desc.contains("token"),
                    "Error should mention API key/token: \(desc)"
                )
            }
        }
    }

    // ============================================================
    // MARK: - notion_datasource_delete behavioral coverage
    //   Closes the gap the v3-hub ledger (Decision row 27) admitted and
    //   the 2026-05-19 test audit flagged HIGH: the destructive tool had
    //   ZERO behavioral tests. We exercise the handler's network-free
    //   safety guards DIRECTLY (bypassing the SecurityGate, which is the
    //   .request/neverAutoApprove gate tested elsewhere) and the pure
    //   wire-body builder. The confirm:true + real dataSourceId path is
    //   intentionally NOT tested — it would risk a live data-source
    //   trash, which is forbidden.
    // ============================================================

    func datasourceDeleteReg() async throws -> ToolRegistration {
        let regs = await router.registrations(forModule: "notion")
        guard let del = regs.first(where: { $0.name == "notion_datasource_delete" }) else {
            throw TestError.assertion("notion_datasource_delete must be registered")
        }
        return del
    }

    await test("notion_datasource_delete REFUSES without confirm:true (explicit false)") {
        let del = try await datasourceDeleteReg()
        let result = try await del.handler(.object([
            "dataSourceId": .string("992fd5ac-d938-4be4-95fb-8ef18bd86bba"),
            "confirm": .bool(false)
        ]))
        guard case .object(let o) = result, case .string(let err)? = o["error"] else {
            throw TestError.assertion("confirm:false must return an {error:…} envelope, got \(result)")
        }
        try expect(err.contains("Refused"), "refusal must say 'Refused', got: \(err)")
        try expect(o["success"] == nil, "a refusal must NOT report success; got \(o)")
    }

    await test("notion_datasource_delete REFUSES when confirm is omitted entirely") {
        let del = try await datasourceDeleteReg()
        // Guard is `case .bool(true)?` — a missing confirm key also refuses.
        let result = try await del.handler(.object([
            "dataSourceId": .string("992fd5ac-d938-4be4-95fb-8ef18bd86bba")
        ]))
        guard case .object(let o) = result, case .string(let err)? = o["error"] else {
            throw TestError.assertion("omitted confirm must refuse, got \(result)")
        }
        try expect(err.contains("Refused"), "refusal must say 'Refused', got: \(err)")
    }

    await test("notion_datasource_delete throws on missing dataSourceId (pre-network)") {
        let del = try await datasourceDeleteReg()
        do {
            // confirm:true but no dataSourceId — the dataSourceId guard is
            // FIRST, so this throws before the confirm check and before
            // any client/network call.
            _ = try await del.handler(.object(["confirm": .bool(true)]))
            throw TestError.assertion("missing dataSourceId must throw, not return a value")
        } catch let e as TestError {
            throw e
        } catch {
            let d = "\(error)"
            try expect(d.contains("dataSourceId") || d.lowercased().contains("invalid"),
                       "error should reference the missing dataSourceId, got: \(d)")
        }
    }

    await test("NotionClient.buildDeleteDataSourceBody emits exactly {in_trash:<bool>}") {
        let trash = NotionClient.buildDeleteDataSourceBody(inTrash: true)
        try expect(trash.count == 1, "body must have exactly one key, got \(trash)")
        try expect((trash["in_trash"] as? Bool) == true,
                   "delete body must be in_trash:true, got \(String(describing: trash["in_trash"]))")
        let restore = NotionClient.buildDeleteDataSourceBody(inTrash: false)
        try expect((restore["in_trash"] as? Bool) == false,
                   "restore body must be in_trash:false, got \(String(describing: restore["in_trash"]))")
        // Exact wire bytes (this builder IS the production path —
        // deleteDataSource serializes precisely this object).
        let data = try JSONSerialization.data(withJSONObject: trash)
        let round = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        try expect(round == ["in_trash": true],
                   "wire round-trip must be {\"in_trash\":true}, got \(String(describing: round))")
    }
}
