// SkillBodyCacheStore.swift — Bridge (feat/backend-remediation)
// TheBridge · Modules · Skills
//
// Persistent per-skill BODY cache backing store. Owns every read/mutation
// of `BridgePaths.applicationSupport(.skillsBodyCache)`. SEPARATE and
// ADDITIVE to SkillsCacheReader/Writer (the per-parent routing cache) — it
// is the fastest persistent layer behind `fetch_skill`'s in-memory cache.
//
// Concurrency: a single `actor`. Reads and atomic writes to the same file
// path are serialized through one instance, so a partial write is never
// observed (writer uses temp→rename; the actor stops a concurrent same-key
// read from racing the rename across the filesystem layer). Mirrors the
// SkillsCacheReader/Writer split, collapsed into one actor because the
// body cache has no separate cold-start reader hot-path to keep distinct.
//
// Failure posture: every error degrades to nil / no-op. The cache is a
// HINT, not a source of truth — `fetch_skill` must still serve from the
// network when the cache is missing, corrupt, or unwritable.

import Foundation
import MCP

public actor SkillBodyCacheStore {
    public static let shared = SkillBodyCacheStore()

    /// Injectable clock for tests (TTL boundary / stale derivation).
    private let clock: @Sendable () -> Date

    public init(clock: @Sendable @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    // MARK: - Read

    /// Returns the cached body for `pageId`, or nil when no file exists or
    /// the file failed to decode. Never throws — a hint, not a truth.
    public func read(pageId: String) -> CachedSkillBody? {
        let url = Self.fileURL(for: pageId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedSkillBody.self, from: data)
    }

    /// Every cached body under the directory, in stable alpha order by
    /// file name. Missing directory → empty list.
    public func readAll() -> [CachedSkillBody] {
        let dir = BridgePaths.applicationSupport(.skillsBodyCache)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: [CachedSkillBody] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let pid = String(name.dropLast(5)) // strip ".json"
            if let entry = read(pageId: pid) {
                out.append(entry)
            }
        }
        return out
    }

    /// State triple for a future UI preview panel: is a body stored, when
    /// was it written, and is it stale (past TTL). `cached:false` →
    /// `writtenAt:nil, stale:false`.
    public func state(pageId: String) -> (cached: Bool, writtenAt: Date?, stale: Bool) {
        guard let entry = read(pageId: pageId) else {
            return (false, nil, false)
        }
        return (true, entry.writtenAt, entry.isExpired(now: clock()))
    }

    // MARK: - Write / mutate

    /// Atomically persist one body (temp file → replace), so a concurrent
    /// reader can never observe a torn JSON document. Throws only on hard
    /// filesystem/encode errors; callers treat a throw as "not cached".
    public func write(_ body: CachedSkillBody) throws {
        let dir = try BridgePaths.ensureApplicationSupport(.skillsBodyCache)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(body)

        let dest = Self.fileURL(for: body.pageId)
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

    /// Remove the cached body for `pageId`. No-op when absent. Used on a
    /// 404 / page-not-found during revalidation (the page is gone).
    public func evict(pageId: String) {
        let url = Self.fileURL(for: pageId)
        try? FileManager.default.removeItem(at: url)
    }

    /// Increment the persisted `callCount` for `pageId` and return the new
    /// value. Returns 0 when there is no cached entry (caller treats 0 as
    /// "no cadence tick"). The read-bump-write runs entirely inside the
    /// actor, so concurrent ticks can't lose an increment.
    @discardableResult
    public func incrementCallCount(pageId: String) -> Int {
        guard let entry = read(pageId: pageId) else { return 0 }
        let next = entry.callCount + 1
        try? write(entry.withCallCount(next))
        return next
    }

    // MARK: - Public refresh + warm API (backend for a future UI / tool)

    /// Force a re-fetch of one skill body from Notion and rewrite the cache
    /// (the manual "refresh" button). Returns the rewritten entry, or nil
    /// when the page could not be fetched. A 404 evicts the entry. Resets
    /// `callCount` to 1 (a fresh body starts a new cadence window).
    @discardableResult
    public func refresh(pageId: String, client: NotionClient) async -> CachedSkillBody? {
        do {
            let entry = try await Self.fetchBody(pageId: pageId, client: client)
            try? write(entry)
            return entry
        } catch let error as NotionClientError {
            if case .httpError(let code, _) = error, code == 404 {
                evict(pageId: pageId)
            }
            return nil
        } catch {
            return nil
        }
    }

    /// A `(id,title)` source for `warmAll` — mirrors the SkillsCacheWriter
    /// `ParentSource` injection so production wires SkillsManager while
    /// tests pass a stub.
    public struct BodySource: Sendable {
        public let load: @Sendable () async -> [(id: String, title: String)]
        public init(load: @Sendable @escaping () async -> [(id: String, title: String)]) {
            self.load = load
        }
    }

    /// Fetch + cache the body of EVERY Notion-source skill in `source`
    /// (the "cache all" button). Returns the count successfully warmed.
    /// Individual failures are logged and skipped — partial success still
    /// lands the healthy bodies on disk.
    @discardableResult
    public func warmAll(source: BodySource, client: NotionClient) async -> Int {
        let entries = await source.load()
        var warmed = 0
        for entry in entries {
            let pid = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pid.isEmpty else { continue }
            if (await refresh(pageId: pid, client: client)) != nil {
                warmed += 1
            } else {
                NSLog("[SkillBodyCacheStore] warmAll page=%@ failed", pid)
            }
        }
        return warmed
    }

    // MARK: - Body fetch (network)

    /// Fetch a skill body from Notion and build a `CachedSkillBody`:
    /// `getPage` (title/url/properties/last_edited_time) + `getPageMarkdown`
    /// (the raw body). Pure of any envelope-building — the cache stores the
    /// RAW body so `fetch_skill` rebuilds the envelope through its own
    /// `buildSkillResult` + annotate path (byte-identical to the network
    /// path). Throws the underlying NotionClientError so callers can map a
    /// 404 to eviction.
    static func fetchBody(pageId: String, client: NotionClient) async throws -> CachedSkillBody {
        let pageData = try await client.getPage(pageId: pageId)
        let pageJSON = (try? JSONSerialization.jsonObject(with: pageData) as? [String: Any]) ?? [:]
        let url = pageJSON["url"] as? String ?? ""
        let lastEdited = pageJSON["last_edited_time"] as? String ?? ""
        let props = pageJSON["properties"] as? [String: Any] ?? [:]
        let title = props.isEmpty ? "Untitled" : NotionJSON.extractTitle(from: props)

        let markdownData = try await client.getPageMarkdown(pageId: pageId)
        let rawMarkdown = SkillsModule.skillMarkdownString(fromMarkdownJSON: markdownData)

        return CachedSkillBody(
            pageId: pageId,
            markdown: rawMarkdown,
            title: title,
            url: url,
            properties: .object(SkillsModule.flattenProperties(props)),
            lastEditedTime: lastEdited,
            writtenAt: Date(),
            ttlHours: BridgeDefaults.skillsCacheTTLHoursEffective,
            callCount: 1
        )
    }

    // MARK: - Path

    /// Canonical path for one cached body file: the bare normalized 32-hex
    /// id + `.json` under the body-cache directory.
    static func fileURL(for pageId: String) -> URL {
        let normalized = CachedSkillBody.normalize(pageId)
        return BridgePaths.applicationSupport(.skillsBodyCache)
            .appendingPathComponent("\(normalized).json", isDirectory: false)
    }
}
