// SkillsCacheWriter.swift — Bridge v3.7·1
// NotionBridge · Modules · Skills
//
// Owns every mutation of `BridgePaths.applicationSupport(.skillsCache)`.
// Two public surfaces:
//
//   - `write(parent:)` — persist a single `CachedParent` atomically
//     (write to temp file → fsync → rename) so a concurrent reader can
//     never observe a torn JSON document.
//
//   - `refreshAll()` — re-enumerate every Notion-source routing skill via
//     the supplied `NotionClient` and persist a fresh `CachedParent` per
//     parent. Idempotent: same inputs → same on-disk bytes (the JSON
//     payload sorts children by id for byte stability, and `writtenAt`
//     is the only timestamp that legitimately moves between runs).
//
// Concurrency: serialized through one actor instance. Two writes to the
// same parent id placed concurrently into the actor's mailbox are
// processed sequentially, so the "last writer wins" semantic is
// deterministic on a per-parent basis without any extra file locking.

import Foundation

public actor SkillsCacheWriter {
    public static let shared = SkillsCacheWriter()

    /// Errors surfaced by `write(parent:)`. `refreshAll()` does NOT
    /// surface per-parent errors — individual failures are logged and the
    /// healthy entries still land on disk.
    public enum Error: Swift.Error, Equatable {
        case directoryCreation(String)
        case encode(String)
        case atomicWrite(String)
    }

    /// Source for the Notion-source routing skills that `refreshAll()`
    /// walks. Defaults to `SkillsManager()` so production callers don't
    /// have to wire anything; tests inject a stub.
    public struct ParentSource: Sendable {
        public let load: @Sendable () async -> [Parent]

        public init(load: @Sendable @escaping () async -> [Parent]) {
            self.load = load
        }

        public struct Parent: Sendable, Equatable {
            public let id: String       // Notion page id (any shape — normalized at write time)
            public let title: String    // Parent display title
            public init(id: String, title: String) {
                self.id = id
                self.title = title
            }
        }
    }

    /// Functional handle to the Notion client. Held as a closure so tests
    /// can stub it without standing up a live `NotionClient`. Returns
    /// `nil` when the client could not be constructed (e.g. missing token).
    public struct ChildEnumerator: Sendable {
        public let listChildren: @Sendable (_ parentId: String) async -> [CachedSpecialist]

        public init(listChildren: @Sendable @escaping (_ parentId: String) async -> [CachedSpecialist]) {
            self.listChildren = listChildren
        }
    }

    public init() {}

    /// Atomically persist one parent. Returns nothing; throws only on
    /// hard errors (encode failure or filesystem inability to rename).
    public func write(parent: CachedParent) throws {
        let dir: URL
        do {
            dir = try BridgePaths.ensureApplicationSupport(.skillsCache)
        } catch {
            throw Error.directoryCreation("\(error)")
        }
        // Sort children by id for deterministic byte output. Idempotent
        // writes (same inputs → same bytes, modulo `writtenAt`) make the
        // sync-idempotency test possible without a special "skip
        // timestamp" comparator.
        let sortedChildren = parent.children.sorted { $0.id < $1.id }
        let normalized = CachedParent(
            writtenAt: parent.writtenAt,
            ttlHours: parent.ttlHours,
            parentId: parent.parentId,
            parentTitle: parent.parentTitle,
            children: sortedChildren
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(normalized)
        } catch {
            throw Error.encode("\(error)")
        }

        let dest = SkillsCacheReader.fileURL(for: parent.parentId)
        // Atomic rename: write to sibling temp file, then `replaceItem`.
        let tmp = dir.appendingPathComponent(
            ".\(dest.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: tmp, options: [.atomic])
            // If a previous file exists, replaceItem swaps in-place; if
            // not, fall back to move. Either way the partial-state window
            // never exposes an unreadable file to the reader.
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw Error.atomicWrite("\(error)")
        }
    }

    /// Re-enumerate every parent supplied by `source`, fetch its children
    /// via `enumerator`, and atomically persist one cache file per parent.
    /// Returns the count of parents successfully refreshed.
    @discardableResult
    public func refreshAll(
        source: ParentSource,
        enumerator: ChildEnumerator,
        ttlHours: Int = BridgeDefaults.skillsCacheTTLHoursEffective,
        now: Date = Date()
    ) async -> Int {
        let parents = await source.load()
        var refreshed = 0
        for parent in parents {
            let children = await enumerator.listChildren(parent.id)
            let entry = CachedParent(
                writtenAt: now,
                ttlHours: ttlHours,
                parentId: parent.id,
                parentTitle: parent.title,
                children: children
            )
            do {
                try write(parent: entry)
                refreshed += 1
            } catch {
                NSLog("[SkillsCacheWriter] refreshAll parent=%@ failed: %@",
                      parent.id, "\(error)")
            }
        }
        return refreshed
    }
}

