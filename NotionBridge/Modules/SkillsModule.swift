// SkillsModule.swift — fetch_skill MCP Tool
// NotionBridge · Modules
// PKT-366 F10: Registers `fetch_skill` at .open tier.
// Looks up skill name in config → NotionClient page + collectBlocksDepthFirst → returns text.
// Session-level cache with 10-minute TTL.
// 403 handling: structured error + "Access Lost" badge.

import Foundation
import MCP

// MARK: - Skill Cache

/// Cache entry for a fetched skill page.
private struct CachedSkill: Sendable {
    let content: Value
    let fetchedAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(fetchedAt) > 600 // 10-minute TTL
    }
}

/// Thread-safe actor cache for fetched skill content.
private actor SkillCache {
    private var cache: [String: CachedSkill] = [:]

    func get(_ key: String) -> Value? {
        guard let entry = cache[key], !entry.isExpired else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.content
    }

    func set(_ key: String, content: Value) {
        cache[key] = CachedSkill(content: content, fetchedAt: Date())
    }

    func clear() {
        cache.removeAll()
    }
}

// MARK: - SkillsModule

/// Provides the `fetch_skill` MCP tool for runtime Notion page injection.
/// Skills are configured via SkillsManager (Settings → Skills tab) and
/// persisted in UserDefaults under `com.notionbridge.skills`.
public enum SkillsModule {

    public static let moduleName = "skills"

    // MARK: - Auto-Routing Instructions (injected into MCP initialize response)

    /// Build a compact instructions string containing the routing skill index.
    /// Called at session creation to embed in the MCP initialize response.
    /// v3.0·0.5: tool-call contract surfaced in the MCP `instructions`
    /// field (both transports). Dense by design — it ships in every
    /// session's context. Tells an agent how to read/trust the tool surface.
    public static let dispatchContract = """
    Tool contract: parameter keys are camelCase (snake_case only for raw \
    Notion-API value passthroughs). Each tool's description carries \
    "When to use" / "Not for" / "Related" guidance — read it before \
    selecting. On a wrong/missing parameter the error returns a \
    "did you mean: x→y" hint; trust it and retry once.
    """

    public static func buildRoutingInstructions() -> String {
        let skills = readAllSkills().filter {
            $0.enabled && $0.visibility == .routing
                && NotionPageRef.isValidStoredPageId($0.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !skills.isEmpty else {
            return "NotionBridge MCP server. Call list_routing_skills to discover available skill-based capabilities.\n\n\(dispatchContract)"
        }
        // Build compact JSON routing index
        var lines: [String] = []
        for s in skills {
            var entry = "\(s.name)"
            if !s.summary.isEmpty { entry += " — \(s.summary)" }
            if !s.triggerPhrases.isEmpty { entry += " [triggers: \(s.triggerPhrases.joined(separator: ", "))]" }
            if !s.antiTriggerPhrases.isEmpty { entry += " [avoid: \(s.antiTriggerPhrases.joined(separator: ", "))]" }
            lines.append(entry)
        }
        return """
        NotionBridge MCP server. \(skills.count) routing skill(s) available:
        \(lines.joined(separator: "\n"))
        Use fetch_skill to load full skill content by name. Call list_routing_skills to refresh this index.

        \(dispatchContract)
        """
    }

    /// Register the `fetch_skill` tool on the given router.
    public static func register(on router: ToolRouter) async {

        let cache = SkillCache()

        // fetch_skill — open tier
        await router.register(ToolRegistration(
            name: "fetch_skill",
            module: moduleName,
            tier: .open,
            description: "Fetch the full body of one skill page from Notion by name. Call only after the routing index has selected a skill.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Name of the skill to fetch (case-insensitive). Must match a configured skill name.")
                    ]),
                    "includeNested": .object([
                        "type": .string("boolean"),
                        "description": .string("Include nested blocks (toggles, lists). Default true for full skill content.")
                    ]),
                    "maxBlocks": .object([
                        "type": .string("number"),
                        "description": .string("Safety cap on total blocks collected (default 5000).")
                    ]),
                    "maxDepth": .object([
                        "type": .string("number"),
                        "description": .string("Max nesting depth from page (default 10).")
                    ])
                ]),
                "required": .array([.string("name")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let name) = args["name"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "fetch_skill",
                        reason: "missing required 'name' parameter"
                    )
                }

