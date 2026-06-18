// RegistryRowCache.swift — Data-Source Registry (vertical slice v0)
// NotionBridge · Modules · Registry
//
// Generalized per-entity read-through ROW cache backing store — the Decision
// 4 cache that makes domain verbs worth building (a warm READ is a local disk
// read: no network, no MCP round trip, no inter-step reasoning). Generalizes
// SkillBodyCacheStore from one body-per-skill to one row-per-(entity,pageId),
// so EVERY registry entity gets stale-while-revalidate + offline reads.
//
// Layout: `…/registry-cache/<entity>/<normalized-pageId>.json`. The per-entity
// subdirectory keeps eviction/enumeration scoped and avoids cross-entity id
// collisions.
//
// Concurrency: a single `actor` serializes reads + atomic writes (temp →
// rename) so a partial write is never observed. Failure posture: every error
// degrades to nil / no-op — the cache is a HINT, never a source of truth; the
// registry must still serve from Notion when the cache is missing/corrupt.

import Foundation
import MCP

public actor RegistryRowCache {
    public static let shared = RegistryRowCache()

    /// Injectable clock for tests (TTL boundary / stale derivation).
    private let clock: @Sendable () -> Date

    public init(clock: @Sendable @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    // MARK: - Read

    /// Cached row for (entity, pageId), or nil when absent/undecodable.
    /// Never throws — a hint, not a truth.
    public func read(entity: String, pageId: String) -> CachedRow? {
        let url = Self.fileURL(entity: entity, pageId: pageId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedRow.self, from: data)
    }

    /// Every cached row for `entity`, in stable alpha order by file name.
    /// Missing directory → empty list (offline-first list read).
    public func readAll(entity: String) -> [CachedRow] {
        let dir = Self.entityDir(entity)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: [CachedRow] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let pid = String(name.dropLast(5)) // strip ".json"
            if let entry = read(entity: entity, pageId: pid) {
                out.append(entry)
            }
        }
        return out
    }

    /// State triple for a UI/freshness indicator: is the row stored, when was
    /// it written, and is it stale (past TTL). `cached:false` →
    /// `writtenAt:nil, stale:false`.
    public func state(entity: String, pageId: String) -> (cached: Bool, writtenAt: Date?, stale: Bool) {
        guard let entry = read(entity: entity, pageId: pageId) else {
            return (false, nil, false)
        }
        return (true, entry.writtenAt, entry.isExpired(now: clock()))
    }

    // MARK: - Write / mutate

    /// Atomically persist one row (temp file → replace).
    public func write(_ row: CachedRow) throws {
        let dir = try Self.ensureEntityDir(row.entity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(row)

        let dest = Self.fileURL(entity: row.entity, pageId: row.pageId)
        let tmp = dir.appendingPathComponent(
            ".\(dest.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: tmp, options: [.atomic])
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Remove the cached row for (entity, pageId). No-op when absent. Used on
    /// a 404 during revalidation (the row was deleted in Notion).
    public func evict(entity: String, pageId: String) {
        let url = Self.fileURL(entity: entity, pageId: pageId)
        try? FileManager.default.removeItem(at: url)
    }

    /// Drop the entire cache for one entity (e.g. on disconnect — Decision 8
    /// wipes the cache for a clean privacy story).
    public func evictAll(entity: String) {
        try? FileManager.default.removeItem(at: Self.entityDir(entity))
    }

    /// Increment the persisted `callCount` and return the new value (0 when
    /// no entry). The read-bump-write runs inside the actor, so concurrent
    /// ticks can't lose an increment. Drives the revalidation cadence.
    @discardableResult
    public func incrementCallCount(entity: String, pageId: String) -> Int {
        guard let entry = read(entity: entity, pageId: pageId) else { return 0 }
        let next = entry.callCount + 1
        try? write(entry.withCallCount(next))
        return next
    }

    // MARK: - Path

    static func entityDir(_ entity: String) -> URL {
        BridgePaths.applicationSupport(.registryCache)
            .appendingPathComponent(Self.safeComponent(entity), isDirectory: true)
    }

    @discardableResult
    static func ensureEntityDir(_ entity: String) throws -> URL {
        let url = entityDir(entity)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fileURL(entity: String, pageId: String) -> URL {
        // Sanitize the pageId filename the SAME way as the entity dir: `id` is
        // attacker-influencable model input (registry_get/update/delete), and
        // `CachedRow.normalize` strips only dashes/whitespace — NOT `/ \ .` — so
        // without this a `pageId` like `../../x` would escape the cache dir.
        entityDir(entity)
            .appendingPathComponent("\(safeComponent(CachedRow.normalize(pageId))).json", isDirectory: false)
    }

    /// Defensive: an entity key is a path component, so strip separators/dots
    /// that could escape the cache directory, and cap the length so a
    /// pathological key can't exceed the filesystem's per-component limit
    /// (~255). Entity keys are simple slugs in practice; this is
    /// belt-and-suspenders. A truncated key appends a short stable hash of the
    /// full key so two long keys sharing a prefix don't collide.
    static func safeComponent(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        if cleaned.isEmpty { return "_" }
        guard cleaned.count > 120 else { return cleaned }
        var hash: UInt64 = 5381
        for b in cleaned.utf8 { hash = (hash &* 33) ^ UInt64(b) }
        return String(cleaned.prefix(100)) + "-" + String(hash, radix: 36)
    }
}
