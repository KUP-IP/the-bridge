// SnippetsModule.swift — WS-D (v2.3, PKT-2135a9e9)
// NotionBridge · Modules · Snippets
//
// 9 snippets_* MCP tools under module="snippets", tier .request, wrapping
// SnippetStore. snippets_delete carries neverAutoApprove (the existing
// confirmation mechanism) — the formal ToolAnnotations field + ratchet audit
// is WS-B's deliverable per Decision D1; wiring it here would do WS-B's job.

import Foundation
import MCP

public enum SnippetsModule {

    public static let moduleName = "snippets"

    /// `store` is injectable so tests run against a temp-path store without
    /// polluting the real ~/Library store. Production uses SnippetStore.shared.
    public static func register(on router: ToolRouter, store: SnippetStore = .shared) async {
        await router.register(makeList(store))
        await router.register(makeGet(store))
        await router.register(makeSearch(store))
        await router.register(makeCreate(store))
        await router.register(makeUpdate(store))
        await router.register(makeRename(store))
        await router.register(makeDelete(store))
        await router.register(makeImport(store))
        await router.register(makeExport(store))
    }

    // MARK: - Helpers

    private static func isoString(_ date: Date) -> String {
        date.ISO8601Format()
    }

    private static func snippetValue(_ s: Snippet, includeText: Bool) -> Value {
        var d: [String: Value] = [
            "id": .string(s.id),
            "name": .string(s.name),
            "tags": .array(s.tags.map { .string($0) }),
            "updated": .string(isoString(s.updated))
        ]
        if includeText {
            d["text"] = .string(s.text)
            d["created"] = .string(isoString(s.created))
            d["source"] = .string(s.source)
        } else {
            let t = s.text.replacingOccurrences(of: "\n", with: " ")
            d["preview"] = .string(t.count > 80 ? String(t.prefix(80)) + "…" : t)
        }
        return .object(d)
    }

    private static func errEnvelope(_ tool: String, _ message: String, code: String) -> Value {
        .object(["ok": .bool(false), "tool": .string(tool), "error": .string(code), "message": .string(message)])
    }

    private static func stringArg(_ args: [String: Value], _ k: String) -> String? {
        if case .string(let s)? = args[k] { return s }
        return nil
    }

    private static func tagsArg(_ args: [String: Value]) -> [String]? {
        guard case .array(let a)? = args["tags"] else { return nil }
        return a.compactMap { if case .string(let s) = $0 { return s }; return nil }
    }

    // MARK: - Tools

