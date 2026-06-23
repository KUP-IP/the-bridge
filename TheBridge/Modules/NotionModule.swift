// NotionModule.swift – V1-05 → V1-12 → PKT-367 Notion Integration Tools
// TheBridge · Modules
//
// 24 tools via NotionClientRegistry for multi-workspace support.
// PKT-320: Updated references from NOTION_API_KEY to NOTION_API_TOKEN
// PKT-367: 13 new tools, NotionClientRegistry integration, optional workspace param
// FB-notionwrite: notion_page_edit — surgical in-place old_str/new_str body edits
//   (mirrors official MCP update_content), reusing the MARK 9 slot.

import Foundation
import MCP

// MARK: - NotionQueryProjection (v3.0·0.5, PKT — agentic-usability)

/// Pure, testable helper for the notion_query `properties` projection.
/// AGENT_FEEDBACK + the v3.0·0.4 reflow both hit the same tax: results
/// carried only id/title/url, so bucketing by Status forced N extra
/// status-filtered queries. Given the requested column names, return the
/// raw Notion property JSON (lossless string) per key so one query
/// suffices.
public enum NotionQueryProjection {
    public static func pick(_ properties: [String: Any], keys: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in keys {
            guard let v = properties[key],
                  let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]),
                  let s = String(data: d, encoding: .utf8) else { continue }
            out[key] = s
        }
        return out
    }
}

/// Pure, testable builder for the notion_query PROJECT-relation server-side
/// filter (fb-resultsize). Evidence (05-20/22, 06-02): PACKETS queries that
/// can't filter by their parent PROJECT relation dump every workspace packet
/// and blow token caps. Passing `relationProperty` + `relationContainsId`
/// builds a Notion relation `contains` filter so the API returns only the
/// matching rows inline — no client-side fan-out, no whole-database dump.
///
/// When the caller ALSO supplies a `filter`, the two are AND-merged (the
/// relation predicate is appended to the existing `and` array, or both are
/// wrapped in a fresh `and`) so the server-side narrowing composes with any
/// status/date predicate the agent already has.
public enum NotionRelationFilter {
    /// Build the relation `contains` predicate object for one relation column.
    public static func relationContains(property: String, pageId: String) -> [String: Any] {
        ["property": property, "relation": ["contains": pageId]]
    }

    /// AND-merge a relation predicate into an OPTIONAL existing filter (the
    /// raw JSON string from the `filter` arg). Returns the merged filter as a
    /// dictionary ready to re-serialize. Pure; never throws.
    ///
    /// - existing `nil`/empty → just the relation predicate.
    /// - existing is `{ "and": [...] }` → relation appended to the array.
    /// - existing is any other single predicate / `{ "or": [...] }` → both
    ///   wrapped in a new `{ "and": [existing, relation] }`.
    public static func merge(existingJSON: String?, property: String, pageId: String) -> [String: Any] {
        let relation = relationContains(property: property, pageId: pageId)
        guard let existingJSON,
              !existingJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = existingJSON.data(using: .utf8),
              let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !existing.isEmpty else {
            return relation
        }
        if var andArray = existing["and"] as? [[String: Any]] {
            andArray.append(relation)
            return ["and": andArray]
        }
        return ["and": [existing, relation]]
    }

    /// `merge` + re-serialize to the JSON Data the client's `filter` argument
    /// expects. Returns `nil` only if serialization fails (never in practice).
    public static func mergeData(existingJSON: String?, property: String, pageId: String) -> Data? {
        let merged = merge(existingJSON: existingJSON, property: property, pageId: pageId)
        return try? JSONSerialization.data(withJSONObject: merged)
    }
}

// MARK: - NotionModule

/// Provides Notion workspace integration tools.
/// Uses NotionClientRegistry for multi-workspace token management.
public enum NotionModule {

    public static let moduleName = "notion"

