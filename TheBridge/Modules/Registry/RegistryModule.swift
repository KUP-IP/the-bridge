// RegistryModule.swift — Data-Source Registry (Wave 3)
// TheBridge · Modules · Registry
//
// The MCP tool surface for the registry. ONE generic CRUD set serves EVERY
// configured entity (validated per-entity against its property map at dispatch)
// — a small, stable surface (9 tools) regardless of how many entities exist,
// rather than N×CRUD per entity. Plus the introspection verb (bind a data
// source's schema by name → property ids + drift) and the `possess` domain verb
// (load an entity's page body — the generalized `fetch_skill`).
//
// All Notion access flows through `LiveRegistryGateway` (central rate limiter +
// connection resolution) and the read-through `RegistryRowCache`, so reads are
// warm-cache fast and offline-tolerant.
//
// `fields` result-projection scope (PKT: fields Param Across Registry Tools +
// fetch_skill): the 6 row-shaped tools built on `rowValue(_:stale:)` —
// registry_list/find/get/create/update/resolve_and_update — accept an opt-in
// `fields` param (see FieldsFilter.swift) that projects the row payload down
// to just the requested keys. The remaining 7 tools do NOT, on purpose:
//   - registry_entities / registry_add_entity — different value shape
//     (`entityValue`, entity-config not row-data); would need a second filter
//     helper, not a free extension of the row-shaped one.
//   - registry_remove_entity / registry_delete / registry_possess — already
//     2–3 keys; nothing worth trimming.
//   - registry_introspect — a diagnostic drift report where every key is
//     usually wanted.
//   - registry_hydrate — a deliberately comprehensive one-hop envelope;
//     trimming it risks undercutting why it exists (its description carries
//     a forward-pointer noting this).
// Any of these becoming in-scope later is a small, separable follow-on.

import CryptoKit
import Foundation
import MCP

public enum RegistryModule {
    public static let moduleName = "registry"
    public static let maxBodyMarkdownCharacters = 100_000

    // MARK: - Injectable seams (tests override; production uses live defaults)

    /// The Notion gateway the handlers use. Default is the live gateway
    /// (rate-limited connection); tests set a deterministic fake.
    ///
    /// `nonisolated(unsafe)` disables the compiler's race checking, so the
    /// CONTRACT is write-once-before-server-start: production never reassigns
    /// this after registration; only tests mutate it (serially, before driving
    /// a handler). Do not reassign it at runtime.
    public nonisolated(unsafe) static var gatewayProvider: @Sendable () -> RegistryNotionGateway = { LiveRegistryGateway() }

    static func gateway() -> RegistryNotionGateway { gatewayProvider() }

    /// The SHARED config store — one actor, so concurrent mutations (add /
    /// introspect from multiple callers) serialize and never lose updates. Its
    /// path resolves dynamically, so it still honors `overrideHomeForTesting`.
    static func configStore() -> RegistryConfigStore { .shared }

    // MARK: - Shared helpers

    static func loadConfig() async -> RegistryConfig {
        let store = configStore()
        if let cfg = try? await store.seedIfMissing() { return cfg }
        return await store.loadOrSeed()
    }

    static func requireEntity(_ key: String, in config: RegistryConfig, tool: String) throws -> RegistryEntity {
        guard let e = config.entity(key) else {
            let known = config.entities.map { $0.key }.sorted().joined(separator: ", ")
            throw ToolRouterError.invalidArguments(toolName: tool, reason: "unknown entity ‘\(key)’ — configured: [\(known)]")
        }
        return e
    }

    static func string(_ args: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = args[key], !s.isEmpty { return s }
        return nil
    }

    static func stringIfPresent(_ args: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = args[key] { return s }
        return nil
    }

    static func fields(_ args: [String: Value]) -> [String: Value] {
        if case .object(let o)? = args["fields"] { return o }
        return [:]
    }

    // MARK: - `fields` result-projection param (shared FieldsFilter)
    //
    // NOTE: `registry_create` / `registry_update` / `registry_resolve_and_update`
    // ALREADY use the key `"fields"` for their write payload — a map of
    // canonical field key → value (see `fields(_:)` above). The new opt-in
    // result-projection param locked by the packet also wants the name
    // `"fields"` (industry-standard partial-response naming). Rather than
    // invent a second parameter name, this reuses the SAME key and
    // discriminates by Value shape: `.array` → result-projection selector
    // (this helper); `.object` → the pre-existing write-field map (`fields(_:)`
    // above, untouched). Every existing caller sends an object for writes, so
    // this is fully backward compatible — a write call never accidentally
    // hits the projection path, and a projection call never accidentally
    // becomes an (empty) field write. `registry_get`/`registry_list`/
    // `registry_find` have no pre-existing `fields` param, so this is a
    // non-issue there; the same helper is used for uniformity.
    static func resultFields(_ args: [String: Value], toolName: String) throws -> [String]? {
        // Pure read tools (registry_get/list/find) have NO pre-existing
        // `fields` param — every present value is unambiguously the
        // projection selector, so it always routes through
        // `parseFieldsArgument` (which hard-errors on any non-array shape).
        return try FieldsFilter.parseFieldsArgument(args, toolName: toolName)
    }

