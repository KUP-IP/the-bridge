// CommandsModule.swift — PKT-1061
// TheBridge · Modules · Commands
//
// CommandStore-backed commands_* MCP tools. Bridge Commands (hot-key palette)
// are NOT Snippets — agents must use this module, not snippets_*, for local
// user-authored command payloads.

import Foundation
import MCP

public enum CommandsModule {

    public static let moduleName = "commands"

    public static func register(on router: ToolRouter, store: CommandStore = .shared) async {
        await router.register(makeList(store))
        await router.register(makeGet(store))
        await router.register(makeSearch(store))
        await router.register(makeCreate(store))
        await router.register(makeUpdate(store))
        await router.register(makeDelete(store))
    }

    // MARK: - Helpers

    private static func isoString(_ date: Date?) -> Value {
        guard let date else { return .null }
        return .string(date.ISO8601Format())
    }

    private static func commandValue(_ c: CommandStore.Command, includeBody: Bool) -> Value {
        var d: [String: Value] = [
            "slug": .string(c.slug),
            "name": .string(c.name),
            "icon": iconValue(c.icon),
            "keySlot": c.keySlot.map { .int($0) } ?? .null,
            "lastUsedAt": isoString(c.lastUsedAt),
        ]
        if let color = c.color {
            d["color"] = .string(color.rawValue)
        }
        if includeBody {
            d["body"] = .string(c.body)
        } else {
            let preview = c.body.replacingOccurrences(of: "\n", with: " ")
            d["preview"] = .string(preview.count > 80 ? String(preview.prefix(80)) + "…" : preview)
        }
        return .object(d)
    }

    private static func iconValue(_ icon: CommandStore.Icon) -> Value {
        switch icon {
        case .emoji(let s): return .object(["kind": .string("emoji"), "value": .string(s)])
        case .symbol(let n): return .object(["kind": .string("symbol"), "value": .string(n)])
        }
    }

    private static func parseIcon(_ args: [String: Value]) -> CommandStore.Icon {
        if let sym = stringArg(args, "iconSymbol"), !sym.isEmpty {
            return .symbol(sym)
        }
        if let emoji = stringArg(args, "iconEmoji"), !emoji.isEmpty {
            return .emoji(emoji)
        }
        return .emoji("📝")
    }

    private static func parseColor(_ args: [String: Value]) -> CommandStore.NotionColor? {
        guard let raw = stringArg(args, "color") else { return nil }
        return CommandStore.NotionColor(rawValue: raw.lowercased())
    }

    private static func intArg(_ args: [String: Value], _ k: String) -> Int? {
        if case .int(let n)? = args[k] { return n }
        if case .double(let d)? = args[k] { return Int(d) }
        return nil
    }

    private static func errEnvelope(_ tool: String, _ message: String, code: String) -> Value {
        .object(["ok": .bool(false), "tool": .string(tool), "error": .string(code), "message": .string(message)])
    }

    private static func stringArg(_ args: [String: Value], _ k: String) -> String? {
        if case .string(let s)? = args[k] { return s }
        return nil
    }

    private static func resolveSlug(store: CommandStore, slugOrName: String) throws -> String? {
        let key = slugOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if try store.get(slug: key) != nil { return key }
        let slug = CommandStore.slugify(key)
        if try store.get(slug: slug) != nil { return slug }
        let lower = key.lowercased()
        return try store.list().first(where: { $0.name.lowercased() == lower })?.slug
    }

    // MARK: - Tools

