// SkillsModule.swift — fetch_skill MCP Tool
// TheBridge · Modules
// PKT-366 F10: Registers `fetch_skill` at .open tier.
// Looks up skill name in config → NotionClient page + collectBlocksDepthFirst → returns text.
// Session-level cache with 10-minute TTL.
// 403 handling: structured error + "Access Lost" badge.

import Foundation
import MCP

// MARK: - Skill Cache

/// Cache entry for a fetched skill page.
struct CachedSkill: Sendable {
    let content: Value
    let fetchedAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(fetchedAt) > 600 // 10-minute TTL
    }
}

/// Thread-safe actor cache for fetched skill content.
@_spi(Testing)
public actor SkillCache {
    public static let shared = SkillCache()
    private var cache: [String: CachedSkill] = [:]

    public init() {}

    public func get(_ key: String) -> Value? {
        guard let entry = cache[key], !entry.isExpired else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.content
    }

    public func set(_ key: String, content: Value) {
        cache[key] = CachedSkill(content: content, fetchedAt: Date())
    }

    public func clear() {
        cache.removeAll()
    }
}

extension SkillsModule {
    /// Policy-then-memory decision used by `fetch_skill`. Tests seed `cache`
    /// and call this function so a helper cannot stay cache-first while the
    /// handler stays wrong.
    @_spi(Testing)
    public enum FetchMemoryResult: Sendable {
        case disabled
        case invalidPageId
        case unpublished
        case cached(Value)
        case miss
    }

    @_spi(Testing)
    public static func fetchMemoryResult(
        enabled: Bool,
        pageId: String,
        cacheKey: String,
        cache: SkillCache,
        gate: SkillRuntimeExposureGate?,
        skipMemoryCache: Bool = false
    ) async -> FetchMemoryResult {
        guard enabled else { return .disabled }
        let trimmed = pageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NotionPageRef.isValidStoredPageId(trimmed) else { return .invalidPageId }
        if let gate, !gate.allows(pageID: trimmed, surface: .exactFetch) {
            return .unpublished
        }
        if skipMemoryCache { return .miss }
        if let cached = await cache.get(cacheKey) { return .cached(cached) }
        return .miss
    }

    static func cachedSpecialistPageID(parentPageID: String, childTitle: String) async -> String? {
        let wanted = childTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        guard let parent = await SkillsCacheReader.shared.read(parentId: parentPageID) else { return nil }
        return parent.children.first { child in
            child.title.lowercased() == wanted
                || child.aliases.contains { $0.lowercased() == wanted }
        }?.id
    }
}