    /// Variant for the 3 write tools where `fields` ALREADY means the
    /// write-field map when it's an `.object` — see the doc comment above.
    /// `.object` (or absent) → not the projection selector, so `nil` is
    /// returned and `fields(_:)` reads the write payload untouched. Any
    /// OTHER present shape — `.array` (the real selector) OR a
    /// structurally malformed one (bare string/number/bool) — routes
    /// through `parseFieldsArgument`, which accepts `.array` and
    /// hard-errors on everything else. This preserves Success Criterion
    /// #11 (malformed `fields` must ALWAYS hard-error, never silently
    /// no-op) even though `.object` is a legitimate third shape here.
    static func resultFieldsOnWriteTool(_ args: [String: Value], toolName: String) throws -> [String]? {
        if case .object? = args["fields"] { return nil }
        guard args["fields"] != nil else { return nil }
        return try FieldsFilter.parseFieldsArgument(args, toolName: toolName)
    }

    /// Shared description snippet for the `fields` result-projection param,
    /// reused verbatim across all 6 tools (Round 2 Decision 4 — one
    /// mechanism, learned once, recognized everywhere).
    static let fieldsParamDescriptionSuffix = " Optional `fields` (array of strings) narrows the returned row to only the requested top-level keys — e.g. [\"title\",\"properties.status\"] — instead of the full envelope. Bare \"properties\" keeps the whole properties map; a dotted \"properties.X\" sub-selects one property (case-insensitive). Identity keys (`id`, `entity`, `title`) are always retained when present so projected list/find rows remain usable for follow-on updates. Omitted or [] → unchanged full response. Unknown keys/paths are silently absent, never an error. On write tools this NEVER filters the operation-status wrapper (created/updated/matchedId/bodyWrite/idempotentReplay/partialFailure/reason) — only the row payload."

    static func fieldsParamSchema() -> Value {
        .object([
            "type": .string("array"),
            "description": .string("Optional. Array of top-level keys to project the row down to (e.g. [\"title\",\"properties.status\"]). Omitted or [] → full response, byte-identical to today. Bare \"properties\" keeps the whole map; \"properties.X\" sub-selects one property (case-insensitive match). Unknown keys/paths silently absent, never an error."),
            "items": .object(["type": .string("string")]),
        ])
    }

    static func markdownHash(_ markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func bodyWriteValue(
        requested: Bool,
        succeeded: Bool,
        characters: Int,
        markdownHash: String?,
        operation: String = "replacePageMarkdown",
        error: String? = nil
    ) -> Value {
        var out: [String: Value] = [
            "requested": .bool(requested),
            "succeeded": .bool(succeeded),
            "operation": .string(operation),
            "characters": .int(characters),
            "maxCharacters": .int(maxBodyMarkdownCharacters),
        ]
        if let markdownHash { out["markdownSha256"] = .string(markdownHash) }
        if let error { out["error"] = .string(error) }
        return .object(out)
    }

    static func entityValue(_ e: RegistryEntity) -> Value {
        .object([
            "key": .string(e.key),
            "displayName": .string(e.displayName),
            "dataSourceId": .string(e.dataSourceId),
            "workspace": e.workspace.map { Value.string($0) } ?? .null,
            "hasBody": .bool(e.hasBody),
            "cacheTTLSeconds": .int(e.cacheTTLSeconds),
            "fullyBound": .bool(e.isFullyBound),
            "properties": .array(e.properties.map { p in
                .object([
                    "key": .string(p.key),
                    "notionName": .string(p.notionName),
                    "type": .string(p.type),
                    "role": .string(p.role.rawValue),
                    "bound": .bool(p.isBound),
                ])
            }),
        ])
    }

    static func rowValue(_ cr: CachedRow, stale: Bool) -> Value {
        .object([
            "entity": .string(cr.entity),
            "id": .string(cr.pageId),
            "title": .string(cr.title),
            "url": .string(cr.url),
            "lastEditedTime": .string(cr.lastEditedTime),
            "stale": .bool(stale),
            "properties": cr.properties,
        ])
    }

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        await router.register(makeEntities())
        await router.register(makeAddEntity())
        await router.register(makeRemoveEntity())
        await router.register(makeIntrospect())
        await router.register(makeList())
        await router.register(makeFind())
        await router.register(makeGet())
        await router.register(makeCreate())
        await router.register(makeUpdate())
        await router.register(makeResolveAndUpdate())
        await router.register(makeDelete())
        await router.register(makePossess())
        await router.register(makeHydrate())
        await router.register(makePacketRegistryPreflight())
    }

    // MARK: - registry_entities

