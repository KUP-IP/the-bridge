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

/// Per-fetch cache for `<mention-page>` title resolution: one Notion
/// `getPage` per distinct page URL within a single `fetch_skill` call
/// (mirrors the cmd-w2 cached-lookup rule). Caches `nil` too so an
/// unresolved URL is not re-fetched.
private actor MentionTitleCache {
    private var titles: [String: String?] = [:]
    func get(_ url: String) -> String?? { titles[url] }
    func set(_ url: String, title: String?) { titles[url] = title }
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
        let skills = readAllSkills().filter { skill in
            guard skill.enabled, skill.routingDiscoverable else { return false }
            switch skill.source {
            case .notion(let pid):
                return NotionPageRef.isValidStoredPageId(pid.trimmingCharacters(in: .whitespacesAndNewlines))
            case .file:
                // W2 D6: file-source routing skills are merged in via
                // `list_routing_skills` (see registerListRoutingSkills);
                // the initial instructions block sticks to Notion skills
                // to preserve the existing wire shape.
                return true
            }
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
        // PKT-907: now accepts slash-delimited paths (`"parent/child"`)
        // and an optional `intent` parameter for confidence-ranked
        // specialist routing. Depth > 1 paths return parent + a
        // `depth-guard` annotation (never crash). Path that names a
        // non-existent child returns parent + `specialist-not-found`.
        await router.register(ToolRegistration(
            name: "fetch_skill",
            module: moduleName,
            tier: .open,
            description: """
            Fetch one skill page's full body. Two ways to address a specialist sub-skill:

              1. Path syntax: name="project-keepr/update" → resolves the "update" \
            child page (Notion) or specialists/update.md (file source). Depth > 1 is \
            rejected with a depth-guard annotation (parent body still returned).
              2. Intent ranking: name="project-keepr", intent="triage stale projects" \
            → ranks the parent's specialists and returns the best match (score ≥ 0.4); \
            otherwise returns the parent body with a low-confidence annotation.

            An unresolvable specialist name never errors — the envelope carries the \
            parent body plus a `specialist-not-found` annotation. Use `name` alone \
            for the parent body (pre-PKT-907 behavior, unchanged).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Skill name (case-insensitive). Accepts slash-delimited paths like 'project-keepr/update' to address a specialist; depth > 1 is rejected with an annotation.")
                    ]),
                    "intent": .object([
                        "type": .string("string"),
                        "description": .string("Optional natural-language intent. When provided, ranks the named parent's specialists and returns the best match (score ≥ 0.4); otherwise falls back to the parent body with a low-confidence annotation.")
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
                      case .string(let rawName) = args["name"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "fetch_skill",
                        reason: "missing required 'name' parameter"
                    )
                }

                // PKT-907 W1: parse slash-delimited path. Pre-PKT-907
                // single-name calls flow through unchanged (the parser
                // returns parent only when no `/` is present). Empty /
                // whitespace-only names fall through to the existing
                // "skill not found" envelope path — never an error
                // throw (pre-PKT-907 wire contract).
                let parsedPath = SkillPath.parse(rawName) ?? SkillPath(parent: "", child: nil, depthExceeded: false)
                let name = parsedPath.parent

                // PKT-907 W2: optional intent string. Only triggers
                // specialist ranking when both are present.
                let intentArg: String? = {
                    if case .string(let s) = args["intent"], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return nil
                }()

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
                    // W2 D4: fall back to the filesystem index. A file-
                    // source skill with this name (bundled or user dir)
                    // takes effect when Notion-skills don't shadow it.
                    if let fileSkill = await FilesystemSkillIndex.shared.skill(named: name) {
                        guard Self.isFileSkillEnabled(path: fileSkill.path) else {
                            return .object([
                                "error": .string("File-source skill '\(name)' is disabled."),
                                "hint": .string("Enable it in Settings \u{2192} Skills tab.")
                            ])
                        }
                        // PKT-907: file-source path/intent dispatch.
                        return await Self.dispatchFileSpecialist(
                            parent: fileSkill,
                            parsedPath: parsedPath,
                            intent: intentArg
                        )
                    }
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

                // PKT-907: cache key must include the resolved sub-skill
                // selector so a `parent/child` request never returns the
                // parent-body cache entry (and vice versa).
                let pathSelectorKey: String = {
                    if parsedPath.depthExceeded { return "|dg" }
                    if let c = parsedPath.child { return "|p=\(c.lowercased())" }
                    if let i = intentArg { return "|i=\(i.lowercased())" }
                    return ""
                }()
                let cacheKey = "\(name.lowercased())|n=\(includeNested)|mb=\(maxBlocks)|md=\(maxDepth)|meta=\(skillConfig.metadataCacheToken)\(pathSelectorKey)"

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

                // cmd-w4: includeNested / maxBlocks / maxDepth are retained
                // for input-schema + cache-key stability (existing callers
                // and cached entries keyed on them stay valid) but no
                // longer drive a block-tree walk — the /markdown path
                // returns one server-rendered document in a single call.
                _ = includeNested; _ = maxBlocks; _ = maxDepth

                // Fetch from Notion API
                do {
                    let client = try NotionClient()
                    let pageId = pageIdRaw

                    // Properties/title still come from getPage — the skill
                    // envelope carries title + url (the block tree does not).
                    let pageData = try await client.getPage(pageId: pageId)
                    guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else {
                        return .object(["error": .string("Failed to parse Notion page response")])
                    }

                    let url = pageJSON["url"] as? String ?? ""
                    var title = "Untitled"
                    // cu-sa: capture the SAME already-fetched properties
                    // blob used for the title so the new `properties`
                    // envelope key surfaces it (no extra network call).
                    let pageProperties = pageJSON["properties"] as? [String: Any] ?? [:]
                    if !pageProperties.isEmpty {
                        title = NotionJSON.extractTitle(from: pageProperties)
                    }

                    // PKT-907: specialist dispatch (path / intent / depth-guard).
                    // Returns either a swapped-in specialist envelope OR
                    // a nil signal meaning "use the parent body with the
                    // (optionally) computed annotation injected below".
                    let specialistDispatch = await Self.dispatchNotionSpecialist(
                        client: client,
                        parentPageId: pageId,
                        parentName: skillConfig.name,
                        parsedPath: parsedPath,
                        intent: intentArg
                    )

                    // If the dispatch resolved a real specialist child page,
                    // swap its identity in for the envelope build.
                    let envelopeTitle = specialistDispatch.resolvedSpecialist?.title ?? title
                    let envelopeURL = specialistDispatch.resolvedSpecialist?.url ?? url
                    let envelopePageId = specialistDispatch.resolvedSpecialist?.pageId ?? pageId
                    let envelopeProperties = specialistDispatch.resolvedSpecialist?.properties ?? pageProperties

                    // cmd-w4: body via the server /markdown render (one call;
                    // preserves headings/lists/code/tables) instead of the
                    // depth-first block walk + extractPlainText join.
                    let markdownData = try await client.getPageMarkdown(pageId: envelopePageId)
                    let rawMarkdown = Self.skillMarkdownString(fromMarkdownJSON: markdownData)

                    // Skill-body <mention-page> tags now render as
                    // [Title](url) via the shared MentionResolver (cmd-w2),
                    // resolved through the cached getPage title lookup;
                    // unresolved / non-page subtypes → safe [link](url).
                    var result = await Self.buildSkillResult(
                        skill: skillConfig,
                        title: envelopeTitle,
                        url: envelopeURL,
                        markdownJSONOrText: rawMarkdown,
                        titleLookup: Self.makeSkillMentionTitleLookup(),
                        pageProperties: envelopeProperties
                    )
                    // PKT-907: surface the resolution outcome in the envelope.
                    result = Self.annotateEnvelope(
                        result,
                        parentName: skillConfig.name,
                        dispatch: specialistDispatch
                    )
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

    // MARK: - skills_routing_list (Sprint A · mcp-builder #14 rename)

    private static func registerListRoutingSkills(on router: ToolRouter) async {
        // Sprint A · mcp-builder #14: list_routing_skills → skills_routing_list
        // (mcp-builder prefix-consistency: skills_* family).
        let skillsRoutingList = ToolRegistration(
            name: "skills_routing_list",
            module: moduleName,
            tier: .open,
            description: "Refresh the skill routing index (summaries + trigger phrases). Initial index is provided in server instructions at connection time — only call after a skill change.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                // W2 D6/W4: merged listing — Notion-source routing-visible
                // skills + file-source skills whose effective routing flag
                // is true (explicit toggle or frontmatter
                // `visibility: routing`).
                // Collisions annotate the Notion-source row with a
                // `shadows: file:<path>` field for operator clarity;
                // Notion wins on collision (D4).
                let items = await Self.mergedRoutingSkills()
                return .object([
                    "skills": .array(items),
                    "count": .int(items.count)
                ])
            }
        )
        await router.register(skillsRoutingList)
        // One-cycle deprecation alias under the old name.
        await router.register(ToolDeprecationAlias.renameAlias(
            oldName: "list_routing_skills",
            newName: "skills_routing_list",
            from: skillsRoutingList
        ))
    }

    // MARK: - manage_skill Tool (PKT-477 Feature 3) + Sprint A · #2 split

    /// Sprint A · mcp-builder #2: manage_skill's 11-action polymorphism is
    /// the worst-case schema-clarity violation in the catalog. We split it
    /// into 5 focused primitives (skill_create, skill_delete, skill_update,
    /// skill_rename, skill_sync_notion) and keep manage_skill itself as a
    /// one-cycle deprecation alias that dispatches on `action` to the same
    /// handler. The primitives wrap the SAME handler — they just inject the
    /// `action` arg server-side, so agents can pick the right primitive by
    /// name without a polymorphic enum decision.
    ///
    /// Action → primitive map (the 11 actions collapse onto 5 verbs):
    ///   skill_create        ← add, bulk_add
    ///   skill_delete        ← delete
    ///   skill_update        ← toggle, update_url, set_visibility, set_metadata
    ///   skill_rename        ← rename
    ///   skill_sync_notion   ← sync_metadata_to_notion, sync_metadata_from_notion
    ///   (`list` stays on manage_skill — fetch_skill already covers per-skill
    ///    reads, and skills_routing_list covers the routing-visible subset.)

    /// Register the `manage_skill` tool on the given router.
    private static func registerManageSkill(on router: ToolRouter, skillCache: SkillCache) async {

        // Capture the handler closure for reuse by the 5 split primitives.
        let manageSkill = ToolRegistration(
            name: "manage_skill",
            module: moduleName,
            tier: .notify, // was .orange — no such SecurityTier member
            description: "DEPRECATED — split into skill_create / skill_delete / skill_update / skill_rename / skill_sync_notion in Sprint A · mcp-builder #2. Removed in 3.5.0. Add, edit, delete, toggle, rename, or sync skills + their Notion metadata (trigger phrases, anti-trigger phrases, summary, visibility).",
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
                        "description": .string("SkillVisibility for add/set_visibility: routing | standard | command (command = appears in the global Commands palette; still fetchable by name. legacy adminOnly accepted as standard)")
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
                        // W4-3.4.2: envelope now exposes BOTH the legacy
                        // `visibility` string (derived; one-cycle back-
                        // compat) AND the new flag pair so MCP callers
                        // can read the combined state losslessly.
                        var row: [String: Value] = [
                            "name": .string(skill.name),
                            "uuid": .string(skill.notionPageId),
                            "enabled": .bool(skill.enabled),
                            "visibility": .string(skill.visibility.rawValue),
                            "routingDiscoverable": .bool(skill.routingDiscoverable),
                            "inCommandPalette": .bool(skill.inCommandPalette),
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
                            reason: "'set_visibility' requires valid visibility: routing, standard, or command"
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
                    // W4-3.4.2 H1 fix: preserve flag pair directly
                    // instead of round-tripping through the legacy enum
                    // (the back-compat enum→flag mapper would collapse
                    // the combined state routingDiscoverable=true &&
                    // inCommandPalette=true to .command, losing the
                    // routing bit).
                    skills[idx] = SkillConfig(
                        name: cur.name,
                        source: cur.source,
                        enabled: cur.enabled,
                        routingDiscoverable: cur.routingDiscoverable,
                        inCommandPalette: cur.inCommandPalette,
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
                        // W4-3.4.2 H1 fix: flag-direct reconstruction.
                        skills[idx] = SkillConfig(
                            name: cur.name,
                            source: cur.source,
                            enabled: cur.enabled,
                            routingDiscoverable: cur.routingDiscoverable,
                            inCommandPalette: cur.inCommandPalette,
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
        )
        await router.register(manageSkill)

        // Sprint A · mcp-builder #2: register the 5 split primitives.
        // Each primitive forwards into manage_skill's handler with `action`
        // injected, so the implementation stays a single source of truth.
        await Self.registerSkillSplitPrimitives(on: router, primaryHandler: manageSkill.handler)
    }

    // MARK: - Sprint A · #2 split primitives

    /// Register the 5 mcp-builder primitives that replace manage_skill's
    /// 11-action polymorphism. Each primitive's handler injects the
    /// appropriate `action` (or `actions` map, for the multi-action
    /// primitives like skill_update) into the input before forwarding.
    private static func registerSkillSplitPrimitives(
        on router: ToolRouter,
        primaryHandler: @escaping @Sendable (Value) async throws -> Value
    ) async {
        // skill_create — folds manage_skill add + bulk_add.
        await router.register(ToolRegistration(
            name: "skill_create",
            module: moduleName,
            tier: .notify,
            description: "Create one or more skills (Notion-source or file-source). For a single skill: name + url (+ optional visibility). For bulk: skills=[{name,url},...]. Replaces manage_skill action='add'/'bulk_add'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Skill name (single-skill mode).")]),
                    "url": .object(["type": .string("string"), "description": .string("Notion page URL or hex page ID (single-skill mode).")]),
                    "visibility": .object(["type": .string("string"), "description": .string("routing | standard | command")]),
                    "skills": .object([
                        "type": .string("array"),
                        "description": .string("Array of {name, url} objects for bulk creation."),
                        "items": .object(["type": .string("object")])
                    ]),
                    "bypassConfirmation": .object(["type": .string("boolean")])
                ])
            ]),
            handler: { args in
                // Bulk mode if `skills` is an array; else single-add.
                var merged = Self.unpackArgsObject(args)
                if case .array = merged["skills"] {
                    merged["action"] = .string("bulk_add")
                } else {
                    merged["action"] = .string("add")
                }
                return try await primaryHandler(.object(merged))
            }
        ))

        // skill_delete — folds manage_skill delete.
        await router.register(ToolRegistration(
            name: "skill_delete",
            module: moduleName,
            tier: .notify,
            description: "Delete one skill by name. Replaces manage_skill action='delete'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Skill name to delete.")]),
                    "bypassConfirmation": .object(["type": .string("boolean")])
                ]),
                "required": .array([.string("name")])
            ]),
            handler: { args in
                var merged = Self.unpackArgsObject(args)
                merged["action"] = .string("delete")
                return try await primaryHandler(.object(merged))
            }
        ))

        // skill_update — folds manage_skill toggle, update_url, set_visibility, set_metadata.
        await router.register(ToolRegistration(
            name: "skill_update",
            module: moduleName,
            tier: .notify,
            description: "Update one skill: toggle on/off, change its URL, set visibility, or replace MCP metadata (summary + trigger/anti-trigger phrases). Picks the right action automatically based on which fields are present. Replaces manage_skill toggle/update_url/set_visibility/set_metadata.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Skill name (required).")]),
                    "toggle": .object(["type": .string("boolean"), "description": .string("If true, toggle enabled/disabled.")]),
                    "url": .object(["type": .string("string"), "description": .string("New URL — selects update_url path.")]),
                    "visibility": .object(["type": .string("string"), "description": .string("routing | standard | command — selects set_visibility.")]),
                    "summary": .object(["type": .string("string")]),
                    "triggerPhrases": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "antiTriggerPhrases": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "bypassConfirmation": .object(["type": .string("boolean")])
                ]),
                "required": .array([.string("name")])
            ]),
            handler: { args in
                var merged = Self.unpackArgsObject(args)
                // Decide which underlying action to invoke based on which
                // field is present. Order matches the original manage_skill
                // explicit-action precedence.
                if case .bool(true) = merged["toggle"] {
                    merged["action"] = .string("toggle")
                } else if merged["url"] != nil {
                    merged["action"] = .string("update_url")
                } else if merged["summary"] != nil
                    || merged["triggerPhrases"] != nil
                    || merged["antiTriggerPhrases"] != nil {
                    merged["action"] = .string("set_metadata")
                } else if merged["visibility"] != nil {
                    merged["action"] = .string("set_visibility")
                } else {
                    return .object([
                        "error": .string("skill_update requires at least one update field: toggle, url, visibility, summary, triggerPhrases, antiTriggerPhrases")
                    ])
                }
                return try await primaryHandler(.object(merged))
            }
        ))

        // skill_rename — folds manage_skill rename.
        await router.register(ToolRegistration(
            name: "skill_rename",
            module: moduleName,
            tier: .notify,
            description: "Rename one skill (preserves UUID, enabled state, visibility, metadata). Replaces manage_skill action='rename'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Current skill name.")]),
                    "newName": .object(["type": .string("string"), "description": .string("New skill name.")]),
                    "bypassConfirmation": .object(["type": .string("boolean")])
                ]),
                "required": .array([.string("name"), .string("newName")])
            ]),
            handler: { args in
                var merged = Self.unpackArgsObject(args)
                merged["action"] = .string("rename")
                return try await primaryHandler(.object(merged))
            }
        ))

        // skill_sync_notion — folds manage_skill sync_metadata_to_notion / from_notion.
        await router.register(ToolRegistration(
            name: "skill_sync_notion",
            module: moduleName,
            tier: .notify,
            description: "Sync one skill's MCP metadata (summary + trigger/anti-trigger phrases) between local store and Notion. direction='push' uploads local → Notion. direction='pull' downloads Notion → local. Replaces manage_skill sync_metadata_to_notion / sync_metadata_from_notion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Skill name (required).")]),
                    "direction": .object([
                        "type": .string("string"),
                        "description": .string("'push' = local → Notion. 'pull' = Notion → local."),
                        "enum": .array([.string("push"), .string("pull")])
                    ]),
                    "bypassConfirmation": .object(["type": .string("boolean")])
                ]),
                "required": .array([.string("name"), .string("direction")])
            ]),
            handler: { args in
                var merged = Self.unpackArgsObject(args)
                if case .string(let dir) = merged["direction"] {
                    merged["action"] = .string(dir == "pull" ? "sync_metadata_from_notion" : "sync_metadata_to_notion")
                } else {
                    return .object([
                        "error": .string("skill_sync_notion requires direction='push' or 'pull'")
                    ])
                }
                return try await primaryHandler(.object(merged))
            }
        ))
    }

    /// Unpack a Value argument expected to be an object literal. Returns
    /// empty dict on non-object input (the handler's own validation will
    /// then surface a meaningful error).
    fileprivate static func unpackArgsObject(_ v: Value) -> [String: Value] {
        if case .object(let dict) = v { return dict }
        return [:]
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
        case "command": return .command   // cmd-ux W3: palette visibility
        case "adminOnly": return .standard
        default: return nil
        }
    }

    /// W4-3.4.2: legacy enum-input setter, preserved as a back-compat
    /// wrapper that delegates to the flag-direct path. The 3-state enum
    /// maps to a flag pair via SkillVisibility.asFlags. A caller that
    /// wants the combined state should use `writeSetFlags` instead.
    private static func writeSetVisibility(named name: String, visibility: SkillVisibility) -> Bool {
        let pair = visibility.asFlags
        return writeSetFlags(
            named: name,
            routingDiscoverable: pair.routingDiscoverable,
            inCommandPalette: pair.inCommandPalette
        )
    }

    /// W4-3.4.2 (H1 fix): flag-direct setter — the new SSOT write path
    /// for the visibility axis. Preserves combined-state losslessly
    /// (both flags can be set independently). Returns false if not found.
    private static func writeSetFlags(
        named name: String,
        routingDiscoverable: Bool,
        inCommandPalette: Bool
    ) -> Bool {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(
                name: s.name,
                source: s.source,
                enabled: s.enabled,
                routingDiscoverable: routingDiscoverable,
                inCommandPalette: inCommandPalette,
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
            // W4-3.4.2 H1 fix: flag-direct reconstruction (toggle).
            skills[idx] = SkillConfig(
                name: s.name,
                source: s.source,
                enabled: !s.enabled,
                routingDiscoverable: s.routingDiscoverable,
                inCommandPalette: s.inCommandPalette,
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
            // W4-3.4.2 H1 fix: flag-direct reconstruction (rename).
            skills[idx] = SkillConfig(
                name: trimmed,
                source: s.source,
                enabled: s.enabled,
                routingDiscoverable: s.routingDiscoverable,
                inCommandPalette: s.inCommandPalette,
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
            // W4-3.4.2 H1 fix: flag-direct reconstruction (update_url).
            // The flag-direct ctor takes `source:` so wrap the new
            // pageId in `.notion(pageId:)` to preserve the W2 D2 shape.
            skills[idx] = SkillConfig(
                name: s.name,
                source: .notion(pageId: newPageId),
                enabled: s.enabled,
                routingDiscoverable: s.routingDiscoverable,
                inCommandPalette: s.inCommandPalette,
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
    ///
    /// W2 D2: carries a `SkillSource`. Decodes the new `source` field OR
    /// the legacy `notionPageId` top-level field (union-of-both backward
    /// compat). Encodes BOTH on the way out — forward compat with the
    /// pre-W2 wire format that consumers expect.
    internal struct SkillConfig: Codable {
        let name: String
        let source: SkillSource
        let enabled: Bool
        /// W4 (3.4.1): primary flag-based visibility — mirrors `SkillsManager.Skill`.
        let routingDiscoverable: Bool
        let inCommandPalette: Bool
        let summary: String
        let triggerPhrases: [String]
        let antiTriggerPhrases: [String]
        /// V2-SKILLS: Original URL for click-to-open.
        let url: String?
        /// V2-SKILLS: Auto-detected platform. Defaults to .notion for backward compat.
        let platform: SkillPlatform

        /// Notion page id for `.notion` sources, empty for `.file` sources.
        var notionPageId: String { source.notionPageIdOrEmpty }

        /// Derived legacy view — every call site that branches on a
        /// single enum value continues to work unchanged.
        var visibility: SkillVisibility {
            SkillVisibility.fromFlags(routingDiscoverable: routingDiscoverable, inCommandPalette: inCommandPalette)
        }

        enum CodingKeys: String, CodingKey {
            case name, source, notionPageId, enabled, visibility,
                 routingDiscoverable, inCommandPalette,
                 summary, triggerPhrases, antiTriggerPhrases, url, platform
        }

        /// Legacy ctor — most call sites still pass `notionPageId` directly.
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
            self.init(
                name: name,
                source: .notion(pageId: notionPageId),
                enabled: enabled,
                visibility: visibility,
                summary: summary,
                triggerPhrases: triggerPhrases,
                antiTriggerPhrases: antiTriggerPhrases,
                url: url,
                platform: platform
            )
        }

        /// W2 D2: source-aware ctor (W4: maps enum → flag pair).
        init(
            name: String,
            source: SkillSource,
            enabled: Bool,
            visibility: SkillVisibility = .standard,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            let pair = visibility.asFlags
            self.init(
                name: name,
                source: source,
                enabled: enabled,
                routingDiscoverable: pair.routingDiscoverable,
                inCommandPalette: pair.inCommandPalette,
                summary: summary,
                triggerPhrases: triggerPhrases,
                antiTriggerPhrases: antiTriggerPhrases,
                url: url,
                platform: platform
            )
        }

        /// W4: flag-direct ctor.
        init(
            name: String,
            source: SkillSource,
            enabled: Bool,
            routingDiscoverable: Bool,
            inCommandPalette: Bool,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            self.name = name
            self.source = source
            self.enabled = enabled
            self.routingDiscoverable = routingDiscoverable
            self.inCommandPalette = inCommandPalette
            self.summary = SkillMetadataLimits.clampedSummary(summary)
            self.triggerPhrases = SkillMetadataLimits.clampedPhraseList(triggerPhrases)
            self.antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(antiTriggerPhrases)
            self.url = url
            self.platform = platform
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            if let decoded = try c.decodeIfPresent(SkillSource.self, forKey: .source) {
                source = decoded
            } else if let legacy = try c.decodeIfPresent(String.self, forKey: .notionPageId) {
                source = .notion(pageId: legacy)
            } else {
                source = .notion(pageId: "")
            }
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            // W4 migration: prefer flag pair; fall back to legacy enum.
            if let rd = try c.decodeIfPresent(Bool.self, forKey: .routingDiscoverable),
               let ip = try c.decodeIfPresent(Bool.self, forKey: .inCommandPalette) {
                routingDiscoverable = rd
                inCommandPalette = ip
            } else {
                let legacy = try c.decodeIfPresent(SkillVisibility.self, forKey: .visibility) ?? .standard
                let pair = legacy.asFlags
                routingDiscoverable = pair.routingDiscoverable
                inCommandPalette = pair.inCommandPalette
            }
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
            try c.encode(source, forKey: .source)
            if case .notion(let pid) = source {
                try c.encode(pid, forKey: .notionPageId)
            }
            try c.encode(enabled, forKey: .enabled)
            // W4: write BOTH the flag pair (primary) AND the derived
            // legacy enum value (one-cycle back-compat).
            try c.encode(routingDiscoverable, forKey: .routingDiscoverable)
            try c.encode(inCommandPalette, forKey: .inCommandPalette)
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

    // MARK: - cu-sa: simplified `properties` map

    /// Flatten a Notion page `properties` JSON object (the verbatim
    /// `pageJSON["properties"]` from `getPage`) into a small,
    /// deterministic `{ propertyName: human-readable scalar/array }`
    /// map for the `fetch_skill` envelope.
    ///
    /// This is the *only* new surface added by cu-sa — it is additive:
    /// every pre-existing envelope key and its value type is unchanged;
    /// the result of this function is injected under a single new
    /// `"properties"` key. The page `properties` blob is ALREADY fetched
    /// by `getPage` (it is parsed today purely to extract the title and
    /// then discarded) — this surfaces what is already in hand, it does
    /// NOT add a network call.
    ///
    /// Mapping (Notion property `type` → flattened `Value`):
    ///  - `title` / `rich_text`        → plain text `String`
    ///  - `select` / `status`          → option `name` `String`
    ///  - `multi_select`               → `[String]` of option names
    ///  - `number`                     → `Int` if integral else `Double`
    ///  - `checkbox`                   → `Bool`
    ///  - `date`                       → `start` `String` (range end dropped)
    ///  - `url` / `email` / `phone_number` → `String`
    ///  - `people`                     → `[String]` of person name (else id)
    ///  - `relation`                   → `[String]` of related page ids
    ///  - `files`                      → `[String]` of file names/urls
    ///  - `created_time` / `last_edited_time` → `String`
    ///  - `created_by` / `last_edited_by`     → name `String` (else id)
    ///  - `unique_id`                  → `"prefix-123"` / `"123"` `String`
    ///  - `formula`                    → its resolved inner value (recursed)
    ///  - `rollup`                     → its resolved value (array/number/
    ///                                   date/recursed single)
    ///  - any other / malformed type   → SKIPPED (never throws, never a
    ///                                   partial/garbage value)
    ///
    /// Pure + network-free + deterministic. A page that is not a database
    /// row (no `properties`, or an empty object) flattens to an empty
    /// map — callers see `"properties": {}` , never an error.
    static func flattenProperties(_ properties: [String: Any]) -> [String: Value] {
        var out: [String: Value] = [:]
        for (key, raw) in properties {
            guard let prop = raw as? [String: Any],
                  let type = prop["type"] as? String else {
                continue
            }
            if let v = flattenProperty(type: type, prop: prop) {
                out[key] = v
            }
        }
        return out
    }

    /// Flatten one Notion property value to a `Value`, or `nil` to skip
    /// (unknown / unmodelled / structurally-absent). Never throws.
    private static func flattenProperty(type: String, prop: [String: Any]) -> Value? {
        switch type {
        case "title", "rich_text":
            guard let arr = prop[type] as? [[String: Any]] else { return nil }
            return .string(NotionJSON.extractPlainText(from: arr))

        case "select", "status":
            guard let opt = prop[type] as? [String: Any] else { return nil }
            guard let name = opt["name"] as? String else { return nil }
            return .string(name)

        case "multi_select":
            guard let arr = prop["multi_select"] as? [[String: Any]] else { return nil }
            return .array(arr.compactMap { ($0["name"] as? String).map(Value.string) })

        case "number":
            return flattenNumber(prop["number"])

        case "checkbox":
            guard let b = prop["checkbox"] as? Bool else { return nil }
            return .bool(b)

        case "date":
            guard let d = prop["date"] as? [String: Any],
                  let start = d["start"] as? String else { return nil }
            return .string(start)

        case "url", "email", "phone_number":
            guard let s = prop[type] as? String else { return nil }
            return .string(s)

        case "created_time", "last_edited_time":
            guard let s = prop[type] as? String else { return nil }
            return .string(s)

        case "created_by", "last_edited_by":
            guard let person = prop[type] as? [String: Any] else { return nil }
            return .string(personLabel(person))

        case "people":
            guard let arr = prop["people"] as? [[String: Any]] else { return nil }
            return .array(arr.map { .string(personLabel($0)) })

        case "relation":
            guard let arr = prop["relation"] as? [[String: Any]] else { return nil }
            return .array(arr.compactMap { ($0["id"] as? String).map(Value.string) })

        case "files":
            guard let arr = prop["files"] as? [[String: Any]] else { return nil }
            return .array(arr.compactMap { f -> Value? in
                if let n = f["name"] as? String, !n.isEmpty { return .string(n) }
                if let ext = f["external"] as? [String: Any],
                   let u = ext["url"] as? String { return .string(u) }
                if let file = f["file"] as? [String: Any],
                   let u = file["url"] as? String { return .string(u) }
                return nil
            })

        case "unique_id":
            guard let uid = prop["unique_id"] as? [String: Any] else { return nil }
            guard let num = uid["number"] else { return nil }
            let numStr: String
            if let i = num as? Int { numStr = String(i) }
            else if let d = num as? Double { numStr = String(d) }
            else if let n = num as? NSNumber { numStr = n.stringValue }
            else { return nil }
            if let prefix = uid["prefix"] as? String, !prefix.isEmpty {
                return .string("\(prefix)-\(numStr)")
            }
            return .string(numStr)

        case "formula":
            guard let f = prop["formula"] as? [String: Any],
                  let inner = f["type"] as? String else { return nil }
            return flattenProperty(type: inner, prop: f)

        case "rollup":
            guard let r = prop["rollup"] as? [String: Any],
                  let inner = r["type"] as? String else { return nil }
            if inner == "array", let elems = r["array"] as? [[String: Any]] {
                return .array(elems.compactMap { e -> Value? in
                    guard let et = e["type"] as? String else { return nil }
                    return flattenProperty(type: et, prop: e)
                })
            }
            return flattenProperty(type: inner, prop: r)

        default:
            return nil
        }
    }

    /// Normalise a Notion JSON number to `.int` when integral else
    /// `.double`; `nil` (no value) is skipped.
    private static func flattenNumber(_ raw: Any?) -> Value? {
        switch raw {
        case let i as Int:
            return .int(i)
        case let d as Double:
            return d.rounded() == d && abs(d) < 9.007199254740992e15
                ? .int(Int(d)) : .double(d)
        case let n as NSNumber:
            let d = n.doubleValue
            return d.rounded() == d && abs(d) < 9.007199254740992e15
                ? .int(Int(d)) : .double(d)
        default:
            return nil
        }
    }

    /// Best human label for a Notion person/user object: `name`, else a
    /// person email, else the opaque `id`, else empty string (never nil
    /// so a people/by array stays positional).
    private static func personLabel(_ person: [String: Any]) -> String {
        if let name = person["name"] as? String, !name.isEmpty { return name }
        if let p = person["person"] as? [String: Any],
           let email = p["email"] as? String, !email.isEmpty { return email }
        if let id = person["id"] as? String { return id }
        return ""
    }

    // MARK: - cmd-w4: /markdown body retrieval + mention resolution

    /// Decode the `markdown` string from a `GET /v1/pages/{id}/markdown`
    /// response (`{ "markdown": String }`). Falls back to the raw UTF-8
    /// bytes when the payload is not the JSON envelope — identical decode
    /// contract to `notion_page_markdown_read` and
    /// `CommandsManager.markdownString(fromMarkdownJSON:)`. Public so the
    /// synthetic-fixture tests exercise the exact production decode.
    public static func skillMarkdownString(fromMarkdownJSON data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return (json["markdown"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
    }

    /// String overload of `skillMarkdownString(fromMarkdownJSON:)`.
    public static func skillMarkdownString(fromMarkdownJSON jsonString: String) -> String {
        skillMarkdownString(fromMarkdownJSON: Data(jsonString.utf8))
    }

    /// Pure, network-free builder for the `fetch_skill` return envelope.
    ///
    /// cmd-w4 behavior delta: `content` is now the *server-rendered*
    /// page markdown (headings / lists / code fences / tables preserved)
    /// run through the shared `MentionResolver`, instead of the old
    /// depth-first block walk joined as bare `extractPlainText` lines
    /// (which flattened structure and rendered `<mention-page>` as plain
    /// title text with no link).
    ///
    /// The envelope SHAPE is preserved byte-for-byte for existing MCP
    /// consumers — same keys (`name`, `title`, `url`, `blockCount`,
    /// `truncated`, `content`, the merged skill metadata, optional
    /// `truncationReason`) in the same value types. `blockCount` no longer
    /// maps to a Notion block count (the /markdown path returns one
    /// document, not a block tree); it is kept for shape stability and
    /// reported honestly as the number of non-empty markdown lines.
    /// `truncated` is always `false` on this path (one server call, no
    /// pagination cap) — `truncationReason` is therefore omitted.
    ///
    /// - Parameters:
    ///   - skill: the resolved skill config (supplies `name` + metadata).
    ///   - title: page title for the envelope (from `getPage` properties).
    ///   - url: page url for the envelope (from `getPage`).
    ///   - markdownJSONOrText: the raw `/markdown` body — either the JSON
    ///     envelope or already-extracted markdown; decoded defensively.
    ///   - titleLookup: injected `<mention-page>` title resolver
    ///     (unresolved → `[link](url)`; never throws, never drops).
    ///   - pageProperties: the verbatim `getPage` `properties` blob
    ///     (already fetched for the title) — flattened into the new,
    ///     additive `properties` envelope key. Empty / non-DB page → an
    ///     empty map (`"properties": {}`), never an error. ALL other
    ///     envelope keys + value types are byte-for-byte unchanged.
    private static func buildSkillResult(
        skill: SkillConfig,
        title: String,
        url: String,
        markdownJSONOrText: String,
        titleLookup: MentionResolver.TitleLookup,
        pageProperties: [String: Any] = [:]
    ) async -> Value {
        let markdown = looksLikeMarkdownJSON(markdownJSONOrText)
            ? skillMarkdownString(fromMarkdownJSON: markdownJSONOrText)
            : markdownJSONOrText

        let resolved = await MentionResolver.resolve(
            markdown: markdown,
            titleLookup: titleLookup
        )

        // Honest non-block "blockCount": count non-empty lines so an
        // empty body still reports 0 and the envelope key stays stable.
        let nonEmptyLineCount = resolved
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .reduce(into: 0) { acc, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { acc += 1 }
            }

        let contentValue: String = resolved.isEmpty ? "(no content)" : resolved

        var resultObj: [String: Value] = [
            "name": .string(skill.name),
            "title": .string(title),
            "url": .string(url),
            "blockCount": .int(nonEmptyLineCount),
            "truncated": .bool(false),
            "content": .string(contentValue)
        ]
        resultObj.merge(mcpMetadataObject(skill)) { _, new in new }
        // cu-sa: additive — a single NEW `properties` key carrying the
        // simplified flatten of the already-fetched getPage properties.
        // Empty / non-DB page → `{}`. No pre-existing key is touched.
        resultObj["properties"] = .object(flattenProperties(pageProperties))
        return .object(resultObj)
    }

    /// Public, network-free entry point mirroring `buildSkillResult` but
    /// taking primitives instead of the private `SkillConfig`, so the
    /// synthetic-fixture suite (separate test target) drives the EXACT
    /// production envelope path: decode → MentionResolver → envelope.
    /// `summary` / `triggerPhrases` / `antiTriggerPhrases` reproduce the
    /// merged skill-metadata block of the live result.
    ///
    /// cu-sa: `pageProperties` drives the new `properties` envelope key
    /// through the EXACT production builder with zero network — pass the
    /// verbatim shape `getPage` returns under `pageJSON["properties"]`.
    /// Default `[:]` keeps every pre-cu-sa test calling this wrapper
    /// byte-for-byte unchanged except for the additive `"properties": {}`.
    public static func buildSkillResultForTesting(
        name: String,
        title: String,
        url: String,
        markdownJSONOrText: String,
        summary: String = "",
        triggerPhrases: [String] = [],
        antiTriggerPhrases: [String] = [],
        pageProperties: [String: Any] = [:],
        titleLookup: @escaping MentionResolver.TitleLookup
    ) async -> Value {
        let cfg = SkillConfig(
            name: name,
            notionPageId: "00000000000000000000000000000000",
            enabled: true,
            visibility: .standard,
            summary: summary,
            triggerPhrases: triggerPhrases,
            antiTriggerPhrases: antiTriggerPhrases
        )
        return await buildSkillResult(
            skill: cfg,
            title: title,
            url: url,
            markdownJSONOrText: markdownJSONOrText,
            titleLookup: titleLookup,
            pageProperties: pageProperties
        )
    }

    /// Heuristic: is this the `/markdown` JSON envelope vs. already-
    /// extracted markdown? Conservative — only true when it parses to an
    /// object carrying a `markdown` key (mirrors CommandsManager).
    private static func looksLikeMarkdownJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any]
        else { return false }
        return obj["markdown"] != nil
    }

    /// Build the injectable `<mention-page>` title resolver used by
    /// `fetch_skill`. Mirrors the cmd-w2 cached-lookup pattern: one Notion
    /// `getPage` per distinct page URL, title via `NotionJSON.extractTitle`,
    /// failures degrade to `nil` (→ `MentionResolver` emits `[link](url)`).
    /// Never throws.
    private static func makeSkillMentionTitleLookup() -> MentionResolver.TitleLookup {
        // Per-fetch cache: one network lookup per distinct page URL.
        let cache = MentionTitleCache()
        return { pageURL in
            if let hit = await cache.get(pageURL) { return hit }
            guard let pid = Self.pageIdFromMentionURL(pageURL) else {
                await cache.set(pageURL, title: nil)
                return nil
            }
            guard let client = try? NotionClient(),
                  let data = try? await client.getPage(pageId: pid),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = json["properties"] as? [String: Any] else {
                await cache.set(pageURL, title: nil)
                return nil
            }
            let t = NotionJSON.extractTitle(from: props)
            let resolved = (t == "Untitled" || t.isEmpty) ? nil : t
            await cache.set(pageURL, title: resolved)
            return resolved
        }
    }

    /// Extract a 32-hex page id from a Notion mention `url=` value
    /// (`https://www.notion.so/<slug-><id>` or a bare id). Returns nil
    /// when no plausible id is present (caller → `[link](url)`).
    private static func pageIdFromMentionURL(_ url: String) -> String? {
        let hexset = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        // Last 32-hex run in the string is the page id for notion.so URLs.
        let scalars = url.unicodeScalars
        var run = ""
        var best = ""
        for sc in scalars {
            if hexset.contains(sc) {
                run.unicodeScalars.append(sc)
                if run.count >= 32 { best = String(run.suffix(32)) }
            } else {
                run = ""
            }
        }
        return best.count == 32 ? best : nil
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

    // MARK: - W2 D5/D6: File-source fetch_skill + merged list_routing_skills

    /// W2 D7: per-path enable state for file-source skills lives in
    /// `BridgeDefaults.fileSkillEnabled` (Dictionary<String, Bool>).
    /// Missing entry → enabled (the default). The SKILL.md itself stays
    /// read-only; we never write into it.
    public static func isFileSkillEnabled(path: URL) -> Bool {
        guard let dict = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillEnabled) as? [String: Bool] else {
            return true
        }
        return dict[path.path] ?? true
    }

    /// W2 D7: write the per-path enabled flag.
    public static func setFileSkillEnabled(path: URL, enabled: Bool) {
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillEnabled) as? [String: Bool]) ?? [:]
        dict[path.path] = enabled
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillEnabled)
    }

    /// W4 (3.4.1): per-path routing-discoverable flag for file-source
    /// skills. Missing entry returns nil so callers can fall back to
    /// the frontmatter-derived default.
    public static func explicitFileSkillRoutingDiscoverable(path: URL) -> Bool? {
        let dict = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillRoutingDiscoverable) as? [String: Bool]
        return dict?[path.path]
    }

    public static func setFileSkillRoutingDiscoverable(path: URL, value: Bool) {
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillRoutingDiscoverable) as? [String: Bool]) ?? [:]
        dict[path.path] = value
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillRoutingDiscoverable)
    }

    /// W4 (3.4.1): per-path palette-membership flag for file-source
    /// skills. Missing entry returns nil → defaults to false (no
    /// auto-promotion into the hot-key palette).
    public static func explicitFileSkillInCommandPalette(path: URL) -> Bool? {
        let dict = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillInCommandPalette) as? [String: Bool]
        return dict?[path.path]
    }

    public static func setFileSkillInCommandPalette(path: URL, value: Bool) {
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillInCommandPalette) as? [String: Bool]) ?? [:]
        dict[path.path] = value
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillInCommandPalette)
    }

    /// W4 (3.4.1): effective routing-discoverable for a file-source
    /// skill — explicit toggle wins, else derives from frontmatter
    /// (`visibility: routing` ⇒ true, anything else ⇒ false).
    public static func isFileSkillRoutingDiscoverable(path: URL, frontmatter: [String: Any]) -> Bool {
        if let explicit = explicitFileSkillRoutingDiscoverable(path: path) {
            return explicit
        }
        if let v = frontmatter["visibility"] as? String, v == "routing" {
            return true
        }
        return false
    }

    /// Same effective routing predicate for already-parsed SKILL.md
    /// frontmatter. Keeps the routing list on the same flag semantics as
    /// Settings → Skills without lossy type-erasure at the call site.
    public static func isFileSkillRoutingDiscoverable(path: URL, frontmatter: [String: FrontmatterValue]) -> Bool {
        if let explicit = explicitFileSkillRoutingDiscoverable(path: path) {
            return explicit
        }
        if case .string(let v) = frontmatter["visibility"], v == "routing" {
            return true
        }
        return false
    }

    /// W4 (3.4.1): effective palette-membership for a file-source
    /// skill — explicit toggle only (no frontmatter default).
    public static func isFileSkillInCommandPalette(path: URL) -> Bool {
        explicitFileSkillInCommandPalette(path: path) ?? false
    }

    /// W2 D5: Build the `fetch_skill` envelope for a file-source skill.
    /// Shape mirrors `buildSkillResult` byte-for-byte (same envelope keys
    /// + value types) so the caller can not distinguish source by
    /// envelope shape — the only differences are: `url` is a `file://`
    /// URL, `properties` carries the flattened YAML frontmatter, and the
    /// `content` markdown body skips the network MentionResolver title
    /// lookup (mentions are passed through unchanged — bundled SKILL.md
    /// files don't typically mention Notion pages).
    public static func buildFileSkillResult(_ s: ParsedSkill) async -> Value {
        let body = s.body
        let nonEmptyLineCount = body
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .reduce(into: 0) { acc, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { acc += 1 }
            }
        let title: String = {
            if case .string(let t) = s.frontmatter["title"], !t.isEmpty { return t }
            if case .string(let t) = s.frontmatter["name"],  !t.isEmpty { return t }
            return s.name
        }()
        let summary: String = {
            if case .string(let d) = s.frontmatter["description"] { return d }
            return String(body.prefix(200))
        }()
        let triggers: [String] = {
            if case .array(let arr) = s.frontmatter["triggers"] { return arr }
            return []
        }()
        let antiTriggers: [String] = {
            if case .array(let arr) = s.frontmatter["anti_triggers"] { return arr }
            return []
        }()
        // Frontmatter → public `properties` map (rich, never `nil`).
        var props: [String: Value] = [:]
        for (k, v) in s.frontmatter {
            switch v {
            case .string(let str):  props[k] = .string(str)
            case .bool(let b):      props[k] = .bool(b)
            case .array(let arr):   props[k] = .array(arr.map { .string($0) })
            }
        }
        let contentValue = body.isEmpty ? "(no content)" : body
        return .object([
            "name": .string(s.name),
            "title": .string(title),
            "url": .string(s.path.absoluteString),
            "blockCount": .int(nonEmptyLineCount),
            "truncated": .bool(false),
            "content": .string(contentValue),
            "summary": .string(summary),
            "triggerPhrases": .array(triggers.map { .string($0) }),
            "antiTriggerPhrases": .array(antiTriggers.map { .string($0) }),
            "properties": .object(props),
            "source": .string("file")
        ])
    }

    /// W2 D6: build the merged routing-skills list returned by
    /// `skills_routing_list`. Notion-source routing entries first (with
    /// a `shadows` annotation when a file-source skill of the same name
    /// is being overridden), then file-source skills whose effective
    /// routing flag is true. That flag is controlled by the operator's
    /// per-path toggle when present, otherwise by frontmatter
    /// `visibility: routing`.
    public static func mergedRoutingSkills() async -> [Value] {
        let notionSkills = readAllSkills().filter { s in
            s.enabled && s.routingDiscoverable
                && NotionPageRef.isValidStoredPageId(s.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let fileSkills = await FilesystemSkillIndex.shared.allSkills().filter { fs in
            // Honour per-path disable.
            guard isFileSkillEnabled(path: fs.path) else { return false }
            return isFileSkillRoutingDiscoverable(
                path: fs.path,
                frontmatter: fs.frontmatter
            )
        }
        let notionNames = Set(notionSkills.map { $0.name.lowercased() })
        var rows: [Value] = []
        for s in notionSkills {
            var row = skillRowFields(s)
            // Annotate shadowed file-source skill, if any.
            if let shadowed = fileSkills.first(where: { $0.name.lowercased() == s.name.lowercased() }) {
                row["shadows"] = .string("file:\(shadowed.displayPath)")
            }
            row["source"] = .string("notion")
            rows.append(.object(row))
        }
        for fs in fileSkills where !notionNames.contains(fs.name.lowercased()) {
            var row: [String: Value] = [
                "name": .string(fs.name),
                "source": .string("file"),
                "path": .string(fs.displayPath)
            ]
            if case .string(let d) = fs.frontmatter["description"] {
                row["summary"] = .string(d)
            }
            if case .array(let arr) = fs.frontmatter["triggers"] {
                row["triggerPhrases"] = .array(arr.map { .string($0) })
            }
            if case .array(let arr) = fs.frontmatter["anti_triggers"] {
                row["antiTriggerPhrases"] = .array(arr.map { .string($0) })
            }
            rows.append(.object(row))
        }
        // Stable alphabetical ordering by name.
        rows.sort { lhs, rhs in
            guard case .object(let l) = lhs, case .string(let ln) = l["name"],
                  case .object(let r) = rhs, case .string(let rn) = r["name"] else {
                return false
            }
            return ln.localizedCaseInsensitiveCompare(rn) == .orderedAscending
        }
        // PKT-907 W3: surface `specialists: [{path,title,summary}]` per
        // row that has file-source children. Notion-source children are
        // discovered lazily on demand (a sync scan of every parent's
        // child pages would blow the connect-time budget); the path
        // resolver still resolves them at fetch_skill call time, and
        // the W3 routing-index `specialists:` array is best-effort for
        // file-source parents now and reserved for Notion via a future
        // background scan.
        return await Self.surfaceSpecialistsInRows(rows)
    }

    // MARK: - PKT-907 (Bridge v3.6 · 10) fetch_skill orchestrator helpers

    /// Resolution outcome from the path/intent dispatcher. Either we
    /// swapped in a specialist (live page identity) or we are returning
    /// the parent body with an annotation. `score` / `reason` only
    /// populate when intent ranking ran.
    /// `@unchecked Sendable`: the inner `[String: Any]` is a read-only
    /// snapshot of the Notion `getPage` response. Created inside one
    /// async task and consumed in the same task — never mutated, never
    /// shared. The unchecked annotation suppresses the conservative
    /// strict-concurrency diagnostic without weakening the actual safety
    /// (no aliased mutable state is ever shared across actors).
    fileprivate struct SpecialistDispatch: @unchecked Sendable {
        struct ResolvedNotion {
            let title: String
            let url: String
            let pageId: String
            let properties: [String: Any]
        }
        let resolvedSpecialist: ResolvedNotion?
        let resolvedPath: String?
        let annotation: SkillAnnotation?
        let matchScore: Double?
        let matchReason: String?
    }

    /// PKT-907 W1: file-source path/intent dispatch.
    /// Returns the full envelope for either the resolved child or the
    /// parent body with an annotation injected.
    fileprivate static func dispatchFileSpecialist(
        parent: ParsedSkill,
        parsedPath: SkillPath,
        intent: String?
    ) async -> Value {
        let parentName = parent.name

        // Depth guard wins over everything else.
        if parsedPath.depthExceeded {
            let parentEnvelope = await Self.buildFileSkillResult(parent)
            return Self.annotateFileEnvelope(
                parentEnvelope,
                parentName: parentName,
                annotation: .depthGuard,
                resolvedPath: nil,
                score: nil,
                reason: nil
            )
        }

        // Path lookup.
        if let child = parsedPath.child {
            if let resolved = SkillSpecialistFileResolver.resolve(parent: parent, child: child) {
                let pseudo = ParsedSkill(
                    name: resolved.name,
                    path: resolved.path,
                    isUserSource: parent.isUserSource,
                    frontmatter: resolved.frontmatter,
                    body: resolved.body,
                    displayPath: parent.displayPath + "/specialists/\(resolved.name)"
                )
                let env = await Self.buildFileSkillResult(pseudo)
                return Self.annotateFileEnvelope(
                    env,
                    parentName: parentName,
                    annotation: nil,
                    resolvedPath: "\(parentName)/\(resolved.name)",
                    score: 1.0,
                    reason: "exact path"
                )
            }
            // Path looked valid but no such child file → parent + annotation.
            let parentEnvelope = await Self.buildFileSkillResult(parent)
            return Self.annotateFileEnvelope(
                parentEnvelope,
                parentName: parentName,
                annotation: .specialistNotFound,
                resolvedPath: nil,
                score: nil,
                reason: nil
            )
        }

        // Intent ranking.
        if let intent = intent {
            let specialists = SkillSpecialistFileResolver.listAll(parent: parent)
            let candidates: [SkillIntentCandidate] = specialists.map { s in
                var aliases: [String] = []
                if case .array(let arr) = s.frontmatter["aliases"] { aliases = arr }
                let summary: String = {
                    if case .string(let d) = s.frontmatter["description"] { return d }
                    return SpecialistSummaryExtractor.firstSentence(from: s.body)
                }()
                return SkillIntentCandidate(name: s.name, aliases: aliases, summary: summary)
            }
            if let best = SkillIntentScorer.bestMatch(intent: intent, candidates: candidates),
               let resolved = specialists.first(where: { $0.name.lowercased() == best.candidate.name.lowercased() }) {
                let pseudo = ParsedSkill(
                    name: resolved.name,
                    path: resolved.path,
                    isUserSource: parent.isUserSource,
                    frontmatter: resolved.frontmatter,
                    body: resolved.body,
                    displayPath: parent.displayPath + "/specialists/\(resolved.name)"
                )
                let env = await Self.buildFileSkillResult(pseudo)
                NSLog("[fetch_skill] intent=\"%@\" parent=%@ → %@/%@ score=%.2f (%@)",
                      intent, parentName, parentName, resolved.name, best.score, best.reason)
                return Self.annotateFileEnvelope(
                    env,
                    parentName: parentName,
                    annotation: nil,
                    resolvedPath: "\(parentName)/\(resolved.name)",
                    score: best.score,
                    reason: best.reason
                )
            }
            // Low confidence → parent + annotation. Surface top score
            // when one existed so the caller can diagnose.
            let ranked = SkillIntentScorer.rank(intent: intent, candidates: candidates)
            let parentEnvelope = await Self.buildFileSkillResult(parent)
            NSLog("[fetch_skill] intent=\"%@\" parent=%@ → no candidate ≥ 0.4 (top=%.2f)",
                  intent, parentName, ranked.first?.score ?? 0)
            return Self.annotateFileEnvelope(
                parentEnvelope,
                parentName: parentName,
                annotation: .lowConfidence,
                resolvedPath: nil,
                score: ranked.first?.score,
                reason: ranked.first?.reason
            )
        }

        // Bare parent name — pre-PKT-907 path.
        return await Self.buildFileSkillResult(parent)
    }

    /// PKT-907 W1+W2: Notion-source path/intent dispatch. Returns a
    /// `SpecialistDispatch` for the caller to splice into the envelope
    /// build (we do this outside so the existing /markdown fetch path
    /// stays the single network choke-point).
    fileprivate static func dispatchNotionSpecialist(
        client: NotionClient,
        parentPageId: String,
        parentName: String,
        parsedPath: SkillPath,
        intent: String?
    ) async -> SpecialistDispatch {
        // Depth guard short-circuits before any network call.
        if parsedPath.depthExceeded {
            return SpecialistDispatch(
                resolvedSpecialist: nil,
                resolvedPath: nil,
                annotation: .depthGuard,
                matchScore: nil,
                matchReason: nil
            )
        }

        // Bare-parent fast path — no extra network calls.
        if parsedPath.child == nil && intent == nil {
            return SpecialistDispatch(
                resolvedSpecialist: nil,
                resolvedPath: nil,
                annotation: nil,
                matchScore: nil,
                matchReason: nil
            )
        }

        // Enumerate child pages of the parent. `fetchAllSiblingBlocks`
        // returns every direct child block; we filter on `type:
        // "child_page"` to get the sub-skill candidates.
        let childPages = await Self.listNotionChildPages(client: client, pageId: parentPageId)

        if let childName = parsedPath.child {
            let needle = childName.lowercased()
            // Exact (case-insensitive), then partial substring (first
            // match wins per packet) match on child page titles.
            if let exact = childPages.first(where: { $0.title.lowercased() == needle }) {
                return SpecialistDispatch(
                    resolvedSpecialist: SpecialistDispatch.ResolvedNotion(
                        title: exact.title,
                        url: exact.url,
                        pageId: exact.pageId,
                        properties: exact.properties
                    ),
                    resolvedPath: "\(parentName)/\(exact.title)",
                    annotation: nil,
                    matchScore: 1.0,
                    matchReason: "exact path"
                )
            }
            if let partial = childPages.first(where: { $0.title.lowercased().contains(needle) || needle.contains($0.title.lowercased()) }) {
                return SpecialistDispatch(
                    resolvedSpecialist: SpecialistDispatch.ResolvedNotion(
                        title: partial.title,
                        url: partial.url,
                        pageId: partial.pageId,
                        properties: partial.properties
                    ),
                    resolvedPath: "\(parentName)/\(partial.title)",
                    annotation: nil,
                    matchScore: 0.7,
                    matchReason: "partial title"
                )
            }
            // Unresolvable child → parent + annotation.
            return SpecialistDispatch(
                resolvedSpecialist: nil,
                resolvedPath: nil,
                annotation: .specialistNotFound,
                matchScore: nil,
                matchReason: nil
            )
        }

        // Intent path — score against child page titles.
        if let intent = intent {
            let candidates = childPages.map { cp in
                SkillIntentCandidate(name: cp.title, aliases: [], summary: "")
            }
            if let best = SkillIntentScorer.bestMatch(intent: intent, candidates: candidates),
               let resolved = childPages.first(where: { $0.title.lowercased() == best.candidate.name.lowercased() }) {
                NSLog("[fetch_skill] intent=\"%@\" parent=%@ → %@/%@ score=%.2f (%@)",
                      intent, parentName, parentName, resolved.title, best.score, best.reason)
                return SpecialistDispatch(
                    resolvedSpecialist: SpecialistDispatch.ResolvedNotion(
                        title: resolved.title,
                        url: resolved.url,
                        pageId: resolved.pageId,
                        properties: resolved.properties
                    ),
                    resolvedPath: "\(parentName)/\(resolved.title)",
                    annotation: nil,
                    matchScore: best.score,
                    matchReason: best.reason
                )
            }
            let ranked = SkillIntentScorer.rank(intent: intent, candidates: candidates)
            NSLog("[fetch_skill] intent=\"%@\" parent=%@ → no candidate ≥ 0.4 (top=%.2f)",
                  intent, parentName, ranked.first?.score ?? 0)
            return SpecialistDispatch(
                resolvedSpecialist: nil,
                resolvedPath: nil,
                annotation: .lowConfidence,
                matchScore: ranked.first?.score,
                matchReason: ranked.first?.reason
            )
        }

        // Should not reach (early-exited above when both nil).
        return SpecialistDispatch(
            resolvedSpecialist: nil,
            resolvedPath: nil,
            annotation: nil,
            matchScore: nil,
            matchReason: nil
        )
    }

    /// Inner record carrying just what `dispatchNotionSpecialist` needs.
    /// `@unchecked Sendable`: see `SpecialistDispatch` doc above —
    /// same read-only-snapshot-inside-one-task contract applies.
    fileprivate struct NotionChildPageRef: @unchecked Sendable {
        let pageId: String
        let title: String
        let url: String
        let properties: [String: Any]
    }

    /// Enumerate direct `child_page` blocks of a parent skill page and
    /// hydrate their title + url via a single `getPage` per child.
    /// Failures degrade silently (empty list) — the caller maps that to
    /// a `specialistNotFound` annotation, never an error envelope.
    ///
    /// Implementation note: uses `fetchChildBlocksRaw` (returns `Data`
    /// which IS Sendable) + manual pagination instead of the actor's
    /// `fetchAllSiblingBlocks` helper (returns `[[String: Any]]` which
    /// is NOT Sendable under strict concurrency). Same wire contract.
    fileprivate static func listNotionChildPages(
        client: NotionClient,
        pageId: String
    ) async -> [NotionChildPageRef] {
        var collectedIds: [String] = []
        var collectedTitles: [String: String] = [:]   // id → block-level title
        var cursor: String? = nil
        // Bounded pagination — defensive 50-page (≈ 5000 blocks) cap.
        for _ in 0..<50 {
            guard let data = try? await client.fetchChildBlocksRaw(blockId: pageId, startCursor: cursor, pageSize: 100) else {
                break
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                break
            }
            for block in results {
                guard let type = block["type"] as? String, type == "child_page",
                      let cid = block["id"] as? String else {
                    continue
                }
                collectedIds.append(cid)
                let blockTitle = (block["child_page"] as? [String: Any])?["title"] as? String ?? ""
                if !blockTitle.isEmpty { collectedTitles[cid] = blockTitle }
            }
            let hasMore = json["has_more"] as? Bool ?? false
            guard hasMore, let next = json["next_cursor"] as? String, !next.isEmpty else { break }
            cursor = next
        }

        var out: [NotionChildPageRef] = []
        for cid in collectedIds {
            var props: [String: Any] = [:]
            var url = ""
            var resolvedTitle = collectedTitles[cid] ?? ""
            if let pageData = try? await client.getPage(pageId: cid),
               let json = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] {
                url = json["url"] as? String ?? ""
                props = json["properties"] as? [String: Any] ?? [:]
                if !props.isEmpty {
                    let t = NotionJSON.extractTitle(from: props)
                    if !t.isEmpty && t != "Untitled" { resolvedTitle = t }
                }
            }
            out.append(NotionChildPageRef(
                pageId: cid,
                title: resolvedTitle,
                url: url,
                properties: props
            ))
        }
        return out
    }

    /// Inject the PKT-907 envelope keys (`resolvedPath`, `matchConfidence`,
    /// `matchReason`, `annotation`) into a Notion-source envelope.
    fileprivate static func annotateEnvelope(
        _ envelope: Value,
        parentName: String,
        dispatch: SpecialistDispatch
    ) -> Value {
        guard case .object(var dict) = envelope else { return envelope }
        if let rp = dispatch.resolvedPath {
            dict["resolvedPath"] = .string(rp)
        }
        if let s = dispatch.matchScore {
            dict["matchConfidence"] = .double(s)
        }
        if let r = dispatch.matchReason {
            dict["matchReason"] = .string(r)
        }
        if let a = dispatch.annotation {
            dict["annotation"] = .string(a.rawValue)
            // Always surface the parent's name when annotating — agents
            // need to know that they got the parent body and why.
            dict["parentName"] = .string(parentName)
        }
        return .object(dict)
    }

    /// File-source annotation helper. Same envelope keys as the Notion
    /// path — agents read one shape across both sources.
    fileprivate static func annotateFileEnvelope(
        _ envelope: Value,
        parentName: String,
        annotation: SkillAnnotation?,
        resolvedPath: String?,
        score: Double?,
        reason: String?
    ) -> Value {
        guard case .object(var dict) = envelope else { return envelope }
        if let rp = resolvedPath { dict["resolvedPath"] = .string(rp) }
        if let s = score { dict["matchConfidence"] = .double(s) }
        if let r = reason { dict["matchReason"] = .string(r) }
        if let a = annotation {
            dict["annotation"] = .string(a.rawValue)
            dict["parentName"] = .string(parentName)
        }
        return .object(dict)
    }

    // MARK: - PKT-907 W3: surface specialists in skills_routing_list

    /// Post-process the `mergedRoutingSkills` rows to attach a
    /// `specialists: [{path,title,summary}]` array for every parent that
    /// has children — file-source parents from the local `specialists/`
    /// directory or a frontmatter `specialists:` array, and (v3.7·1)
    /// Notion-source parents from the on-disk `SkillsCacheReader` cache.
    ///
    /// Notion enumeration used to be deferred here ("N×(getPage +
    /// fetchAllSiblingBlocks) blows the cold-start budget"); the v3.7·1
    /// cache makes the read O(1) per parent so the eager surface is now
    /// safe. Stale cache entries are still surfaced — flagged via the
    /// row-level `specialistsStale` key — so a long-running operator
    /// without network never loses the routing hints. Cache misses
    /// remain silent (no specialists rendered), preserving the previous
    /// degrade-gracefully contract.
    fileprivate static func surfaceSpecialistsInRows(_ rows: [Value]) async -> [Value] {
        let maxSurfacedSpecialists = 5

        // Build a name → ParsedSkill map for file-source skills.
        let fileSkills = await FilesystemSkillIndex.shared.allSkills()
        var byName: [String: ParsedSkill] = [:]
        for fs in fileSkills { byName[fs.name.lowercased()] = fs }

        // v3.7·1: snapshot the Notion-source cache once per call. The
        // reader is O(N) over cached parents (single JSON load each) so
        // even with 100s of parents this is well under the per-handshake
        // budget. The previous N×N cold-start path is gone.
        let cachedParents = await SkillsCacheReader.shared.readAll()
        var cacheByName: [String: CachedParent] = [:]
        for cp in cachedParents { cacheByName[cp.parentTitle.lowercased()] = cp }

        var out: [Value] = []
        for row in rows {
            guard case .object(var dict) = row else {
                out.append(row)
                continue
            }
            guard case .string(let name) = dict["name"] else {
                out.append(row)
                continue
            }
            let isFileSource: Bool = {
                if case .string(let src)? = dict["source"], src == "file" { return true }
                return false
            }()
            if isFileSource, let parent = byName[name.lowercased()] {
                let specialists = SkillSpecialistFileResolver.listAll(parent: parent)
                if !specialists.isEmpty {
                    let visible = specialists.prefix(maxSurfacedSpecialists)
                    let arr: [Value] = visible.map { sp in
                        let summary: String = {
                            if case .string(let d) = sp.frontmatter["description"] { return d }
                            if case .string(let s) = sp.frontmatter["summary"] { return s }
                            return SpecialistSummaryExtractor.firstSentence(from: sp.body)
                        }()
                        return .object([
                            "path": .string("\(name)/\(sp.name)"),
                            "title": .string(sp.name),
                            "summary": .string(summary)
                        ])
                    }
                    dict["specialists"] = .array(arr)
                    dict["specialistCount"] = .int(specialists.count)
                    if specialists.count > maxSurfacedSpecialists {
                        dict["specialistsTruncated"] = .bool(true)
                    }
                }
            } else if let cached = cacheByName[name.lowercased()], !cached.children.isEmpty {
                // Notion-source row with a cache hit.
                let visible = cached.children.prefix(maxSurfacedSpecialists)
                let arr: [Value] = visible.map { child in
                    .object([
                        "path": .string("\(name)/\(child.title)"),
                        "title": .string(child.title),
                        "summary": .string(child.summary),
                        "pageId": .string(child.id)
                    ])
                }
                dict["specialists"] = .array(arr)
                dict["specialistCount"] = .int(cached.children.count)
                if cached.children.count > maxSurfacedSpecialists {
                    dict["specialistsTruncated"] = .bool(true)
                }
                if cached.stale {
                    dict["specialistsStale"] = .bool(true)
                }
            }
            out.append(.object(dict))
        }
        return out
    }
}
