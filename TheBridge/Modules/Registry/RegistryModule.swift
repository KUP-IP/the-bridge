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

import Foundation
import MCP

public enum RegistryModule {
    public static let moduleName = "registry"

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

    static func fields(_ args: [String: Value]) -> [String: Value] {
        if case .object(let o)? = args["fields"] { return o }
        return [:]
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
        await router.register(makeGet())
        await router.register(makeCreate())
        await router.register(makeUpdate())
        await router.register(makeDelete())
        await router.register(makePossess())
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
                // Guard the seeded Skills entity (entity #1 — the validating
                // fold-in + the default a fresh install relies on): removing it
                // needs an explicit confirm so an offhand call can't strip it.
                var confirm = false
                if case .bool(let b)? = a["confirm"] { confirm = b }
                if key == RegistryEntity.seedEntityKey && !confirm {
                    throw ToolRouterError.invalidArguments(
                        toolName: "registry_remove_entity",
                        reason: "‘\(key)’ is the seeded Skills entity — pass confirm:true to remove it")
                }
                _ = try await configStore().removeEntity(key: key)
                return .object(["removed": .bool(true), "entity": .string(key)])
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
                let entity = try requireEntity(key, in: config, tool: "registry_introspect")
                let schema = try await gateway().schema(dataSourceId: entity.dataSourceId, workspace: entity.workspace)
                let result = RegistrySchemaBinder.bind(entity, to: schema)
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
            description: "List rows of a registry entity (cache-backed, offline-tolerant). Returns projected rows keyed by the entity's canonical field keys.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string"), "description": .string("Entity key.")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max rows to return (default 50, max 500; paginates internally).")]),
                ]),
                "required": .array([.string("entity")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_list", reason: "missing ‘entity’")
                }
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_list")
                var limit = 50
                if case .int(let n)? = a["limit"] { limit = max(1, min(500, n)) }
                let reader = RegistryReader(gateway: gateway())
                let rows = try await reader.list(entity: entity, limit: limit)
                return .object([
                    "entity": .string(key),
                    "count": .int(rows.count),
                    "rows": .array(rows.map { rowValue($0, stale: $0.isExpired()) }),
                ])
            })
    }

    // MARK: - registry_get

    public static func makeGet() -> ToolRegistration {
        ToolRegistration(
            name: "registry_get", module: moduleName, tier: .open,
            description: "Get one row of a registry entity by page id (cache-first; serves a fresh hit instantly and revalidates a stale one).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string")]),
                    "id": .object(["type": .string("string"), "description": .string("Notion page id of the row.")]),
                    "forceRefresh": .object(["type": .string("boolean"), "description": .string("Bypass the cache.")]),
                ]),
                "required": .array([.string("entity"), .string("id")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity"), let id = string(a, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_get", reason: "missing ‘entity’ or ‘id’")
                }
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_get")
                var force = false
                if case .bool(let b)? = a["forceRefresh"] { force = b }
                let reader = RegistryReader(gateway: gateway())
                let row = try await reader.get(entity: entity, pageId: id, forceRefresh: force)
                return rowValue(row, stale: row.isExpired())
            })
    }

    // MARK: - registry_create

    public static func makeCreate() -> ToolRegistration {
        ToolRegistration(
            name: "registry_create", module: moduleName, tier: .notify,
            description: "Create a new row in a registry entity from canonical field keys (create-then-update: a titled row is created first, then the rest of the properties are set). Each supplied field must already be bound to a Notion property id — run registry_introspect first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string")]),
                    "fields": .object(["type": .string("object"), "description": .string("Map of canonical field key → value (e.g. {\"name\":\"…\",\"status\":\"Active\"}).")]),
                ]),
                "required": .array([.string("entity"), .string("fields")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_create", reason: "missing ‘entity’")
                }
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_create")
                let writer = RegistryWriter(gateway: gateway())
                let row = try await writer.create(entity: entity, fields: fields(a))
                return .object(["created": .bool(true), "row": rowValue(row, stale: false)])
            })
    }

    // MARK: - registry_update

    public static func makeUpdate() -> ToolRegistration {
        ToolRegistration(
            name: "registry_update", module: moduleName, tier: .notify,
            description: "Update fields on an existing registry-entity row (by page id), keyed by canonical field key. Only the supplied fields are changed.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object(["type": .string("string")]),
                    "id": .object(["type": .string("string")]),
                    "fields": .object(["type": .string("object")]),
                ]),
                "required": .array([.string("entity"), .string("id"), .string("fields")]),
            ]),
            handler: { args in
                guard case .object(let a) = args, let key = string(a, "entity"), let id = string(a, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "registry_update", reason: "missing ‘entity’ or ‘id’")
                }
                let config = await loadConfig()
                let entity = try requireEntity(key, in: config, tool: "registry_update")
                let writer = RegistryWriter(gateway: gateway())
                let row = try await writer.update(entity: entity, pageId: id, fields: fields(a))
                return .object(["updated": .bool(true), "row": rowValue(row, stale: false)])
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
}