    public static func makeEntities() -> ToolRegistration {
        ToolRegistration(
            name: "registry_entities", module: moduleName, tier: .open,
            description: "List the configured data-source registry entities (entity → Notion data source + property map), including per-property binding status. Read-only; reads local config.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in
                let config = await loadConfig()
                return .object([
                    "schemaVersion": .int(config.schemaVersion),
                    "entities": .array(config.entities.map { entityValue($0) }),
                ])
            })
    }

    // MARK: - registry_add_entity

    public static func makeAddEntity() -> ToolRegistration {
        ToolRegistration(
            name: "registry_add_entity", module: moduleName, tier: .notify,
            description: "Register a new entity in the data-source registry: map a Notion data source to a canonical entity + property map (bound by name → property id at introspect). Upserts by key. After adding, run registry_introspect to resolve the property ids.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "key": .object(["type": .string("string"), "description": .string("Canonical entity key, e.g. ‘project’.")]),
                    "displayName": .object(["type": .string("string")]),
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Notion data source id.")]),
                    "workspace": .object(["type": .string("string"), "description": .string("Connection name (omit for primary).")]),
                    "hasBody": .object(["type": .string("boolean")]),
                    "cacheTTLSeconds": .object(["type": .string("integer")]),
                    "properties": .object([
                        "type": .string("array"),
                        "description": .string("Property map: [{key, notionName, type, role?}]. role ∈ {title,status,date,relation,generic}."),
                        "items": .object(["type": .string("object")]),
                    ]),
                ]),
                "required": .array([.string("key"), .string("dataSourceId"), .string("properties")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "key"), let dsId = string(a, "dataSourceId") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_add_entity", reason: "missing ‘key’ or ‘dataSourceId’")
                }
                guard case .array(let propArr)? = a["properties"], !propArr.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_add_entity", reason: "‘properties’ must be a non-empty array")
                }
                var props: [RegistryProperty] = []
                for p in propArr {
                    guard case .object(let po) = p, let pkey = string(po, "key"), let pname = string(po, "notionName") else {
                        throw ToolRouterError.invalidArguments(toolName: "registry_add_entity", reason: "each property needs ‘key’ + ‘notionName’")
                    }
                    let ptype = string(po, "type") ?? "rich_text"
                    let role = (string(po, "role").flatMap { RegistryPropertyRole(rawValue: $0) }) ?? .generic
                    props.append(RegistryProperty(key: pkey, notionName: pname, type: ptype, role: role))
                }
                var ttl = 3600
                if case .int(let n)? = a["cacheTTLSeconds"] { ttl = max(0, n) }
                var hasBody = false
                if case .bool(let b)? = a["hasBody"] { hasBody = b }
                let entity = RegistryEntity(
                    key: key, displayName: string(a, "displayName") ?? key,
                    dataSourceId: dsId, workspace: string(a, "workspace"),
                    properties: props, cacheTTLSeconds: ttl, hasBody: hasBody)
                // Atomic upsert on the shared actor (serialized).
                _ = try await configStore().upsertEntity(entity)
                return .object(["added": .bool(true), "entity": entityValue(entity)])
            })
    }

    // MARK: - registry_remove_entity

    public static func makeRemoveEntity() -> ToolRegistration {
        ToolRegistration(
            name: "registry_remove_entity", module: moduleName, tier: .request,
            description: "Remove an entity from the data-source registry: forget its entity→data-source mapping + property map and evict its cached rows. Does NOT touch Notion — the data source and its rows remain; only the Bridge's local binding is removed. Removing the seeded Skills entity requires confirm:true.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string"), "description": .string("Entity key to remove, e.g. ‘project’.")]),
                    "confirm": .object(["type": .string("boolean"), "description": .string("Required (true) to remove the seeded Skills entity.")]),
                ]),
                "required": .array([.string("entity")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_remove_entity", reason: "missing ‘entity’")
                }
                let config = await loadConfig()
                _ = try requireEntity(key, in: config, tool: "registry_remove_entity")   // 404 on unknown
                let storedKeys = PacketRegistryContract.removalKeys(
                    forRequestedKey: key, in: config)
                // Guard the seeded Skills entity (entity #1 — the validating
                // fold-in + the default a fresh install relies on): removing it
                // needs an explicit confirm so an offhand call can't strip it.
                var confirm = false
                if case .bool(let b)? = a["confirm"] { confirm = b }
                if storedKeys.contains(RegistryEntity.seedEntityKey) && !confirm {
                    throw ToolRouterError.invalidArguments(
                        toolName: "registry_remove_entity",
                        reason: "‘\(key)’ is the seeded Skills entity — pass confirm:true to remove it")
                }
                let result = try await configStore().removeEntities(keys: storedKeys)
                if storedKeys.contains(where: { storedKey in
                    config.entities.contains { entity in
                        entity.key == storedKey && PacketRegistryContract.isPacketEntity(entity)
                    }
                }) {
                    await RegistryRowCache.shared.evictAll(entity: "packet")
                }
                return .object([
                    "removed": .bool(!result.removed.isEmpty),
                    "entity": .string(key),
                    "storedEntities": .array(result.removed.map(Value.string)),
                ])
            })
    }

    // MARK: - registry_introspect

    public static func makeIntrospect() -> ToolRegistration {
        ToolRegistration(
            name: "registry_introspect", module: moduleName, tier: .notify,
            description: "Introspect an entity's Notion data source: read the live schema, bind its properties by name → PROPERTY ID, and report drift (unmatched columns, type changes). Persists the bindings (an AUTHORITATIVE rebind — a property whose column was renamed/removed is UN-bound). Run at setup or after a Notion schema change.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string"), "description": .string("Entity key, e.g. ‘skill’.")]),
                ]),
                "required": .array([.string("entity")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_introspect", reason: "missing ‘entity’")
                }
                let config = await loadConfig()
                _ = try requireEntity(key, in: config, tool: "registry_introspect")
                // Persist bindings onto the directly addressed STORED row.
                // `session` aliases packet only when no genuine Sessions row is
                // present or the direct session row is itself PACKETS-shaped.
                guard let storedEntity = PacketRegistryContract.storedEntity(
                    forRequestedKey: key, in: config) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "registry_introspect",
                        reason: "unknown stored entity ‘\(key)’")
                }
                let schema = try await gateway().schema(
                    dataSourceId: storedEntity.dataSourceId, workspace: storedEntity.workspace)
                let result = RegistrySchemaBinder.bind(storedEntity, to: schema)
                // Atomic load→upsert→save on the shared actor (serialized).
                _ = try? await configStore().upsertEntity(result.entity)
                return .object([
                    "entity": .string(key),
                    "fullyBound": .bool(result.entity.isFullyBound),
                    "clean": .bool(result.isClean),
                    "boundCount": .int(result.entity.properties.filter { $0.isBound }.count),
                    "drift": .array(result.drift.map { .string($0.message) }),
                    "schemaColumns": .array(schema.names.map { .string($0) }),
                ])
            })
    }

    // MARK: - registry_list

    public static func makeList() -> ToolRegistration {
        ToolRegistration(
            name: "registry_list", module: moduleName, tier: .open,
            description: "List rows of a registry entity (cache-backed, offline-tolerant). Returns projected rows keyed by the entity's canonical field keys. The additive `has_more` flag is true when the requested window is truncated." + fieldsParamDescriptionSuffix,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string"), "description": .string("Entity key.")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max rows to return (default 50, max 500; paginates internally).")]),
                    "fields": fieldsParamSchema(),
                ]),
                "required": .array([.string("entity")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_list", reason: "missing ‘entity’")
                }
                let requestedFields = try resultFields(a, toolName: "registry_list")
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_list")
                var limit = 50
                if case .int(let n)? = a["limit"] { limit = max(1, min(500, n)) }
                let reader = RegistryReader(gateway: gateway())
                // Read one sentinel row beyond the requested window so callers
                // can distinguish an exhausted source from a truncated list.
                let scanned = try await reader.list(entity: entity, limit: limit + 1)
                let hasMore = scanned.count > limit
                let rows = Array(scanned.prefix(limit))
                return .object([
                    "entity": .string(key),
                    "count": .int(rows.count),
                    "has_more": .bool(hasMore),
                    "rows": .array(rows.map { FieldsFilter.project(rowValue($0, stale: $0.isExpired()), fields: requestedFields) }),
                ])
            })
    }

    // MARK: - registry_find

    /// Convergent lookup: resolve an EXISTING row by canonical field
    /// predicate(s) BEFORE a blind `registry_create`, so an agent converges on
    /// the live row instead of minting a duplicate. Read-only; reuses the
    /// `registry_list` read-through + offline path. Matching is by BOUND
    /// PROPERTY ID (rename-safe) — predicate keys are the entity's canonical
    /// field keys, matched against the id-resolved projection. Zero matches is
    /// a valid empty result, NOT an error; multiple matches surface the
    /// ambiguity so the caller can disambiguate before writing.
    public static func makeFind() -> ToolRegistration {
        ToolRegistration(
            name: "registry_find", module: moduleName, tier: .open,
            description: "Find EXISTING registry rows by canonical field value(s) BEFORE creating — the resolve-before-write convergence primitive that avoids duplicate rows. Read-only, cache-backed, offline-tolerant. Pass `where` as a map of canonical field key → value (ALL must match, AND); values are matched rename-safe by the entity's bound property id, not the raw Notion name. Scalars compare case-insensitively; relation/multi-select fields match if any element equals. Returns matching rows (id + title + projected properties); no match → empty (not an error); multiple → ambiguous, all returned." + fieldsParamDescriptionSuffix,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string"), "description": .string("Entity key.")]),
                    "where": .object(["type": .string("object"), "description": .string("Map of canonical field key → value to match (e.g. {\"name\":\"Alpha\"} or {\"status\":\"Active\",\"slug\":\"x\"}). ALL predicates must match.")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max matching rows returned (default 100, max 500). The source scan paginates independently to exhaustion.")]),
                    "fields": fieldsParamSchema(),
                ]),
                "required": .array([.string("entity"), .string("where")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_find", reason: "missing ‘entity’")
                }
                guard case .object(let predicates)? = a["where"], !predicates.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_find", reason: "missing or empty ‘where’ — supply at least one field=value predicate")
                }
                let requestedFields = try resultFields(a, toolName: "registry_find")
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_find")
                var limit = 100
                if case .int(let n)? = a["limit"] { limit = max(1, min(500, n)) }
                let reader = RegistryReader(gateway: gateway())
                let rows = try await reader.find(entity: entity, predicates: predicates, limit: limit)
                return .object([
                    "entity": .string(key),
                    "count": .int(rows.count),
                    "rows": .array(rows.map { FieldsFilter.project(rowValue($0, stale: $0.isExpired()), fields: requestedFields) }),
                ])
            })
    }

    // MARK: - registry_get

    public static func makeGet() -> ToolRegistration {
        ToolRegistration(
            name: "registry_get", module: moduleName, tier: .open,
            description: "Get one row of a registry entity by page id (cache-first; serves a fresh hit instantly and revalidates a stale one)." + fieldsParamDescriptionSuffix,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string")]),
                    "id": .object(["type": .string("string"), "description": .string("Notion page id of the row.")]),
                    "forceRefresh": .object(["type": .string("boolean"), "description": .string("Bypass the cache.")]),
                    "fields": fieldsParamSchema(),
                ]),
                "required": .array([.string("entity"), .string("id")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity"), let id = string(a, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_get", reason: "missing ‘entity’ or ‘id’")
                }
                let requestedFields = try resultFields(a, toolName: "registry_get")
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_get")
                var force = false
                if case .bool(let b)? = a["forceRefresh"] { force = b }
                let reader = RegistryReader(gateway: gateway())
                let row = try await reader.get(entity: entity, pageId: id, forceRefresh: force)
                return FieldsFilter.project(rowValue(row, stale: row.isExpired()), fields: requestedFields)
            })
    }

    // MARK: - registry_create

    public static func makeCreate() -> ToolRegistration {
        ToolRegistration(
            name: "registry_create", module: moduleName, tier: .notify,
            description: "Create a new row in a registry entity from canonical field keys. Optional bodyMarkdown initializes the newly-created Notion page body for body-bearing entities (see registry_entities hasBody=true); the supplied Markdown is copied as source content, not summarized, regenerated, or improved. Supported Markdown is Notion's page-markdown subset: headings, paragraphs, bulleted/numbered lists, code fences, block quotes, links, and inline emphasis. bodyMarkdown is optional, Max 100000 characters, and used only for initial creation via replacePageMarkdown on the new blank page. Use idempotencyKey to make retries return the first created page instead of creating duplicates. If the body write fails after row creation, the result is created=false with partialFailure=true and the page id plus body error; it is never reported as a successful creation." + fieldsParamDescriptionSuffix + " NOTE: the write-payload `fields` (object) and the result-projection `fields` (array) share one parameter name — pass an OBJECT to write, or an ARRAY to project the response; the shapes never collide.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string")]),
                    "fields": .object(["type": .string("object"), "description": .string("Map of canonical field key → value to WRITE (e.g. {\"name\":\"…\",\"status\":\"Active\"}). To instead PROJECT the response, pass an array of strings — see the tool description.")]),
                    "bodyMarkdown": .object(["type": .string("string"), "description": .string("Optional initial page body for body-bearing entities only. Copied verbatim as Markdown source through Notion's page-markdown writer; never summarized or rewritten. Max 100000 characters.")]),
                    "idempotencyKey": .object(["type": .string("string"), "description": .string("Optional stable retry key/source id. Reusing the same key returns the first created page and avoids duplicate packets.")]),
                ]),
                "required": .array([.string("entity"), .string("fields")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_create", reason: "missing ‘entity’")
                }
                let requestedFields = try resultFieldsOnWriteTool(a, toolName: "registry_create")
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_create")
                let bodyMarkdown = stringIfPresent(a, "bodyMarkdown")
                let bodyRequested = bodyMarkdown != nil
                if bodyRequested && !entity.hasBody {
                    throw ToolRouterError.invalidArguments(
                        toolName: "registry_create",
                        reason: "entity ‘\(key)’ does not support page bodies — omit bodyMarkdown or choose an entity with hasBody=true")
                }
                if let bodyMarkdown, bodyMarkdown.count > maxBodyMarkdownCharacters {
                    throw ToolRouterError.invalidArguments(
                        toolName: "registry_create",
                        reason: "bodyMarkdown is \(bodyMarkdown.count) characters; max is \(maxBodyMarkdownCharacters). Nothing was created.")
                }
                let bodyHash = bodyMarkdown.map(markdownHash)
                let idempotencyKey = string(a, "idempotencyKey")
                let idemStore = RegistryCreateIdempotencyStore.shared
                let gateway = gateway()
                if let idempotencyKey, let record = try await idemStore.record(entity: entity.key, key: idempotencyKey) {
                    if let bodyHash, let priorHash = record.bodyMarkdownHash, priorHash != bodyHash {
                        throw ToolRouterError.invalidArguments(
                            toolName: "registry_create",
                            reason: "idempotencyKey ‘\(idempotencyKey)’ was already used with different bodyMarkdown")
                    }
                    if record.bodyRequested, !record.bodySucceeded, let bodyMarkdown {
                        do {
                            try await gateway.writeMarkdown(pageId: record.row.pageId, workspace: entity.workspace, markdown: bodyMarkdown)
                            let healed = record.withBodySuccess()
                            try await idemStore.save(healed)
                            return .object([
                                "created": .bool(false),
                                "idempotentReplay": .bool(true),
                                "partialFailure": .bool(false),
                                "row": FieldsFilter.project(rowValue(healed.row, stale: false), fields: requestedFields),
                                "bodyWrite": bodyWriteValue(
                                    requested: true,
                                    succeeded: true,
                                    characters: healed.bodyCharacters,
                                    markdownHash: healed.bodyMarkdownHash),
                            ])
                        } catch {
                            let failed = record.withBodyFailure(String(describing: error))
                            try? await idemStore.save(failed)
                            return .object([
                                "created": .bool(false),
                                "idempotentReplay": .bool(true),
                                "partialFailure": .bool(true),
                                "reason": .string("body_write_failed"),
                                "row": FieldsFilter.project(rowValue(failed.row, stale: false), fields: requestedFields),
                                "bodyWrite": bodyWriteValue(
                                    requested: true,
                                    succeeded: false,
                                    characters: failed.bodyCharacters,
                                    markdownHash: failed.bodyMarkdownHash,
                                    error: failed.bodyError),
                            ])
                        }
                    }
                    return .object([
                        "created": .bool(false),
                        "idempotentReplay": .bool(true),
                        "partialFailure": .bool(!record.bodySucceeded && record.bodyRequested),
                        "row": FieldsFilter.project(rowValue(record.row, stale: false), fields: requestedFields),
                        "bodyWrite": bodyWriteValue(
                            requested: record.bodyRequested,
                            succeeded: record.bodySucceeded,
                            characters: record.bodyCharacters,
                            markdownHash: record.bodyMarkdownHash,
                            error: record.bodyError),
                    ])
                }
                let writer = RegistryWriter(gateway: gateway)
                let row = try await writer.create(entity: entity, fields: fields(a))
                if let idempotencyKey {
                    try await idemStore.save(RegistryCreateIdempotencyRecord(
                        entity: entity.key,
                        key: idempotencyKey,
                        row: row,
                        bodyRequested: bodyRequested,
                        bodySucceeded: !bodyRequested,
                        bodyMarkdownHash: bodyHash,
                        bodyCharacters: bodyMarkdown?.count ?? 0,
                        bodyError: nil,
                        createdAt: Date()))
                }
                guard let bodyMarkdown else {
                    return .object([
                        "created": .bool(true),
                        "partialFailure": .bool(false),
                        "row": FieldsFilter.project(rowValue(row, stale: false), fields: requestedFields),
                    ])
                }
                do {
                    try await gateway.writeMarkdown(pageId: row.pageId, workspace: entity.workspace, markdown: bodyMarkdown)
                    if let idempotencyKey {
                        try await idemStore.save(RegistryCreateIdempotencyRecord(
                            entity: entity.key,
                            key: idempotencyKey,
                            row: row,
                            bodyRequested: true,
                            bodySucceeded: true,
                            bodyMarkdownHash: bodyHash,
                            bodyCharacters: bodyMarkdown.count,
                            bodyError: nil,
                            createdAt: Date()))
                    }
                    return .object([
                        "created": .bool(true),
                        "partialFailure": .bool(false),
                        "row": FieldsFilter.project(rowValue(row, stale: false), fields: requestedFields),
                        "bodyWrite": bodyWriteValue(
                            requested: true,
                            succeeded: true,
                            characters: bodyMarkdown.count,
                            markdownHash: bodyHash),
                    ])
                } catch {
                    let err = String(describing: error)
                    if let idempotencyKey {
                        try? await idemStore.save(RegistryCreateIdempotencyRecord(
                            entity: entity.key,
                            key: idempotencyKey,
                            row: row,
                            bodyRequested: true,
                            bodySucceeded: false,
                            bodyMarkdownHash: bodyHash,
                            bodyCharacters: bodyMarkdown.count,
                            bodyError: err,
                            createdAt: Date()))
                    }
                    return .object([
                        "created": .bool(false),
                        "partialFailure": .bool(true),
                        "reason": .string("body_write_failed"),
                        "row": FieldsFilter.project(rowValue(row, stale: false), fields: requestedFields),
                        "bodyWrite": bodyWriteValue(
                            requested: true,
                            succeeded: false,
                            characters: bodyMarkdown.count,
                            markdownHash: bodyHash,
                            error: err),
                    ])
                }
            })
    }

    // MARK: - registry_update

    public static func makeUpdate() -> ToolRegistration {
        ToolRegistration(
            name: "registry_update", module: moduleName, tier: .notify,
            description: "Update fields on an existing registry-entity row (by page id), keyed by canonical field key. Only the supplied fields are changed. Optional `appendKeys` names fields whose write value is APPENDED to the row's current value as a dated block rather than overwriting it — reuses the exact same merge logic as registry_resolve_and_update's appendKeys mode. Omit `appendKeys` entirely for the original plain-overwrite behavior." + fieldsParamDescriptionSuffix + " NOTE: the write-payload `fields` (object) and the result-projection `fields` (array) share one parameter name — pass an OBJECT to write, or an ARRAY to project the response; the shapes never collide.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string")]),
                    "id": .object(["type": .string("string")]),
                    "fields": .object(["type": .string("object"), "description": .string("Map of canonical field key → value to WRITE. To instead PROJECT the response, pass an array of strings — see the tool description.")]),
                    "appendKeys": .object([
                        "type": .string("array"),
                        "description": .string("Optional. Canonical field keys that append (existing value + new content, dated block) instead of overwrite — same semantics as registry_resolve_and_update's appendKeys. Omit for plain overwrite of every field (default, unchanged behavior). Pass [] to explicitly force plain-overwrite via the append-aware read path."),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("entity"), .string("id"), .string("fields")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity"), let id = string(a, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_update", reason: "missing ‘entity’ or ‘id’")
                }
                let requestedFields = try resultFieldsOnWriteTool(a, toolName: "registry_update")
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_update")
                let gw = gateway()
                let writer = RegistryWriter(gateway: gw)
                let appendKeys: Set<String>? = {
                    guard case .array(let arr)? = a["appendKeys"] else { return nil }
                    return Set(arr.compactMap { v -> String? in if case .string(let s) = v { return s } else { return nil } })
                }()
                let row: CachedRow
                if let appendKeys {
                    let reader = RegistryReader(gateway: gw)
                    row = try await writer.update(entity: entity, pageId: id, fields: fields(a), reader: reader, appendKeys: appendKeys)
                } else {
                    row = try await writer.update(entity: entity, pageId: id, fields: fields(a))
                }
                return .object(["updated": .bool(true), "row": FieldsFilter.project(rowValue(row, stale: false), fields: requestedFields)])
            })
    }

    // MARK: - registry_resolve_and_update (PKT-MEM-135 — find+get+update in one call)

    /// Collapses the find-then-get-then-update three-round-trip pattern
    /// duplicated inside `VoiceMemoProcessor.executeRegistryUpdate` (D57: a
    /// general-purpose registry primitive, not Memory-Hub-scoped) into ONE MCP
    /// call: resolve a row by `registry_find`-identical predicate matching,
    /// merge any configured append-style fields against the resolved row's
    /// CURRENT values, then write. Ambiguity/no-match semantics are IDENTICAL
    /// to `registry_find` (single match → write; ≥2 matches → ambiguous error,
    /// NO write; 0 matches → not-found error, NO write) — the only difference
    /// from `registry_find` is that ambiguous/no-match are ERRORS here rather
    /// than a returned empty/multi-row result, because there is nothing valid
    /// to update. Create-on-no-match (upsert) is explicitly OUT of scope
    /// (D56) — this tool never creates a row.
    public static func makeResolveAndUpdate() -> ToolRegistration {
        ToolRegistration(
            name: "registry_resolve_and_update", module: moduleName, tier: .notify,
            description: "Resolve an EXISTING registry row by canonical field predicate(s) (identical matching to registry_find) and update it — in ONE call, replacing the find-then-get-then-update three-round-trip pattern. Pass `where` as a map of canonical field key → value (ALL must match, AND; same rename-safe bound-property-id matching as registry_find). Exactly one match is required: 0 matches is a not-found error (no write); ≥2 matches is an ambiguous error (no write, resolve the predicate further or use registry_find + registry_update directly). `fields` are the canonical field key → value pairs to write (REQUIRED, non-empty object) — this tool's `fields` is always the write payload, never the result-projection selector (unlike the other 5 fields-enabled tools) because a write payload is mandatory here; use `resultFields` (array of strings) instead to narrow the response — same mechanics as the shared `fields` projector elsewhere:" + fieldsParamDescriptionSuffix + " Optional `appendKeys` (default: brief, objective, summary, description) names fields whose write value is APPENDED to the row's current value as a dated block rather than overwriting it — matches the existing voice-memo append-merge behavior exactly; every other field is a plain overwrite. Never creates a row (no upsert — see registry_create for that).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string"), "description": .string("Entity key.")]),
                    "where": .object(["type": .string("object"), "description": .string("Map of canonical field key → value to match (e.g. {\"name\":\"Alpha\"}). ALL predicates must match. Exactly one row must match.")]),
                    "fields": .object(["type": .string("object"), "description": .string("Map of canonical field key → value to write. ALWAYS the write payload on this tool (required, non-empty) — use resultFields to project the response instead.")]),
                    "appendKeys": .object([
                        "type": .string("array"),
                        "description": .string("Canonical field keys that append (existing value + new content, dated block) instead of overwrite. Defaults to [brief, objective, summary, description] — the existing voice-memo append set. Pass [] to disable append-merge entirely (all fields overwrite)."),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "resultFields": fieldsParamSchema(),
                ]),
                "required": .array([.string("entity"), .string("where"), .string("fields")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_resolve_and_update", reason: "missing ‘entity’")
                }
                guard case .object(let predicates)? = a["where"], !predicates.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_resolve_and_update", reason: "missing or empty ‘where’ — supply at least one field=value predicate")
                }
                let input = fields(a)
                guard !input.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_resolve_and_update", reason: "missing or empty ‘fields’ — supply at least one field to write")
                }
                var resultFieldsArg: [String: Value] = [:]
                if let rf = a["resultFields"] { resultFieldsArg["fields"] = rf }
                let requestedFields = try FieldsFilter.parseFieldsArgument(
                    resultFieldsArg, toolName: "registry_resolve_and_update")
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_resolve_and_update")
                var appendKeys = RegistryAppendMerge.defaultAppendKeys
                if case .array(let arr)? = a["appendKeys"] {
                    appendKeys = Set(arr.compactMap { v -> String? in if case .string(let s) = v { return s } else { return nil } })
                }
                let gw = gateway()
                let reader = RegistryReader(gateway: gw)
                let writer = RegistryWriter(gateway: gw)
                do {
                    let result = try await writer.resolveAndUpdate(
                        entity: entity, reader: reader, predicates: predicates, fields: input, appendKeys: appendKeys)
                    return .object(["updated": .bool(true), "matchedId": .string(result.matchedId), "row": FieldsFilter.project(rowValue(result.row, stale: false), fields: requestedFields)])
                } catch let e as RegistryWriter.RegistryResolveError {
                    switch e {
                    case .noMatch:
                        throw ToolRouterError.invalidArguments(toolName: "registry_resolve_and_update", reason: e.errorDescription ?? "no match")
                    case .ambiguous:
                        throw ToolRouterError.invalidArguments(toolName: "registry_resolve_and_update", reason: e.errorDescription ?? "ambiguous match")
                    }
                }
            })
    }

    // MARK: - registry_delete

    public static func makeDelete() -> ToolRegistration {
        ToolRegistration(
            name: "registry_delete", module: moduleName, tier: .request,
            description: "Archive (soft-delete) a registry-entity row by page id and evict it from the cache. The Notion page is moved to trash, not permanently deleted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string")]),
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("entity"), .string("id")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity"), let id = string(a, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_delete", reason: "missing ‘entity’ or ‘id’")
                }
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_delete")
                let writer = RegistryWriter(gateway: gateway())
                try await writer.delete(entity: entity, pageId: id)
                return .object(["archived": .bool(true), "entity": .string(key), "id": .string(id)])
            })
    }

    // MARK: - registry_possess (domain verb — body load)

    public static func makePossess() -> ToolRegistration {
        ToolRegistration(
            name: "registry_possess", module: moduleName, tier: .open,
            description: "Load an entity row's page BODY on demand — the generalized ‘possess’/fetch_skill verb for body-bearing entities (Skills, BLOCKS). Returns the rendered markdown.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string")]),
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("entity"), .string("id")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity"), let id = string(a, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_possess", reason: "missing ‘entity’ or ‘id’")
                }
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_possess")
                guard entity.hasBody else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_possess", reason: "entity ‘\(key)’ has no body to possess")
                }
                let reader = RegistryReader(gateway: gateway())
                let body = try await reader.body(entity: entity, pageId: id)
                return .object(["entity": .string(key), "id": .string(id), "body": .string(body)])
            })
    }

    // MARK: - registry_hydrate (packet-registry-v1 envelope — FR-1 / §8.3)

    public static func makeHydrate() -> ToolRegistration {
        ToolRegistration(
            name: "registry_hydrate", module: moduleName, tier: .open,
            description: "Hydrate one entity row into the packet-registry-v1 envelope (PRD FR-1/§8.3): primary properties + page body + curated ONE-HOP relation projections (project/skills/blockedBy/blocking/event) + provenance + unresolved-relation warnings. Read-only, one hop only — a relation's body is NOT loaded (use registry_possess for a deeper body). A missing/inaccessible relation is omitted + warned, never guessed. NOTE: unlike the 6 row-shaped registry tools, this comprehensive one-hop envelope does not yet support a `fields` result-projection param — the full envelope is always returned.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string"), "description": .string("Entity key (e.g. ‘packet’).")]),
                    "id": .object(["type": .string("string"), "description": .string("Notion page id of the primary row.")]),
                    "forceRefresh": .object(["type": .string("boolean"), "description": .string("Bypass the cache for the primary read.")]),
                ]),
                "required": .array([.string("entity"), .string("id")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity"), let id = string(a, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_hydrate", reason: "missing ‘entity’ or ‘id’")
                }
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_hydrate")
                var force = false
                if case .bool(let b)? = a["forceRefresh"] { force = b }
                let reader = RegistryReader(gateway: gateway())
                let envelope = try await reader.hydrate(entity: entity, pageId: id, forceRefresh: force)
                return envelope.asValue()
            })
    }

    // MARK: - packet_registry_preflight (read-only canonical contract gate)

    public static func makePacketRegistryPreflight() -> ToolRegistration {
        ToolRegistration(
            name: "packet_registry_preflight", module: moduleName, tier: .open,
            description: "Read-only validation of the canonical packet-registry-v1 binding against the live PACKETS schema. Never repairs bindings, persists config, mutates Notion, or evicts caches.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contractVersion": .object(["type": .string("string"), "description": .string("Optional; only packet-registry-v1 is accepted.")]),
                ]),
            ]),
            handler: { args in
                guard case .object(let a) = args else {
                    throw ToolRouterError.invalidArguments(toolName: "packet_registry_preflight", reason: "arguments must be an object")
                }
                let requested = stringIfPresent(a, "contractVersion")
                guard requested == nil || requested == PacketRegistryContract.version else {
                    throw ToolRouterError.invalidArguments(toolName: "packet_registry_preflight", reason: "unsupported contractVersion ‘\(requested ?? "")’")
                }
                // Deliberately use load(), not loadConfig()/seedIfMissing(): preflight
                // is an observation and must not create registry.json on first run.
                let config = try await configStore().load()
                guard let entity = PacketRegistryContract.entity(from: config), !entity.dataSourceId.isEmpty else {
                    return PacketRegistryPreflight.value(contractVersion: requested, config: config, schema: DataSourceSchema(columnsByName: [:]))
                }
                let schema = try await gateway().schema(dataSourceId: entity.dataSourceId, workspace: entity.workspace)
                return PacketRegistryPreflight.value(contractVersion: requested, config: config, schema: schema)
            })
    }
}

