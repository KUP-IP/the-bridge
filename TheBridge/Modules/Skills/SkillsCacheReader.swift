// SkillsCacheReader.swift — Bridge v3.7·1
// TheBridge · Modules · Skills
//
// Pure-read view over the on-disk skills cache populated by
// `SkillsCacheWriter`. O(1) per parent (single JSON load + decode), so
// callers can safely read at hot paths (routing-list enumeration, MCP
// handshake) that previously couldn't afford the Notion round-trip.
//
// Concurrency: an `actor` because the on-disk file may be written
// concurrently by the writer; serializing reads through one actor
// instance guarantees a partial write is never observed as a decode error
// — the writer uses atomic replace, but a concurrent read on the SAME
// file path while the writer hasn't yet moved the temp file in could
// otherwise race on filesystem APIs across processes.
//
// Failure posture: every error degrades to "no entry" rather than
// throwing. The cache is a hint, not a source of truth — routing must
// still work when the cache is missing or corrupt.

import Foundation

/// Read-only accessor over `BridgePaths.applicationSupport(.skillsCache)`.
public actor SkillsCacheReader {
    public static let shared = SkillsCacheReader()

    /// Injectable clock for tests (e.g. asserting the TTL boundary).
    /// Production callers use `Date()`.
    private let clock: @Sendable () -> Date

    public init(clock: @Sendable @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Returns the cached entry for `parentId`, or `nil` when no file
    /// exists or the file failed to decode. Stale entries are returned
    /// with `stale = true`; callers may still use them.
    public func read(parentId: String) -> CachedParent? {
        let url = Self.fileURL(for: parentId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard var decoded = try? JSONDecoder().decode(CachedParent.self, from: data) else {
            return nil
        }
        decoded.stale = decoded.isExpired(now: clock())
        return decoded
    }

    /// Returns every cached entry under the skills-cache directory, in
    /// stable alpha order by parent id. Missing directory → empty list.
    public func readAll() -> [CachedParent] {
        let dir = BridgePaths.applicationSupport(.skillsCache)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: [CachedParent] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let parentId = String(name.dropLast(5)) // strip ".json"
            if let entry = read(parentId: parentId) {
                out.append(entry)
            }
        }
        return out
    }

    // MARK: - Internal helpers

    /// Canonical path for the per-parent cache file. Public-via-internal
    /// for the writer + tests; never exposed to UI callers.
    internal static func fileURL(for parentId: String) -> URL {
        // Normalize: cache files use the bare 32-hex Notion id (no dashes,
        // no surrounding whitespace). Callers may pass either shape.
        let normalized = parentId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return BridgePaths.applicationSupport(.skillsCache)
            .appendingPathComponent("\(normalized).json", isDirectory: false)
    }
}
