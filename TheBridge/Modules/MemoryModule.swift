// MemoryModule.swift — Unified Memory MCP tools · Wave 1 + Wave 2
// TheBridge · Modules
//
// Registers `memory_remember` + `memory_recall` on the ToolRouter so BOTH
// transports (stdio ServerManager + Streamable-HTTP SSETransport) expose them
// — registration is centralized in `BridgeModuleRegistry`, which both surfaces
// call, exactly like reminders_* / fetch_skill.
//
// TIERS (matching the convention — see RemindersModule):
//   • memory_remember → .notify  — a low-risk LOCAL write. .notify executes
//     immediately and fires a fire-and-forget notification, the same posture
//     reminders_create uses for non-destructive writes. (Not .open, because
//     it mutates the store; not .request, because it is local + reversible via
//     the soft-tombstone forget path.)
//   • memory_recall   → .open    — read-only.
//
// SOURCE: the writing client/agent. The handler signature the router hands a
// tool is `(Value) async throws -> Value` — it does NOT carry the MCP
// `clientInfo` (that lives per-session in SSETransport, off the dispatch
// path). So `source` is taken from an optional `source` argument when the
// caller supplies it, else a stable default. This is the clean seam for a
// later wave to thread the live client name through dispatch.

import Foundation
import MCP

public enum MemoryModule {

    public static let moduleName = "memory"

    /// Default `source` when the caller does not pass one. A later wave can
    /// replace this with the resolved MCP client name once dispatch carries it.
    static let defaultSource = "bridge-mcp"

