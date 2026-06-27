// MemoryRoutingScopeMap.swift — keeper parent → memory scope map (PKT-MEM-115)
// TheBridge · Modules

import Foundation

/// Maps `fetch_skill` parent slugs to agent-memory scopes for the routing appendix.
public enum MemoryRoutingScopeMap {
    public struct ScopePair: Sendable, Equatable {
        public var primary: String
        public var secondary: String?

        public init(primary: String, secondary: String? = nil) {
            self.primary = primary
            self.secondary = secondary
        }
    }

    private static let table: [String: ScopePair] = [
        "focus-keepr": ScopePair(primary: "project", secondary: "global"),
        "project-keepr": ScopePair(primary: "project", secondary: "global"),
        "people-keepr": ScopePair(primary: "people"),
        "mac-keepr": ScopePair(primary: "mac"),
        "notion-keepr": ScopePair(primary: "skill", secondary: "project"),
        "time-keepr": ScopePair(primary: "time"),
        "skill-keepr": ScopePair(primary: "skill"),
        "executor": ScopePair(primary: "project", secondary: "global"),
    ]

    private static let entityDenylist: Set<String> = [
        "make", "install", "copy", "build", "test", "run", "the", "bridge", "keep",
        "fetch", "skill", "open", "use", "for", "and", "with", "from", "this", "that",
        "when", "what", "how", "help", "need", "want", "into", "onto", "over", "under",
    ]

    /// Parent slug from `fetch_skill` `name` (segment before first `/`).
    public static func parentSlug(from rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let slash = trimmed.firstIndex(of: "/") else { return trimmed }
        return String(trimmed[..<slash])
    }

    public static func scopes(for parentSlug: String) -> [String] {
        let key = parentSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let pair = table[key] {
            if let secondary = pair.secondary {
                return [pair.primary, secondary]
            }
            return [pair.primary]
        }
        return ["global"]
    }

    /// Slug-like tokens from intent, minus common verbs; prefers a live entity match.
    public static func extractEntityHint(
        from intent: String?,
        scopes: [String],
        liveEntities: Set<String>
    ) -> String? {
        guard let intent, !intent.isEmpty else { return nil }
        let normalized = intent.lowercased()
        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .filter { $0.count >= 3 && $0.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil }
            .filter { !entityDenylist.contains($0) }

        guard !tokens.isEmpty else { return nil }

        for token in tokens where liveEntities.contains(token) {
            return token
        }
        // Only filter by entity when a token matches a live row — avoids
        // false-positive entity filters from verb-adjacent slug tokens.
        return nil
    }

    /// Collect distinct non-empty entity strings for the given scopes.
    public static func liveEntities(in scopes: [String], from entries: [MemoryEntry]) -> Set<String> {
        let scopeSet = Set(scopes.map { $0.lowercased() })
        var result = Set<String>()
        for entry in entries {
            guard scopeSet.contains(entry.scope.lowercased()),
                  let entity = entry.entity?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !entity.isEmpty else { continue }
            result.insert(entity.lowercased())
        }
        return result
    }
}