    private static func makeList(_ store: CommandStore) -> ToolRegistration {
        ToolRegistration(
            name: "commands_list", module: moduleName, tier: .open,
            description: "List Bridge Commands (CommandStore hot-key palette payloads) as [{slug, name, preview, keySlot, …}]. Not Snippets — use commands_* for palette commands.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in
                do {
                    let items = try store.list()
                    return .object(["ok": .bool(true), "commands": .array(items.map { commandValue($0, includeBody: false) })])
                } catch {
                    return errEnvelope("commands_list", error.localizedDescription, code: "store_error")
                }
            })
    }

    private static func makeGet(_ store: CommandStore) -> ToolRegistration {
        ToolRegistration(
            name: "commands_get", module: moduleName, tier: .open,
            description: "Get one Bridge Command by slug or display name → full body markdown. Not snippets_get.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "slugOrName": .object(["type": .string("string"), "description": .string("Command slug or display name.")])
                ]),
                "required": .array([.string("slugOrName")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let key = stringArg(args, "slugOrName") else {
                    throw ToolRouterError.invalidArguments(toolName: "commands_get", reason: "missing required 'slugOrName'")
                }
                do {
                    guard let slug = try resolveSlug(store: store, slugOrName: key),
                          let cmd = try store.get(slug: slug) else {
                        return errEnvelope("commands_get", "no command matching '\(key)'", code: "not_found")
                    }
                    return .object(["ok": .bool(true), "command": commandValue(cmd, includeBody: true)])
                } catch {
                    return errEnvelope("commands_get", error.localizedDescription, code: "store_error")
                }
            })
    }

    private static func makeSearch(_ store: CommandStore) -> ToolRegistration {
        ToolRegistration(
            name: "commands_search", module: moduleName, tier: .open,
            description: "Search Bridge Commands by name substring (CommandStore). Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search query.")])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let q = stringArg(args, "query") else {
                    throw ToolRouterError.invalidArguments(toolName: "commands_search", reason: "missing required 'query'")
                }
                do {
                    let results = try store.search(q)
                    return .object(["ok": .bool(true), "results": .array(results.map { commandValue($0, includeBody: false) })])
                } catch {
                    return errEnvelope("commands_search", error.localizedDescription, code: "store_error")
                }
            })
    }

    private static func makeCreate(_ store: CommandStore) -> ToolRegistration {
        ToolRegistration(
            name: "commands_create", module: moduleName, tier: .request,
            description: "Create a Bridge Command (markdown body). Rejects duplicate slug.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Display name.")]),
                    "body": .object(["type": .string("string"), "description": .string("Markdown payload copied to clipboard when fired.")]),
                    "keySlot": .object(["type": .string("integer"), "description": .string("Optional hot-key slot 0–9.")]),
                    "iconEmoji": .object(["type": .string("string"), "description": .string("Optional emoji icon.")]),
                    "iconSymbol": .object(["type": .string("string"), "description": .string("Optional SF Symbol name.")]),
                    "color": .object(["type": .string("string"), "description": .string("Optional Notion color when icon is symbol.")])
                ]),
                "required": .array([.string("name"), .string("body")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      let name = stringArg(args, "name"), let body = stringArg(args, "body") else {
                    throw ToolRouterError.invalidArguments(toolName: "commands_create", reason: "missing required 'name' or 'body'")
                }
                do {
                    let cmd = try store.create(
                        name: name,
                        icon: parseIcon(args),
                        color: parseColor(args),
                        body: body,
                        keySlot: intArg(args, "keySlot")
                    )
                    return .object(["ok": .bool(true), "slug": .string(cmd.slug), "command": commandValue(cmd, includeBody: true)])
                } catch CommandStore.StoreError.slugTaken(let slug) {
                    return errEnvelope("commands_create", "command slug '\(slug)' already exists", code: "duplicate_slug")
                } catch {
                    return errEnvelope("commands_create", error.localizedDescription, code: "store_error")
                }
            })
    }

    private static func makeUpdate(_ store: CommandStore) -> ToolRegistration {
        ToolRegistration(
            name: "commands_update", module: moduleName, tier: .request,
            description: "Update a Bridge Command by slug (partial fields).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "slug": .object(["type": .string("string"), "description": .string("Command slug.")]),
                    "name": .object(["type": .string("string"), "description": .string("New display name (optional).")]),
                    "body": .object(["type": .string("string"), "description": .string("New markdown body (optional).")]),
                    "keySlot": .object(["type": .string("integer"), "description": .string("Hot-key slot 0–9 or omit to leave unchanged.")]),
                    "clearKeySlot": .object(["type": .string("boolean"), "description": .string("When true, clears key slot.")]),
                    "iconEmoji": .object(["type": .string("string"), "description": .string("Optional emoji icon.")]),
                    "iconSymbol": .object(["type": .string("string"), "description": .string("Optional SF Symbol name.")]),
                    "color": .object(["type": .string("string"), "description": .string("Optional color for symbol icons.")])
                ]),
                "required": .array([.string("slug")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let slug = stringArg(args, "slug") else {
                    throw ToolRouterError.invalidArguments(toolName: "commands_update", reason: "missing required 'slug'")
                }
                do {
                    guard var cmd = try store.get(slug: slug) else {
                        return errEnvelope("commands_update", "no command with slug '\(slug)'", code: "not_found")
                    }
                    if let name = stringArg(args, "name") { cmd.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if let body = stringArg(args, "body") { cmd.body = body }
                    if stringArg(args, "iconEmoji") != nil || stringArg(args, "iconSymbol") != nil {
                        cmd.icon = parseIcon(args)
                    }
                    if let color = parseColor(args) { cmd.color = color }
                    if case .bool(true)? = args["clearKeySlot"] { cmd.keySlot = nil }
                    else if let slot = intArg(args, "keySlot") { cmd.keySlot = slot }
                    let updated = try store.update(cmd)
                    return .object(["ok": .bool(true), "command": commandValue(updated, includeBody: true)])
                } catch CommandStore.StoreError.slugNotFound(let s) {
                    return errEnvelope("commands_update", "no command with slug '\(s)'", code: "not_found")
                } catch {
                    return errEnvelope("commands_update", error.localizedDescription, code: "store_error")
                }
            })
    }

    private static func makeDelete(_ store: CommandStore) -> ToolRegistration {
        ToolRegistration(
            name: "commands_delete", module: moduleName, tier: .request,
            neverAutoApprove: true,
            description: "Delete a Bridge Command by slug. Destructive; requires confirmation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "slug": .object(["type": .string("string"), "description": .string("Command slug.")])
                ]),
                "required": .array([.string("slug")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let slug = stringArg(args, "slug") else {
                    throw ToolRouterError.invalidArguments(toolName: "commands_delete", reason: "missing required 'slug'")
                }
                do {
                    try store.delete(slug: slug)
                    return .object(["ok": .bool(true)])
                } catch CommandStore.StoreError.slugNotFound(let s) {
                    return errEnvelope("commands_delete", "no command with slug '\(s)'", code: "not_found")
                } catch {
                    return errEnvelope("commands_delete", error.localizedDescription, code: "store_error")
                }
            })
    }
}
