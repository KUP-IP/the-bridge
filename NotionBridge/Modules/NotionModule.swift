// NotionModule.swift – V1-05 → V1-12 → PKT-367 Notion Integration Tools
// NotionBridge · Modules
//
// 20 tools via NotionClientRegistry for multi-workspace support.
// PKT-320: Updated references from NOTION_API_KEY to NOTION_API_TOKEN
// PKT-367: 13 new tools, NotionClientRegistry integration, optional workspace param

import Foundation
import MCP

// MARK: - NotionModule

/// Provides Notion workspace integration tools.
/// Uses NotionClientRegistry for multi-workspace token management.
public enum NotionModule {

    public static let moduleName = "notion"

    /// Register all NotionModule tools on the given router.
    /// Lazily initializes NotionClientRegistry on first tool invocation.
    public static func register(on router: ToolRouter) async {

        // Lazy registry — initialized once on first use
        let registryHolder = NotionRegistryHolder()

        // Helper: extract optional workspace parameter
        @Sendable func extractWorkspace(_ args: [String: Value]) -> String? {
            if case .string(let ws) = args["workspace"] { return ws }
            return nil
        }

        // Helper: workspace parameter schema fragment
        let workspaceParam: Value = .object([
            "type": .string("string"),
            "description": .string("Optional workspace connection name. Uses primary connection if omitted.")
        ])

        // MARK: 1. notion_search – open
        await router.register(ToolRegistration(
            name: "notion_search",
            module: moduleName,
            tier: .open,
            description: "Keyword-search a Notion workspace for pages and data sources. Returns IDs + titles; no semantic ranking.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search query text")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results to return (default: 10, max: 100)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_search", reason: "missing 'query'")
                }
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 10 }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.search(query: query, pageSize: pageSize)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse search response")])
                }

                var items: [Value] = []
                for result in results {
                    let id = result["id"] as? String ?? ""
                    let objectType = result["object"] as? String ?? ""
                    let url = result["url"] as? String ?? ""

                    var title = "Untitled"
                    if let properties = result["properties"] as? [String: Any] {
                        title = NotionJSON.extractTitle(from: properties)
                    } else if let titleArr = result["title"] as? [[String: Any]] {
                        title = titleArr.compactMap { $0["plain_text"] as? String }.joined()
                    }

                    items.append(.object([
                        "id": .string(id),
                        "type": .string(objectType),
                        "title": .string(title),
                        "url": .string(url)
                    ]))
                }

                return .object([
                    "query": .string(query),
                    "count": .int(items.count),
                    "results": .array(items)
                ])
            }
        ))

        // MARK: 2. notion_page_read – open
        await router.register(ToolRegistration(
            name: "notion_page_read",
            module: moduleName,
            tier: .open,
            description: "Read a Notion page's properties + full block tree (paginates children, optional nested). Heavier than notion_page_markdown_read.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID (with or without dashes)")]),
                    "includeBlocks": .object(["type": .string("boolean"), "description": .string("Whether to also fetch child blocks (default: true)")]),
                    "includeNested": .object(["type": .string("boolean"), "description": .string("Include nested block children (default false). When false, still paginates all direct children.")]),
                    "maxBlocks": .object(["type": .string("number"), "description": .string("Max blocks to collect (default 5000)")]),
                    "maxDepth": .object(["type": .string("number"), "description": .string("Max nesting depth when includeNested true (default 10)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_read", reason: "missing 'pageId'")
                }
                let includeBlocks: Bool = {
                    if case .bool(let b) = args["includeBlocks"] { return b }
                    return true
                }()
                let includeNested: Bool = {
                    if case .bool(let b) = args["includeNested"] { return b }
                    return false
                }()
                let maxBlocks: Int = {
                    if case .int(let n) = args["maxBlocks"], n > 0 { return n }
                    if case .double(let d) = args["maxBlocks"], d > 0 { return Int(d) }
                    return 5000
                }()
                let maxDepth: Int = {
                    if case .int(let n) = args["maxDepth"], n > 0 { return n }
                    if case .double(let d) = args["maxDepth"], d > 0 { return Int(d) }
                    return 10
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))

                let pageData = try await client.getPage(pageId: pageId)
                guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse page response")])
                }

                let id = pageJSON["id"] as? String ?? pageId
                let url = pageJSON["url"] as? String ?? ""
                let inTrash = pageJSON["in_trash"] as? Bool ?? false

                var title = "Untitled"
                if let properties = pageJSON["properties"] as? [String: Any] {
                    title = NotionJSON.extractTitle(from: properties)
                }

                var result: [String: Value] = [
                    "id": .string(id),
                    "url": .string(url),
                    "title": .string(title),
                    "in_trash": .bool(inTrash),
                    "properties": .string(NotionJSON.prettyPrint(pageJSON["properties"] ?? [:]))
                ]

                // PKT-526: Expose parent for data source resolution
                if let parent = pageJSON["parent"] as? [String: Any] {
                    result["parent"] = .string(NotionJSON.prettyPrint(parent))
                }

                if includeBlocks {
                    do {
                        let collected = try await client.collectBlocksDepthFirst(
                            rootBlockId: pageId,
                            includeNested: includeNested,
                            maxBlocks: maxBlocks,
                            maxDepth: maxDepth
                        )
                        let blockResults = collected.blocks
                        let truncated = collected.truncated
                        let truncReason = collected.truncationReason

                        var blocks: [Value] = []
                        for block in blockResults {
                            let bid = block["id"] as? String ?? ""
                            let blockType = block["type"] as? String ?? ""
                            let hasChildren = block["has_children"] as? Bool ?? false
                            let textContent = NotionJSON.extractPlainTextFromBlock(block)

                            blocks.append(.object([
                                "id": .string(bid),
                                "type": .string(blockType),
                                "hasChildren": .bool(hasChildren),
                                "text": .string(textContent)
                            ]))
                        }

                        result["blocks"] = .array(blocks)
                        result["blockCount"] = .int(blocks.count)
                        result["truncated"] = .bool(truncated)
                        if let r = truncReason {
                            result["truncationReason"] = .string(r)
                        }
                    } catch {
                        result["blocks"] = .string("Failed to fetch blocks: \(error.localizedDescription)")
                    }
                }

                return .object(result)
            }
        ))

        // MARK: 3. notion_page_update – notify
        await router.register(ToolRegistration(
            name: "notion_page_update",
            module: moduleName,
            tier: .notify,
            description: "Update a Notion page's properties only (title, status, relations). For body content use notion_blocks_append / notion_block_update.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID (with or without dashes)")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of properties to update (Notion API format)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("properties")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let propsJSON) = args["properties"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_update", reason: "missing 'pageId' or 'properties'")
                }

                guard let propsData = propsJSON.data(using: .utf8),
                      var propsObj = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any] else {
                    return .object(["error": .string("Invalid JSON in 'properties' parameter")])
                }

                // File property sugar: ["id1", "id2"] → {"files": [{"type": "file_upload", "file_upload": {"id": "id1"}}, ...]}
                for (key, value) in propsObj {
                    if let arr = value as? [String], !arr.isEmpty,
                       arr.allSatisfy({ $0.count >= 32 && $0.count <= 36 }) {
                        // Heuristic: array of UUID-length strings → treat as file upload IDs
                        let files = arr.map { id in
                            ["type": "file_upload", "file_upload": ["id": id]] as [String: Any]
                        }
                        propsObj[key] = ["files": files] as [String: Any]
                    }
                }

                let envelope: [String: Any] = ["properties": propsObj]
                let envelopeData = try JSONSerialization.data(withJSONObject: envelope)

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let resultData = try await client.updatePage(pageId: pageId, properties: envelopeData)

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse update response")])
                }

                let id = resultJSON["id"] as? String ?? pageId
                let url = resultJSON["url"] as? String ?? ""

                return .object([
                    "success": .bool(true),
                    "id": .string(id),
                    "url": .string(url)
                ])
            }
        ))

        // MARK: 4. notion_page_create – notify (A3)
        await router.register(ToolRegistration(
            name: "notion_page_create",
            module: moduleName,
            tier: .notify,
            description: "Create a new Notion page under a page, database, or data source parent. Returns the new pageId.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "parentId": .object(["type": .string("string"), "description": .string("Parent page or database ID")]),
                    "parentType": .object(["type": .string("string"), "description": .string("Parent type: 'page_id', 'database_id', or 'data_source_id' (default: page_id)")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of page properties")]),
                    "children": .object(["type": .string("string"), "description": .string("Optional JSON string of child blocks")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("parentId"), .string("properties")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let parentId) = args["parentId"],
                      case .string(let propsJSON) = args["properties"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_create", reason: "missing 'parentId' or 'properties'")
                }

                let parentType: String = {
                    if case .string(let pt) = args["parentType"] { return pt }
                    return "page_id"
                }()

                guard let propsData = propsJSON.data(using: .utf8) else {
                    return .object(["error": .string("Invalid JSON in 'properties'")])
                }

                var childrenData: Data? = nil
                if case .string(let childrenJSON) = args["children"] {
                    childrenData = childrenJSON.data(using: .utf8)
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let resultData = try await client.createPage(
                    parentId: parentId,
                    parentType: parentType,
                    properties: propsData,
                    children: childrenData
                )

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse create response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(resultJSON["id"] as? String ?? ""),
                    "url": .string(resultJSON["url"] as? String ?? "")
                ])
            }
        ))

        // MARK: 5. notion_query – open (A4)
        await router.register(ToolRegistration(
            name: "notion_query",
            module: moduleName,
            tier: .open,
            description: "Query rows in a Notion data source with Notion-API filters/sorts/cursor pagination. Requires notion_datasource_get first for column names.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Data source ID to query")]),
                    "filter": .object(["type": .string("string"), "description": .string("Optional JSON string of filter object")]),
                    "sorts": .object(["type": .string("string"), "description": .string("Optional JSON string of sorts array")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default: 100)")]),
                    "startCursor": .object(["type": .string("string"), "description": .string("Pagination cursor from previous query")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("dataSourceId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dsId) = args["dataSourceId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_query", reason: "missing 'dataSourceId'")
                }

                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 100 }()
                let startCursor: String? = { if case .string(let c) = args["startCursor"] { return c }; return nil }()

                var filterData: Data? = nil
                if case .string(let f) = args["filter"] { filterData = f.data(using: .utf8) }
                var sortsData: Data? = nil
                if case .string(let s) = args["sorts"] { sortsData = s.data(using: .utf8) }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                // v1.7.0+v1.8.0: Auto-retry transient 404 (KI-06, C2)
                var data = Data()
                var retryCount = 0
                do {
                    data = try await client.queryDataSource(
                        dataSourceId: dsId, filter: filterData,
                        sorts: sortsData, pageSize: pageSize,
                        startCursor: startCursor
                    )
                } catch {
                    if String(describing: error).contains("404") {
                        retryCount = 1
                        NSLog("[notion_query] Retrying transient 404 for dataSource=%@ (attempt %d/2, delay=2s)", dsId, retryCount + 1)
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        do {
                            data = try await client.queryDataSource(
                                dataSourceId: dsId, filter: filterData,
                                sorts: sortsData, pageSize: pageSize,
                                startCursor: startCursor
                            )
                            NSLog("[notion_query] Retry succeeded for dataSource=%@ after %d retry", dsId, retryCount)
                        } catch {
                            NSLog("[notion_query] Permanent 404 for dataSource=%@ after %d retry — check sharing permissions", dsId, retryCount)
                            throw error
                        }
                    } else {
                        throw error
                    }
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse query response")])
                }

                var items: [Value] = []
                for result in results {
                    let id = result["id"] as? String ?? ""
                    let url = result["url"] as? String ?? ""
                    var title = "Untitled"
                    if let properties = result["properties"] as? [String: Any] {
                        title = NotionJSON.extractTitle(from: properties)
                    }
                    items.append(.object([
                        "id": .string(id),
                        "title": .string(title),
                        "url": .string(url)
                    ]))
                }

                var resultObj: [String: Value] = [
                    "count": .int(items.count),
                    "results": .array(items)
                ]
                if let hasMore = json["has_more"] as? Bool {
                    resultObj["has_more"] = .bool(hasMore)
                }
                if let nextCursor = json["next_cursor"] as? String {
                    resultObj["next_cursor"] = .string(nextCursor)
                }
                return .object(resultObj)
            }
        ))

        // MARK: 6. notion_blocks_append – notify (A5)
        // After changing registration or behavior, reload NotionBridge (sk mac ops) so MCP clients list the updated tool.
        await router.register(ToolRegistration(
            name: "notion_blocks_append",
            module: moduleName,
            tier: .notify,
            description: "Append child blocks to a Notion page or block. Supports position: start | end | after:{id} for insertion order.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Parent page or block ID")]),
                    "children": .object(["type": .string("string"), "description": .string("JSON string of children blocks array")]),
                    "afterBlock": .object(["type": .string("string"), "description": .string("Optional block ID to insert after (legacy param; prefer `position: after:{id}`).")]),
                    "position": .object(["type": .string("string"), "description": .string("Optional insert position (API 2026-03-11): `start`, `end` (default), or `after:{blockId}`.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId"), .string("children")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"],
                      case .string(let childrenJSON) = args["children"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_blocks_append", reason: "missing 'blockId' or 'children'")
                }

                guard let childrenData = childrenJSON.data(using: .utf8) else {
                    return .object(["error": .string("Invalid JSON in 'children'")])
                }

                // API 2026-03-11 position resolution:
                //   1. Explicit `position` string wins: "start" | "end" | "after:{blockId}".
                //   2. Legacy `afterBlock` param falls through to `.afterBlock(id:)`.
                //   3. Default is `.end` (omits position).
                let insertPosition: AppendBlocksPosition = {
                    if case .string(let raw) = args["position"] {
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = trimmed.lowercased()
                        if lower == "start" { return .start }
                        if lower == "end" { return .end }
                        if lower.hasPrefix("after:") {
                            let id = String(trimmed.dropFirst("after:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !id.isEmpty { return .afterBlock(id: id) }
                        }
                    }
                    if case .string(let afterId) = args["afterBlock"], !afterId.isEmpty {
                        return .afterBlock(id: afterId)
                    }
                    return .end
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.appendBlocks(blockId: blockId, children: childrenData, position: insertPosition)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse append response")])
                }

                var resultItems: [Value] = []
                for block in results {
                    let bid = block["id"] as? String ?? ""
                    let btype = block["type"] as? String ?? ""
                    resultItems.append(.object([
                        "id": .string(bid),
                        "type": .string(btype)
                    ]))
                }

                return .object([
                    "success": .bool(true),
                    "blocksAppended": .int(results.count),
                    "results": .array(resultItems)
                ])
            }
        ))

        // MARK: 7. notion_block_delete – notify (A6)
        await router.register(ToolRegistration(
            name: "notion_block_delete",
            module: moduleName,
            tier: .notify,
            description: "Soft-delete a block (recoverable from Notion's trash). Reversible.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Block ID to delete")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_block_delete", reason: "missing 'blockId'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.deleteBlock(blockId: blockId)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse delete response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? blockId),
                    "in_trash": .bool(json["in_trash"] as? Bool ?? true)
                ])
            }
        ))

        // MARK: 8. notion_page_markdown_read – open (A7)
        await router.register(ToolRegistration(
            name: "notion_page_markdown_read",
            module: moduleName,
            tier: .open,
            description: "Read a Notion page body as plain markdown only — no properties, no block IDs. Use when you just need the text.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_markdown_read", reason: "missing 'pageId'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.getPageMarkdown(pageId: pageId)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    return .object(["markdown": .string(text)])
                }

                let markdown = json["markdown"] as? String ?? String(data: data, encoding: .utf8) ?? ""
                return .object(["markdown": .string(markdown)])
            }
        ))
        // (MARK 9 removed: notion_page_markdown_write — D3 v1.8.0)
        // MARK: 10. notion_comments_list – open (A9a)
        await router.register(ToolRegistration(
            name: "notion_comments_list",
            module: moduleName,
            tier: .open,
            description: "List all comments on a Notion page or specific block (threaded discussions included).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Page or block ID to list comments for")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default: 100)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comments_list", reason: "missing 'blockId'")
                }
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 100 }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.listComments(blockId: blockId, pageSize: pageSize)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse comments response")])
                }

                var comments: [Value] = []
                for comment in results {
                    let id = comment["id"] as? String ?? ""
                    let createdTime = comment["created_time"] as? String ?? ""
                    var text = ""
                    if let richText = comment["rich_text"] as? [[String: Any]] {
                        text = NotionJSON.extractPlainText(from: richText)
                    }
                    var createdBy = ""
                    if let user = comment["created_by"] as? [String: Any] {
                        createdBy = user["id"] as? String ?? ""
                    }
                    comments.append(.object([
                        "id": .string(id),
                        "text": .string(text),
                        "created_time": .string(createdTime),
                        "created_by": .string(createdBy)
                    ]))
                }

                return .object([
                    "count": .int(comments.count),
                    "comments": .array(comments)
                ])
            }
        ))

        // MARK: 11. notion_comment_create – notify (A9b)
        await router.register(ToolRegistration(
            name: "notion_comment_create",
            module: moduleName,
            tier: .notify,
            description: "Post a top-level inline-only markdown comment on a Notion page. Preflights Notion's 2000-character rich_text run limit. For threaded replies use notion_discussion_create.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Page ID to comment on")]),
                    "text": .object(["type": .string("string"), "description": .string("Comment text content")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("text")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let text) = args["text"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_create", reason: "missing 'pageId' or 'text'")
                }

                let maxChars = 2000
                if text.count > maxChars {
                    return .object([
                        "success": .bool(false),
                        "error": .string("notion_comment_create: rich_text.text.content exceeds Notion's 2000-character per-run limit"),
                        "maxChars": .int(maxChars),
                        "actualChars": .int(text.count),
                        "hint": .string("Split long comments into multiple shorter comments or use notion_code_block_append for long code/text blocks. Comments support inline-only markdown, not block markdown.")
                    ])
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.createComment(pageId: pageId, text: text)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse comment response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? "")
                ])
            }
        ))

        // MARK: 12. notion_users_list – open (A10)
        await router.register(ToolRegistration(
            name: "notion_users_list",
            module: moduleName,
            tier: .open,
            description: "List all people (members + guests) in the Notion workspace with their IDs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default: 100)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 100 }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.listUsers(pageSize: pageSize)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse users response")])
                }

                var users: [Value] = []
                for user in results {
                    let id = user["id"] as? String ?? ""
                    let name = user["name"] as? String ?? ""
                    let type = user["type"] as? String ?? ""
                    var email = ""
                    if let person = user["person"] as? [String: Any] {
                        email = person["email"] as? String ?? ""
                    }
                    users.append(.object([
                        "id": .string(id),
                        "name": .string(name),
                        "type": .string(type),
                        "email": .string(email)
                    ]))
                }

                return .object([
                    "count": .int(users.count),
                    "users": .array(users)
                ])
            }
        ))

        // MARK: 13. notion_page_move – notify (A11)
        await router.register(ToolRegistration(
            name: "notion_page_move",
            module: moduleName,
            tier: .notify,
            description: "Reparent a Notion page to a new page, database, or data source. Does not copy — moves the canonical page.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Page ID to move")]),
                    "newParentId": .object(["type": .string("string"), "description": .string("New parent page or database ID")]),
                    "parentType": .object(["type": .string("string"), "description": .string("Parent type: 'page_id', 'database_id', or 'data_source_id' (default: page_id)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("newParentId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let newParentId) = args["newParentId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_move", reason: "missing 'pageId' or 'newParentId'")
                }

                let parentType: String = {
                    if case .string(let pt) = args["parentType"] { return pt }
                    return "page_id"
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.movePage(pageId: pageId, newParentId: newParentId, parentType: parentType)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse move response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? pageId),
                    "url": .string(json["url"] as? String ?? "")
                ])
            }
        ))

        // MARK: 14. notion_file_upload – notify (A12)
        await router.register(ToolRegistration(
            name: "notion_file_upload",
            module: moduleName,
            tier: .notify,
            description: "Upload a local Mac file and return a Notion-hosted file reference for use in file / image / pdf blocks. Optional trace=true returns safe create_upload vs send_content diagnostics.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filePath": .object(["type": .string("string"), "description": .string("Absolute path to the local file")]),
                    "trace": .object(["type": .string("boolean"), "description": .string("If true, include safe phase diagnostics for create_upload and send_content failures/success.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("filePath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let filePath) = args["filePath"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_file_upload", reason: "missing 'filePath'")
                }

                guard let fileData = FileManager.default.contents(atPath: filePath) else {
                    return .object(["error": .string("File not found or unreadable: \(filePath)")])
                }

                guard fileData.count <= 20 * 1024 * 1024 else {
                    return .object(["error": .string("File exceeds 20MB limit (\(fileData.count) bytes)")])
                }

                let fileName = (filePath as NSString).lastPathComponent
                let ext = (fileName as NSString).pathExtension.lowercased()
                let contentType: String = {
                    switch ext {
                    case "pdf": return "application/pdf"
                    case "png": return "image/png"
                    case "jpg", "jpeg": return "image/jpeg"
                    case "gif": return "image/gif"
                    case "txt": return "text/plain"
                    case "json": return "application/json"
                    case "csv": return "text/csv"
                    case "mp4": return "video/mp4"
                    case "mov": return "video/quicktime"
                    case "mp3": return "audio/mpeg"
                    case "wav": return "audio/wav"
                    case "m4a": return "audio/mp4"
                    case "ogg": return "audio/ogg"
                    case "webm": return "video/webm"
                    case "webp": return "image/webp"
                    case "svg": return "image/svg+xml"
                    case "html", "htm": return "text/html"
                    case "xml": return "text/xml"
                    case "zip": return "application/zip"
                    case "md": return "text/markdown"
                    default: return "application/octet-stream"
                    }
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let includeTrace: Bool = { if case .bool(let b) = args["trace"] { return b }; return false }()
                let upload = try await client.uploadFileWithTrace(fileName: fileName, fileData: fileData, contentType: contentType)

                guard let json = try? JSONSerialization.jsonObject(with: upload.data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse upload response")])
                }

                var result: [String: Value] = [
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? ""),
                    "status": .string(json["status"] as? String ?? "unknown")
                ]
                if includeTrace { result["trace"] = .array(upload.trace.map { .string($0) }) }
                return .object(result)
            }
        ))

        // MARK: 15. notion_token_introspect – open (A13)
        await router.register(ToolRegistration(
            name: "notion_token_introspect",
            module: moduleName,
            tier: .open,
            description: "Introspect the current Notion connection: returns workspace name, bot identity, and granted scopes.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.introspectToken()

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse introspect response")])
                }

                var result: [String: Value] = [:]
                if let botId = json["bot_id"] as? String { result["bot_id"] = .string(botId) }
                if let type = json["type"] as? String { result["type"] = .string(type) }
                if let workspace = json["workspace_name"] as? String { result["workspace_name"] = .string(workspace) }
                if let owner = json["owner"] as? [String: Any] {
                    result["owner"] = .string(NotionJSON.prettyPrint(owner))
                }
                result["raw"] = .string(NotionJSON.prettyPrint(json))

                return .object(result)
            }
        ))

        // MARK: 16. notion_connections_list – open (B4)
        await router.register(ToolRegistration(
            name: "notion_connections_list",
            module: moduleName,
            tier: .open,
            description: "List saved Notion workspace connections registered with the bridge. For all bridge connections use connections_list.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let connList = try await registryHolder.listConnections()

                var items: [Value] = []
                for conn in connList {
                    items.append(.object([
                        "name": .string(conn.name),
                        "primary": .bool(conn.isPrimary),
                        "status": .string(conn.status),
                        "token": .string(conn.maskedToken)
                    ]))
                }

                return .object([
                    "count": .int(items.count),
                    "connections": .array(items)
                ])
            }
        ))

        // MARK: 17. notion_block_read - open (A14, v1.7.0)
        await router.register(ToolRegistration(
            name: "notion_block_read",
            module: moduleName,
            tier: .open,
            description: "Fetch one block by ID with full raw block JSON (type, content, children flag). Use for surgical edits.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object([
                        "type": .string("string"),
                        "description": .string("Block ID to retrieve")
                    ]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_block_read", reason: "missing 'blockId'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.getBlock(blockId: blockId)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse block response")])
                }

                let id = json["id"] as? String ?? ""
                let type = json["type"] as? String ?? ""
                let hasChildren = json["has_children"] as? Bool ?? false
                let text = NotionJSON.extractPlainTextFromBlock(json)

                var result: [String: Value] = [
                    "id": .string(id),
                    "type": .string(type),
                    "has_children": .bool(hasChildren),
                    "text": .string(text)
                ]

                // Include full type-specific payload as JSON string
                if let typeData = json[type] {
                    if let jsonData = try? JSONSerialization.data(withJSONObject: typeData, options: [.sortedKeys]),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        result["raw"] = .string(jsonStr)
                    }
                }

                return .object(result)
            }
        ))

        // MARK: 18. notion_block_update - notify (A15, v1.7.0)
        await router.register(ToolRegistration(
            name: "notion_block_update",
            module: moduleName,
            tier: .notify,
            description: "Replace one block's inline content / type payload. For code blocks prefer notion_code_block_append (handles 2000-char chunking).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object([
                        "type": .string("string"),
                        "description": .string("Block ID to update")
                    ]),
                    "data": .object([
                        "type": .string("string"),
                        "description": .string("JSON string of block update payload (e.g. type-specific content)")
                    ]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId"), .string("data")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"],
                      case .string(let dataStr) = args["data"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_block_update", reason: "missing 'blockId' or 'data'")
                }

                guard let bodyData = dataStr.data(using: .utf8),
                      let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                    return .object(["error": .string("Invalid JSON in 'data' parameter")])
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let responseData = try await client.updateBlock(blockId: blockId, data: body)

                guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse update response")])
                }

                let id = json["id"] as? String ?? ""
                let type = json["type"] as? String ?? ""

                return .object([
                    "id": .string(id),
                    "type": .string(type),
                    "updated": .bool(true)
                ])
            }
        ))

        // MARK: 19. notion_database_get - open (B1, v1.8.0)
        await router.register(ToolRegistration(
            name: "notion_database_get",
            module: moduleName,
            tier: .open,
            description: "Get database-level metadata (title, icon, data sources). For column schema call notion_datasource_get.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "databaseId": .object(["type": .string("string"), "description": .string("Database ID (with or without hyphens)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("databaseId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dbId) = args["databaseId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_database_get", reason: "missing 'databaseId'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.getDatabase(databaseId: dbId)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse database response")])
                }

                let id = json["id"] as? String ?? ""
                let url = json["url"] as? String ?? ""
                var title = "Untitled"
                if let titleArr = json["title"] as? [[String: Any]] {
                    title = titleArr.compactMap { $0["plain_text"] as? String }.joined()
                }
                let icon = json["icon"] as? [String: Any]
                let iconType = icon?["type"] as? String ?? ""
                let iconValue: String = {
                    if iconType == "emoji" { return icon?["emoji"] as? String ?? "" }
                    if iconType == "external" {
                        return (icon?["external"] as? [String: Any])?["url"] as? String ?? ""
                    }
                    return ""
                }()

                var parentInfo: [String: Value] = [:]
                if let parent = json["parent"] as? [String: Any],
                   let parentType = parent["type"] as? String {
                    parentInfo["type"] = .string(parentType)
                    if let pid = parent[parentType] as? String {
                        parentInfo["id"] = .string(pid)
                    }
                }

                return .object([
                    "id": .string(id),
                    "title": .string(title),
                    "url": .string(url),
                    "icon": .object(["type": .string(iconType), "value": .string(iconValue)]),
                    "parent": .object(parentInfo)
                ])
            }
        ))

        // MARK: 20. notion_datasource_get - open (B2, v1.8.0)
        await router.register(ToolRegistration(
            name: "notion_datasource_get",
            module: moduleName,
            tier: .open,
            description: "Get a data source's column schema (property names, types, select options). Required before notion_query or property writes.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Data source ID (with or without hyphens)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("dataSourceId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dsId) = args["dataSourceId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_datasource_get", reason: "missing 'dataSourceId'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.getDataSource(dataSourceId: dsId)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse data source response")])
                }

                let id = json["id"] as? String ?? ""
                let name = json["name"] as? String ?? "Untitled"

                // Extract properties/schema
                var schemaItems: [Value] = []
                if let properties = json["properties"] as? [String: [String: Any]] {
                    for (propName, propDef) in properties.sorted(by: { $0.key < $1.key }) {
                        let propId = propDef["id"] as? String ?? ""
                        let propType = propDef["type"] as? String ?? ""
                        var item: [String: Value] = [
                            "name": .string(propName),
                            "id": .string(propId),
                            "type": .string(propType)
                        ]
                        // Include select/multi_select/status options if present
                        if let typeConfig = propDef[propType] as? [String: Any],
                           let options = typeConfig["options"] as? [[String: Any]] {
                            item["options"] = .array(options.compactMap { opt in
                                guard let optName = opt["name"] as? String else { return nil }
                                return .string(optName)
                            })
                        }
                        if let typeConfig = propDef[propType] as? [String: Any],
                           let groups = typeConfig["groups"] as? [[String: Any]] {
                            item["groups"] = .array(groups.compactMap { grp in
                                guard let grpName = grp["name"] as? String else { return nil }
                                return .string(grpName)
                            })
                        }
                        schemaItems.append(.object(item))
                    }
                }

                return .object([
                    "id": .string(id),
                    "name": .string(name),
                    "schema": .array(schemaItems)
                ])
            }
        ))

        // MARK: 21. notion_datasource_update - notify (B3, v1.8.5)
        await router.register(ToolRegistration(
            name: "notion_datasource_update",
            module: moduleName,
            tier: .notify,
            description: "Add or modify columns on one data source's schema. Scope is isolated to this data source — sibling data sources unaffected.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Data source ID (with or without hyphens)")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of properties to add or update (Notion API format)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("dataSourceId"), .string("properties")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dsId) = args["dataSourceId"],
                      case .string(let propsJSON) = args["properties"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_datasource_update", reason: "missing 'dataSourceId' or 'properties'")
                }

                guard let propsData = propsJSON.data(using: .utf8),
                      let propsObj = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any] else {
                    return .object(["error": .string("Invalid JSON in 'properties' parameter")])
                }

                let envelope: [String: Any] = ["properties": propsObj]
                let envelopeData = try JSONSerialization.data(withJSONObject: envelope)

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let resultData = try await client.updateDataSource(dataSourceId: dsId, properties: envelopeData)

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse update response")])
                }

                let id = resultJSON["id"] as? String ?? dsId
                var name = "Untitled"
                if let titleArr = resultJSON["title"] as? [[String: Any]] {
                    name = titleArr.compactMap { $0["plain_text"] as? String }.joined()
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(id),
                    "name": .string(name)
                ])
            }
        ))

        // MARK: 22. notion_datasource_create - notify (B4, v1.8.5)
        await router.register(ToolRegistration(
            name: "notion_datasource_create",
            module: moduleName,
            tier: .notify,
            description: "Create a new data source (schema) under an existing database or page parent.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "databaseId": .object(["type": .string("string"), "description": .string("Parent database or page ID (page ID supported as of v1.9.1 when parentType='page_id')")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of property schema definitions (Notion API format)")]),
                    "title": .object(["type": .string("string"), "description": .string("Optional name for the new data source")]),
                    "parentType": .object(["type": .string("string"), "description": .string("Parent type: 'database_id' (default) or 'page_id'. v1.9.1 B2+E1.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("databaseId"), .string("properties")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dbId) = args["databaseId"],
                      case .string(let propsJSON) = args["properties"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_datasource_create", reason: "missing 'databaseId' or 'properties'")
                }

                guard let propsData = propsJSON.data(using: .utf8) else {
                    return .object(["error": .string("Invalid JSON in 'properties'")])
                }

                let title: String? = {
                    if case .string(let t) = args["title"] { return t }
                    return nil
                }()

                let parentType: String = {
                    if case .string(let pt) = args["parentType"] { return pt }
                    return "database_id"
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let resultData = try await client.createDataSource(databaseId: dbId, properties: propsData, title: title, parentType: parentType)

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse create response")])
                }

                let id = resultJSON["id"] as? String ?? ""
                var name = "Untitled"
                if let titleArr = resultJSON["title"] as? [[String: Any]] {
                    name = titleArr.compactMap { $0["plain_text"] as? String }.joined()
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(id),
                    "name": .string(name)
                ])
            }
        ))

        // MARK: 23. notion_discussion_create – notify (E5, v1.9.1)
        // Starts a NEW discussion thread on a page. Same endpoint as notion_comment_create
        // (POST /v1/comments) but semantically distinct: no discussion_id hint, so Notion
        // creates a fresh thread. Accepts compressed URLs via normalizePageId (v1.9.0 B3).
        await router.register(ToolRegistration(
            name: "notion_discussion_create",
            module: moduleName,
            tier: .notify,
            description: "Start a new threaded discussion on a Notion page (accepts compressed URLs, UUIDs, or full Notion URLs). Initial comment is inline-only markdown and preflights Notion's 2000-character rich_text run limit.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Page ID, URL, or compressed placeholder to start the discussion on")]),
                    "text": .object(["type": .string("string"), "description": .string("Initial comment text for the discussion thread")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("text")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let text) = args["text"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_discussion_create", reason: "missing 'pageId' or 'text'")
                }

                let maxChars = 2000
                if text.count > maxChars {
                    return .object([
                        "success": .bool(false),
                        "error": .string("notion_discussion_create: rich_text.text.content exceeds Notion's 2000-character per-run limit"),
                        "maxChars": .int(maxChars),
                        "actualChars": .int(text.count),
                        "hint": .string("Split long discussion starters into shorter comments or move long structured content into the page body/code block. Comments support inline-only markdown, not block markdown.")
                    ])
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.createDiscussion(pageId: pageId, text: text)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse discussion response")])
                }

                let id = json["id"] as? String ?? ""
                let discussionId = json["discussion_id"] as? String ?? ""

                return .object([
                    "success": .bool(true),
                    "id": .string(id),
                    "discussionId": .string(discussionId)
                ])
            }
        ))

        // MARK: 24. notion_code_block_append – notify (E3, v1.9.1)
        // Auto-chunks long strings into ≤2000-char rich_text runs inside a single code
        // block via PATCH /v1/blocks/{id}. Target block must already be a code block.
        await router.register(ToolRegistration(
            name: "notion_code_block_append",
            module: moduleName,
            tier: .notify,
            description: "Replace a code block's content with a long string, auto-chunking into ≤2000-char runs. Target must already be type 'code'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Target code block ID, URL, or compressed placeholder")]),
                    "content": .object(["type": .string("string"), "description": .string("Full content string; auto-chunked into 2000-char runs")]),
                    "language": .object(["type": .string("string"), "description": .string("Optional code language (e.g. swift, typescript, plain text)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId"), .string("content")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"],
                      case .string(let content) = args["content"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_code_block_append", reason: "missing 'blockId' or 'content'")
                }

                let language: String? = {
                    if case .string(let l) = args["language"] { return l }
                    return nil
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let responseData = try await client.updateCodeBlockChunked(blockId: blockId, content: content, language: language)

                guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse code block update response")])
                }

                let id = json["id"] as? String ?? ""
                let type = json["type"] as? String ?? ""
                let chunkCount = (content.count + 1999) / 2000

                return .object([
                    "success": .bool(true),
                    "id": .string(id),
                    "type": .string(type),
                    "chunkCount": .int(max(chunkCount, 1))
                ])
            }
        ))
    }
}

// MARK: - Lazy Registry Holder


/// Routes MCP tool calls to `NotionClientRegistry.shared` so Settings and tools share one registry
/// (factory reset can clear in-memory state in one place).
private final class NotionRegistryHolder: @unchecked Sendable {
    func getClient(workspace: String?) async throws -> NotionClient {
        try await NotionClientRegistry.shared.getClient(workspace: workspace)
    }

    func listConnections() async throws -> [NotionConnectionInfo] {
        try await NotionClientRegistry.shared.listConnections()
    }
}