    /// WS-3: Extract the EMOJI icon from a Notion page/database JSON object
    /// (the parsed `getPage` response). Returns the emoji glyph (e.g. "✨")
    /// for an `icon.type == "emoji"` icon, and `nil` otherwise.
    ///
    /// EMOJI ONLY by design: an `external`- or `file`-typed (uploaded image)
    /// icon returns `nil` — image icons are explicitly out of scope this
    /// pass (no image downloader). A missing/blank emoji also returns `nil`.
    /// Pure + deterministic; safe to call on any decoded page JSON.
    public static func extractIconEmoji(from pageJSON: [String: Any]) -> String? {
        guard let icon = pageJSON["icon"] as? [String: Any],
              (icon["type"] as? String) == "emoji",
              let emoji = icon["emoji"] as? String else {
            return nil
        }
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default: 25, max: 100). Lowered default keeps large data sources under token caps — page with startCursor for more.")]),
                    "startCursor": .object(["type": .string("string"), "description": .string("Pagination cursor from previous query")]),
                    "properties": .object(["type": .string("array"), "description": .string("Optional column names to project into each result row (raw Notion property JSON). Avoids N follow-up reads to bucket by Status/etc.")]),
                    "compact": .object(["type": .string("boolean"), "description": .string("When true, each row is id + title only (drops url and any projection) — the smallest result shape, for high-volume scans that only need to enumerate/identify rows. Default false.")]),
                    "relationProperty": .object(["type": .string("string"), "description": .string("Relation column name (e.g. 'Project') to filter on server-side. Pair with relationContainsId — the API returns only rows whose relation contains that page, so e.g. a PACKETS query scoped to one PROJECT comes back inline instead of dumping every packet. AND-merges with `filter` if both are given.")]),
                    "relationContainsId": .object(["type": .string("string"), "description": .string("Related page ID the relationProperty must contain (the PROJECT page id). Requires relationProperty.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("dataSourceId")])
            ]),
            metadata: ToolMetadata(
                title: "Notion: Query Data Source",
                whenToUse: ["filtering/sorting rows of a Notion database",
                            "need specific columns back — pass `properties` to avoid N follow-up reads",
                            "scope a PACKETS-style query to one PROJECT — pass `relationProperty` + `relationContainsId` so it returns inline",
                            "high-volume scan that only needs id + title — pass `compact: true`"],
                whenNotToUse: ["reading one page's body (use notion_page_markdown_read)",
                               "discovering column names first (use notion_datasource_get)"],
                relatedTools: ["notion_datasource_get", "notion_page_read", "notion_page_markdown_read"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dsId) = args["dataSourceId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_query", reason: "missing 'dataSourceId'")
                }

                // fb-resultsize: default lowered 100 → 25 so high-volume data
                // sources don't blow token caps; clamped to 100, floored at 1.
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return max(1, min(ps, 100)) }; return 25 }()
                let startCursor: String? = { if case .string(let c) = args["startCursor"] { return c }; return nil }()
                let compact: Bool = { if case .bool(let b) = args["compact"] { return b }; return false }()
                let projection: [String] = {
                    if case .array(let arr)? = args["properties"] {
                        return arr.compactMap { if case .string(let s) = $0 { return s }; return nil }
                    }
                    return []
                }()

                // fb-resultsize: optional PROJECT-relation server-side filter.
                let relationProperty: String? = { if case .string(let s) = args["relationProperty"] { return s }; return nil }()
                let relationContainsId: String? = { if case .string(let s) = args["relationContainsId"] { return s }; return nil }()
                let rawFilterString: String? = { if case .string(let f) = args["filter"] { return f }; return nil }()

                var filterData: Data? = nil
                if let prop = relationProperty, let relId = relationContainsId,
                   !prop.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !relId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // AND-merge the relation predicate with any explicit filter
                    // so PACKETS-by-PROJECT comes back inline, not the whole DB.
                    filterData = NotionRelationFilter.mergeData(
                        existingJSON: rawFilterString, property: prop, pageId: relId
                    )
                } else if let f = rawFilterString {
                    filterData = f.data(using: .utf8)
                }
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
                    // fb-resultsize: compact mode → id + title only (smallest
                    // shape). Drops url and any projection.
                    if compact {
                        items.append(.object(["id": .string(id), "title": .string(title)]))
                        continue
                    }
                    var row: [String: Value] = [
                        "id": .string(id),
                        "title": .string(title),
                        "url": .string(url)
                    ]
                    if !projection.isEmpty,
                       let props = result["properties"] as? [String: Any] {
                        let picked = NotionQueryProjection.pick(props, keys: projection)
                        if !picked.isEmpty {
                            row["properties"] = .object(picked.mapValues { .string($0) })
                        }
                    }
                    items.append(.object(row))
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
        // After changing registration or behavior, reload TheBridge (sk mac ops) so MCP clients list the updated tool.
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
            description: "Soft-delete one block (`blockId`) or many (`blockIds` array) — recoverable from Notion's trash. Bulk deletes run sequentially with per-id status and partial-failure reporting.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Single block ID to delete")]),
                    "blockIds": .object([
                        "type": .string("array"),
                        "description": .string("Optional array of block IDs to delete sequentially; returns per-id status."),
                        "items": .object(["type": .string("string")])
                    ]),
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_block_delete", reason: "missing arguments")
                }

                // FB-6: Resolve targets — either a `blockIds` array (bulk) or a single `blockId`.
                let isBulk: Bool
                var blockIds: [String] = []
                if case .array(let arr)? = args["blockIds"] {
                    isBulk = true
                    for v in arr { if case .string(let s) = v { blockIds.append(s) } }
                } else if case .string(let single)? = args["blockId"] {
                    isBulk = false
                    blockIds = [single]
                } else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_block_delete", reason: "missing 'blockId' or 'blockIds'")
                }

                if blockIds.isEmpty {
                    throw ToolRouterError.invalidArguments(toolName: "notion_block_delete", reason: "'blockIds' must contain at least one block ID")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))

                // Single-block back-compat path: identical response shape as before.
                if !isBulk {
                    let blockId = blockIds[0]
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

                // Bulk path: delete sequentially, capture per-id status, never abort on one failure.
                var results: [Value] = []
                var deleted = 0
                var failed = 0
                for blockId in blockIds {
                    do {
                        let data = try await client.deleteBlock(blockId: blockId)
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        deleted += 1
                        results.append(.object([
                            "id": .string((json?["id"] as? String) ?? blockId),
                            "success": .bool(true),
                            "in_trash": .bool((json?["in_trash"] as? Bool) ?? true)
                        ]))
                    } catch {
                        failed += 1
                        results.append(.object([
                            "id": .string(blockId),
                            "success": .bool(false),
                            "error": .string("\(error)")
                        ]))
                    }
                }

                return .object([
                    "success": .bool(failed == 0),
                    "requested": .int(blockIds.count),
                    "deleted": .int(deleted),
                    "failed": .int(failed),
                    "results": .array(results)
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
        // MARK: 9. notion_page_edit – notify (FB-notionwrite)
        // Surgical in-place body edit mirroring the official MCP `update_content`:
        // read the page markdown, apply ordered literal old_str→new_str edits in
        // process, then write the edited body back via PATCH .../markdown
        // (replace_content). This replaces the block-append-only amendment sprawl
        // that the deprecated whole-page markdown_write (D3 v1.8.0) invited — every
        // wire write is the full, intentionally-edited body, never a blind overwrite.
        await router.register(ToolRegistration(
            name: "notion_page_edit",
            module: moduleName,
            tier: .notify,
            description: "Surgically edit a Notion page body in place via literal old_str→new_str find/replace (mirrors the official MCP update_content). Reads the page markdown, applies your edits in order, then writes the edited body back. Each old_str must match the current markdown exactly; unmatched edits fail the call without writing. Use notion_page_markdown_read first to copy exact snippets. For pure appends use notion_blocks_append.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID (with or without hyphens)")]),
                    "edits": .object([
                        "type": .string("array"),
                        "description": .string("Ordered search/replace edits applied to the page markdown. Each item: {\"old_str\": exact existing text, \"new_str\": replacement, optional \"replaceAll\": bool (default false = first match only)}."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "old_str": .object(["type": .string("string"), "description": .string("Exact existing markdown to find. Must match verbatim.")]),
                                "new_str": .object(["type": .string("string"), "description": .string("Replacement markdown.")]),
                                "replaceAll": .object(["type": .string("boolean"), "description": .string("Replace every occurrence (default false = first only).")])
                            ]),
                            "required": .array([.string("old_str"), .string("new_str")])
                        ])
                    ]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("edits")])
            ]),
            metadata: ToolMetadata(
                title: "Notion: Edit Page Body",
                whenToUse: ["amending existing page text in place (rename a heading, fix a sentence, update a value)",
                            "avoiding append-only block sprawl when correcting prose already on the page"],
                whenNotToUse: ["adding brand-new content to the end of a page (use notion_blocks_append)",
                               "editing one structured block by ID (use notion_block_update)",
                               "changing page properties/title/status (use notion_page_update)"],
                relatedTools: ["notion_page_markdown_read", "notion_blocks_append", "notion_block_update"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .array(let rawEdits) = args["edits"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_edit", reason: "missing 'pageId' or 'edits'")
                }

                if rawEdits.isEmpty {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_edit", reason: "'edits' must contain at least one {old_str, new_str} edit")
                }

                // Parse edits, preserving order. old_str/new_str are required strings;
                // replaceAll is optional (default false). Reject empty old_str up front —
                // it can never match and would otherwise look like a silent no-op edit.
                var edits: [NotionModule.ContentEdit] = []
                for (i, raw) in rawEdits.enumerated() {
                    guard case .object(let e) = raw,
                          case .string(let oldStr) = e["old_str"],
                          case .string(let newStr) = e["new_str"] else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_page_edit", reason: "edit[\(i)] must be an object with string 'old_str' and 'new_str'")
                    }
                    if oldStr.isEmpty {
                        throw ToolRouterError.invalidArguments(toolName: "notion_page_edit", reason: "edit[\(i)] 'old_str' must not be empty")
                    }
                    let replaceAll: Bool = { if case .bool(let b) = e["replaceAll"] { return b }; return false }()
                    edits.append(NotionModule.ContentEdit(oldStr: oldStr, newStr: newStr, replaceAll: replaceAll))
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))

                // 1. Read current body.
                let readData = try await client.getPageMarkdown(pageId: pageId)
                let currentMarkdown: String = {
                    if let json = try? JSONSerialization.jsonObject(with: readData) as? [String: Any],
                       let md = json["markdown"] as? String { return md }
                    return String(data: readData, encoding: .utf8) ?? ""
                }()

                // 2. Apply edits in process (literal, ordered).
                let (editedMarkdown, editResults) = NotionModule.applyContentEdits(currentMarkdown, edits: edits)

                // 3. Fail fast on any unmatched old_str — never write a body whose
                //    intended edits didn't all land (mirrors the official tool's
                //    "must exactly match" guarantee). Nothing has been written yet.
                let unmatched = editResults.filter { !$0.matched }.map { $0.index }
                if !unmatched.isEmpty {
                    return .object([
                        "success": .bool(false),
                        "error": .string("No match found for old_str in edit(s) at index \(unmatched.map(String.init).joined(separator: ", ")). Read the page with notion_page_markdown_read and copy the exact text. Nothing was written."),
                        "unmatchedEdits": .array(unmatched.map { .int($0) })
                    ])
                }

                // 4. Write the edited body back.
                _ = try await client.replacePageMarkdown(pageId: pageId, markdown: editedMarkdown)

                let totalReplacements = editResults.reduce(0) { $0 + $1.replacements }
                return .object([
                    "success": .bool(true),
                    "editsApplied": .int(edits.count),
                    "replacements": .int(totalReplacements)
                ])
            }
        ))
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
            description: "Post a top-level inline-only markdown comment on a Notion page. Text over Notion's 2000-character per-run limit is auto-chunked into sequential comments preserving order. For threaded replies use notion_discussion_create.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Page ID to comment on")]),
                    "text": .object(["type": .string("string"), "description": .string("Comment text content")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("text")])
            ]),
            metadata: ToolMetadata(
                title: "Notion: Create Comment",
                whenToUse: ["posting a short inline comment on a page"],
                whenNotToUse: ["threaded replies (use notion_discussion_create)",
                               "long code/text (use notion_blocks_append with autoChunk:true)"],
                relatedTools: ["notion_discussion_create", "notion_comments_list"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let text) = args["text"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_create", reason: "missing 'pageId' or 'text'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))

                // FB-3: Auto-chunk into sequential <=2000-char comments preserving order,
                // instead of hard-rejecting. Notion enforces a 2000-character per-run limit;
                // post one comment per chunk and report all created IDs in order.
                let chunks = NotionModule.chunkCommentText(text, maxChars: 2000)

                var ids: [Value] = []
                for chunk in chunks {
                    let data = try await client.createComment(pageId: pageId, text: chunk)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .object([
                            "success": .bool(false),
                            "error": .string("Failed to parse comment response"),
                            "postedChunks": .int(ids.count),
                            "totalChunks": .int(chunks.count),
                            "ids": .array(ids)
                        ])
                    }
                    ids.append(.string(json["id"] as? String ?? ""))
                }

                // Back-compat: single chunk keeps the original `id` field; multi-chunk adds `ids`.
                return .object([
                    "success": .bool(true),
                    "id": ids.first ?? .string(""),
                    "ids": .array(ids),
                    "chunks": .int(chunks.count)
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

                // PKT-739 (v2.2 · 0.2): Reject unsupported MIME early. Notion's File Upload API
                // rejects application/octet-stream with a 400 validation_error at create_upload phase;
                // surface a clearer error here listing the supported extensions.
                if contentType == "application/octet-stream" {
                    let extLabel = ext.isEmpty ? "(none)" : ext
                    return .object(["error": .string("Unsupported file extension '\(extLabel)' for notion_file_upload. The Notion File Upload API does not accept application/octet-stream. Supported extensions: pdf, png, jpg, jpeg, gif, webp, svg, mp3, m4a, mp4, mov, ogg, wav, webm, txt, json, csv, html, htm, xml, zip, md.")])
                }
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

        // Sprint A · mcp-builder #1: notion_block_read DEPRECATED shim
        // removed (PKT-738 v2.2 ramp complete; audit allows full removal).
        // Use notion_page_read for whole-page reads, or notion_block_update
        // for surgical edits.

        // MARK: 18. notion_block_update - notify (A15, v1.7.0)
        await router.register(ToolRegistration(
            name: "notion_block_update",
            module: moduleName,
            tier: .notify,
            description: "Replace one block's inline content / type payload. For code blocks prefer notion_blocks_append with autoChunk:true.",
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

        // MARK: 22b. notion_datasource_delete - request + neverAutoApprove
        //   Destructive: trashes an ENTIRE data source (a whole DB). The
        //   soft-delete is trash-recoverable, but the blast radius is a
        //   full collection, so this is human-gated (.request) AND
        //   non-auto-approvable (neverAutoApprove wins over any user tier
        //   override — see ToolRouter effectiveTier resolution), mirroring
        //   the snippets_delete posture. The in-handler confirm:true guard
        //   stays as defense-in-depth against an accidental LLM call.
        await router.register(ToolRegistration(
            name: "notion_datasource_delete",
            module: moduleName,
            tier: .request,
            neverAutoApprove: true,
            description: "Move a data source to Notion's trash (soft-delete, recoverable). Notion has no hard delete — the data source is trashed via in_trash:true. Destructive: requires confirm:true AND human approval (neverAutoApprove). Use mode:'restore' to untrash.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Data source ID (with or without hyphens)")]),
                    "mode": .object(["type": .string("string"), "description": .string("'delete' (trash, default) or 'restore' (untrash)")]),
                    "confirm": .object(["type": .string("boolean"), "description": .string("Must be true — guard against accidental deletion")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("dataSourceId"), .string("confirm")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dsId) = args["dataSourceId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_datasource_delete", reason: "missing 'dataSourceId'")
                }
                guard case .bool(true)? = args["confirm"] else {
                    return .object(["error": .string("Refused: pass confirm:true to trash a data source")])
                }
                let mode: String = {
                    if case .string(let m) = args["mode"] { return m }
                    return "delete"
                }()
                let inTrash = (mode != "restore")

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let resultData = try await client.deleteDataSource(dataSourceId: dsId, inTrash: inTrash)

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse delete response")])
                }

                let id = resultJSON["id"] as? String ?? dsId
                let trashed = resultJSON["in_trash"] as? Bool ?? inTrash
                return .object([
                    "success": .bool(true),
                    "id": .string(id),
                    "in_trash": .bool(trashed)
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

    }
}

// MARK: - NotionModule Pure Helpers

extension NotionModule {
    /// FB-notionwrite: one surgical search/replace edit for `notion_page_edit`,
    /// mirroring the official Notion MCP `update_content` op shape.
    public struct ContentEdit: Sendable, Equatable {
        public let oldStr: String
        public let newStr: String
        /// When true, replace every literal occurrence of `oldStr`; otherwise only the first.
        public let replaceAll: Bool
        public init(oldStr: String, newStr: String, replaceAll: Bool) {
            self.oldStr = oldStr
            self.newStr = newStr
            self.replaceAll = replaceAll
        }
    }

    /// Per-edit outcome from `applyContentEdits`.
    public struct ContentEditResult: Sendable, Equatable {
        public let index: Int
        public let matched: Bool
        public let replacements: Int
    }

    /// FB-notionwrite: apply ordered `old_str` → `new_str` edits to a markdown body
    /// in-process, mirroring the official MCP `update_content` semantics.
    ///
    /// Contract (matches the official tool):
    ///   - `old_str` is matched **literally** (no regex) and must appear exactly.
    ///   - Edits apply in order; each sees the result of the prior edits.
    ///   - An empty `old_str` is a no-op that never matches (guards against
    ///     accidental whole-string corruption).
    ///   - Returns the edited text plus a per-edit match/replacement report so the
    ///     caller can fail-fast on an unmatched `old_str` instead of writing a
    ///     silently-unchanged body back to Notion.
    ///
    /// Order-of-edits, first-vs-all, and unmatched cases are all covered by tests.
    public static func applyContentEdits(_ markdown: String, edits: [ContentEdit]) -> (text: String, results: [ContentEditResult]) {
        var text = markdown
        var results: [ContentEditResult] = []
        for (idx, edit) in edits.enumerated() {
            guard !edit.oldStr.isEmpty else {
                results.append(ContentEditResult(index: idx, matched: false, replacements: 0))
                continue
            }
            if edit.replaceAll {
                // Count occurrences against the current text, then replace all literally.
                var count = 0
                var search = text.startIndex
                while let r = text.range(of: edit.oldStr, range: search..<text.endIndex) {
                    count += 1
                    search = r.upperBound
                }
                if count > 0 {
                    text = text.replacingOccurrences(of: edit.oldStr, with: edit.newStr)
                }
                results.append(ContentEditResult(index: idx, matched: count > 0, replacements: count))
            } else if let r = text.range(of: edit.oldStr) {
                text.replaceSubrange(r, with: edit.newStr)
                results.append(ContentEditResult(index: idx, matched: true, replacements: 1))
            } else {
                results.append(ContentEditResult(index: idx, matched: false, replacements: 0))
            }
        }
        return (text, results)
    }

    /// FB-3: Split comment text into ordered chunks no longer than `maxChars` characters.
    /// Uses Swift `Character` counting to match the handler's `text.count` semantics, so the
    /// 2000-character boundary lines up with Notion's per-run limit. Order is preserved and
    /// concatenating the chunks reproduces the original text exactly.
    public static func chunkCommentText(_ text: String, maxChars: Int) -> [String] {
        guard maxChars > 0 else { return [text] }
        guard text.count > maxChars else { return [text] }
        var chunks: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[idx..<end]))
            idx = end
        }
        return chunks
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
