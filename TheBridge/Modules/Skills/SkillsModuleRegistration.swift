// Extracted from SkillsModule.swift by PKT-1126. Pure decomposition; behavior unchanged.

import Foundation
import MCP

extension SkillsModule {
    // MARK: - skills_routing_list (Sprint A · mcp-builder #14 rename)

    static func registerListRoutingSkills(on router: ToolRouter) async {
        // Sprint A · mcp-builder #14: list_routing_skills → skills_routing_list
        // (mcp-builder prefix-consistency: skills_* family).
        let skillsRoutingList = ToolRegistration(
            name: "skills_routing_list",
            module: moduleName,
            tier: .open,
            description: "Read the authoritative Runtime Exposure routing snapshot used by handshake instructions and bridge_initialize. Returns status, source, snapshot, count, reason, and the exact routable skill identities.",
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
                return await Self.routingSnapshot().value
            }
        )
        await router.register(skillsRoutingList)
    }

    // MARK: - Sprint A · #2 split primitives

    /// Register the 5 mcp-builder primitives (skill_create, skill_delete,
    /// skill_update, skill_rename, skill_sync_notion).
    static func registerSkillSplitPrimitives(
        on router: ToolRouter
    ) async {
        // skill_create — single-add or bulk_add.
        await router.register(ToolRegistration(
            name: "skill_create",
            module: moduleName,
            tier: .notify,
            description: "Create one or more skills after SKILLS Keepr approves the construction route. Requires routeReceipt. For a single skill: name + url (+ optional visibility). For bulk: skills=[{name,url},...]. Replaces manage_skill action='add'/'bulk_add'.",
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
                    "bypassConfirmation": .object(["type": .string("boolean")]),
                    "routeReceipt": SkillRouteReceiptValidator.schema
                ])
            ]),
            handler: { args in
                let dict = Self.unpackArgsObject(args)
                // Bulk mode if `skills` is an array; else single-add.
                if case .array(let skillsArray) = dict["skills"] {
                    var pairs: [(name: String, pageId: String)] = []
                    for item in skillsArray {
                        if case .object(let obj) = item,
                           case .string(let n) = obj["name"],
                           case .string(let u) = obj["url"] {
                            pairs.append((name: n, pageId: u))
                        }
                    }
                    try Self.requireSkillRouteReceipt(
                        dict,
                        expectedTargets: pairs.map { $0.name },
                        toolName: "skill_create"
                    )
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
                            .object(["name": .string(row.name), "reason": .string(row.reason)])
                        })
                    }
                    return .object(bulk)
                }
                guard case .string(let name) = dict["name"],
                      case .string(let url) = dict["url"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skill_create",
                        reason: "single-skill mode requires 'name' and 'url' parameters"
                    )
                }
                try Self.requireSkillRouteReceipt(
                    dict,
                    expectedTargets: [name],
                    toolName: "skill_create"
                )
                let vis = parseVisibilityArg(dict) ?? .standard
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
            }
        ))

        // skill_delete — delete one skill by name.
        await router.register(ToolRegistration(
            name: "skill_delete",
            module: moduleName,
            tier: .request,
            description: "Delete one skill by name after SKILLS Keepr approves the lifecycle route. Requires routeReceipt. Replaces manage_skill action='delete'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Skill name to delete.")]),
                    "bypassConfirmation": .object(["type": .string("boolean")]),
                    "routeReceipt": SkillRouteReceiptValidator.schema
                ]),
                "required": .array([.string("name")])
            ]),
            handler: { args in
                let dict = Self.unpackArgsObject(args)
                guard case .string(let name) = dict["name"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skill_delete",
                        reason: "'name' parameter is required"
                    )
                }
                try Self.requireSkillRouteReceipt(
                    dict,
                    expectedTargets: [name],
                    toolName: "skill_delete"
                )
                let success = writeDeleteSkill(named: name)
                return .object([
                    "success": .bool(success),
                    "action": .string("delete"),
                    "name": .string(name),
                    "message": .string(success ? "Skill '\(name)' deleted." : "Skill '\(name)' not found.")
                ])
            }
        ))

        // skill_update — toggle, update_url, set_visibility, or set_metadata.
        await router.register(ToolRegistration(
            name: "skill_update",
            module: moduleName,
            tier: .notify,
            description: "Update one skill after SKILLS Keepr approves the change. Requires routeReceipt. Supports toggle, URL, visibility, or MCP metadata changes. Replaces manage_skill toggle/update_url/set_visibility/set_metadata.",
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
                    "bypassConfirmation": .object(["type": .string("boolean")]),
                    "routeReceipt": SkillRouteReceiptValidator.schema
                ]),
                "required": .array([.string("name")])
            ]),
            handler: { args in
                let dict = Self.unpackArgsObject(args)
                guard case .string(let name) = dict["name"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skill_update",
                        reason: "'name' parameter is required"
                    )
                }
                try Self.requireSkillRouteReceipt(
                    dict,
                    expectedTargets: [name],
                    toolName: "skill_update"
                )
                if case .bool(true) = dict["toggle"] {
                    let result = writeToggleSkill(named: name)
                    return .object([
                        "success": .bool(result.found),
                        "action": .string("toggle"),
                        "name": .string(name),
                        "enabled": .bool(result.newState),
                        "message": .string(result.found ? "Skill '\(name)' is now \(result.newState ? "enabled" : "disabled")." : "Skill '\(name)' not found.")
                    ])
                } else if case .string(let url) = dict["url"] {
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
                } else if dict["summary"] != nil || dict["triggerPhrases"] != nil || dict["antiTriggerPhrases"] != nil {
                    let resolution = await resolveMutationTarget(named: name)
                    switch resolution {
                    case .notFound:
                        return .object([
                            "success": .bool(false), "action": .string("set_metadata"),
                            "message": .string("Skill not found in configured parents or the curated specialist routing cache.")
                        ])
                    case .ambiguous(let candidates):
                        return .object([
                            "success": .bool(false), "action": .string("set_metadata"),
                            "message": .string("Skill name is ambiguous; use an explicit parent/specialist path."),
                            "candidates": .array(candidates.map(Value.string))
                        ])
                    case .found(let target) where target.kind == .configuredParent:
                        var skills = readAllSkills()
                        let wanted = CachedSkillBody.normalize(target.pageId)
                        guard let idx = skills.firstIndex(where: {
                            CachedSkillBody.normalize($0.notionPageId) == wanted
                        }) else {
                            return .object(["success": .bool(false), "action": .string("set_metadata"), "message": .string("Configured skill row not found.")])
                        }
                        let cur = skills[idx]
                        let newSummary: String = {
                            if case .string(let value) = dict["summary"] {
                                return SkillMetadataLimits.clampedSummary(value)
                            }
                            return cur.summary
                        }()
                        let newTrig: [String] = {
                            if let value = dict["triggerPhrases"] {
                                return SkillMetadataLimits.clampedPhraseList(Self.parseStringArrayValue(value))
                            }
                            return cur.triggerPhrases
                        }()
                        let newAnti: [String] = {
                            if let value = dict["antiTriggerPhrases"] {
                                return SkillMetadataLimits.clampedPhraseList(Self.parseStringArrayValue(value))
                            }
                            return cur.antiTriggerPhrases
                        }()
                        skills[idx] = SkillConfig(
                            name: cur.name, source: cur.source, enabled: cur.enabled,
                            routingDiscoverable: cur.routingDiscoverable, inCommandPalette: cur.inCommandPalette,
                            summary: newSummary, triggerPhrases: newTrig, antiTriggerPhrases: newAnti,
                            url: cur.url, platform: cur.platform
                        )
                        writeSkills(skills)
                        return .object([
                            "success": .bool(true), "action": .string("set_metadata"),
                            "name": .string(target.name), "targetKind": .string(target.kind.rawValue),
                            "message": .string("Configured skill metadata updated locally. Use skill_sync_notion push to publish it to Notion.")
                        ])
                    case .found(let target):
                        do {
                            let client = try NotionClient()
                            let pageData = try await client.getPage(pageId: target.pageId)
                            guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any],
                                  let properties = pageJSON["properties"] as? [String: Any] else {
                                return .object(["success": .bool(false), "action": .string("set_metadata"), "message": .string("Failed to parse specialist Notion page.")])
                            }
                            let current = SkillNotionMetadata.parsePulledMetadata(properties: properties)
                            let summary: String = {
                                if case .string(let value) = dict["summary"] {
                                    return SkillMetadataLimits.clampedSummary(value)
                                }
                                return current.summary
                            }()
                            let triggers: [String] = {
                                if let value = dict["triggerPhrases"] {
                                    return SkillMetadataLimits.clampedPhraseList(Self.parseStringArrayValue(value))
                                }
                                return current.triggerPhrases
                            }()
                            let antiTriggers: [String] = {
                                if let value = dict["antiTriggerPhrases"] {
                                    return SkillMetadataLimits.clampedPhraseList(Self.parseStringArrayValue(value))
                                }
                                return current.antiTriggerPhrases
                            }()
                            let patch = try SkillNotionMetadata.buildPagePropertiesPatchData(
                                summary: summary,
                                triggerPhrases: triggers,
                                antiTriggerPhrases: antiTriggers
                            )
                            _ = try await client.updatePage(pageId: target.pageId, properties: patch)
                            let cache = await SkillBodyCacheEviction.refreshReceipt(target.pageId)
                            let resolvedPath = [target.parentName, target.name].compactMap { $0 }.joined(separator: "/")
                            return .object([
                                "success": .bool(true), "action": .string("set_metadata"),
                                "name": .string(target.name), "targetKind": .string(target.kind.rawValue),
                                "resolvedPath": .string(resolvedPath),
                                "bodyEvicted": .bool(cache.bodyEvicted),
                                "routingRefreshAttempted": .bool(cache.routingRefreshAttempted),
                                "routingRefreshSucceeded": .bool(cache.routingRefreshSucceeded),
                                "routingParentsExpected": .int(cache.routingParentsExpected),
                                "routingParentsRefreshed": .int(cache.routingParentsRefreshed),
                                "message": .string("Specialist metadata updated in Notion; cache evidence is reported separately.")
                            ])
                        } catch {
                            return .object([
                                "success": .bool(false), "action": .string("set_metadata"),
                                "error": .string(error.localizedDescription)
                            ])
                        }
                    }
                } else if dict["visibility"] != nil {
                    guard let vis = parseVisibilityArg(dict) else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "skill_update",
                            reason: "set_visibility requires valid visibility: routing, standard, or command"
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
                } else {
                    return .object([
                        "error": .string("skill_update requires at least one update field: toggle, url, visibility, summary, triggerPhrases, antiTriggerPhrases")
                    ])
                }
            }
        ))

        // skill_rename — rename one skill.
        await router.register(ToolRegistration(
            name: "skill_rename",
            module: moduleName,
            tier: .notify,
            description: "Rename one skill after SKILLS Keepr approves identity propagation. Requires routeReceipt and preserves UUID, enabled state, visibility, and metadata. Replaces manage_skill action='rename'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Current skill name.")]),
                    "newName": .object(["type": .string("string"), "description": .string("New skill name.")]),
                    "bypassConfirmation": .object(["type": .string("boolean")]),
                    "routeReceipt": SkillRouteReceiptValidator.schema
                ]),
                "required": .array([.string("name"), .string("newName")])
            ]),
            handler: { args in
                let dict = Self.unpackArgsObject(args)
                guard case .string(let name) = dict["name"],
                      case .string(let newName) = dict["newName"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skill_rename",
                        reason: "'name' and 'newName' parameters are required"
                    )
                }
                try Self.requireSkillRouteReceipt(
                    dict,
                    expectedTargets: [name, newName],
                    toolName: "skill_rename"
                )
                let success = writeRenameSkill(named: name, to: newName)
                return .object([
                    "success": .bool(success),
                    "action": .string("rename"),
                    "oldName": .string(name),
                    "newName": .string(newName),
                    "message": .string(success ? "Skill renamed '\(name)' → '\(newName)'." : "Failed — skill not found or name conflict.")
                ])
            }
        ))

        // skill_sync_notion — push or pull metadata between local store and Notion.
        await router.register(ToolRegistration(
            name: "skill_sync_notion",
            module: moduleName,
            tier: .notify,
            description: "Sync one skill's MCP metadata between local store and Notion. direction='push' is a skill-system mutation and requires routeReceipt; direction='pull' is read-only. Replaces manage_skill sync_metadata_to_notion / sync_metadata_from_notion.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Skill name (required).")]),
                    "direction": .object([
                        "type": .string("string"),
                        "description": .string("'push' = local → Notion. 'pull' = Notion → local."),
                        "enum": .array([.string("push"), .string("pull")])
                    ]),
                    "bypassConfirmation": .object(["type": .string("boolean")]),
                    "routeReceipt": SkillRouteReceiptValidator.schema
                ]),
                "required": .array([.string("name"), .string("direction")])
            ]),
            handler: { args in
                let dict = Self.unpackArgsObject(args)
                guard case .string(let name) = dict["name"] else {
                    throw ToolRouterError.invalidArguments(toolName: "skill_sync_notion", reason: "'name' is required")
                }
                guard case .string(let dir) = dict["direction"], dir == "push" || dir == "pull" else {
                    return .object(["error": .string("skill_sync_notion requires direction='push' or 'pull'")])
                }
                let isPush = (dir == "push")
                let actionLabel = isPush ? "sync_metadata_to_notion" : "sync_metadata_from_notion"
                if isPush {
                    try Self.requireSkillRouteReceipt(
                        dict,
                        expectedTargets: [name],
                        toolName: "skill_sync_notion"
                    )
                }
                let resolution = await resolveMutationTarget(named: name)
                let target: SkillMutationTarget
                switch resolution {
                case .notFound:
                    return .object([
                        "success": .bool(false), "action": .string(actionLabel),
                        "message": .string("Skill not found in configured parents or the curated specialist routing cache.")
                    ])
                case .ambiguous(let candidates):
                    return .object([
                        "success": .bool(false), "action": .string(actionLabel),
                        "message": .string("Skill name is ambiguous; use an explicit parent/specialist path."),
                        "candidates": .array(candidates.map { .string($0) })
                    ])
                case .found(let resolved):
                    target = resolved
                }

                let pageId = target.pageId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard NotionPageRef.isValidStoredPageId(pageId) else {
                    return .object([
                        "success": .bool(false), "action": .string(actionLabel),
                        "message": .string("Skill has an invalid Notion page id — fix the parent routing relation or Settings → Skills.")
                    ])
                }
                do {
                    let client = try NotionClient()
                    if target.kind == .cachedSpecialist {
                        if isPush {
                            return .object([
                                "success": .bool(false), "action": .string(actionLabel),
                                "name": .string(target.name), "targetKind": .string(target.kind.rawValue),
                                "message": .string("Cached specialists have no independent local metadata row to push. Use skill_update with the explicit parent/specialist path; it writes the child page directly and refreshes both caches.")
                            ])
                        }

                        let pageData = try await client.getPage(pageId: pageId)
                        guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any],
                              let properties = pageJSON["properties"] as? [String: Any] else {
                            return .object([
                                "success": .bool(false), "action": .string(actionLabel),
                                "message": .string("Failed to parse specialist Notion page.")
                            ])
                        }
                        let pulled = SkillNotionMetadata.parsePulledMetadata(properties: properties)
                        let cache = await SkillBodyCacheEviction.refreshReceipt(pageId)
                        let resolvedPath = [target.parentName, target.name].compactMap { $0 }.joined(separator: "/")
                        return .object([
                            "success": .bool(true), "action": .string(actionLabel),
                            "name": .string(target.name), "targetKind": .string(target.kind.rawValue),
                            "resolvedPath": .string(resolvedPath),
                            "summary": .string(pulled.summary),
                            "triggerPhrases": .array(pulled.triggerPhrases.map { .string($0) }),
                            "antiTriggerPhrases": .array(pulled.antiTriggerPhrases.map { .string($0) }),
                            "bodyEvicted": .bool(cache.bodyEvicted),
                            "routingRefreshAttempted": .bool(cache.routingRefreshAttempted),
                            "routingRefreshSucceeded": .bool(cache.routingRefreshSucceeded),
                            "routingParentsExpected": .int(cache.routingParentsExpected),
                            "routingParentsRefreshed": .int(cache.routingParentsRefreshed),
                            "message": .string("Specialist metadata read from Notion; cache evidence is reported separately.")
                        ])
                    }

                    var skills = readAllSkills()
                    let wanted = CachedSkillBody.normalize(pageId)
                    guard let idx = skills.firstIndex(where: {
                        CachedSkillBody.normalize($0.notionPageId) == wanted
                    }) else {
                        return .object([
                            "success": .bool(false), "action": .string(actionLabel),
                            "message": .string("Configured skill row not found.")
                        ])
                    }
                    let skill = skills[idx]
                    if isPush {
                        let patch = try SkillNotionMetadata.buildPagePropertiesPatchData(
                            summary: skill.summary,
                            triggerPhrases: skill.triggerPhrases,
                            antiTriggerPhrases: skill.antiTriggerPhrases
                        )
                        _ = try await client.updatePage(pageId: pageId, properties: patch)
                        let cache = await SkillBodyCacheEviction.refreshReceipt(pageId)
                        return .object([
                            "success": .bool(true), "action": .string(actionLabel),
                            "name": .string(target.name), "targetKind": .string(target.kind.rawValue),
                            "bodyEvicted": .bool(cache.bodyEvicted),
                            "routingRefreshAttempted": .bool(cache.routingRefreshAttempted),
                            "routingRefreshSucceeded": .bool(cache.routingRefreshSucceeded),
                            "routingParentsExpected": .int(cache.routingParentsExpected),
                            "routingParentsRefreshed": .int(cache.routingParentsRefreshed),
                            "message": .string("Notion page properties updated; cache evidence is reported separately.")
                        ])
                    } else {
                        let pageData = try await client.getPage(pageId: pageId)
                        guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any],
                              let properties = pageJSON["properties"] as? [String: Any] else {
                            return .object([
                                "success": .bool(false), "action": .string(actionLabel),
                                "message": .string("Failed to parse Notion page.")
                            ])
                        }
                        // SSOT = Notion. Read the REAL columns
                        // (Description, Activation Examples, Anti-Triggers).
                        // Empty values remain gate-safe no-ops for configured
                        // parent rows.
                        let pulled = SkillNotionMetadata.parsePulledMetadata(properties: properties)
                        let newSummary = pulled.summary.isEmpty
                            ? skill.summary
                            : SkillMetadataLimits.clampedSummary(pulled.summary)
                        let trig = pulled.triggerPhrases.isEmpty
                            ? skill.triggerPhrases
                            : SkillMetadataLimits.clampedPhraseList(pulled.triggerPhrases)
                        let anti = pulled.antiTriggerPhrases.isEmpty
                            ? skill.antiTriggerPhrases
                            : SkillMetadataLimits.clampedPhraseList(pulled.antiTriggerPhrases)
                        skills[idx] = SkillConfig(
                            name: skill.name, source: skill.source, enabled: skill.enabled,
                            routingDiscoverable: skill.routingDiscoverable, inCommandPalette: skill.inCommandPalette,
                            summary: newSummary, triggerPhrases: trig, antiTriggerPhrases: anti,
                            url: skill.url, platform: skill.platform
                        )
                        writeSkills(skills)
                        await SkillBodyCacheStore.shared.evict(pageId: pageId)
                        return .object([
                            "success": .bool(true), "action": .string(actionLabel),
                            "name": .string(target.name), "targetKind": .string(target.kind.rawValue),
                            "message": .string("MCP metadata updated from Notion (Description-sourced; empty fields preserved); body cache evicted.")
                        ])
                    }
                } catch let error as NotionClientError {
                    return .object(["success": .bool(false), "action": .string(actionLabel), "error": .string(error.localizedDescription)])
                } catch {
                    return .object(["success": .bool(false), "action": .string(actionLabel), "error": .string(error.localizedDescription)])
                }
            }
        ))
    }

    /// #254: copy a Notion-hosted skill attachment onto the local cache.
    static func registerSkillFilePrimitives(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "skill_materialize_file",
            module: moduleName,
            tier: .open,
            description: """
            Copy one Notion-hosted Files & media attachment from a configured skill \
            onto the local skill-files cache so file_read can open it.

            IDENTITY: same as fetch_skill — prefer `id` (Notion UUID), else `name`. \
            Select the file with `fileName` or `notionFileId` from the fetch_skill \
            `files` catalog.

            Writes ~/Library/Application Support/The Bridge/skill-files/<uuid>/<name>. \
            Notion is a catalog/mirror, not binary SSOT. When fetch_skill returns \
            `assetRoot` (e.g. ~/Desktop/Brand Master), that local folder remains SSOT; \
            this tool only materializes Notion-hosted binaries. External / Google Drive \
            URLs are not downloaded.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Skill Notion UUID (dashed or compact). Authoritative when both id and name are supplied.")
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Configured skill name when the UUID is not known.")
                    ]),
                    "fileName": .object([
                        "type": .string("string"),
                        "description": .string("Attachment name from fetch_skill files[].name")
                    ]),
                    "notionFileId": .object([
                        "type": .string("string"),
                        "description": .string("Notion file id from fetch_skill files[].notionFileId when present")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { args in
                try await Self.handleMaterializeSkillFile(args)
            }
        ))
    }

    /// Unpack a Value argument expected to be an object literal. Returns
    /// empty dict on non-object input (the handler's own validation will
    /// then surface a meaningful error).
    static func unpackArgsObject(_ v: Value) -> [String: Value] {
        if case .object(let dict) = v { return dict }
        return [:]
    }

    static func requireSkillRouteReceipt(
        _ args: [String: Value],
        expectedTargets: [String],
        toolName: String
    ) throws {
        if let error = SkillRouteReceiptValidator.validationError(
            receipt: args["routeReceipt"],
            expectedTargets: expectedTargets
        ) {
            throw ToolRouterError.invalidArguments(toolName: toolName, reason: error)
        }
    }

}
