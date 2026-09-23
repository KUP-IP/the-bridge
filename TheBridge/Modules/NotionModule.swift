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

/// Pure flatten for `notion_datasource_get` schema entries (and any twin
/// dump that wants the same shape). Always emits id/name/type. Select-like
/// types keep options/groups. Formula props add a flat `expression` when
/// Notion returns `formula.expression` — omit when missing/null; never invent.
public enum NotionDataSourceSchemaFlatten {
    public static func item(name: String, definition: [String: Any]) -> [String: Value] {
        let propId = definition["id"] as? String ?? ""
        let propType = definition["type"] as? String ?? ""
        var item: [String: Value] = [
            "name": .string(name),
            "id": .string(propId),
            "type": .string(propType)
        ]
        // Include select/multi_select/status options if present
        if let typeConfig = definition[propType] as? [String: Any],
           let options = typeConfig["options"] as? [[String: Any]] {
            item["options"] = .array(options.compactMap { opt in
                guard let optName = opt["name"] as? String else { return nil }
                return .string(optName)
            })
        }
        if let typeConfig = definition[propType] as? [String: Any],
           let groups = typeConfig["groups"] as? [[String: Any]] {
            item["groups"] = .array(groups.compactMap { grp in
                guard let grpName = grp["name"] as? String else { return nil }
                return .string(grpName)
            })
        }
        // Ask 1 Option A (2026-09-23): pass formula.expression through flat.
        if propType == "formula",
           let formula = definition["formula"] as? [String: Any],
           let expression = formula["expression"] as? String {
            item["expression"] = .string(expression)
        }
        return item
    }

    public static func schema(from properties: [String: [String: Any]]) -> [Value] {
        properties.sorted(by: { $0.key < $1.key }).map { name, def in
            .object(item(name: name, definition: def))
        }
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

    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
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
    }

