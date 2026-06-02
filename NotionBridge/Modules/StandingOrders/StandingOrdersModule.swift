// StandingOrdersModule.swift — PKT-931 (v3.7·B)
// NotionBridge · Modules · StandingOrders
//
// 4 standing_orders_* MCP tools under module="standing_orders", wrapping the
// actor-isolated StandingOrdersRecordStore. Standing orders are persistent
// operator directives consumed by bridge-keepr and the routing skills.
//
// Tier policy: ALL FOUR tools are tier `.notify` (packet DoD — operator-curated
// config must not silently change, and writes must not auto-execute). The
// read-only-named tools (_list / _read) are deliberately kept at `.notify`
// rather than `.open`; they are allow-listed in ReadOnlyTierAuditTests with a
// justification, mirroring the credential_read / credential_list precedent.
//
// Shape mirrors the credential_* / skill_* families:
//   standing_orders_list   → metadata only [{id, title, scope, updatedAt}]
//   standing_orders_read   → full body + metadata by id (404 on archived)
//   standing_orders_save   → idempotent upsert by id
//   standing_orders_delete → soft-delete + archive (idempotent)

import Foundation
import MCP

public enum StandingOrdersModule {

    public static let moduleName = "standing_orders"

    /// `store` is injectable so tests run against a temp-path store without
    /// polluting the real ~/Library store. Production uses the shared actor.
    public static func register(on router: ToolRouter, store: StandingOrdersRecordStore = .shared) async {
        await router.register(makeList(store))
        await router.register(makeRead(store))
        await router.register(makeSave(store))
        await router.register(makeDelete(store))
    }

    // MARK: - Helpers

    private static func isoString(_ date: Date) -> String { date.ISO8601Format() }

    private static func stringArg(_ args: [String: Value], _ k: String) -> String? {
        if case .string(let s)? = args[k] { return s }
        return nil
    }

    private static func boolArg(_ args: [String: Value], _ k: String) -> Bool? {
        if case .bool(let b)? = args[k] { return b }
        return nil
    }

    private static func summaryValue(_ s: StandingOrderSummary) -> Value {
        .object([
            "id": .string(s.id),
            "title": .string(s.title),
            "scope": .string(s.scope.rawValue),
            "updatedAt": .string(isoString(s.updatedAt)),
            "archived": .bool(s.archived)
        ])
    }

    private static func orderValue(_ o: StandingOrder) -> Value {
        var d: [String: Value] = [
            "id": .string(o.id),
            "title": .string(o.title),
            "body": .string(o.body),
            "scope": .string(o.scope.rawValue),
            "createdAt": .string(isoString(o.createdAt)),
            "updatedAt": .string(isoString(o.updatedAt)),
            "archived": .bool(o.archived)
        ]
        if let a = o.archivedAt { d["archivedAt"] = .string(isoString(a)) }
        return .object(d)
    }

    private static func errEnvelope(_ tool: String, _ message: String, code: String) -> Value {
        .object(["ok": .bool(false), "tool": .string(tool), "error": .string(code), "message": .string(message)])
    }

    // MARK: - Tools

    private static func makeList(_ store: StandingOrdersRecordStore) -> ToolRegistration {
        ToolRegistration(
            name: "standing_orders_list",
            module: moduleName,
            tier: .notify,
            description: "List standing orders as metadata only — [{id, title, scope, updatedAt, archived}]. Bodies are omitted; use standing_orders_read for the full text. Archived (soft-deleted) orders are excluded unless includeArchived=true.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "includeArchived": .object([
                        "type": .string("boolean"),
                        "description": .string("Include soft-deleted (archived) orders in the listing (default: false).")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = { if case .object(let a) = arguments { return a }; return [:] }()
                let includeArchived = boolArg(args, "includeArchived") ?? false
                let items = await store.list(includeArchived: includeArchived)
                return .object([
                    "ok": .bool(true),
                    "orders": .array(items.map(summaryValue)),
                    "count": .int(items.count)
                ])
            })
    }

    private static func makeRead(_ store: StandingOrdersRecordStore) -> ToolRegistration {
        ToolRegistration(
            name: "standing_orders_read",
            module: moduleName,
            tier: .notify,
            description: "Read one standing order by id → full {id, title, body, scope, createdAt, updatedAt, archived}. Returns not_found for an unknown id or a soft-deleted order (unless includeArchived=true).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Standing order id.")
                    ]),
                    "includeArchived": .object([
                        "type": .string("boolean"),
                        "description": .string("Allow reading a soft-deleted (archived) order (default: false).")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "standing_orders_read", reason: "missing required 'id'")
                }
                let includeArchived = boolArg(args, "includeArchived") ?? false
                guard let order = await store.read(id: id, includeArchived: includeArchived) else {
                    return errEnvelope("standing_orders_read", "no standing order with id '\(id)'", code: "not_found")
                }
                return .object(["ok": .bool(true), "order": orderValue(order)])
            })
    }

    private static func makeSave(_ store: StandingOrdersRecordStore) -> ToolRegistration {
        ToolRegistration(
            name: "standing_orders_save",
            module: moduleName,
            tier: .notify,
            description: "Upsert a standing order. Omit id to create; supply an existing id to update in place (idempotent — no duplicate). scope ∈ {global, per-skill, per-tool, per-context}. Saving an archived id un-archives it. Returns the saved {id, ...}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Existing order id to update. Omit to create a new order.")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Short human label for the order.")
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Full directive text.")
                    ]),
                    "scope": .object([
                        "type": .string("string"),
                        "description": .string("One of: global (default), per-skill, per-tool, per-context.")
                    ])
                ]),
                "required": .array([.string("title"), .string("body")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      let title = stringArg(args, "title"),
                      let body = stringArg(args, "body") else {
                    throw ToolRouterError.invalidArguments(toolName: "standing_orders_save", reason: "missing required 'title' or 'body'")
                }
                let id = stringArg(args, "id")
                let scope: StandingOrderScope
                if let raw = stringArg(args, "scope") {
                    guard let parsed = StandingOrderScope(rawValue: raw) else {
                        return errEnvelope("standing_orders_save", "invalid scope '\(raw)'. Must be one of: \(StandingOrderScope.allCases.map(\.rawValue).joined(separator: ", "))", code: "invalid_scope")
                    }
                    scope = parsed
                } else {
                    scope = .global
                }
                do {
                    let saved = try await store.save(id: id, title: title, body: body, scope: scope)
                    return .object(["ok": .bool(true), "order": orderValue(saved)])
                } catch {
                    return errEnvelope("standing_orders_save", error.localizedDescription, code: "save_failed")
                }
            })
    }

    private static func makeDelete(_ store: StandingOrdersRecordStore) -> ToolRegistration {
        ToolRegistration(
            name: "standing_orders_delete",
            module: moduleName,
            tier: .notify,
            neverAutoApprove: true,
            description: "Soft-delete a standing order by id (archives the row — it is not purged). Idempotent — deleting an already-archived order succeeds. Returns the archived {id, archived: true, archivedAt}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Standing order id to soft-delete (archive).")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "standing_orders_delete", reason: "missing required 'id'")
                }
                do {
                    let archived = try await store.delete(id: id)
                    return .object(["ok": .bool(true), "order": orderValue(archived)])
                } catch StandingOrdersRecordError.notFound(let missing) {
                    return errEnvelope("standing_orders_delete", "no standing order with id '\(missing)'", code: "not_found")
                } catch {
                    return errEnvelope("standing_orders_delete", error.localizedDescription, code: "delete_failed")
                }
            })
    }
}