// MARK: - Production wiring

extension SkillsCacheWriter.ParentSource {
    /// Pulls every Notion-source routing-discoverable skill from
    /// `SkillsManager`. Filtered through `routingSkillsForDiscovery` so
    /// the cache only ever holds entries that can actually appear in the
    /// routing index — keeps the working set bounded.
    @MainActor
    public static func fromSkillsManager(_ manager: SkillsManager) -> SkillsCacheWriter.ParentSource {
        // Snapshot on the main actor (read-only); the captured array is
        // value-typed and Sendable.
        let snapshot: [Parent] = manager.routingSkillsForDiscovery.compactMap { skill in
            let pid = skill.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pid.isEmpty else { return nil }
            return Parent(id: pid, title: skill.name)
        }
        return SkillsCacheWriter.ParentSource(load: { snapshot })
    }
}

extension SkillsCacheWriter.ChildEnumerator {
    /// Production enumerator backed by a live `NotionClient`. Surfaces
    /// each child page's `id`, `title`, and a heuristic `summary`
    /// (description property when present, else empty). Failures degrade
    /// to "no children" — the cache will surface zero specialists for
    /// that parent and the routing index renders without the section.
    public static func live(client: NotionClient) -> SkillsCacheWriter.ChildEnumerator {
        SkillsCacheWriter.ChildEnumerator(listChildren: { parentId in
            await Self.fetchChildren(client: client, parentId: parentId)
        })
    }

    /// Walk `child_page` blocks of `parentId` and hydrate each to a
    /// `CachedSpecialist`. Mirrors the bounded-pagination contract used
    /// by `SkillsModule.listNotionChildPages` (50 pages × 100 = 5000
    /// blocks defensive cap).
    private static func fetchChildren(
        client: NotionClient,
        parentId: String
    ) async -> [CachedSpecialist] {
        var collectedIds: [(id: String, title: String)] = []
        var cursor: String? = nil
        for _ in 0..<50 {
            guard let data = try? await client.fetchChildBlocksRaw(blockId: parentId, startCursor: cursor, pageSize: 100) else {
                break
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                break
            }
            for block in results {
                guard let type = block["type"] as? String, type == "child_page",
                      let cid = block["id"] as? String else { continue }
                let title = (block["child_page"] as? [String: Any])?["title"] as? String ?? ""
                collectedIds.append((id: cid, title: title))
            }
            let hasMore = json["has_more"] as? Bool ?? false
            guard hasMore, let next = json["next_cursor"] as? String, !next.isEmpty else { break }
            cursor = next
        }

        var out: [CachedSpecialist] = []
        for entry in collectedIds {
            var title = entry.title
            var summary = ""
            if let pageData = try? await client.getPage(pageId: entry.id),
               let json = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] {
                if let props = json["properties"] as? [String: Any] {
                    let t = NotionJSON.extractTitle(from: props)
                    if !t.isEmpty && t != "Untitled" { title = t }
                    // Best-effort one-line description.
                    if let desc = props["description"] as? [String: Any],
                       let arr = desc["rich_text"] as? [[String: Any]],
                       let first = arr.first,
                       let plain = first["plain_text"] as? String {
                        summary = plain
                    }
                }
            }
            out.append(CachedSpecialist(
                id: entry.id,
                title: title,
                summary: summary,
                aliases: []
            ))
        }
        return out
    }
}