    private static func makeList(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_list", module: moduleName, tier: .request,
            description: "List all snippets as [{id, name, preview, tags, updated}]. Read-only.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in
                let items = await store.all().sorted { $0.name < $1.name }
                return .object(["ok": .bool(true), "snippets": .array(items.map { snippetValue($0, includeText: false) })])
            })
    }

    private static func makeGet(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_get", module: moduleName, tier: .request,
            description: "Get one snippet by id or name → {id, name, text, tags, created, updated, source}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["idOrName": .object(["type": .string("string"), "description": .string("Snippet id or unique name/trigger.")])]),
                "required": .array([.string("idOrName")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let key = stringArg(args, "idOrName") else {
                    throw ToolRouterError.invalidArguments(toolName: "snippets_get", reason: "missing required 'idOrName'")
                }
                guard let s = await store.get(idOrName: key) else {
                    return errEnvelope("snippets_get", "no snippet matching id/name '\(key)'", code: "not_found")
                }
                return .object(["ok": .bool(true), "snippet": snippetValue(s, includeText: true)])
            })
    }

    private static func makeSearch(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_search", module: moduleName, tier: .request,
            description: "Ranked search (exact > prefix > fuzzy > text-contains). Optional tags AND-filter. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search query.")]),
                    "tags": .object(["type": .string("array"), "description": .string("Optional tag AND-filter.")])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let q = stringArg(args, "query") else {
                    throw ToolRouterError.invalidArguments(toolName: "snippets_search", reason: "missing required 'query'")
                }
                let results = await store.search(query: q, tags: tagsArg(args) ?? [])
                return .object(["ok": .bool(true), "results": .array(results.map { snippetValue($0, includeText: false) })])
            })
    }

    private static func makeCreate(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_create", module: moduleName, tier: .request,
            description: "Create a snippet → {id}. Rejects duplicate name.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Unique trigger/name.")]),
                    "text": .object(["type": .string("string"), "description": .string("Snippet body.")]),
                    "tags": .object(["type": .string("array"), "description": .string("Optional tags.")])
                ]),
                "required": .array([.string("name"), .string("text")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      let name = stringArg(args, "name"), let text = stringArg(args, "text") else {
                    throw ToolRouterError.invalidArguments(toolName: "snippets_create", reason: "missing required 'name' or 'text'")
                }
                do {
                    let s = try await store.create(name: name, text: text, tags: tagsArg(args) ?? [])
                    return .object(["ok": .bool(true), "id": .string(s.id)])
                } catch SnippetStoreError.duplicateName(let n) {
                    return errEnvelope("snippets_create", "snippet name '\(n)' already exists", code: "duplicate_name")
                }
            })
    }

    private static func makeUpdate(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_update", module: moduleName, tier: .request,
            description: "Update a snippet's name/text/tags by id → {ok}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Snippet id.")]),
                    "name": .object(["type": .string("string"), "description": .string("New name (optional).")]),
                    "text": .object(["type": .string("string"), "description": .string("New text (optional).")]),
                    "tags": .object(["type": .string("array"), "description": .string("New tags (optional).")])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "snippets_update", reason: "missing required 'id'")
                }
                do {
                    let s = try await store.update(id: id, name: stringArg(args, "name"), text: stringArg(args, "text"), tags: tagsArg(args))
                    return .object(["ok": .bool(true), "snippet": snippetValue(s, includeText: true)])
                } catch SnippetStoreError.notFound(let i) {
                    return errEnvelope("snippets_update", "no snippet with id '\(i)'", code: "not_found")
                } catch SnippetStoreError.duplicateName(let n) {
                    return errEnvelope("snippets_update", "name '\(n)' already in use", code: "duplicate_name")
                }
            })
    }

    private static func makeRename(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_rename", module: moduleName, tier: .request,
            description: "Rename a snippet by id → {ok}. Rejects duplicate name with a clear error.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("Snippet id.")]),
                    "name": .object(["type": .string("string"), "description": .string("New unique name.")])
                ]),
                "required": .array([.string("id"), .string("name")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      let id = stringArg(args, "id"), let name = stringArg(args, "name") else {
                    throw ToolRouterError.invalidArguments(toolName: "snippets_rename", reason: "missing required 'id' or 'name'")
                }
                do {
                    _ = try await store.rename(id: id, name: name)
                    return .object(["ok": .bool(true)])
                } catch SnippetStoreError.notFound(let i) {
                    return errEnvelope("snippets_rename", "no snippet with id '\(i)'", code: "not_found")
                } catch SnippetStoreError.duplicateName(let n) {
                    return errEnvelope("snippets_rename", "name '\(n)' already in use", code: "duplicate_name")
                }
            })
    }

    private static func makeDelete(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_delete", module: moduleName, tier: .request,
            neverAutoApprove: true,   // destructive — step-up consent (D1: formal destructiveHint = WS-B ratchet)
            description: "Delete a snippet by id → {ok}. Destructive; requires confirmation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["id": .object(["type": .string("string"), "description": .string("Snippet id.")])]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "snippets_delete", reason: "missing required 'id'")
                }
                do {
                    try await store.delete(id: id)
                    return .object(["ok": .bool(true)])
                } catch SnippetStoreError.notFound(let i) {
                    return errEnvelope("snippets_delete", "no snippet with id '\(i)'", code: "not_found")
                }
            })
    }

    private static func makeImport(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_import", module: moduleName, tier: .request,
            description: "Import snippets. format: 'wispr'|'json' ([{name,text,tags?}]) or 'espanso' (matches: YAML). Idempotent on name (existing skipped). → {imported, skipped, errors}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "format": .object(["type": .string("string"), "description": .string("'wispr' | 'json' | 'espanso'")]),
                    "data": .object(["type": .string("string"), "description": .string("Raw import payload.")])
                ]),
                "required": .array([.string("format"), .string("data")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      let format = stringArg(args, "format"), let data = stringArg(args, "data") else {
                    throw ToolRouterError.invalidArguments(toolName: "snippets_import", reason: "missing required 'format' or 'data'")
                }
                do {
                    let r = try await store.importSnippets(format: format, data: data)
                    return .object([
                        "ok": .bool(true), "imported": .int(r.imported), "skipped": .int(r.skipped),
                        "errors": .array(r.errors.map { .string($0) })
                    ])
                } catch SnippetStoreError.unsupportedFormat(let f) {
                    return errEnvelope("snippets_import", "unsupported format '\(f)'", code: "unsupported_format")
                } catch SnippetStoreError.invalidImport(let m) {
                    return errEnvelope("snippets_import", m, code: "invalid_import")
                }
            })
    }

    private static func makeExport(_ store: SnippetStore) -> ToolRegistration {
        ToolRegistration(
            name: "snippets_export", module: moduleName, tier: .request,
            description: "Export snippets. format: 'json' (inline payload) or 'espanso' (writes match YAML, returns path).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["format": .object(["type": .string("string"), "description": .string("'json' | 'espanso'")])]),
                "required": .array([.string("format")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let format = stringArg(args, "format") else {
                    throw ToolRouterError.invalidArguments(toolName: "snippets_export", reason: "missing required 'format'")
                }
                switch format.lowercased() {
                case "json":
                    return .object(["ok": .bool(true), "format": .string("json"), "payload": .string(await store.exportJSON())])
                case "espanso":
                    do {
                        let path = try await store.exportEspanso()
                        return .object(["ok": .bool(true), "format": .string("espanso"), "path": .string(path)])
                    } catch {
                        return errEnvelope("snippets_export", "espanso export failed: \(error.localizedDescription)", code: "export_failed")
                    }
                default:
                    return errEnvelope("snippets_export", "unsupported format '\(format)'", code: "unsupported_format")
                }
            })
    }
}