    /// Block-level write responses include their parent when the touched block
    /// is directly under a page. Evict both the explicit target (which may be a
    /// page id for top-level appends) and any returned page/block parent; the
    /// eviction helper itself ignores ids that are not configured skill pages.
    public static func skillCacheEvictionCandidates(
        targetId: String,
        responseJSON: [String: Any]? = nil
    ) -> [String] {
        var candidates = [targetId]
        guard let parent = responseJSON?["parent"] as? [String: Any] else { return candidates }
        for key in ["page_id", "block_id"] {
            if let parentId = parent[key] as? String {
                candidates.append(parentId)
            }
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func evictSkillBodyCache(
        targetId: String,
        responseJSON: [String: Any]? = nil
    ) async {
        for candidate in skillCacheEvictionCandidates(targetId: targetId, responseJSON: responseJSON) {
            await SkillBodyCacheEviction.evictIfConfiguredSkillPage(candidate)
            await RegistryRowCache.shared.evictPageEverywhere(pageId: candidate)
        }
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
            description: "Keyword-search a Notion workspace for pages and data sources. Unique vs hosted MCP: in_trash listing. REST filter/sort/cursor supported. Do not invent connector (Slack/Drive) search.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search query text. Optional when inTrash is true.")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results to return (default: 10, max: 100)")]),
                    "startCursor": .object(["type": .string("string"), "description": .string("Pagination cursor from a prior search.")]),
                    "objectFilter": .object(["type": .string("string"), "description": .string("REST object filter: 'page' or 'data_source' only.")]),
                    "inTrash": .object(["type": .string("boolean"), "description": .string("When true, list trashed pages/data sources (unique vs official MCP search).")]),
                    "sort": .object(["type": .string("string"), "description": .string("Optional JSON string of the REST search sort object.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_search", reason: "missing arguments")
                }
                let query: String? = { if case .string(let q) = args["query"] { return q }; return nil }()
                let inTrash: Bool? = { if case .bool(let b) = args["inTrash"] { return b }; return nil }()
                let objectFilter: String? = { if case .string(let s) = args["objectFilter"] { return s }; return nil }()
                let hasQuery = !(query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if !hasQuery && inTrash != true && (objectFilter?.isEmpty ?? true) {
                    throw ToolRouterError.invalidArguments(toolName: "notion_search", reason: "missing 'query' (or pass inTrash:true to list trash)")
                }
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 10 }()
                let startCursor: String? = { if case .string(let c) = args["startCursor"] { return c }; return nil }()
                let sortJSON: String? = { if case .string(let s) = args["sort"] { return s }; return nil }()

                let body = try NotionRESTContracts.buildSearchBody(
                    query: query, pageSize: pageSize, startCursor: startCursor,
                    objectFilter: objectFilter, inTrash: inTrash, sortJSON: sortJSON
                )
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.search(body: body)

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

                var out: [String: Value] = [
                    "query": .string(query ?? ""),
                    "count": .int(items.count),
                    "results": .array(items)
                ]
                NotionRESTContracts.mergeQueryStatus(from: json, into: &out)
                return .object(out)
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
            description: "Update a Notion page's properties only (title, status, relations). Distinguishes status applied (exact), canonicalized (Notion rewrote UUID/select/number form — still success), and rejected (field missing or value mismatch). Canonicalized-only is never reported as partially applied. For body content use notion_blocks_append / notion_block_update.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID (with or without dashes)")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of properties to update (Notion API format)")]),
                    "icon": .object(["type": .string("string"), "description": .string("Optional single emoji to set as the page icon (e.g. \"🎯\"). Emoji only — omit to leave the icon unchanged.")]),
                    "templateId": .object(["type": .string("string"), "description": .string("Apply a data-source template to this existing page (XOR with a children payload; erase_content is refused).")]),
                    "templateType": .object(["type": .string("string"), "description": .string("'template_id' or 'default'.")]),
                    "timezone": .object(["type": .string("string"), "description": .string("Timezone for template variable resolution.")]),
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
                let icon: String? = { if case .string(let e) = args["icon"] { return e }; return nil }()

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

                let templateId: String? = { if case .string(let s) = args["templateId"] { return s }; return nil }()
                let templateType: String? = { if case .string(let s) = args["templateType"] { return s }; return nil }()
                let timezone: String? = { if case .string(let s) = args["timezone"] { return s }; return nil }()
                let erase: Bool? = { if case .bool(let b) = args["eraseContent"] { return b }; return nil }()
                let resolved: (template: [String: Any]?, children: Data?)
                do {
                    resolved = try NotionRESTContracts.resolveTemplateXORChildren(
                        templateId: templateId, templateType: templateType, timezone: timezone,
                        childrenJSON: nil, eraseContent: erase
                    )
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let resultData = try await client.updatePage(pageId: pageId, properties: envelopeData, icon: icon)
                if let template = resolved.template {
                    let taskData = try await client.applyPageTemplate(pageId: pageId, template: template, allowAsync: true)
                    guard let taskJSON = try? JSONSerialization.jsonObject(with: taskData) as? [String: Any] else {
                        return .object(["error": .string("Failed to parse template apply response")])
                    }
                    if NotionRESTContracts.isAsyncTaskEnvelope(taskJSON) {
                        return NotionRESTContracts.asyncTaskValue(taskJSON)
                    }
                }

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse update response")])
                }

                let id = resultJSON["id"] as? String ?? pageId
                let url = resultJSON["url"] as? String ?? ""

                await SkillBodyCacheEviction.evictIfConfiguredSkillPage(pageId)
                await RegistryRowCache.shared.evictPageEverywhere(pageId: pageId)

                let classification = PageUpdateApplication.classify(requested: propsObj, returnedPage: resultJSON)
                var out: [String: Value] = [
                    "success": .bool(classification.success),
                    "id": .string(id),
                    "url": .string(url),
                ]
                for (k, v) in classification.asValue { out[k] = v }
                return .object(out)
            }
        ))

        // MARK: 4. notion_page_create – notify (A3)
        await router.register(ToolRegistration(
            name: "notion_page_create",
            module: moduleName,
            tier: .notify,
            description: "Create a new Notion page under a page, database, or data source parent. Returns the new pageId. If a 'children' block payload is supplied, materialization is verified post-create and auto-repaired via notion_blocks_append if the API accepted the page but silently dropped the children (see 'childrenMaterialization' in the result).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "parentId": .object(["type": .string("string"), "description": .string("Parent page or database ID")]),
                    "parentType": .object(["type": .string("string"), "description": .string("Parent type: 'page_id', 'database_id', or 'data_source_id' (default: page_id)")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of page properties")]),
                    "children": .object(["type": .string("string"), "description": .string("Optional JSON string of child blocks")]),
                    "icon": .object(["type": .string("string"), "description": .string("Optional single emoji to set as the page icon (e.g. \"🎯\"). Emoji only.")]),
                    "templateId": .object(["type": .string("string"), "description": .string("Data-source template id. XOR with children. Apply is async — poll notion_async_task_get.")]),
                    "templateType": .object(["type": .string("string"), "description": .string("Template type: 'template_id' (with templateId) or 'default'. XOR with children.")]),
                    "timezone": .object(["type": .string("string"), "description": .string("Timezone for template variable resolution (IANA).")]),
                    "allowAsync": .object(["type": .string("boolean"), "description": .string("When true, large markdown/template creates may return an async_task instead of a completed page.")]),
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
                let icon: String? = { if case .string(let e) = args["icon"] { return e }; return nil }()

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
                let templateId: String? = { if case .string(let s) = args["templateId"] { return s }; return nil }()
                let templateType: String? = { if case .string(let s) = args["templateType"] { return s }; return nil }()
                let timezone: String? = { if case .string(let s) = args["timezone"] { return s }; return nil }()
                let erase: Bool? = { if case .bool(let b) = args["eraseContent"] { return b }; return nil }()
                let resolved: (template: [String: Any]?, children: Data?)
                do {
                    resolved = try NotionRESTContracts.resolveTemplateXORChildren(
                        templateId: templateId, templateType: templateType, timezone: timezone,
                        childrenJSON: {
                            if case .string(let s) = args["children"] { return s }
                            return nil
                        }(),
                        eraseContent: erase
                    )
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
                childrenData = resolved.children
                let allowAsync: Bool = {
                    if case .bool(let b) = args["allowAsync"] { return b }
                    return resolved.template != nil
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let resultData = try await client.createPage(
                    parentId: parentId,
                    parentType: parentType,
                    properties: propsData,
                    children: childrenData,
                    icon: icon,
                    template: resolved.template,
                    allowAsync: allowAsync
                )

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse create response")])
                }
                if NotionRESTContracts.isAsyncTaskEnvelope(resultJSON) {
                    return NotionRESTContracts.asyncTaskValue(resultJSON)
                }

                let newPageId = resultJSON["id"] as? String ?? ""

                var out: [String: Value] = [
                    "success": .bool(true),
                    "id": .string(newPageId),
                    "url": .string(resultJSON["url"] as? String ?? "")
                ]

                // Verified fallback for the children-materialization gap: Notion's
                // POST /pages create-response never echoes back children content
                // (it's a Page object, not a block list), so a caller has no
                // native signal that a `children` payload actually landed. Read
                // the new page's blocks back; if the API accepted the create but
                // produced zero blocks despite a non-empty `children` request,
                // repair it in the same call via the same append path
                // notion_blocks_append uses (PATCH /blocks/{id}/children) — so
                // the caller-visible result is correct either way, whether or not
                // the underlying create-time materialization bug reproduces.
                if let childrenData, !newPageId.isEmpty {
                    var materializationStatus: [String: Value] = ["checked": .bool(true)]
                    do {
                        let blocksData = try await client.getBlocks(blockId: newPageId)
                        let blocksJSON = try? JSONSerialization.jsonObject(with: blocksData) as? [String: Any]
                        let existingCount = (blocksJSON?["results"] as? [[String: Any]])?.count ?? 0
                        materializationStatus["blockCountAfterCreate"] = .int(existingCount)
                        if existingCount == 0 {
                            // Create-time children didn't materialize — repair via
                            // the append path (same as calling notion_blocks_append
                            // with blockId: newPageId, children: <the same JSON>).
                            let appendData = try await client.appendBlocks(blockId: newPageId, children: childrenData, position: .end)
                            let appendJSON = try? JSONSerialization.jsonObject(with: appendData) as? [String: Any]
                            let appendedCount = (appendJSON?["results"] as? [[String: Any]])?.count ?? 0
                            materializationStatus["repaired"] = .bool(true)
                            materializationStatus["blocksAppended"] = .int(appendedCount)
                        } else {
                            materializationStatus["repaired"] = .bool(false)
                        }
                    } catch {
                        // Verification/repair failure must not fail the overall
                        // create (the page itself was created successfully) —
                        // surface it for visibility instead.
                        materializationStatus["repaired"] = .bool(false)
                        materializationStatus["error"] = .string("\(error)")
                    }
                    out["childrenMaterialization"] = .object(materializationStatus)
                }

                return .object(out)
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
                    "parentId": .object(["type": .string("string"), "description": .string("Alias for 'dataSourceId', for symmetry with notion_page_create's parentId/parentType vocabulary. Requires parentType: \"data_source_id\". Ignored if 'dataSourceId' is also supplied.")]),
                    "parentType": .object(["type": .string("string"), "description": .string("Required alongside 'parentId' (not 'dataSourceId'); must be \"data_source_id\" — the only parent type notion_query supports.")]),
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
                // Not unconditionally required: 'parentId' + parentType:
                // "data_source_id" is a valid alternative (see property
                // descriptions above); the handler enforces "one of the two
                // shapes" at call time.
                "required": .array([])
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
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_query", reason: "missing 'dataSourceId'")
                }
                // 'parentId' is an alias for 'dataSourceId', gated on
                // parentType: "data_source_id" for symmetry with
                // notion_page_create's parentId/parentType vocabulary — the only
                // parent type notion_query supports. 'dataSourceId' wins if both
                // are supplied.
                let dsId: String
                if case .string(let explicit) = args["dataSourceId"] {
                    dsId = explicit
                } else if case .string(let parentId) = args["parentId"],
                          case .string(let parentType) = args["parentType"],
                          parentType == "data_source_id" {
                    dsId = parentId
                } else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_query", reason: "missing 'dataSourceId' (or 'parentId' + parentType: \"data_source_id\")")
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
                NotionRESTContracts.mergeQueryStatus(from: json, into: &resultObj)
                return .object(resultObj)
            }
        ))

        // MARK: 6. notion_blocks_append – notify (A5)
        // After changing registration or behavior, reload TheBridge (sk mac ops) so MCP clients list the updated tool.
        await router.register(ToolRegistration(
            name: "notion_blocks_append",
            module: moduleName,
            tier: .notify,
            description: "Append child blocks to a Notion page or block. Supports position: start | end | after:{id} for insertion order. For a plain markdown append (no hand-authored block JSON), pass `pageId` + `markdown` instead of `blockId` + `children` — server-side markdown→blocks conversion via the same Notion Markdown Content API notion_page_edit/replacePageMarkdown already use.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Parent page or block ID")]),
                    "children": .object(["type": .string("string"), "description": .string("JSON string of children blocks array")]),
                    "pageId": .object(["type": .string("string"), "description": .string("Alias for 'blockId' — a page id and a top-level block id are the same value. Pair with 'markdown' (not 'children') for the markdown shorthand.")]),
                    "markdown": .object(["type": .string("string"), "description": .string("Alias for 'children' — plain markdown text to append (server-side converted to native blocks: headings, tables, etc.), instead of hand-authored raw block JSON. Requires 'pageId' or 'blockId'; ignores position/afterBlock (always appends at the end of the body).")]),
                    "afterBlock": .object(["type": .string("string"), "description": .string("Optional block ID to insert after (legacy param; prefer `position: after:{id}`).")]),
                    "position": .object(["type": .string("string"), "description": .string("Optional insert position (API 2026-03-11): `start`, `end` (default), or `after:{blockId}`. Only applies to the blockId+children shape.")]),
                    "workspace": workspaceParam
                ]),
                // Not unconditionally required: 'pageId' aliases 'blockId' and
                // 'markdown' aliases 'children' (see property descriptions
                // above); the handler enforces "one of each pair" at call time.
                "required": .array([])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_blocks_append", reason: "missing 'blockId' or 'children'")
                }

                // pageId+markdown shorthand: resolve the target id from either
                // 'blockId' or its alias 'pageId' (same value space — a page id
                // IS a block id for top-level appends), and the markdown body
                // from either 'children' (raw block JSON, existing shape) or
                // its alias 'markdown' (plain text). 'children' JSON wins if
                // both 'children' and 'markdown' are somehow supplied, matching
                // the "existing shape always wins" additive contract.
                let targetId: String? = {
                    if case .string(let b) = args["blockId"] { return b }
                    if case .string(let p) = args["pageId"] { return p }
                    return nil
                }()
                guard let blockId = targetId else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_blocks_append", reason: "missing 'blockId' or 'children'")
                }

                if case .string(let childrenJSON)? = args["children"] {
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

                    await Self.evictSkillBodyCache(targetId: blockId, responseJSON: results.first)

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

                if case .string(let markdown)? = args["markdown"] {
                    // Markdown shorthand: server-side markdown→blocks conversion
                    // via the same Notion Markdown Content API `insert_content`
                    // mode `notion_page_edit`/`replacePageMarkdown` already rely
                    // on (in `replace_content` mode). Always appends at the end
                    // of the body — position/afterBlock don't apply to this
                    // shape (no per-block insertion point on a markdown blob).
                    let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                    let data = try await client.insertPageMarkdown(pageId: blockId, markdown: markdown)

                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .object(["error": .string("Failed to parse append response")])
                    }

                    await Self.evictSkillBodyCache(targetId: blockId, responseJSON: json)

                    // The markdown endpoint doesn't return a per-block results
                    // array like PATCH /blocks/{id}/children does; report what
                    // it does give us. `blocksAppended` is omitted (unknown)
                    // rather than reported as 0, so callers don't mistake "we
                    // didn't count them" for "nothing was appended".
                    var resultObj: [String: Value] = ["success": .bool(true)]
                    if let markdownEcho = json["markdown"] as? String {
                        resultObj["markdown"] = .string(markdownEcho)
                    }
                    return .object(resultObj)
                }

                throw ToolRouterError.invalidArguments(toolName: "notion_blocks_append", reason: "missing 'children' or 'markdown'")
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
                    await Self.evictSkillBodyCache(targetId: blockId, responseJSON: json)
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
                        await Self.evictSkillBodyCache(targetId: blockId, responseJSON: json)
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
            description: "Read a Notion page body as plain markdown only — no properties or block IDs. Optional section returns one heading slice; a miss returns a compact heading index instead of the full page.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID")]),
                    "section": .object(["type": .string("string"), "description": .string("Optional markdown heading to return, case-insensitive and without # markers. Exact match first; else unique prefix (e.g. 'Thread Handoff' → 'Thread Handoff — A · Bridge…').")]),
                    "includeTranscript": .object(["type": .string("boolean"), "description": .string("When true, include meeting-notes transcript in the markdown (GET ?include_transcript=true).")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_markdown_read", reason: "missing 'pageId'")
                }

                let includeTranscript: Bool = { if case .bool(let b) = args["includeTranscript"] { return b }; return false }()
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.getPageMarkdown(pageId: pageId, includeTranscript: includeTranscript)

                let markdown = SkillsModule.skillMarkdownString(fromMarkdownJSON: data)
                if case .string(let section)? = args["section"] {
                    if let slice = SkillsModule.extractMarkdownSection(markdown, section: section) {
                        return .object([
                            "markdown": .string(slice),
                            "section": .string(section),
                            "sectionMatched": .bool(true)
                        ])
                    }
                    let headings = SkillsModule.markdownHeadings(markdown)
                    return .object([
                        "markdown": .string(SkillsModule.sectionMissMarkdown(requested: section, markdown: markdown)),
                        "section": .string(section),
                        "sectionMatched": .bool(false),
                        "annotation": .string("section-not-found"),
                        "availableSections": .array(headings.prefix(100).map(Value.string))
                    ])
                }
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

                await SkillBodyCacheEviction.evictIfConfiguredSkillPage(pageId)
                await RegistryRowCache.shared.evictPageEverywhere(pageId: pageId)

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
            description: "Post a comment on a Notion page (pageId), block (blockId), OR reply in an existing discussion (discussionId). Exactly one parent. Markdown XOR text/rich_text per call. Rich-text over Notion's 2000-character per-run limit is auto-chunked. Own-comment mutate is notion_comment_update / notion_comment_delete.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Page ID for a new top-level page comment. Mutually exclusive with discussionId and blockId.")]),
                    "blockId": .object(["type": .string("string"), "description": .string("Block ID parent for an inline comment. Mutually exclusive with pageId/discussionId.")]),
                    "discussionId": .object(["type": .string("string"), "description": .string("Existing discussion thread ID for a reply. Mutually exclusive with pageId/blockId.")]),
                    "text": .object(["type": .string("string"), "description": .string("Rich-text comment content (XOR with markdown).")]),
                    "content": .object(["type": .string("string"), "description": .string("Alias for 'text'. If both are supplied, 'text' wins.")]),
                    "markdown": .object(["type": .string("string"), "description": .string("Markdown body (XOR with text/rich_text).")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Notion: Create Comment",
                whenToUse: ["posting a short inline comment on a page",
                            "replying to an existing discussion via discussionId"],
                whenNotToUse: ["starting a named new thread (use notion_discussion_create for the same page-level start, or pageId here)",
                               "long code/text (use notion_blocks_append with autoChunk:true)"],
                relatedTools: ["notion_discussion_create", "notion_comments_list"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_create", reason: "missing arguments")
                }
                let pageId: String? = { if case .string(let p) = args["pageId"] { return p }; return nil }()
                let blockId: String? = { if case .string(let b) = args["blockId"] { return b }; return nil }()
                let discussionIdArg: String? = {
                    if case .string(let d) = args["discussionId"] { return d }
                    return nil
                }()
                let hasPage = !(pageId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasDiscussion = !(discussionIdArg?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasBlock = !(blockId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                guard [hasPage, hasDiscussion, hasBlock].filter({ $0 }).count == 1 else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notion_comment_create",
                        reason: "exactly one of 'pageId', 'discussionId', or 'blockId' is required"
                    )
                }
                let markdown: String? = { if case .string(let m) = args["markdown"] { return m }; return nil }()
                let text: String? = {
                    if case .string(let t) = args["text"] { return t }
                    if case .string(let c) = args["content"] { return c }
                    return nil
                }()
                let content: NotionRESTContracts.CommentContentMode
                do {
                    content = try NotionRESTContracts.CommentContentMode.parse(markdown: markdown, text: text)
                } catch {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_create", reason: error.localizedDescription)
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))

                if case .markdown(let md) = content {
                    let data = try await client.createComment(
                        pageId: hasPage ? pageId : nil,
                        discussionId: hasDiscussion ? discussionIdArg : nil,
                        blockId: hasBlock ? blockId : nil,
                        markdown: md,
                        text: nil
                    )
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .object(["success": .bool(false), "error": .string("Failed to parse comment response")])
                    }
                    return .object([
                        "success": .bool(true),
                        "id": .string(json["id"] as? String ?? ""),
                        "discussionId": .string(json["discussion_id"] as? String ?? discussionIdArg ?? "")
                    ])
                }

                guard case .richText(let textBody) = content else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_create", reason: "missing 'text'")
                }

                // FB-3: Auto-chunk into sequential <=2000-char comments preserving order.
                // For replies, every chunk uses the same discussionId so they stay in-thread.
                let chunks = NotionModule.chunkCommentText(textBody, maxChars: 2000)

                var ids: [Value] = []
                // PKT-MEM-136: surface discussion_id so VoiceMemoProcessor can ledger it.
                var discussionIdOut = discussionIdArg ?? ""
                for chunk in chunks {
                    let data: Data
                    data = try await client.createComment(
                        pageId: hasPage ? pageId : nil,
                        discussionId: hasDiscussion ? discussionIdArg : nil,
                        blockId: hasBlock ? blockId : nil,
                        markdown: nil,
                        text: chunk
                    )
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
                    if discussionIdOut.isEmpty {
                        discussionIdOut = json["discussion_id"] as? String ?? ""
                    }
                }

                // Back-compat: single chunk keeps the original `id` field; multi-chunk adds `ids`.
                return .object([
                    "success": .bool(true),
                    "id": ids.first ?? .string(""),
                    "ids": .array(ids),
                    "chunks": .int(chunks.count),
                    "discussionId": .string(discussionIdOut)
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
                    "filePath": .object(["type": .string("string"), "description": .string("Absolute path to the local file (required unless mode is external_url).")]),
                    "mode": .object(["type": .string("string"), "description": .string("single_part (default, 20MB reject), multi_part (opt-in ≤5GB), or external_url (opt-in import).")]),
                    "externalUrl": .object(["type": .string("string"), "description": .string("HTTPS URL to import when mode is external_url.")]),
                    "trace": .object(["type": .string("boolean"), "description": .string("If true, include safe phase diagnostics for create_upload and send_content failures/success.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_file_upload", reason: "missing arguments")
                }
                let mode = NotionRESTContracts.parseFileUploadMode({
                    if case .string(let m) = args["mode"] { return m }
                    return nil
                }())
                if mode == .externalURL {
                    guard case .string(let url) = args["externalUrl"], !url.isEmpty else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_file_upload", reason: "external_url mode requires 'externalUrl'")
                    }
                    let fileName: String = {
                        if case .string(let n) = args["fileName"], !n.isEmpty { return n }
                        return URL(string: url)?.lastPathComponent ?? "import"
                    }()
                    let ext = (fileName as NSString).pathExtension.lowercased()
                    let contentType = NotionModule.mimeType(forExtension: ext)
                    if contentType == "application/octet-stream" {
                        return .object(["error": .string("Unsupported file extension for external_url import.")])
                    }
                    let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                    let data = try await client.importFileFromExternalURL(fileName: fileName, externalURL: url, contentType: contentType)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .object(["error": .string("Failed to parse upload response")])
                    }
                    return .object([
                        "success": .bool(true),
                        "id": .string(json["id"] as? String ?? ""),
                        "status": .string(json["status"] as? String ?? "unknown"),
                        "mode": .string("external_url")
                    ])
                }

                guard case .string(let filePath) = args["filePath"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_file_upload", reason: "missing 'filePath'")
                }

                guard let fileData = FileManager.default.contents(atPath: filePath) else {
                    return .object(["error": .string("File not found or unreadable: \(filePath)")])
                }

                if let reject = NotionRESTContracts.rejectSinglePartIfOversized(byteCount: fileData.count, mode: mode) {
                    return .object(["error": .string(reject)])
                }

                let fileName = (filePath as NSString).lastPathComponent
                let ext = (fileName as NSString).pathExtension.lowercased()
                let contentType = NotionModule.mimeType(forExtension: ext)

                // PKT-739 (v2.2 · 0.2): Reject unsupported MIME early. Notion's File Upload API
                // rejects application/octet-stream with a 400 validation_error at create_upload phase;
                // surface a clearer error here listing the supported extensions.
                if contentType == "application/octet-stream" {
                    let extLabel = ext.isEmpty ? "(none)" : ext
                    return .object(["error": .string("Unsupported file extension '\(extLabel)' for notion_file_upload. The Notion File Upload API does not accept application/octet-stream. Supported extensions: pdf, png, jpg, jpeg, gif, webp, svg, mp3, m4a, mp4, mov, ogg, wav, webm, txt, json, csv, html, htm, xml, zip, md.")])
                }
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let includeTrace: Bool = { if case .bool(let b) = args["trace"] { return b }; return false }()
                if mode == .multiPart {
                    let data = try await client.uploadFileMultiPart(fileName: fileName, fileData: fileData, contentType: contentType)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .object(["error": .string("Failed to parse upload response")])
                    }
                    return .object([
                        "success": .bool(true),
                        "id": .string(json["id"] as? String ?? ""),
                        "status": .string(json["status"] as? String ?? "unknown"),
                        "mode": .string("multi_part")
                    ])
                }
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

                await Self.evictSkillBodyCache(targetId: blockId, responseJSON: json)

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
                    schemaItems = NotionDataSourceSchemaFlatten.schema(from: properties)
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

        // MARK: 22b. notion_datasource_delete - request (Always Allow available)
        //   Destructive: trashes an ENTIRE data source (a whole DB). The
        //   soft-delete is trash-recoverable, but the blast radius is a
        //   full collection, so this is human-gated (.request). Always Allow
        //   persists sticky Notify (#258). The in-handler confirm:true guard
        //   stays as defense-in-depth against an accidental LLM call.
        await router.register(ToolRegistration(
            name: "notion_datasource_delete",
            module: moduleName,
            tier: .request,
            description: "Move a data source to Notion's trash (soft-delete, recoverable). Notion has no hard delete — the data source is trashed via in_trash:true. Destructive: requires confirm:true AND human approval (Always Allow available). Use mode:'restore' to untrash.",
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
            description: "Start a NEW top-level discussion on a Notion page (same as notion_comment_create with pageId — not a reply). For replies, pass discussionId to notion_comment_create. Accepts compressed URLs, UUIDs, or full Notion URLs. Initial comment is inline-only markdown and preflights Notion's 2000-character rich_text run limit.",
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

        // MARK: 24. notion_views_list – open (Views API)
        await router.register(ToolRegistration(
            name: "notion_views_list",
            module: moduleName,
            tier: .open,
            description: "List database views for a database_id and/or data_source_id (Notion Views API). List results are often id-only references — use notion_view_get for filter/sorts/configuration. At least one of databaseId or dataSourceId is required.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "databaseId": .object(["type": .string("string"), "description": .string("Database container ID — lists views on that database.")]),
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Data source ID — lists views over that collection (including linked views).")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default 100, max 100).")]),
                    "startCursor": .object(["type": .string("string"), "description": .string("Pagination cursor from a prior next_cursor.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Notion: List Views",
                whenToUse: ["discovering board/table/chart views on a database or data source"],
                whenNotToUse: ["reading one view's filter/sorts (use notion_view_get)",
                               "querying rows (use notion_query)"],
                relatedTools: ["notion_view_get", "notion_database_get", "notion_datasource_get", "notion_query"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_views_list", reason: "missing arguments")
                }
                let databaseId: String? = { if case .string(let d) = args["databaseId"] { return d }; return nil }()
                let dataSourceId: String? = { if case .string(let d) = args["dataSourceId"] { return d }; return nil }()
                let hasDB = !(databaseId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasDS = !(dataSourceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                guard hasDB || hasDS else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notion_views_list",
                        reason: "at least one of 'databaseId' or 'dataSourceId' is required"
                    )
                }
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(max(ps, 1), 100) }; return 100 }()
                let startCursor: String? = { if case .string(let c) = args["startCursor"] { return c }; return nil }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.listViews(
                    databaseId: hasDB ? databaseId : nil,
                    dataSourceId: hasDS ? dataSourceId : nil,
                    startCursor: startCursor,
                    pageSize: pageSize
                )
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse views list response")])
                }
                let results = (json["results"] as? [[String: Any]]) ?? []
                var items: [Value] = []
                for row in results {
                    let id = row["id"] as? String ?? ""
                    let object = row["object"] as? String ?? "view"
                    let name = row["name"] as? String
                    let type = row["type"] as? String
                    var entry: [String: Value] = [
                        "id": .string(id),
                        "object": .string(object)
                    ]
                    if let name { entry["name"] = .string(name) }
                    if let type { entry["type"] = .string(type) }
                    items.append(.object(entry))
                }
                let hasMore = json["has_more"] as? Bool ?? false
                var out: [String: Value] = [
                    "success": .bool(true),
                    "count": .int(items.count),
                    "has_more": .bool(hasMore),
                    "results": .array(items)
                ]
                if let next = json["next_cursor"] as? String {
                    out["next_cursor"] = .string(next)
                }
                return .object(out)
            }
        ))

        // MARK: 25. notion_view_get – open (Views API)
        await router.register(ToolRegistration(
            name: "notion_view_get",
            module: moduleName,
            tier: .open,
            description: "Retrieve one Notion database view by ID — name, type, filter, sorts, quick_filters, and configuration (table/board/chart/etc.). Use after notion_views_list.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "viewId": .object(["type": .string("string"), "description": .string("View ID (with or without dashes).")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("viewId")])
            ]),
            metadata: ToolMetadata(
                title: "Notion: Get View",
                whenToUse: ["reading a view's filters, sorts, and layout configuration"],
                whenNotToUse: ["listing views (use notion_views_list)",
                               "querying rows of a data source (use notion_query)"],
                relatedTools: ["notion_views_list", "notion_query", "notion_database_get"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let viewId) = args["viewId"], !viewId.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_view_get", reason: "missing 'viewId'")
                }
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.getView(viewId: viewId)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse view response")])
                }
                // Pass through the full view object as JSON string for nested filter/config fidelity,
                // plus a few top-level convenience fields.
                let raw = String(data: data, encoding: .utf8) ?? "{}"
                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? viewId),
                    "object": .string(json["object"] as? String ?? "view"),
                    "name": .string(json["name"] as? String ?? ""),
                    "type": .string(json["type"] as? String ?? ""),
                    "data_source_id": .string(json["data_source_id"] as? String ?? ""),
                    "url": .string(json["url"] as? String ?? ""),
                    "view": .string(raw)
                ])
            }
        ))

        // MARK: 26. notion_view_create – notify (Views API write)
        await router.register(ToolRegistration(
            name: "notion_view_create",
            module: moduleName,
            tier: .notify,
            description: "Create a Notion database view (POST /v1/views). Requires name + type and at least one of databaseId or dataSourceId. Pass configuration as a JSON string; table property entries must use property_id (not display name). Prefer a disposable database — never experiment on production PACKETS.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "databaseId": .object(["type": .string("string"), "description": .string("Parent database ID.")]),
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Data source ID (recommended with databaseId).")]),
                    "name": .object(["type": .string("string"), "description": .string("View name.")]),
                    "type": .object(["type": .string("string"), "description": .string("View type: table, board, calendar, list, gallery, timeline, chart, form, map, …")]),
                    "configuration": .object(["type": .string("string"), "description": .string("JSON string of view configuration (must include type + properties with property_id / visible / width / wrap_cells / frozen_column_index as needed).")]),
                    "filter": .object(["type": .string("string"), "description": .string("Optional JSON string filter object.")]),
                    "sorts": .object(["type": .string("string"), "description": .string("Optional JSON string sorts array.")]),
                    "quickFilters": .object(["type": .string("string"), "description": .string("Optional JSON object of quick_filters for the view filter bar.")]),
                    "position": .object(["type": .string("string"), "description": .string("Optional JSON position union (start/end/after_view) for the database tab bar.")]),
                    "viewId": .object(["type": .string("string"), "description": .string("Dashboard-widget PARENT view id — not a duplicate-from source. Mutually exclusive with databaseId.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("name"), .string("type")])
            ]),
            metadata: ToolMetadata(
                title: "Notion: Create View",
                whenToUse: ["creating a table/board view with width/visible/wrap/freeze on a disposable or owned database"],
                whenNotToUse: ["listing or inspecting views (use notion_views_list / notion_view_get)",
                               "mutating an existing view (use notion_view_update)"],
                relatedTools: ["notion_view_update", "notion_view_get", "notion_views_list", "notion_datasource_get"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: "missing arguments")
                }
                guard case .string(let name) = args["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: "missing 'name'")
                }
                guard case .string(let viewType) = args["type"], !viewType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: "missing 'type'")
                }
                let databaseId: String? = { if case .string(let d) = args["databaseId"] { return d }; return nil }()
                let dataSourceId: String? = { if case .string(let d) = args["dataSourceId"] { return d }; return nil }()
                let dashboardViewId: String? = { if case .string(let d) = args["viewId"] { return d }; return nil }()
                let parentKind: (hasDB: Bool, hasDS: Bool, hasView: Bool)
                do {
                    parentKind = try NotionRESTContracts.viewCreateParentKind(
                        databaseId: databaseId, dataSourceId: dataSourceId, viewId: dashboardViewId
                    )
                } catch {
                    throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: error.localizedDescription)
                }

                var body: [String: Any] = [
                    "name": name,
                    "type": viewType
                ]
                if parentKind.hasDB, let databaseId {
                    body["database_id"] = databaseId.replacingOccurrences(of: "-", with: "")
                }
                if parentKind.hasDS, let dataSourceId {
                    body["data_source_id"] = dataSourceId.replacingOccurrences(of: "-", with: "")
                }
                if parentKind.hasView, let dashboardViewId {
                    body["view_id"] = dashboardViewId.replacingOccurrences(of: "-", with: "")
                }
                if case .string(let cfgJSON) = args["configuration"], !cfgJSON.isEmpty {
                    guard let cfgData = cfgJSON.data(using: .utf8),
                          let cfgObj = try? JSONSerialization.jsonObject(with: cfgData) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: "configuration must be valid JSON")
                    }
                    body["configuration"] = cfgObj
                }
                if case .string(let filterJSON) = args["filter"], !filterJSON.isEmpty {
                    guard let filterData = filterJSON.data(using: .utf8),
                          let filterObj = try? JSONSerialization.jsonObject(with: filterData) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: "filter must be valid JSON")
                    }
                    body["filter"] = filterObj
                }
                if case .string(let sortsJSON) = args["sorts"], !sortsJSON.isEmpty {
                    guard let sortsData = sortsJSON.data(using: .utf8),
                          let sortsObj = try? JSONSerialization.jsonObject(with: sortsData) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: "sorts must be valid JSON")
                    }
                    body["sorts"] = sortsObj
                }
                if case .string(let qfJSON) = args["quickFilters"], !qfJSON.isEmpty {
                    guard let qfData = qfJSON.data(using: .utf8),
                          let qfObj = try? JSONSerialization.jsonObject(with: qfData) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: "quickFilters must be valid JSON")
                    }
                    body["quick_filters"] = qfObj
                }
                if case .string(let posJSON) = args["position"], !posJSON.isEmpty {
                    guard let posData = posJSON.data(using: .utf8),
                          let posObj = try? JSONSerialization.jsonObject(with: posData) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_view_create", reason: "position must be valid JSON")
                    }
                    body["position"] = posObj
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.createView(body: body)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse create view response")])
                }
                let raw = String(data: data, encoding: .utf8) ?? "{}"
                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? ""),
                    "object": .string(json["object"] as? String ?? "view"),
                    "name": .string(json["name"] as? String ?? name),
                    "type": .string(json["type"] as? String ?? viewType),
                    "data_source_id": .string(json["data_source_id"] as? String ?? ""),
                    "url": .string(json["url"] as? String ?? ""),
                    "view": .string(raw)
                ])
            }
        ))

        // MARK: 27. notion_view_update – notify (Views API write)
        await router.register(ToolRegistration(
            name: "notion_view_update",
            module: moduleName,
            tier: .notify,
            description: "Update a Notion database view (PATCH /v1/views/{id}). Pass configuration as a JSON string (property_id required for property entries). Use for width/visible/wrap_cells/frozen_column_index changes after notion_view_get.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "viewId": .object(["type": .string("string"), "description": .string("View ID to update.")]),
                    "name": .object(["type": .string("string"), "description": .string("Optional new view name.")]),
                    "configuration": .object(["type": .string("string"), "description": .string("JSON string of view configuration to patch.")]),
                    "filter": .object(["type": .string("string"), "description": .string("Optional JSON string filter object.")]),
                    "sorts": .object(["type": .string("string"), "description": .string("Optional JSON string sorts array.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("viewId")])
            ]),
            metadata: ToolMetadata(
                title: "Notion: Update View",
                whenToUse: ["changing column width/visibility/wrap/freeze or renaming a view"],
                whenNotToUse: ["creating a new view (use notion_view_create)",
                               "read-only inspection (use notion_view_get)"],
                relatedTools: ["notion_view_create", "notion_view_get", "notion_views_list"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let viewId) = args["viewId"], !viewId.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_view_update", reason: "missing 'viewId'")
                }
                var body: [String: Any] = [:]
                if case .string(let name) = args["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    body["name"] = name
                }
                if case .string(let cfgJSON) = args["configuration"], !cfgJSON.isEmpty {
                    guard let cfgData = cfgJSON.data(using: .utf8),
                          let cfgObj = try? JSONSerialization.jsonObject(with: cfgData) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_view_update", reason: "configuration must be valid JSON")
                    }
                    body["configuration"] = cfgObj
                }
                if case .string(let filterJSON) = args["filter"], !filterJSON.isEmpty {
                    guard let filterData = filterJSON.data(using: .utf8),
                          let filterObj = try? JSONSerialization.jsonObject(with: filterData) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_view_update", reason: "filter must be valid JSON")
                    }
                    body["filter"] = filterObj
                }
                if case .string(let sortsJSON) = args["sorts"], !sortsJSON.isEmpty {
                    guard let sortsData = sortsJSON.data(using: .utf8),
                          let sortsObj = try? JSONSerialization.jsonObject(with: sortsData) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_view_update", reason: "sorts must be valid JSON")
                    }
                    body["sorts"] = sortsObj
                }
                guard !body.isEmpty else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notion_view_update",
                        reason: "at least one of name, configuration, filter, or sorts is required"
                    )
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.updateView(viewId: viewId, body: body)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse update view response")])
                }
                let raw = String(data: data, encoding: .utf8) ?? "{}"
                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? viewId),
                    "object": .string(json["object"] as? String ?? "view"),
                    "name": .string(json["name"] as? String ?? ""),
                    "type": .string(json["type"] as? String ?? ""),
                    "data_source_id": .string(json["data_source_id"] as? String ?? ""),
                    "url": .string(json["url"] as? String ?? ""),
                    "view": .string(raw)
                ])
            }
        ))

        // MARK: 28. notion_view_query – open (#225)
        await router.register(ToolRegistration(
            name: "notion_view_query",
            module: moduleName,
            tier: .open,
            description: "Query rows through a saved Notion database view (POST /v1/views/{id}/queries). Reproduces the view's filter/sort. Paginate with queryId + startCursor. Echoes request_status/truncated; a capped page is still success.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "viewId": .object(["type": .string("string"), "description": .string("View ID to query.")]),
                    "queryId": .object(["type": .string("string"), "description": .string("Existing query id for pagination (GET). Omit to create a new query.")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default 50, max 100).")]),
                    "startCursor": .object(["type": .string("string"), "description": .string("Pagination cursor for an existing queryId.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("viewId")])
            ]),
            metadata: ToolMetadata(
                title: "Notion: Query View",
                whenToUse: ["reading rows as a saved view shows them"],
                whenNotToUse: ["ad-hoc filters (use notion_query)", "SQL / multi-source query (not built)"],
                relatedTools: ["notion_view_get", "notion_query", "notion_views_list"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let viewId) = args["viewId"], !viewId.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_view_query", reason: "missing 'viewId'")
                }
                let pageSize: Int = { if case .int(let n) = args["pageSize"] { return n }; return 50 }()
                let queryId: String? = { if case .string(let s) = args["queryId"] { return s }; return nil }()
                let startCursor: String? = { if case .string(let s) = args["startCursor"] { return s }; return nil }()
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data: Data
                if let queryId, !queryId.isEmpty {
                    data = try await client.getViewQuery(viewId: viewId, queryId: queryId, startCursor: startCursor, pageSize: pageSize)
                } else {
                    data = try await client.createViewQuery(viewId: viewId, pageSize: pageSize)
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse view query response")])
                }
                var out: [String: Value] = [:]
                if let results = json["results"] as? [[String: Any]] {
                    out["count"] = .int(results.count)
                    out["results"] = NotionRESTContracts.mcpValue(fromJSON: results)
                }
                if let qid = json["query_id"] as? String { out["query_id"] = .string(qid) }
                NotionRESTContracts.mergeQueryStatus(from: json, into: &out)
                return .object(out)
            }
        ))

        // MARK: 29. notion_view_delete – request (#225)
        await router.register(ToolRegistration(
            name: "notion_view_delete",
            module: moduleName,
            tier: .request,
            description: "Permanently delete a Notion database view (DELETE /v1/views/{id}). Irreversible. Last remaining view returns REST validation_error. Requires confirm:true.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "viewId": .object(["type": .string("string"), "description": .string("View ID to delete.")]),
                    "confirm": .object(["type": .string("boolean"), "description": .string("Must be true.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("viewId"), .string("confirm")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let viewId) = args["viewId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_view_delete", reason: "missing 'viewId'")
                }
                guard case .bool(true)? = args["confirm"] else {
                    return .object(["error": .string("Refused: pass confirm:true to delete a view")])
                }
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.deleteView(viewId: viewId)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse delete view response")])
                }
                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? viewId)
                ])
            }
        ))

        // MARK: 30. notion_page_trash – request (#228)
        await router.register(ToolRegistration(
            name: "notion_page_trash",
            module: moduleName,
            tier: .request,
            description: "Trash or restore a Notion page via PATCH in_trash. No hard delete. No is_locked. Requires confirm:true.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Page ID (UUID or Notion URL).")]),
                    "mode": .object(["type": .string("string"), "description": .string("'trash' (default) or 'restore'.")]),
                    "confirm": .object(["type": .string("boolean"), "description": .string("Must be true.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("confirm")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_trash", reason: "missing 'pageId'")
                }
                guard case .bool(true)? = args["confirm"] else {
                    return .object(["error": .string("Refused: pass confirm:true to trash or restore a page")])
                }
                let mode: String = { if case .string(let m) = args["mode"] { return m }; return "trash" }()
                let inTrash = (mode != "restore")
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.setPageTrash(pageId: pageId, inTrash: inTrash)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse trash response")])
                }
                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? pageId),
                    "in_trash": .bool(json["in_trash"] as? Bool ?? inTrash)
                ])
            }
        ))

        // MARK: 31. notion_comment_update – notify (#229)
        await router.register(ToolRegistration(
            name: "notion_comment_update",
            module: moduleName,
            tier: .notify,
            description: "PATCH an existing comment you created (own-comments only; otherwise 404). Markdown XOR text/rich_text.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "commentId": .object(["type": .string("string"), "description": .string("Comment ID.")]),
                    "text": .object(["type": .string("string"), "description": .string("Rich-text replacement (XOR with markdown).")]),
                    "markdown": .object(["type": .string("string"), "description": .string("Markdown replacement (XOR with text).")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("commentId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let commentId) = args["commentId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_update", reason: "missing 'commentId'")
                }
                let markdown: String? = { if case .string(let m) = args["markdown"] { return m }; return nil }()
                let text: String? = { if case .string(let t) = args["text"] { return t }; return nil }()
                let content: NotionRESTContracts.CommentContentMode
                do {
                    content = try NotionRESTContracts.CommentContentMode.parse(markdown: markdown, text: text)
                } catch {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_update", reason: error.localizedDescription)
                }
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let md: String? = { if case .markdown(let s) = content { return s }; return nil }()
                let tx: String? = { if case .richText(let s) = content { return s }; return nil }()
                let data = try await client.updateComment(commentId: commentId, markdown: md, text: tx)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse comment update")])
                }
                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? commentId)
                ])
            }
        ))

        // MARK: 32. notion_comment_delete – request (#229)
        await router.register(ToolRegistration(
            name: "notion_comment_delete",
            module: moduleName,
            tier: .request,
            description: "DELETE a comment you created (own-comments only; otherwise 404). Requires confirm:true.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "commentId": .object(["type": .string("string"), "description": .string("Comment ID.")]),
                    "confirm": .object(["type": .string("boolean"), "description": .string("Must be true.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("commentId"), .string("confirm")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let commentId) = args["commentId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_delete", reason: "missing 'commentId'")
                }
                guard case .bool(true)? = args["confirm"] else {
                    return .object(["error": .string("Refused: pass confirm:true to delete a comment")])
                }
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                _ = try await client.deleteComment(commentId: commentId)
                return .object(["success": .bool(true), "id": .string(commentId)])
            }
        ))

        // MARK: 33. notion_async_task_get – open (#237)
        await router.register(ToolRegistration(
            name: "notion_async_task_get",
            module: moduleName,
            tier: .open,
            description: "GET /v1/async_tasks/{id}. Poll after allow_async page create/markdown/template apply. Not Custom Agent sessions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "taskId": .object(["type": .string("string"), "description": .string("Async task id from a queued write.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("taskId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let taskId) = args["taskId"], !taskId.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_async_task_get", reason: "missing 'taskId'")
                }
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.getAsyncTask(taskId: taskId)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse async task")])
                }
                return NotionRESTContracts.mcpValue(fromJSON: json)
            }
        ))

        // MARK: 34. notion_templates_list – open (#230)
        await router.register(ToolRegistration(
            name: "notion_templates_list",
            module: moduleName,
            tier: .open,
            description: "List data-source templates (GET /v1/data_sources/{id}/templates). Use templateId on create/update; template XOR children; erase_content is refused.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Data source ID.")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max templates (default 100).")]),
                    "startCursor": .object(["type": .string("string"), "description": .string("Pagination cursor.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("dataSourceId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dsId) = args["dataSourceId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_templates_list", reason: "missing 'dataSourceId'")
                }
                let pageSize: Int = { if case .int(let n) = args["pageSize"] { return n }; return 100 }()
                let startCursor: String? = { if case .string(let s) = args["startCursor"] { return s }; return nil }()
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.listTemplates(dataSourceId: dsId, startCursor: startCursor, pageSize: pageSize)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse templates list")])
                }
                return NotionRESTContracts.mcpValue(fromJSON: json)
            }
        ))

        // MARK: 35. notion_meeting_notes_query – open (#236)
        await router.register(ToolRegistration(
            name: "notion_meeting_notes_query",
            module: moduleName,
            tier: .open,
            description: "Query meeting-notes blocks (POST /v1/blocks/meeting_notes/query). Pass filter JSON. Pair with notion_page_markdown_read includeTranscript=true.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filter": .object(["type": .string("string"), "description": .string("Optional JSON filter object for meeting-note properties.")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default 25, max 100).")]),
                    "startCursor": .object(["type": .string("string"), "description": .string("Pagination cursor.")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = { if case .object(let a) = arguments { return a }; return [:] }()
                var body: [String: Any] = [:]
                let pageSize: Int = { if case .int(let n) = args["pageSize"] { return max(1, min(n, 100)) }; return 25 }()
                body["page_size"] = pageSize
                if case .string(let c) = args["startCursor"], !c.isEmpty { body["start_cursor"] = c }
                if case .string(let f) = args["filter"], !f.isEmpty {
                    guard let d = f.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) else {
                        throw ToolRouterError.invalidArguments(toolName: "notion_meeting_notes_query", reason: "filter must be valid JSON")
                    }
                    body["filter"] = obj
                }
                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.queryMeetingNotes(body: body)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse meeting notes query")])
                }
                var out: [String: Value] = [:]
                if let results = json["results"] {
                    out["results"] = NotionRESTContracts.mcpValue(fromJSON: results)
                }
                NotionRESTContracts.mergeQueryStatus(from: json, into: &out)
                return .object(out)
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