    /// Register on the given router. `store` defaults to the production
    /// singleton; tests inject a temp-path `MemoryStore` so the real DB is
    /// never touched.
    public static func register(
        on router: ToolRouter,
        store: MemoryStore = .shared
    ) async {

        // MARK: 1. memory_remember — notify (local write, reversible)
        await router.register(ToolRegistration(
            name: "memory_remember",
            module: moduleName,
            tier: .notify,
            description: "Persist a durable memory for later recall. Stores text under a scope (people|project|mac|time|skill|global|…) with an optional entity sub-key and a type (fact|preference|decision|reference). Deduplicates: identical or near-identical text in the same scope/entity refreshes/supersedes the prior entry instead of inserting a duplicate. Returns the stored entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string"), "description": .string("The memory to remember (required)")]),
                    "scope": .object(["type": .string("string"), "description": .string("Partition: people | project | mac | time | skill | global | … (default: global)")]),
                    "entity": .object(["type": .string("string"), "description": .string("Optional sub-key within the scope (e.g. a person id, project slug)")]),
                    "type": .object(["type": .string("string"), "description": .string("fact | preference | decision | reference (default: fact)")]),
                    "source": .object(["type": .string("string"), "description": .string("Writing agent/client label (optional; defaults to the calling client)")]),
                    "ttlSeconds": .object(["type": .string("number"), "description": .string("Optional explicit TTL in seconds. After this duration, the entry is soft-tombstoned by the consolidation sweep. Omit for indefinite retention (default). Negative values are rejected.")])
                ]),
                "required": .array([.string("text")])
            ]),
            metadata: ToolMetadata(
                title: "Memory Remember",
                whenToUse: [
                    "persist a fact, preference, decision, or reference you will want to recall in a later session",
                    "record something durable about a person, project, or the machine"
                ],
                whenNotToUse: [
                    "transient within-conversation scratch state (keep that in context)",
                    "structured records that belong in Notion/Reminders/Calendar (use those tools)"
                ],
                relatedTools: ["memory_recall"]
            ),
            handler: { arguments in
                guard case .object(let obj) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "memory_remember", reason: "expected an object")
                }
                guard case .string(let text)? = obj["text"], !text.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "memory_remember", reason: "missing 'text'")
                }
                let scope = stringArg(obj, "scope") ?? "global"
                let entity = stringArg(obj, "entity")
                let type = MemoryEntry.EntryType(rawValue: stringArg(obj, "type") ?? "fact") ?? .fact
                let source = stringArg(obj, "source") ?? defaultSource
                let ttlSeconds: TimeInterval? = {
                    if case .double(let d)? = obj["ttlSeconds"] { return d }
                    if case .int(let i)? = obj["ttlSeconds"] { return TimeInterval(i) }
                    return nil
                }()
                let entry = try await store.remember(
                    text: text, scope: scope, entity: entity, type: type,
                    source: source, ttlSeconds: ttlSeconds
                )
                return entryValue(entry)
            }
        ))

        // MARK: 2. memory_recall — open (read-only)
        await router.register(ToolRegistration(
            name: "memory_recall",
            module: moduleName,
            tier: .open,
            description: "Recall stored memories by full-text query, ranked by salience (relevance, recency, use frequency, type weight; pinned entries first). Optionally filter by scope and entity. Recalling a memory promotes it (bumps its use count + recency). Read-only with respect to content. Returns up to `limit` entries (default 8).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Full-text query to match against stored memories (required; pass an empty string to list salience-ranked recents within a scope)")]),
                    "scope": .object(["type": .string("string"), "description": .string("Restrict to a scope (people | project | mac | time | skill | global | …)")]),
                    "entity": .object(["type": .string("string"), "description": .string("Restrict to an entity sub-key within the scope")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max entries to return (default 8, max 100)")])
                ]),
                "required": .array([.string("query")])
            ]),
            metadata: ToolMetadata(
                title: "Memory Recall",
                whenToUse: [
                    "look up what you previously remembered about a person, project, or preference",
                    "ground a response in durable memory before answering"
                ],
                whenNotToUse: [
                    "searching the live filesystem or Notion (use those search tools)"
                ],
                relatedTools: ["memory_remember"]
            ),
            handler: { arguments in
                guard case .object(let obj) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "memory_recall", reason: "expected an object")
                }
                guard case .string(let query)? = obj["query"] else {
                    throw ToolRouterError.invalidArguments(toolName: "memory_recall", reason: "missing 'query'")
                }
                let scope = stringArg(obj, "scope")
                let entity = stringArg(obj, "entity")
                let limit: Int = {
                    if case .int(let i)? = obj["limit"] { return i }
                    if case .double(let d)? = obj["limit"] { return Int(d) }
                    return 8
                }()
                let entries = try await store.recall(query: query, scope: scope, entity: entity, limit: limit)
                return .object([
                    "count": .int(entries.count),
                    "memories": .array(entries.map(entryValue))
                ])
            }
        ))

        // MARK: 3. memory_export — request (local backup seam)
        await router.register(ToolRegistration(
            name: "memory_export",
            module: moduleName,
            tier: .request,
            description: "Export all live memories as a versioned JSON envelope for backup or migration. Local-only; does not include soft-tombstoned rows.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            metadata: ToolMetadata(
                title: "Memory Export",
                whenToUse: ["backup memories before a reinstall", "migrate memory between Macs via export/import"],
                whenNotToUse: ["reading memories for grounding (use memory_recall)"],
                relatedTools: ["memory_import", "memory_recall"]
            ),
            handler: { _ in
                let payload = try await store.exportJSON()
                return .object([
                    "ok": .bool(true),
                    "format": .string("json"),
                    "schemaVersion": .int(MemoryStore.ExportEnvelope.currentSchemaVersion),
                    "payload": .string(payload)
                ])
            }
        ))

        // MARK: 4. memory_import — request (local restore seam)
        await router.register(ToolRegistration(
            name: "memory_import",
            module: moduleName,
            tier: .request,
            description: "Import memories from a `memory_export` JSON envelope. Skips duplicates (same scope+entity+contentHash). Assigns fresh ids to imported rows.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "payload": .object(["type": .string("string"), "description": .string("JSON from memory_export")])
                ]),
                "required": .array([.string("payload")])
            ]),
            metadata: ToolMetadata(
                title: "Memory Import",
                whenToUse: ["restore a memory_export backup on this Mac"],
                whenNotToUse: ["creating a single new memory (use memory_remember)"],
                relatedTools: ["memory_export", "memory_remember"]
            ),
            handler: { arguments in
                guard case .object(let obj) = arguments,
                      case .string(let payload)? = obj["payload"], !payload.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "memory_import", reason: "missing 'payload'")
                }
                let result = try await store.importJSON(payload)
                return .object([
                    "ok": .bool(true),
                    "imported": .int(result.imported),
                    "skipped": .int(result.skipped),
                    "errors": .array(result.errors.map { .string($0) })
                ])
            }
        ))

        // MARK: 5. memory_update — notify (in-place editable field update, D35/D41)
        await router.register(ToolRegistration(
            name: "memory_update",
            module: moduleName,
            tier: .notify,
            description: "Update editable fields of an agent memory row by ID (text, scope, entity, type, pinned, source, expiry). Protected fields (id, createdAt, lastUsedAt, useCount, contentHash, supersededBy) are rejected. Last-save-wins; no conflict detection. Returns the updated entry.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Row ID to update (required)")]),
                    "text": .object(["type": .string("string"), "description": .string("New text content")]),
                    "scope": .object(["type": .string("string"), "description": .string("New scope (people | project | mac | time | skill | global | …)")]),
                    "entity": .object(["type": .string("string"), "description": .string("New entity sub-key within the scope")]),
                    "type": .object(["type": .string("string"), "description": .string("fact | preference | decision | reference")]),
                    "pinned": .object(["type": .string("boolean"), "description": .string("Pin (true) or unpin (false) the entry")]),
                    "source": .object(["type": .string("string"), "description": .string("Writing agent/client label")]),
                    "expiry": .object(["type": .string("string"), "description": .string("ISO 8601 date after which the entry is soft-tombstoned")])
                ]),
                "required": .array([.string("id")])
            ]),
            metadata: ToolMetadata(
                title: "Memory Update",
                whenToUse: [
                    "correct or refine an existing agent memory by its ID",
                    "pin or unpin an entry",
                    "change the scope, entity, or type of an existing memory"
                ],
                whenNotToUse: [
                    "creating a new memory (use memory_remember)",
                    "removing a memory (use memory_forget)",
                    "modifying protected fields (id, createdAt, lastUsedAt, useCount, contentHash, supersededBy)"
                ],
                relatedTools: ["memory_remember", "memory_recall", "memory_forget"]
            ),
            handler: { arguments in
                guard case .object(let obj) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "memory_update", reason: "expected an object")
                }
                guard case .string(let id)? = obj["id"], !id.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "memory_update", reason: "missing 'id'")
                }

                // Reject protected fields.
                for key in obj.keys where MemoryStore.protectedFields.contains(key) && key != "id" {
                    return .object(["error": .bool(true), "message": .string("Field '\(key)' is not editable")])
                }

                let text = stringArg(obj, "text")
                let scope = stringArg(obj, "scope")
                let entity = stringArg(obj, "entity")
                let type = stringArg(obj, "type")
                let source = stringArg(obj, "source")

                let pinned: Bool? = {
                    if case .bool(let b)? = obj["pinned"] { return b }
                    return nil
                }()

                let expiry: Date? = {
                    guard let expiryStr = stringArg(obj, "expiry") else { return nil }
                    return ISO8601DateFormatter().date(from: expiryStr)
                }()

                let entry = try await store.update(
                    id: id, text: text, scope: scope, entity: entity,
                    type: type, pinned: pinned, source: source, expiry: expiry
                )
                return entryValue(entry)
            }
        ))

        // MARK: 6. memory_forget — notify (soft tombstone, reversible via export only)
        await router.register(ToolRegistration(
            name: "memory_forget",
            module: moduleName,
            tier: .notify,
            description: "Soft-delete one agent memory by id (sets expiresAt tombstone; excluded from recall/list). Local-only; does not remove Notion rows.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Memory entry id from memory_recall or memory_export")])
                ]),
                "required": .array([.string("id")])
            ]),
            metadata: ToolMetadata(
                title: "Memory Forget",
                whenToUse: ["remove a stale or mistaken agent memory after verification"],
                whenNotToUse: ["Notion Memory registry rows (use registry_delete)", "bulk wipe (use memory_export then selective cleanup)"],
                relatedTools: ["memory_recall", "memory_remember", "memory_export"]
            ),
            handler: { arguments in
                guard case .object(let obj) = arguments,
                      case .string(let id)? = obj["id"], !id.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "memory_forget", reason: "missing 'id'")
                }
                try await store.forget(id: id)
                return .object(["ok": .bool(true), "id": .string(id), "forgotten": .bool(true)])
            }
        ))
    }

    // MARK: - Client source threading (Wave 2 · Q3)

    /// Inject the live MCP client name as `source` when the caller omitted it.
    public static func argumentsWithClientSource(_ arguments: Value, clientName: String?) -> Value {
        guard let name = clientName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return arguments
        }
        guard case .object(var obj) = arguments else { return arguments }
        if stringArg(obj, "source") != nil { return arguments }
        obj["source"] = .string(name)
        return .object(obj)
    }

    // MARK: - Helpers

    private static func stringArg(_ obj: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = obj[key], !s.isEmpty { return s }
        return nil
    }

    static func entryValue(_ e: MemoryEntry) -> Value {
        var obj: [String: Value] = [
            "id": .string(e.id),
            "scope": .string(e.scope),
            "text": .string(e.text),
            "type": .string(e.type.rawValue),
            "pinned": .bool(e.pinned),
            "useCount": .int(e.useCount),
            "createdAt": .string(ISO8601DateFormatter().string(from: e.createdAt)),
            "lastUsedAt": .string(ISO8601DateFormatter().string(from: e.lastUsedAt)),
            "source": .string(e.source)
        ]
        if let entity = e.entity { obj["entity"] = .string(entity) }
        if let sup = e.supersedesId { obj["supersedesId"] = .string(sup) }
        return .object(obj)
    }
}
