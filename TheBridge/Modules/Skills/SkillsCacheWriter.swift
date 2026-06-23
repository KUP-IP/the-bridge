// SkillsCacheWriter.swift — Bridge v3.7·1
// TheBridge · Modules · Skills
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
    /// Production enumerator backed by a live `NotionClient`. Surfaces each
    /// curated specialist's `id`, `title`, and a one-line `summary` (the
    /// related page's `Description` rich_text when present, else empty).
    /// Failures degrade to "no children" — the cache will surface
    /// zero specialists for that parent and the routing index renders
    /// without the section.
    public static func live(client: NotionClient) -> SkillsCacheWriter.ChildEnumerator {
        SkillsCacheWriter.ChildEnumerator(listChildren: { parentId in
            await Self.fetchChildren(client: client, parentId: parentId)
        })
    }

    /// Resolve a parent skill's CURATED specialists and hydrate each to a
    /// `CachedSpecialist`.
    ///
    /// routing/specialist-relation (v3.7.4): the PRIMARY source is now the
    /// parent's `Specialist` **relation property** (the operator-curated set
    /// of related specialist pages) — NOT the parent's `child_page` blocks.
    /// Reading the relation is what stops docs / changelogs / §-sections /
    /// duplicate stubs from leaking in, and surfaces real specialists that
    /// live as sibling database rows (never as child pages under the parent).
    /// Verified live: the property is named singular `Specialist` (see
    /// `NotionJSON.specialistRelationPropertyNames`).
    ///
    /// Fallback: if the parent has NO `Specialist` relation (empty or the
    /// property is absent — e.g. a file-shaped or legacy page), we degrade to
    /// the historical `child_page` walk so older pages keep working. Either
    /// way `SpecialistFilter` runs as a defensive secondary guard (belt +
    /// suspenders) so any doc-page that slips into the relation is still
    /// excluded from the routing surface.
    private static func fetchChildren(
        client: NotionClient,
        parentId: String
    ) async -> [CachedSpecialist] {
        // 1) PRIMARY: the parent's curated `Specialist` relation.
        var relationIds: [String] = []
        if let parentData = try? await client.getPage(pageId: parentId),
           let parentJSON = try? JSONSerialization.jsonObject(with: parentData) as? [String: Any],
           let props = parentJSON["properties"] as? [String: Any] {
            relationIds = NotionJSON.extractSpecialistRelationIDs(from: props)
        }

        let candidateIds: [String]
        if relationIds.isEmpty {
            // 2) FALLBACK: no curated relation → walk child_page blocks.
            candidateIds = await fetchChildPageIds(client: client, parentId: parentId)
        } else {
            candidateIds = relationIds
        }

        var out: [CachedSpecialist] = []
        for cid in candidateIds {
            var title = ""
            var summary = ""
            // Fail-open: if the page can't be fetched we don't hide it on
            // status grounds (the title guard below already drops an
            // unresolved/empty-title candidate).
            var isActive = true
            if let pageData = try? await client.getPage(pageId: cid),
               let json = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any],
               let props = json["properties"] as? [String: Any] {
                let t = NotionJSON.extractTitle(from: props)
                if !t.isEmpty && t != "Untitled" { title = t }
                // Best-effort one-line summary: SSOT = Notion "Description"
                // (the single agent-facing field), with lowercase `description`
                // tolerated for file/test fixtures.
                summary = firstRichText(props, keys: ["Description", "description"])
                isActive = SpecialistFilter.isActiveSpecialist(properties: props)
            }
            // Two hydration-time guards (belt + suspenders): drop doc-pages by
            // title, AND drop a retired specialist by lifecycle status — a
            // deprecated/archived/folded row (or one with a Deprecation Date)
            // may linger in the curated relation for history but must never
            // surface in routing (v3.7.6).
            guard SpecialistFilter.isSpecialist(title: title), isActive else { continue }
            out.append(CachedSpecialist(
                id: cid,
                title: title,
                summary: summary,
                aliases: []
            ))
        }
        return out
    }

    /// Bounded `child_page`-block walk (the legacy fallback source).
    /// 50 pages × 100 = 5000-block defensive cap. Returns the child page
    /// ids in document order.
    private static func fetchChildPageIds(
        client: NotionClient,
        parentId: String
    ) async -> [String] {
        var ids: [String] = []
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
                ids.append(cid)
            }
            let hasMore = json["has_more"] as? Bool ?? false
            guard hasMore, let next = json["next_cursor"] as? String, !next.isEmpty else { break }
            cursor = next
        }
        return ids
    }

    /// First non-empty `rich_text` plain text among `keys`, in order. Used
    /// to derive a one-line specialist summary from the related page's
    /// curated properties. Pure; never throws.
    private static func firstRichText(_ props: [String: Any], keys: [String]) -> String {
        for k in keys {
            guard let prop = props[k] as? [String: Any],
                  let arr = prop["rich_text"] as? [[String: Any]] else { continue }
            let text = NotionJSON.extractPlainText(from: arr)
            if !text.isEmpty { return text }
        }
        return ""
    }
}