                let includeNested: Bool = {
                    if case .bool(let b) = args["includeNested"] { return b }
                    return true
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

                // Look up skill in UserDefaults config (cache key includes metadata fingerprint)
                guard let skillConfig = lookupSkill(named: name) else {
                    let closeMatches = closestSkillMatches(for: name)
                    let allSkills = listAvailableSkillNames()
                    return .object([
                        "error": .string("Skill not found: '\(name)'"),
                        "hint": .string(closeMatches.isEmpty
                            ? "No close matches found. Configure skills in Settings \u{2192} Skills tab."
                            : "Did you mean: \(closeMatches.joined(separator: ", "))?"),
                        "closeMatches": .array(closeMatches.map { .string($0) }),
                        "availableSkills": .array(allSkills.map { .string($0) })
                    ])
                }

                let cacheKey = "\(name.lowercased())|n=\(includeNested)|mb=\(maxBlocks)|md=\(maxDepth)|meta=\(skillConfig.metadataCacheToken)"

                if let cached = await cache.get(cacheKey) {
                    return cached
                }

                guard skillConfig.enabled else {
                    return .object([
                        "error": .string("Skill '\(name)' is disabled."),
                        "hint": .string("Enable it in Settings \u{2192} Skills tab.")
                    ])
                }

                let pageIdRaw = skillConfig.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard NotionPageRef.isValidStoredPageId(pageIdRaw) else {
                    return .object([
                        "error": .string("Invalid Notion page ID for skill '\(name)'."),
                        "hint": .string("Update the page URL or ID in Settings \u{2192} Skills to a valid Notion page (32 hex digits or a notion.so / notion.site link).")
                    ])
                }

                // Fetch from Notion API
                do {
                    let client = try NotionClient()
                    let pageId = pageIdRaw

                    // Fetch page properties
                    let pageData = try await client.getPage(pageId: pageId)
                    guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else {
                        return .object(["error": .string("Failed to parse Notion page response")])
                    }

                    let url = pageJSON["url"] as? String ?? ""
                    var title = "Untitled"
                    if let properties = pageJSON["properties"] as? [String: Any] {
                        title = NotionJSON.extractTitle(from: properties)
                    }

                    let collected = try await client.collectBlocksDepthFirst(
                        rootBlockId: pageId,
                        includeNested: includeNested,
                        maxBlocks: maxBlocks,
                        maxDepth: maxDepth
                    )
                    let blockResults = collected.blocks
                    let truncated = collected.truncated
                    let truncationReason = collected.truncationReason

                    if blockResults.isEmpty {
                        var base: [String: Value] = [
                            "name": .string(skillConfig.name),
                            "title": .string(title),
                            "url": .string(url),
                            "blockCount": .int(0),
                            "truncated": .bool(false),
                            "content": .string("(no blocks)")
                        ]
                        base.merge(Self.mcpMetadataObject(skillConfig)) { _, new in new }
                        let result: Value = .object(base)
                        await cache.set(cacheKey, content: result)
                        return result
                    }

                    var textParts: [String] = []
                    for block in blockResults {
                        let line = NotionJSON.extractPlainTextFromBlock(block)
                        if !line.isEmpty {
                            textParts.append(line)
                        }
                    }

                    var resultObj: [String: Value] = [
                        "name": .string(skillConfig.name),
                        "title": .string(title),
                        "url": .string(url),
                        "blockCount": .int(blockResults.count),
                        "truncated": .bool(truncated),
                        "content": .string(textParts.joined(separator: "\n"))
                    ]
                    resultObj.merge(Self.mcpMetadataObject(skillConfig)) { _, new in new }
                    if let r = truncationReason {
                        resultObj["truncationReason"] = .string(r)
                    }

                    let result: Value = .object(resultObj)
                    await cache.set(cacheKey, content: result)
                    return result

                } catch let error as NotionClientError {
                    // F10: 403 handling — structured error + "Access Lost" badge
                    if case .httpError(let code, let msg) = error, code == 403 {
                        return .object([
                            "error": .string("Access Lost"),
                            "status": .int(403),
                            "skill": .string(name),
                            "detail": .string("The Notion integration no longer has access to this page. Re-share the page with your integration."),
                            "raw": .string(msg)
                        ])
                    }
                    return .object([
                        "error": .string("Notion API error"),
                        "detail": .string(error.localizedDescription)
                    ])
                } catch {
                    return .object([
                        "error": .string("Failed to fetch skill"),
                        "detail": .string(error.localizedDescription)
                    ])
                }
            }
        ))

        await registerListRoutingSkills(on: router)

        await registerManageSkill(on: router, skillCache: cache)
    }

    // MARK: - list_routing_skills

    private static func registerListRoutingSkills(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "list_routing_skills",
            module: moduleName,
            tier: .open,
            description: "Refresh the skill routing index (summaries + trigger phrases). Initial index is provided in server instructions at connection time — only call after a skill change.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let skills = readAllSkills().filter {
                    $0.enabled && $0.visibility == .routing
                        && NotionPageRef.isValidStoredPageId($0.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let items: [Value] = skills.map { s in
                    .object(Self.skillRowFields(s))
                }
                return .object([
                    "skills": .array(items),
                    "count": .int(skills.count)
                ])
            }
        ))
    }

    // MARK: - manage_skill Tool (PKT-477 Feature 3)

    /// Register the `manage_skill` tool on the given router.
    private static func registerManageSkill(on router: ToolRouter, skillCache: SkillCache) async {

        await router.register(ToolRegistration(
            name: "manage_skill",
            module: moduleName,
            tier: .notify, // was .orange — no such SecurityTier member
            description: "Add, edit, delete, toggle, rename, or sync skills + their Notion metadata (trigger phrases, anti-trigger phrases, summary, visibility).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("Action: list, add, delete, toggle, rename, update_url, set_visibility, bulk_add, set_metadata, sync_metadata_to_notion, sync_metadata_from_notion"),
                        "enum": .array([
                            .string("list"), .string("add"), .string("delete"), .string("toggle"), .string("rename"),
                            .string("update_url"), .string("set_visibility"), .string("bulk_add"),
                            .string("set_metadata"), .string("sync_metadata_to_notion"), .string("sync_metadata_from_notion")
                        ])
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Skill name (required for most actions)")
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("Notion page URL (notion.so or notion.site) or 32-character hex page ID (required for add, update_url)")
                    ]),
                    "newName": .object([
                        "type": .string("string"),
                        "description": .string("New name for rename action")
                    ]),
                    "visibility": .object([
                        "type": .string("string"),
                        "description": .string("SkillVisibility for add/set_visibility: routing | standard (legacy adminOnly accepted as standard)")
                    ]),
                    "summary": .object([
                        "type": .string("string"),
                        "description": .string("MCP summary text (set_metadata); optional if other metadata fields provided")
                    ]),
                    "triggerPhrases": .object([
                        "type": .string("array"),
                        "description": .string("Trigger phrases (set_metadata); array of strings"),
                        "items": .object(["type": .string("string")])
                    ]),
                    "antiTriggerPhrases": .object([
                        "type": .string("array"),
                        "description": .string("Anti-trigger phrases (set_metadata); array of strings"),
                        "items": .object(["type": .string("string")])
                    ]),
                    "skills": .object([
                        "type": .string("array"),
                        "description": .string("Array of {name, url} objects for bulk_add. Rows with invalid URLs or duplicate names are skipped; see invalidPageRows in the response."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "name": .object(["type": .string("string")]),
                                "url": .object(["type": .string("string")])
                            ])
                        ])
                    ]),
                    "bypassConfirmation": .object([
                        "type": .string("boolean"),
                        "description": .string("When true, skip SecurityGate confirmation prompt. Use for automated/unattended sessions. Default: false.")
                    ])
                ]),
                "required": .array([.string("action")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let action) = args["action"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "manage_skill",
                        reason: "missing required 'action' parameter"
                    )
                }

                // C3: bypassConfirmation skips SecurityGate notify for automated sessions
                let bypassConfirmation: Bool = {
                    if case .bool(let b) = args["bypassConfirmation"] { return b }
                    return false
                }()
                if bypassConfirmation {
                    NSLog("[manage_skill] bypassConfirmation=true for action=%@, skipping SecurityGate", action)
                }

                switch action {
                case "list":
                    let skills = readAllSkills()
                    let items: [Value] = skills.map { skill in
                        var row: [String: Value] = [
                            "name": .string(skill.name),
                            "uuid": .string(skill.notionPageId),
                            "enabled": .bool(skill.enabled),
                            "visibility": .string(skill.visibility.rawValue),
                            "platform": .string(skill.platform.rawValue)
                        ]
                        if let skillUrl = skill.url {
                            row["url"] = .string(skillUrl)
                        }
                        row.merge(Self.mcpMetadataObject(skill)) { _, new in new }
                        return .object(row)
                    }
                    return .object([
                        "skills": .array(items),
                        "count": .int(skills.count)
                    ])

                case "add":
                    guard case .string(let name) = args["name"],
                          case .string(let url) = args["url"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'add' requires 'name' and 'url' parameters"
                        )
                    }
                    let vis = parseVisibilityArg(args) ?? .standard
                    // V2-SKILLS: Try SkillURLParser first for multi-platform support
                    let parseResult = SkillURLParser.parse(url: url)
                    switch parseResult {
                    case .success(let parsed):
                        let success = writeAddSkill(
                            name: name, pageId: parsed.uuid, visibility: vis,
                            url: parsed.originalURL, platform: parsed.platform
                        )
                        return .object([
                            "success": .bool(success),
                            "action": .string("add"),
                            "name": .string(name),
                            "platform": .string(parsed.platform.rawValue),
                            "message": .string(success ? "Skill '\(name)' added (\(parsed.platform.displayName))." : "Failed — name may be empty or duplicate.")
                        ])
                    case .failure:
                        // Fallback: treat as Notion page ID/URL via NotionPageRef
                        switch NotionPageRef.normalizedPageId(from: url) {
                        case .failure(let err):
                            return .object([
                                "success": .bool(false),
                                "action": .string("add"),
                                "name": .string(name),
                                "message": .string(err.message)
                            ])
                        case .success(let normalized):
                            let success = writeAddSkill(name: name, pageId: normalized, visibility: vis, platform: .notion)
                            return .object([
                                "success": .bool(success),
                                "action": .string("add"),
                                "name": .string(name),
                                "platform": .string("notion"),
                                "message": .string(success ? "Skill '\(name)' added." : "Failed — name may be empty or duplicate.")
                            ])
                        }
                    }

                case "delete":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'delete' requires 'name' parameter"
                        )
                    }
                    let success = writeDeleteSkill(named: name)
                    return .object([
                        "success": .bool(success),
                        "action": .string("delete"),
                        "name": .string(name),
                        "message": .string(success ? "Skill '\(name)' deleted." : "Skill '\(name)' not found.")
                    ])

                case "toggle":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'toggle' requires 'name' parameter"
                        )
                    }
                    let result = writeToggleSkill(named: name)
                    return .object([
                        "success": .bool(result.found),
                        "action": .string("toggle"),
                        "name": .string(name),
                        "enabled": .bool(result.newState),
                        "message": .string(result.found ? "Skill '\(name)' is now \(result.newState ? "enabled" : "disabled")." : "Skill '\(name)' not found.")
                    ])

                case "rename":
                    guard case .string(let name) = args["name"],
                          case .string(let newName) = args["newName"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'rename' requires 'name' and 'newName' parameters"
                        )
                    }
                    let success = writeRenameSkill(named: name, to: newName)
                    return .object([
                        "success": .bool(success),
                        "action": .string("rename"),
                        "oldName": .string(name),
                        "newName": .string(newName),
                        "message": .string(success ? "Skill renamed '\(name)' → '\(newName)'." : "Failed — skill not found or name conflict.")
                    ])

                case "update_url":
                    guard case .string(let name) = args["name"],
                          case .string(let url) = args["url"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'update_url' requires 'name' and 'url' parameters"
                        )
                    }
                    switch NotionPageRef.normalizedPageId(from: url) {
                    case .failure(let err):
                        return .object([
                            "success": .bool(false),
                            "action": .string("update_url"),
                            "name": .string(name),
                            "message": .string(err.message)
                        ])
                    case .success(let normalized):
                        let success = writeUpdateSkillURL(named: name, newPageId: normalized)
                        return .object([
                            "success": .bool(success),
                            "action": .string("update_url"),
                            "name": .string(name),
                            "message": .string(success ? "Skill '\(name)' URL updated." : "Skill '\(name)' not found.")
                        ])
                    }

                case "set_visibility":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'set_visibility' requires 'name' and 'visibility' parameters"
                        )
                    }
                    guard let vis = parseVisibilityArg(args) else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'set_visibility' requires valid visibility: routing or standard"
                        )
                    }
                    let success = writeSetVisibility(named: name, visibility: vis)
                    return .object([
                        "success": .bool(success),
                        "action": .string("set_visibility"),
                        "name": .string(name),
                        "visibility": .string(vis.rawValue),
                        "message": .string(success ? "Skill '\(name)' visibility set to \(vis.rawValue)." : "Skill '\(name)' not found.")
                    ])

                case "bulk_add":
                    guard case .array(let skillsArray) = args["skills"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'bulk_add' requires 'skills' array parameter"
                        )
                    }
                    var pairs: [(name: String, pageId: String)] = []
                    for item in skillsArray {
                        if case .object(let obj) = item,
                           case .string(let name) = obj["name"],
                           case .string(let url) = obj["url"] {
                            pairs.append((name: name, pageId: url))
                        }
                    }
                    let result = writeBulkAdd(skills: pairs)
                    var bulk: [String: Value] = [
                        "action": .string("bulk_add"),
                        "added": .int(result.added),
                        "skipped": .int(result.skipped),
                        "total": .int(pairs.count),
                        "message": .string("Bulk add complete: \(result.added) added, \(result.skipped) skipped.")
                    ]
                    if !result.invalidPageRows.isEmpty {
                        bulk["invalidPageRows"] = .array(result.invalidPageRows.map { row in
                            .object([
                                "name": .string(row.name),
                                "reason": .string(row.reason)
                            ])
                        })
                    }
                    return .object(bulk)

                case "set_metadata":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'set_metadata' requires 'name' parameter"
                        )
                    }
                    let hasSummary = args["summary"] != nil
                    let hasTrig = args["triggerPhrases"] != nil
                    let hasAnti = args["antiTriggerPhrases"] != nil
                    guard hasSummary || hasTrig || hasAnti else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'set_metadata' requires at least one of: summary, triggerPhrases, antiTriggerPhrases"
                        )
                    }
                    var skills = readAllSkills()
                    guard let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
                        return .object([
                            "success": .bool(false),
                            "action": .string("set_metadata"),
                            "message": .string("Skill not found.")
                        ])
                    }
                    let cur = skills[idx]
                    let newSummary: String = {
                        if case .string(let s) = args["summary"] { return SkillMetadataLimits.clampedSummary(s) }
                        return cur.summary
                    }()
                    let newTrig: [String] = {
                        if let v = args["triggerPhrases"] {
                            return SkillMetadataLimits.clampedPhraseList(Self.parseStringArrayValue(v))
                        }
                        return cur.triggerPhrases
                    }()
                    let newAnti: [String] = {
                        if let v = args["antiTriggerPhrases"] {
                            return SkillMetadataLimits.clampedPhraseList(Self.parseStringArrayValue(v))
                        }
                        return cur.antiTriggerPhrases
                    }()
                    skills[idx] = SkillConfig(
                        name: cur.name,
                        notionPageId: cur.notionPageId,
                        enabled: cur.enabled,
                        visibility: cur.visibility,
                        summary: newSummary,
                        triggerPhrases: newTrig,
                        antiTriggerPhrases: newAnti,
                        url: cur.url,
                        platform: cur.platform
                    )
                    writeSkills(skills)
                    await skillCache.clear()
                    return .object([
                        "success": .bool(true),
                        "action": .string("set_metadata"),
                        "name": .string(name),
                        "message": .string("Metadata updated.")
                    ])

                case "sync_metadata_to_notion":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'sync_metadata_to_notion' requires 'name' parameter"
                        )
                    }
                    guard let skill = lookupSkill(named: name) else {
                        return .object([
                            "success": .bool(false),
                            "action": .string("sync_metadata_to_notion"),
                            "message": .string("Skill not found.")
                        ])
                    }
                    let pageId = skill.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard NotionPageRef.isValidStoredPageId(pageId) else {
                        return .object([
                            "success": .bool(false),
                            "action": .string("sync_metadata_to_notion"),
                            "message": .string("Skill has an invalid Notion page id — fix in Settings → Skills.")
                        ])
                    }
                    do {
                        let client = try NotionClient()
                        let patch = try SkillNotionMetadata.buildPagePropertiesPatchData(
                            summary: skill.summary,
                            triggerPhrases: skill.triggerPhrases,
                            antiTriggerPhrases: skill.antiTriggerPhrases
                        )
                        _ = try await client.updatePage(pageId: pageId, properties: patch)
                        await skillCache.clear()
                        return .object([
                            "success": .bool(true),
                            "action": .string("sync_metadata_to_notion"),
                            "name": .string(name),
                            "message": .string("Notion page properties updated from MCP metadata.")
                        ])
                    } catch let error as NotionClientError {
                        return .object([
                            "success": .bool(false),
                            "action": .string("sync_metadata_to_notion"),
                            "error": .string(error.localizedDescription)
                        ])
                    } catch {
                        return .object([
                            "success": .bool(false),
                            "action": .string("sync_metadata_to_notion"),
                            "error": .string(error.localizedDescription)
                        ])
                    }

                case "sync_metadata_from_notion":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'sync_metadata_from_notion' requires 'name' parameter"
                        )
                    }
                    guard let skill = lookupSkill(named: name) else {
                        return .object([
                            "success": .bool(false),
                            "action": .string("sync_metadata_from_notion"),
                            "message": .string("Skill not found.")
                        ])
                    }
                    let pageId = skill.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard NotionPageRef.isValidStoredPageId(pageId) else {
                        return .object([
                            "success": .bool(false),
                            "action": .string("sync_metadata_from_notion"),
                            "message": .string("Skill has an invalid Notion page id — fix in Settings → Skills.")
                        ])
                    }
                    do {
                        let client = try NotionClient()
                        let pageData = try await client.getPage(pageId: pageId)
                        guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any],
                              let properties = pageJSON["properties"] as? [String: Any] else {
                            return .object([
                                "success": .bool(false),
                                "action": .string("sync_metadata_from_notion"),
                                "message": .string("Failed to parse Notion page.")
                            ])
                        }
                        let sum = SkillNotionMetadata.richTextPlain(
                            propertyName: SkillBridgeNotionPropertyNames.summary,
                            properties: properties
                        )
                        let trigText = SkillNotionMetadata.richTextPlain(
                            propertyName: SkillBridgeNotionPropertyNames.triggers,
                            properties: properties
                        )
                        let antiText = SkillNotionMetadata.richTextPlain(
                            propertyName: SkillBridgeNotionPropertyNames.antiTriggers,
                            properties: properties
                        )
                        let trig = SkillMetadataLimits.clampedPhraseList(
                            SkillNotionMetadata.phrasesFromStoredText(trigText)
                        )
                        let anti = SkillMetadataLimits.clampedPhraseList(
                            SkillNotionMetadata.phrasesFromStoredText(antiText)
                        )
                        let newSummary = SkillMetadataLimits.clampedSummary(sum)
                        var skills = readAllSkills()
                        guard let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
                            return .object([
                                "success": .bool(false),
                                "action": .string("sync_metadata_from_notion"),
                                "message": .string("Skill not found.")
                            ])
                        }
                        let cur = skills[idx]
                        skills[idx] = SkillConfig(
                            name: cur.name,
                            notionPageId: cur.notionPageId,
                            enabled: cur.enabled,
                            visibility: cur.visibility,
                            summary: newSummary,
                            triggerPhrases: trig,
                            antiTriggerPhrases: anti,
                            url: cur.url,
                            platform: cur.platform
                        )
                        writeSkills(skills)
                        await skillCache.clear()
                        return .object([
                            "success": .bool(true),
                            "action": .string("sync_metadata_from_notion"),
                            "name": .string(name),
                            "message": .string("MCP metadata updated from Notion.")
                        ])
                    } catch let error as NotionClientError {
                        return .object([
                            "success": .bool(false),
                            "action": .string("sync_metadata_from_notion"),
                            "error": .string(error.localizedDescription)
                        ])
                    } catch {
                        return .object([
                            "success": .bool(false),
                            "action": .string("sync_metadata_from_notion"),
                            "error": .string(error.localizedDescription)
                        ])
                    }

                default:
                    return .object([
                        "error": .string("Unknown action: '\(action)'"),
                        "hint": .string("Valid actions: list, add, delete, toggle, rename, update_url, set_visibility, bulk_add, set_metadata, sync_metadata_to_notion, sync_metadata_from_notion")
                    ])
                }
            }
        ))
    }

    // MARK: - UserDefaults Write Helpers (non-MainActor safe)

    /// Read all skills from UserDefaults (thread-safe).
    private static func readAllSkills() -> [SkillConfig] {
        guard let data = UserDefaults.standard.data(forKey: BridgeDefaults.skills),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return []
        }
        return skills
    }

    /// Write skills array back to UserDefaults.
    private static func writeSkills(_ skills: [SkillConfig]) {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        UserDefaults.standard.set(data, forKey: BridgeDefaults.skills)
        NotificationCenter.default.post(name: .notionBridgeSkillsStorageDidChange, object: nil)
    }

    /// Add a skill via UserDefaults. Returns true on success.
    private static func writeAddSkill(name: String, pageId: String, visibility: SkillVisibility = .standard, url: String? = nil, platform: SkillPlatform = .notion) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var skills = readAllSkills()
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        skills.append(SkillConfig(
            name: trimmed,
            notionPageId: pageId,
            enabled: true,
            visibility: visibility,
            summary: "",
            triggerPhrases: [],
            antiTriggerPhrases: [],
            url: url,
            platform: platform
        ))
        writeSkills(skills)
        return true
    }

    private static func parseVisibilityArg(_ args: [String: Value]) -> SkillVisibility? {
        guard case .string(let raw) = args["visibility"] else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch t {
        case "routing": return .routing
        case "standard": return .standard
        case "adminOnly": return .standard
        default: return nil
        }
    }

    private static func writeSetVisibility(named name: String, visibility: SkillVisibility) -> Bool {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(
                name: s.name,
                notionPageId: s.notionPageId,
                enabled: s.enabled,
                visibility: visibility,
                summary: s.summary,
                triggerPhrases: s.triggerPhrases,
                antiTriggerPhrases: s.antiTriggerPhrases,
                url: s.url,
                platform: s.platform
            )
            writeSkills(skills)
            return true
        }
        return false
    }

    /// Delete a skill by name. Returns true if found and removed.
    private static func writeDeleteSkill(named name: String) -> Bool {
        var skills = readAllSkills()
        let before = skills.count
        skills.removeAll { $0.name.lowercased() == name.lowercased() }
        guard skills.count < before else { return false }
        writeSkills(skills)
        return true
    }

    /// Toggle a skill's enabled state. Returns (found, newState).
    private static func writeToggleSkill(named name: String) -> (found: Bool, newState: Bool) {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(
                name: s.name,
                notionPageId: s.notionPageId,
                enabled: !s.enabled,
                visibility: s.visibility,
                summary: s.summary,
                triggerPhrases: s.triggerPhrases,
                antiTriggerPhrases: s.antiTriggerPhrases,
                url: s.url,
                platform: s.platform
            )
            let newState = skills[idx].enabled
            writeSkills(skills)
            return (true, newState)
        }
        return (false, false)
    }

    /// Rename a skill. Returns true on success.
    private static func writeRenameSkill(named oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var skills = readAllSkills()
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == oldName.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(
                name: trimmed,
                notionPageId: s.notionPageId,
                enabled: s.enabled,
                visibility: s.visibility,
                summary: s.summary,
                triggerPhrases: s.triggerPhrases,
                antiTriggerPhrases: s.antiTriggerPhrases,
                url: s.url,
                platform: s.platform
            )
            writeSkills(skills)
            return true
        }
        return false
    }

    /// Update a skill's page ID. Returns true on success.
    private static func writeUpdateSkillURL(named name: String, newPageId: String) -> Bool {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(
                name: s.name,
                notionPageId: newPageId,
                enabled: s.enabled,
                visibility: s.visibility,
                summary: s.summary,
                triggerPhrases: s.triggerPhrases,
                antiTriggerPhrases: s.antiTriggerPhrases,
                url: s.url,
                platform: s.platform
            )
            writeSkills(skills)
            return true
        }
        return false
    }

    private struct BulkAddWriteResult {
        let added: Int
        let skipped: Int
        let invalidPageRows: [(name: String, reason: String)]
    }

    /// Bulk add skills. Skips invalid page URLs (per-row reasons) and duplicate names.
    private static func writeBulkAdd(skills newSkills: [(name: String, pageId: String)]) -> BulkAddWriteResult {
        var existing = readAllSkills()
        var added = 0
        var skipped = 0
        var invalidPageRows: [(name: String, reason: String)] = []
        for s in newSkills {
            let trimmed = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                skipped += 1
                continue
            }
            if existing.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                skipped += 1
                continue
            }
            switch NotionPageRef.normalizedPageId(from: s.pageId) {
            case .failure(let err):
                skipped += 1
                invalidPageRows.append((trimmed, err.message))
            case .success(let normalized):
                existing.append(SkillConfig(
                    name: trimmed,
                    notionPageId: normalized,
                    enabled: true,
                    visibility: .standard,
                    summary: "",
                    triggerPhrases: [],
                    antiTriggerPhrases: []
                ))
                added += 1
            }
        }
        writeSkills(existing)
        return BulkAddWriteResult(added: added, skipped: skipped, invalidPageRows: invalidPageRows)
    }

    // MARK: - Config Helpers

    /// Lightweight Codable struct matching `SkillsManager.Skill` layout.
    /// Used to read directly from UserDefaults without requiring @MainActor.
    private struct SkillConfig: Codable {
        let name: String
        let notionPageId: String
        let enabled: Bool
        let visibility: SkillVisibility
        let summary: String
        let triggerPhrases: [String]
        let antiTriggerPhrases: [String]
        /// V2-SKILLS: Original URL for click-to-open.
        let url: String?
        /// V2-SKILLS: Auto-detected platform. Defaults to .notion for backward compat.
        let platform: SkillPlatform

        enum CodingKeys: String, CodingKey {
            case name, notionPageId, enabled, visibility, summary, triggerPhrases, antiTriggerPhrases, url, platform
        }

        init(
            name: String,
            notionPageId: String,
            enabled: Bool,
            visibility: SkillVisibility = .standard,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            self.name = name
            self.notionPageId = notionPageId
            self.enabled = enabled
            self.visibility = visibility
            self.summary = SkillMetadataLimits.clampedSummary(summary)
            self.triggerPhrases = SkillMetadataLimits.clampedPhraseList(triggerPhrases)
            self.antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(antiTriggerPhrases)
            self.url = url
            self.platform = platform
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            notionPageId = try c.decode(String.self, forKey: .notionPageId)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            visibility = try c.decodeIfPresent(SkillVisibility.self, forKey: .visibility) ?? .standard
            let rawSummary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            let rawTriggers = try c.decodeIfPresent([String].self, forKey: .triggerPhrases) ?? []
            let rawAnti = try c.decodeIfPresent([String].self, forKey: .antiTriggerPhrases) ?? []
            summary = SkillMetadataLimits.clampedSummary(rawSummary)
            triggerPhrases = SkillMetadataLimits.clampedPhraseList(rawTriggers)
            antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(rawAnti)
            // V2-SKILLS: Backward-compat — existing skills default to .notion, no URL
            url = try c.decodeIfPresent(String.self, forKey: .url)
            platform = try c.decodeIfPresent(SkillPlatform.self, forKey: .platform) ?? .notion
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(notionPageId, forKey: .notionPageId)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(visibility, forKey: .visibility)
            try c.encode(summary, forKey: .summary)
            try c.encode(triggerPhrases, forKey: .triggerPhrases)
            try c.encode(antiTriggerPhrases, forKey: .antiTriggerPhrases)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encode(platform, forKey: .platform)
        }

        /// Stable token for `fetch_skill` cache invalidation when metadata changes.
        var metadataCacheToken: String {
            let raw = "\(summary)\u{1e}\(triggerPhrases.joined(separator: "\u{1f}"))\u{1e}\(antiTriggerPhrases.joined(separator: "\u{1f}"))"
            var h: UInt64 = 14695981039346656037
            for b in raw.utf8 {
                h ^= UInt64(b)
                h &*= 1099511628211
            }
            return String(h, radix: 16)
        }
    }

    private static func mcpMetadataObject(_ s: SkillConfig) -> [String: Value] {
        [
            "summary": .string(s.summary),
            "triggerPhrases": .array(s.triggerPhrases.map { .string($0) }),
            "antiTriggerPhrases": .array(s.antiTriggerPhrases.map { .string($0) })
        ]
    }

    private static func skillRowFields(_ s: SkillConfig) -> [String: Value] {
        var row = mcpMetadataObject(s)
        row["name"] = .string(s.name)
        row["notionPageId"] = .string(s.notionPageId)
        row["platform"] = .string(s.platform.rawValue)
        if let url = s.url {
            row["url"] = .string(url)
        }
        return row
    }

    private static func parseStringArrayValue(_ v: Value) -> [String] {
        switch v {
        case .array(let arr):
            return arr.compactMap { item in
                if case .string(let s) = item { return s }
                return nil
            }
        case .string(let s):
            return s.split(whereSeparator: \.isNewline).map { String($0) }
        default:
            return []
        }
    }

    /// Look up a skill from UserDefaults by name with fuzzy matching (v1.7.0, F5).
    /// Tries: exact (case-insensitive) > normalized (strip "sk ", space/hyphen swap) > substring.
    private static func lookupSkill(named name: String) -> SkillConfig? {
        guard let data = UserDefaults.standard.data(forKey: BridgeDefaults.skills),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return nil
        }
        let input = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 1. Exact case-insensitive
        if let exact = skills.first(where: { $0.name.lowercased() == input }) {
            return exact
        }
        // 2. Normalized: strip "sk " prefix, swap spaces and hyphens
        let stripped = input.hasPrefix("sk ") ? String(input.dropFirst(3)) : input
        let variants = [stripped, stripped.replacingOccurrences(of: " ", with: "-"), stripped.replacingOccurrences(of: "-", with: " ")]
        for v in variants {
            if let match = skills.first(where: { $0.name.lowercased() == v }) {
                return match
            }
        }
        // 3. Substring: input contained in skill name or vice versa (unique match only)
        let subs = skills.filter {
            $0.name.lowercased().contains(stripped) || stripped.contains($0.name.lowercased())
        }
        if subs.count == 1 { return subs[0] }
        return nil
    }

    /// List all configured skill names.
    private static func listAvailableSkillNames() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: BridgeDefaults.skills),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return []
        }
        return skills.filter(\.enabled).map(\.name) // Only enabled skills
    }

    /// C1: Find close matches for a skill name using edit distance.
    private static func closestSkillMatches(for input: String, maxResults: Int = 3) -> [String] {
        let available = listAvailableSkillNames()
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped = normalized.hasPrefix("sk ") ? String(normalized.dropFirst(3)) : normalized

        // Score each skill by edit distance to input variants
        let scored = available.map { skill -> (String, Int) in
            let skillLow = skill.lowercased()
            let dist = min(
                editDistance(skillLow, stripped),
                editDistance(skillLow, stripped.replacingOccurrences(of: " ", with: "-")),
                editDistance(skillLow, stripped.replacingOccurrences(of: "-", with: " "))
            )
            return (skill, dist)
        }
        .filter { $0.1 <= max(3, $0.0.count / 2) }  // Only reasonably close matches
        .sorted { $0.1 < $1.1 }

        return Array(scored.prefix(maxResults).map { $0.0 })
    }

    /// Simple Levenshtein edit distance.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : 1 + min(prev, dp[j], dp[j-1])
                prev = temp
            }
        }
        return dp[n]
    }
}
