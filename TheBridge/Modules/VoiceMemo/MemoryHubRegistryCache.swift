// MemoryHubRegistryCache.swift — last-good registry rows for the Process picker (PKT-MEM-106 0b)
// TheBridge · Modules · VoiceMemo
//
// One JSON file per entity at memory-hub/registry-cache/<entity>.json carrying the
// last-good rows from `registry_list` plus TTL metadata. The Process registry picker
// loads LIVE first; this cache is the offline / source-error fallback. Rows older than
// 24h are still selectable but flagged `stale`. Distinct from the Data-Source Registry's
// own RegistryRowCache (top-level registry-cache/) — this is the Memory Hub's picker cache.

import Foundation

public struct MemoryHubRegistryRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct MemoryHubRegistryCacheEntry: Codable, Sendable, Equatable {
    public var rows: [MemoryHubRegistryRow]
    public var fetchedAt: String        // ISO-8601
    public var ttlSeconds: Double
    public var sourceError: String?

    public init(rows: [MemoryHubRegistryRow], fetchedAt: String, ttlSeconds: Double, sourceError: String? = nil) {
        self.rows = rows
        self.fetchedAt = fetchedAt
        self.ttlSeconds = ttlSeconds
        self.sourceError = sourceError
    }

    public func fetchedAtDate() -> Date? { ISO8601DateFormatter().date(from: fetchedAt) }

    /// Stale once older than `ttlSeconds` (default 24h). Boundary: exactly TTL ⇒ NOT stale.
    public func isStale(now: Date) -> Bool {
        guard let date = fetchedAtDate() else { return true }
        return now.timeIntervalSince(date) > ttlSeconds
    }
}

public enum MemoryHubRegistryCache {
    /// Rows older than this are flagged stale (PKT-MEM-106 0b: "stale after 24h").
    public static let staleAfterSeconds: Double = 24 * 3600

    public static var cacheDir: URL {
        BridgePaths.applicationSupport(.memoryHub).appendingPathComponent("registry-cache", isDirectory: true)
    }

    public static func cacheURL(entity: String) -> URL {
        cacheDir.appendingPathComponent("\(safeName(entity)).json")
    }

    /// Persist last-good rows for an entity (call on every successful `registry_list`).
    @discardableResult
    public static func write(
        entity: String,
        rows: [MemoryHubRegistryRow],
        fetchedAt: Date = Date(),
        ttlSeconds: Double = staleAfterSeconds,
        sourceError: String? = nil
    ) throws -> MemoryHubRegistryCacheEntry {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let entry = MemoryHubRegistryCacheEntry(
            rows: rows,
            fetchedAt: ISO8601DateFormatter().string(from: fetchedAt),
            ttlSeconds: ttlSeconds,
            sourceError: sourceError
        )
        let data = try JSONEncoder().encode(entry)
        try data.write(to: cacheURL(entity: entity), options: .atomic)
        return entry
    }

    public static func read(entity: String) -> MemoryHubRegistryCacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL(entity: entity)),
              let entry = try? JSONDecoder().decode(MemoryHubRegistryCacheEntry.self, from: data) else {
            return nil
        }
        return entry
    }

    /// Picker-facing state: is there a cache, when was it fetched, is it stale, and any source error.
    public static func state(entity: String, now: Date = Date()) -> (cached: Bool, fetchedAt: Date?, stale: Bool, sourceError: String?) {
        guard let entry = read(entity: entity) else { return (false, nil, false, nil) }
        return (true, entry.fetchedAtDate(), entry.isStale(now: now), entry.sourceError)
    }

    public static func isStale(entity: String, now: Date = Date()) -> Bool {
        read(entity: entity)?.isStale(now: now) ?? false
    }

    /// Sanitize an entity key into a safe filename component.
    static func safeName(_ entity: String) -> String {
        let lowered = entity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "_"
        }
        let result = String(mapped)
        return result.isEmpty ? "entity" : result
    }
}