/// Per-fetch cache for `<mention-page>` title resolution: one Notion
/// `getPage` per distinct page URL within a single `fetch_skill` call
/// (mirrors the cmd-w2 cached-lookup rule). Caches `nil` too so an
/// unresolved URL is not re-fetched.
actor MentionTitleCache {
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

    /// Carries the handler-resolved parent doctrine identity through public
    /// field projection. ToolRouter consumes and strips this key before the
    /// result leaves dispatch; callers never receive it as envelope data.
    static func attachingRoutingAuthorityEvidence(
        to value: Value,
        slug: String?,
        name: String
    ) -> Value {
        guard case .object(var object) = value else { return value }
        var evidence: [String: Value] = ["name": .string(name)]
        if let slug { evidence["slug"] = .string(slug) }
        object[ToolRouter.routingAuthorityEvidenceKey] = .object(evidence)
        return .object(object)
    }

    static func projectSkillResult(_ value: Value, fields: [String]?) -> Value {
        let evidence: Value? = {
            guard case .object(let object) = value else { return nil }
            return object[ToolRouter.routingAuthorityEvidenceKey]
        }()
        var projected = FieldsFilter.project(value, fields: fields)
        if let evidence, case .object(var object) = projected {
            object[ToolRouter.routingAuthorityEvidenceKey] = evidence
            projected = .object(object)
        }
        return projected
    }

    // MARK: - Auto-Routing Instructions (injected into MCP initialize response)

    /// Build a compact instructions string containing the routing skill index.
    /// Called at session creation to embed in the MCP initialize response.
    /// v3.0·0.5: tool-call contract surfaced in the MCP `instructions`
    /// field (both transports). Dense by design — it ships in every
    /// session's context. Tells an agent how to read/trust the tool surface.
    public static let dispatchContract = """
    Routing protocol: route CONTINUOUSLY, per sub-task — don't fetch one \
    skill and coast. For each new sub-task, watch for a domain trigger, then \
    call fetch_skill(parent, intent: '<this sub-task>') and act on the \
    specialist it returns. When the sub-task changes, re-route with a fresh \
    intent. If fetch_skill returns a `disambiguate` annotation, pick from its \
    `candidates` (fetch_skill('parent/<name>')) rather than guessing; a \
    `    routingFooter` names the sibling specialists you can switch to.
    Skill-system ownership: when the target is a KEEP OS skill or command \
    definition, call fetch_skill('skill-keepr', intent: '<this sub-task>') \
    before selecting a specialist or executor. A named worker does not \
    transfer ownership. Re-route when targets change or planning moves to \
    execution; normal use of an existing skill routes to that skill.
    After `fetch_skill(parent, intent:)`, read `scopedMemory.markdown` when \
    present and treat it as grounding for this sub-task only — re-fetch when \
    the intent changes (scope map uses the parent slug from `name`, not a \
    resolved specialist title).
    Capture disambiguation: when something should be DONE for the user, use \
    reminders_create (a real Apple/iCloud reminder the user will see); when \
    something should be KNOWN by the agent for later, use the memory/remember \
    path (an agent-side note). "Do" → reminders_create; "know" → memory.
    Tool contract: parameter keys are camelCase (snake_case only for raw \
    Notion-API value passthroughs). Each tool's description carries \
    "When to use" / "Not for" / "Related" guidance — read it before \
    selecting. On a wrong/missing parameter the error returns a \
    "did you mean: x→y" hint; trust it and retry once.
    Standing orders: persistent operator directives live behind the \
    standing_orders_* family — standing_orders_list (metadata only), \
    standing_orders_read (full body by id), standing_orders_save \
    (idempotent upsert), standing_orders_delete (soft-delete + archive). \
    These are operator-curated config; writes are Notify-tier and never \
    auto-execute.
    Apple Shortcuts: the shortcuts_* family wraps the macOS `shortcuts` CLI \
    — shortcuts_list (enumerate the user's shortcuts/folders, read-only) and \
    shortcuts_run (run one by name with optional input, capture its output). \
    A Shortcut can do anything, so shortcuts_run is Notify-tier and never \
    auto-executes silently.
    Calendar: the calendar_* family is native EventKit (.event entities) — \
    calendar_list (enumerate calendars), calendar_events (query a date \
    range), and calendar_free_busy (FOCUS EventKit occupancy SSOT \
    A33CAC6E-9D15-44F4-BC35-54F204F4DA39 only; Meetings freeBusy is \
    out of scope) are read-only/Open-tier; calendar_create and \
    calendar_update are Notify-tier writes; calendar_delete is Request-tier \
    (confirmation required, irreversible). Events use ISO-8601 start/end times.
    """

    public static func buildRoutingInstructions() -> String {
        renderRoutingInstructions(snapshot: legacyRoutingSnapshotSync())
    }

    /// Register the `fetch_skill` tool on the given router.
    public static func register(on router: ToolRouter) async {

        let cache = SkillCache.shared

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
            Fetch one skill page's full body, OR route into a domain's specialist.

            IDENTITY: prefer `id` (the stable Notion UUID) when an agent already
            knows the exact skill. Use `name` for human/routing labels and for
            parent/child or intent-based specialist routing. Exactly one is
            required; when both are supplied, `id` is authoritative.

            RECOMMENDED DEFAULT — call with the parent name + the current intent for \
            EACH new sub-task: name="project-keepr", intent="triage stale projects". \
            The server ranks the parent's curated specialists and returns the best \
            match. Re-call with the SAME parent and a fresh `intent` whenever the \
            sub-task changes — that continuous per-sub-task routing is how you stay on \
            the right specialist instead of drifting on a stale one.

            Two ways to address a specialist sub-skill:

              1. Intent ranking (preferred): name + intent → best-matching specialist \
            (score ≥ 0.4). If the top two are too close to call, or nothing clears the \
            bar, the envelope carries a `disambiguate` annotation with a `candidates` \
            list — pick one and re-fetch with `parent/<that-name>` rather than guessing.
              2. Path syntax: name="project-keepr/update" → resolves the "update" \
            child page (Notion) or specialists/update.md (file source). Depth > 1 is \
            rejected with a depth-guard annotation (parent body still returned).

            Every specialist/parent body returns a footer naming the sibling \
            specialists and how to re-route to them. An unresolvable specialist name \
            never errors — the envelope carries the parent body plus a \
            `specialist-not-found` annotation. Use `name` alone for the bare parent \
            body when you genuinely want the index page itself.

            GRANULAR FETCH: pass `section="<heading>"` to return ONLY that heading's \
            slice instead of the whole body — use this when you need one part of a \
            large skill and want to stay under token caps. No match → compact heading \
            index + a `section-not-found` annotation.

            FILES: when the SKILLS row has a Files & media (or Google Drive File) \
            property, the envelope includes `files: [{ name, kind, notionFileId?, \
            localPath?, sha256?, role? }]`. An empty array is honest. Call \
            skill_materialize_file to copy a Notion-hosted binary into \
            ~/Library/Application Support/The Bridge/skill-files/<uuid>/ for file_read. \
            Notion is not binary SSOT — when the body names a Mac folder, `assetRoot` \
            is included so you do not scrape /Users paths from prose.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Preferred exact identity for agent calls: the skill's Notion UUID. Resolves configured Notion skills without fuzzy name matching.")
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Skill name (case-insensitive). Accepts slash-delimited paths like 'project-keepr/update' to address a specialist; depth > 1 is rejected with an annotation.")
                    ]),
                    "intent": .object([
                        "type": .string("string"),
                        "description": .string("RECOMMENDED. The current sub-task in natural language (e.g. 'triage stale projects'). Ranks the named parent's curated specialists and returns the best match (score ≥ 0.4). Ambiguous or sub-threshold → a `disambiguate` annotation + `candidates` list instead of a silent parent fallback. Re-send with a fresh intent for each new sub-task in the domain.")
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
                    ]),
                    "section": .object([
                        "type": .string("string"),
                        "description": .string("Optional heading name to return ONLY that section's slice (case-insensitive, '#' markers ignored) instead of the whole body — a granular partial fetch to avoid blowing token caps. Exact match first; else unique prefix (heading starts with query). Nested subsections are included; a sibling/shallower heading ends the slice. No match → compact heading index + a `section-not-found` annotation.")
                    ]),
                    "fields": .object([
                        "type": .string("array"),
                        "description": .string("Optional. Array of top-level envelope keys to project the response down to — e.g. [\"content\",\"uuid\",\"version\"] or [\"title\",\"properties.status\"]. Valid identity keys include uuid, slug, version, status, maturity. Bare \"properties\" keeps the whole properties map; a dotted \"properties.X\" sub-selects one property (case-insensitive). Omitted or [] → the full response. Unknown keys/paths silently absent, never an error."),
                        "items": .object(["type": .string("string")])
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "fetch_skill",
                        reason: "expected an object with 'id' or 'name'"
                    )
                }

                let rawIDArg: String? = {
                    guard case .string(let raw) = args["id"] else { return nil }
                    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }()
                let idArg: String? = {
                    guard let raw = rawIDArg, !raw.isEmpty else { return nil }
                    let normalized = CachedSkillBody.normalize(raw)
                    return CachedSkillBody.isNotionUUID(normalized) ? normalized : nil
                }()
                let nameArg: String? = {
                    guard case .string(let raw) = args["name"] else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()
                guard idArg != nil || nameArg != nil else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "fetch_skill",
                        reason: "one of 'id' (preferred UUID) or 'name' is required"
                    )
                }
                if let rawIDArg, !rawIDArg.isEmpty, idArg == nil {
                    throw ToolRouterError.invalidArguments(
                        toolName: "fetch_skill",
                        reason: "'id' must be a 32-hex Notion UUID (dashed or compact)"
                    )
                }

                let uuidSkill: SkillConfig? = if let idArg {
                    if let configured = lookupSkill(pageId: idArg) {
                        configured
                    } else {
                        await lookupCachedSpecialist(pageId: idArg)
                    }
                } else {
                    nil
                }
                if let idArg, uuidSkill == nil {
                    return .object([
                        "error": .string("Skill UUID is not configured in Bridge."),
                        "id": .string(CachedSkillBody.canonicalUUID(idArg)),
                        "hint": .string("Refresh or register the Notion skill in Settings → Skills; arbitrary Notion pages are not treated as doctrine.")
                    ])
                }
                let rawName = uuidSkill?.name ?? nameArg ?? ""

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
                    // UUID addressing is exact: never route away from the
                    // requested doctrine record because an intent was also
                    // supplied by a generic client wrapper.
                    guard idArg == nil else { return nil }
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
                // fb-resultsize: optional section selector for granular fetch.
                let sectionArg: String? = {
                    if case .string(let s) = args["section"],
                       !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return nil
                }()
                // fields Param: optional result-projection selector — parsed
                // once up front so a structurally malformed value (wrong
                // type, not just an unknown key) hard-errors before any
                // work happens, on every code path below (cache hit, file-
                // source, offline plain-hit, live Notion fetch, error
                // envelopes are never filtered).
                let fieldsArg = try FieldsFilter.parseFieldsArgument(args, toolName: "fetch_skill")

                // Look up skill in UserDefaults config (cache key includes metadata fingerprint)
                let skillConfig: SkillConfig?
                if let uuidSkill {
                    skillConfig = uuidSkill
                } else {
                    skillConfig = await lookupSkill(named: name)
                }
                guard let skillConfig else {
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
                        let fileEnvelope = await Self.dispatchFileSpecialist(
                            parent: fileSkill,
                            parsedPath: parsedPath,
                            intent: intentArg
                        )
                        // fb-resultsize: apply the optional section selector
                        // to the file-source envelope's rendered `content`.
                        // fields Param: project AFTER scopedMemory is
                        // attached (the last envelope addition), so an
                        // omitted/empty `fields` stays byte-identical and a
                        // populated one governs the FINAL key set.
                        let fileResult = await MemoryRoutingAppendix.attach(
                            to: Self.applySectionToEnvelope(fileEnvelope, section: sectionArg),
                            parent: name,
                            intent: intentArg
                        )
                        let fileSlug: String? = {
                            if case .string(let slug)? = fileSkill.frontmatter["slug"] { return slug }
                            return nil
                        }()
                        return Self.projectSkillResult(
                            Self.attachingRoutingAuthorityEvidence(
                                to: fileResult,
                                slug: fileSlug,
                                name: fileSkill.name
                            ),
                            fields: fieldsArg
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
                let sectionKey = sectionArg.map { "|s=\($0.lowercased())" } ?? ""
                let cacheKey = "\(name.lowercased())|n=\(includeNested)|mb=\(maxBlocks)|md=\(maxDepth)|meta=\(skillConfig.metadataCacheToken)\(pathSelectorKey)\(sectionKey)"

                let parentPageId = skillConfig.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
                var fetchPageId = parentPageId
                var skipMemoryCache = false
                if let child = parsedPath.child {
                    if let childId = await Self.cachedSpecialistPageID(
                        parentPageID: parentPageId, childTitle: child
                    ) {
                        fetchPageId = childId
                    } else {
                        skipMemoryCache = true
                    }
                } else if intentArg != nil {
                    skipMemoryCache = true
                }

                let exposureGate = await SkillRuntimeGenerationStore.shared.gate()
                switch await Self.fetchMemoryResult(
                    enabled: skillConfig.enabled,
                    pageId: fetchPageId,
                    cacheKey: cacheKey,
                    cache: cache,
                    gate: exposureGate,
                    skipMemoryCache: skipMemoryCache
                ) {
                case .disabled:
                    return .object([
                        "error": .string("Skill '\(name)' is disabled."),
                        "hint": .string("Enable it in Settings \u{2192} Skills tab.")
                    ])
                case .invalidPageId:
                    return .object([
                        "error": .string("Invalid Notion page ID for skill '\(name)'."),
                        "hint": .string("Update the page URL or ID in Settings \u{2192} Skills to a valid Notion page (32 hex digits or a notion.so / notion.site link).")
                    ])
                case .unpublished:
                    return .object([
                        "error": .string("Skill '\(name)' is not published in the active runtime generation."),
                        "hint": .string("Review Runtime Exposure and the latest reconciliation receipt in Settings → Skills.")
                    ])
                case .cached(let cached):
                    let cachedResult = await MemoryRoutingAppendix.attach(
                        to: cached,
                        parent: name,
                        intent: intentArg
                    )
                    return Self.projectSkillResult(cachedResult, fields: fieldsArg)
                case .miss:
                    break
                }

                let pageIdRaw = parentPageId

                // cmd-w4: includeNested / maxBlocks / maxDepth are retained
                // for input-schema + cache-key stability (existing callers
                // and cached entries keyed on them stay valid) but no
                // longer drive a block-tree walk — the /markdown path
                // returns one server-rendered document in a single call.
                _ = includeNested; _ = maxBlocks; _ = maxDepth

                // body-cache: ZERO-NETWORK plain-hit fast path.
                //
                // A PLAIN request — no path, no intent, no section, not a
                // depth-guard — resolves to the parent page itself: the live
                // path's `dispatchNotionSpecialist` would take its bare-parent
                // fast path (no specialist swap, no sibling enumeration → no
                // routingFooter / annotation keys), so the served envelope is
                // exactly `buildSkillResult(parent body)`. We can therefore
                // build that envelope ENTIRELY from the persisted body cache
                // (keyed by the parent page id, since no specialist is
                // resolved) WITHOUT ever constructing a NotionClient — so a
                // warm plain fetch succeeds offline, as fast as a local file.
                //
                // The lookup + envelope build run BEFORE `try NotionClient()`.
                // Selector requests (path / intent / section / depth-guard)
                // skip this and fall through to the live path below, where
                // they still benefit from the cached body inside the `do`.
                let isPlainRequest = parsedPath.child == nil
                    && intentArg == nil
                    && sectionArg == nil
                    && !parsedPath.depthExceeded
                if isPlainRequest,
                   let cachedBody = await SkillBodyCacheStore.shared.read(pageId: pageIdRaw) {
                    // Build the envelope with ZERO network — no client is
                    // constructed or awaited on this branch.
                    var result = await Self.buildPlainCacheHitEnvelope(
                        skill: skillConfig,
                        cachedBody: cachedBody
                    )
                    result = Self.attachingRoutingAuthorityEvidence(
                        to: result,
                        slug: cachedBody.slug,
                        name: skillConfig.name
                    )
                    await cache.set(cacheKey, content: result)

                    // Off the return path: bump callCount; on every 5th call
                    // kick a DETACHED freshness check (stale-while-revalidate).
                    // The revalidation is the ONLY place this branch may ever
                    // touch the network, and it runs detached AFTER we return.
                    let store = SkillBodyCacheStore.shared
                    let n = await store.incrementCallCount(pageId: pageIdRaw)
                    if n > 0, cachedBody.isExpired() || n % 5 == 0 {
                        let revalPageId = pageIdRaw
                        let knownEdited = cachedBody.lastEditedTime
                        let memCache = cache
                        Task.detached {
                            await Self.revalidateBodyCache(
                                pageId: revalPageId,
                                knownLastEdited: knownEdited,
                                store: store,
                                memCache: memCache
                            )
                        }
                    }
                    let plainHitResult = await MemoryRoutingAppendix.attach(
                        to: result,
                        parent: name,
                        intent: intentArg
                    )
                    return Self.projectSkillResult(plainHitResult, fields: fieldsArg)
                }

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

                    // body-cache: a persistent per-skill BODY cache sits
                    // BELOW the in-memory `cache` and ABOVE the network.
                    // Keyed by the RESOLVED `envelopePageId` so parent and
                    // parent/child get distinct bodies. On HIT we skip the
                    // `getPageMarkdown` payload (the large body call) and
                    // reuse the cached raw markdown — every downstream step
                    // (section slice → buildSkillResult → annotate*) runs
                    // IDENTICALLY to the network path, so the rebuilt
                    // envelope is byte-identical for the same input.
                    let bodyStore = SkillBodyCacheStore.shared
                    let cachedBody = await bodyStore.read(pageId: envelopePageId)
                    let bodyServedFromCache = (cachedBody != nil)

                    // cmd-w4: body via the server /markdown render (one call;
                    // preserves headings/lists/code/tables) instead of the
                    // depth-first block walk + extractPlainText join.
                    let rawMarkdown: String
                    if let cachedBody {
                        rawMarkdown = cachedBody.markdown
                    } else {
                        let markdownData = try await client.getPageMarkdown(pageId: envelopePageId)
                        rawMarkdown = Self.skillMarkdownString(fromMarkdownJSON: markdownData)
                    }

                    // fb-resultsize: when a `section` is requested, slice the
                    // rendered markdown down to that heading's content before
                    // mention-resolution + envelope build — a granular partial
                    // fetch. No match → a compact heading index, and we record
                    // it so the envelope carries a `section-not-found` annotation.
                    let sectionBody = sectionArg.flatMap {
                        Self.extractMarkdownSection(rawMarkdown, section: $0)
                    }
                    let sectionMissed = (sectionArg != nil) && (sectionBody == nil)
                    let bodyForEnvelope: String
                    if let sectionBody {
                        bodyForEnvelope = sectionBody
                    } else if let sectionArg {
                        bodyForEnvelope = Self.sectionMissMarkdown(requested: sectionArg, markdown: rawMarkdown)
                    } else {
                        bodyForEnvelope = rawMarkdown
                    }

                    // Skill-body <mention-page> tags now render as
                    // [Title](url) via the shared MentionResolver (cmd-w2),
                    // resolved through the cached getPage title lookup;
                    // unresolved / non-page subtypes → safe [link](url).
                    var result = await Self.buildSkillResult(
                        skill: skillConfig,
                        title: envelopeTitle,
                        url: envelopeURL,
                        markdownJSONOrText: bodyForEnvelope,
                        titleLookup: Self.makeSkillMentionTitleLookup(),
                        pageProperties: envelopeProperties
                    )
                    result = Self.annotateDoctrineIdentity(
                        result,
                        pageId: envelopePageId,
                        flattenedProperties: .object(Self.flattenProperties(envelopeProperties))
                    )
                    // fb-resultsize: surface the section-selector outcome.
                    result = Self.annotateSection(
                        result,
                        requested: sectionArg,
                        matched: sectionBody != nil,
                        missed: sectionMissed
                    )
                    // PKT-907: surface the resolution outcome in the envelope.
                    result = Self.annotateEnvelope(
                        result,
                        parentName: skillConfig.name,
                        dispatch: specialistDispatch
                    )
                    let parentSlug = CachedSkillBody.propertyString(
                        "Slug",
                        in: .object(Self.flattenProperties(pageProperties))
                    )
                    result = Self.attachingRoutingAuthorityEvidence(
                        to: result,
                        slug: parentSlug,
                        name: skillConfig.name
                    )
                    await cache.set(cacheKey, content: result)

                    // body-cache: persist (miss) or bump + maybe revalidate
                    // (hit). Off the return path — never blocks the result.
                    if bodyServedFromCache {
                        // HIT: bump callCount; on every 5th call kick a
                        // DETACHED freshness check (stale-while-revalidate).
                        let n = await bodyStore.incrementCallCount(pageId: envelopePageId)
                        if n > 0, cachedBody?.isExpired() == true || n % 5 == 0 {
                            let revalPageId = envelopePageId
                            let knownEdited = cachedBody?.lastEditedTime ?? ""
                            let memCache = cache
                            Task.detached {
                                await Self.revalidateBodyCache(
                                    pageId: revalPageId,
                                    knownLastEdited: knownEdited,
                                    store: bodyStore,
                                    memCache: memCache
                                )
                            }
                        }
                    } else {
                        // MISS / first fetch: write the RAW body keyed by the
                        // resolved page id (callCount=1, lastEditedTime from
                        // the getPage JSON). flattenProperties matches the
                        // envelope's `properties` builder exactly.
                        let lastEdited = specialistDispatch.resolvedSpecialist?.lastEditedTime
                            ?? (pageJSON["last_edited_time"] as? String ?? "")
                        let entry = CachedSkillBody(
                            pageId: envelopePageId,
                            markdown: rawMarkdown,
                            title: envelopeTitle,
                            url: envelopeURL,
                            properties: .object(Self.flattenProperties(envelopeProperties)),
                            lastEditedTime: lastEdited,
                            writtenAt: Date(),
                            ttlHours: BridgeDefaults.skillsCacheTTLHoursEffective,
                            callCount: 1
                        )
                        if entry.hasMinimumDoctrinePayload {
                            try? await bodyStore.write(entry)
                        } else {
                            NSLog("[fetch_skill] page=%@ not cached — minimum doctrine identity incomplete", envelopePageId)
                        }
                    }

                    let liveResult = await MemoryRoutingAppendix.attach(
                        to: result,
                        parent: name,
                        intent: intentArg
                    )
                    return Self.projectSkillResult(liveResult, fields: fieldsArg)
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
        await registerSkillSplitPrimitives(on: router)
        await registerExposurePrimitives(on: router)
        await registerSkillFilePrimitives(on: router)
    }

}