public struct RegistryCreateIdempotencyRecord: Codable, Sendable, Equatable {
    public let entity: String
    public let key: String
    public let row: CachedRow
    public let bodyRequested: Bool
    public let bodySucceeded: Bool
    public let bodyMarkdownHash: String?
    public let bodyCharacters: Int
    public let bodyError: String?
    public let createdAt: Date

    public init(
        entity: String,
        key: String,
        row: CachedRow,
        bodyRequested: Bool,
        bodySucceeded: Bool,
        bodyMarkdownHash: String?,
        bodyCharacters: Int,
        bodyError: String?,
        createdAt: Date
    ) {
        self.entity = entity
        self.key = key
        self.row = row
        self.bodyRequested = bodyRequested
        self.bodySucceeded = bodySucceeded
        self.bodyMarkdownHash = bodyMarkdownHash
        self.bodyCharacters = bodyCharacters
        self.bodyError = bodyError
        self.createdAt = createdAt
    }

    public func withBodySuccess() -> RegistryCreateIdempotencyRecord {
        RegistryCreateIdempotencyRecord(
            entity: entity,
            key: key,
            row: row,
            bodyRequested: bodyRequested,
            bodySucceeded: true,
            bodyMarkdownHash: bodyMarkdownHash,
            bodyCharacters: bodyCharacters,
            bodyError: nil,
            createdAt: createdAt)
    }

