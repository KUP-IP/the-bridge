// MemoryRoutingAppendix.swift — fetch_skill scopedMemory appendix (PKT-MEM-115)
// TheBridge · Modules

import Foundation
import MCP

/// Builds and attaches task-scoped memory to `fetch_skill` envelopes (post-cache).
public enum MemoryRoutingAppendix {
    /// Attach `scopedMemory` when hits exist; omit key on zero hits or error envelopes.
    public static func attach(
        to result: Value,
        parent rawName: String,
        intent: String?,
        store: MemoryStore = .shared
    ) async -> Value {
        guard case .object(var obj) = result else { return result }
        if obj["error"] != nil { return result }

        let parent = MemoryRoutingScopeMap.parentSlug(from: rawName)
        guard let appendix = await build(parent: parent, intent: intent, store: store) else {
            return result
        }
        obj["scopedMemory"] = appendix
        return .object(obj)
    }

    /// Build the appendix object, or nil when no memories match.
    public static func build(
        parent: String,
        intent: String?,
        store: MemoryStore = .shared
    ) async -> Value? {
        let scopes = MemoryRoutingScopeMap.scopes(for: parent)
        do {
            try await store.open()
            let allLive = try await store.list(scope: nil, entity: nil)
            let entityHint = MemoryRoutingScopeMap.extractEntityHint(
                from: intent,
                scopes: scopes,
                liveEntities: MemoryRoutingScopeMap.liveEntities(in: scopes, from: allLive)
            )
            let query = intent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var collected: [MemoryEntry] = []
            var seen = Set<String>()
            for scope in scopes {
                let batch = try await store.recall(
                    query: query,
                    scope: scope,
                    entity: entityHint,
                    limit: 3
                )
                for entry in batch where seen.insert(entry.id).inserted {
                    collected.append(entry)
                }
                if collected.count >= 5 { break }
            }
            let entries = Array(collected.prefix(5))
            guard !entries.isEmpty else { return nil }

            let primaryScope = scopes.first ?? "global"
            let markdownBody = entries.map(MemoryRowFormatter.rowLine).joined(separator: "\n")
            let markdown = "### Scoped memory (\(primaryScope))\n\(markdownBody)"

            return .object([
                "parent": .string(parent),
                "intent": .string(intent ?? ""),
                "scopesQueried": .array(scopes.map { .string($0) }),
                "count": .int(entries.count),
                "markdown": .string(markdown),
            ])
        } catch {
            return nil
        }
    }
}