    public func withBodyFailure(_ error: String) -> RegistryCreateIdempotencyRecord {
        RegistryCreateIdempotencyRecord(
            entity: entity,
            key: key,
            row: row,
            bodyRequested: bodyRequested,
            bodySucceeded: false,
            bodyMarkdownHash: bodyMarkdownHash,
            bodyCharacters: bodyCharacters,
            bodyError: error,
            createdAt: createdAt)
    }
}

public actor RegistryCreateIdempotencyStore {
    public static let shared = RegistryCreateIdempotencyStore()

    private var loaded: [String: RegistryCreateIdempotencyRecord]?

    public init() {}

    private var fileURL: URL {
        BridgePaths.applicationSupport(.registry).appendingPathComponent("create-idempotency.json")
    }

    private func composite(entity: String, key: String) -> String {
        "\(entity)\u{1F}\(key)"
    }

    private func load() -> [String: RegistryCreateIdempotencyRecord] {
        if let loaded { return loaded }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: RegistryCreateIdempotencyRecord].self, from: data) else {
            loaded = [:]
            return [:]
        }
        loaded = decoded
        return decoded
    }

    public func record(entity: String, key: String) throws -> RegistryCreateIdempotencyRecord? {
        load()[composite(entity: entity, key: key)]
    }

    public func save(_ record: RegistryCreateIdempotencyRecord) throws {
        var records = load()
        records[composite(entity: record.entity, key: record.key)] = record
        try BridgePaths.ensureApplicationSupport(.registry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: [.atomic])
        loaded = records
    }

    public func resetForTesting() throws {
        loaded = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
