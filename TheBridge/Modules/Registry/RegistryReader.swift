// RegistryReader.swift — Data-Source Registry (Wave 2)
// TheBridge · Modules · Registry
//
// The read-through cache path (Decision 4) — the layer that makes domain verbs
// worth building: a warm READ is a local disk read (no network, no MCP round
// trip). `get` serves a fresh cache hit instantly, serves+revalidates a stale
// one, and fetches on a miss; on a network failure it serves the stale/cached
// copy (offline reads). `list` caches every projected row and falls back to the
// on-disk projection when offline. Projection maps a `NotionRow`'s cells to the
// entity's canonical keys, matched rename-safe by bound property id.

import Foundation
import MCP

public struct RegistryReader: Sendable {
    public let gateway: RegistryNotionGateway
    public let cache: RegistryRowCache

    public init(gateway: RegistryNotionGateway, cache: RegistryRowCache = .shared) {
        self.gateway = gateway
        self.cache = cache
    }

    public enum RegistryReadError: Error, LocalizedError, Equatable {
        /// The page exists in Notion but is trashed (soft-deleted) — treated as
        /// not-found so a deleted row never reads back as live.
        case deleted(String)
        public var errorDescription: String? {
            switch self {
            case .deleted(let id): return "row \(id) is deleted (in trash)"
            }
        }
    }

    // MARK: - Projection (shared with the writer)

    /// Map a row's cells to the entity's canonical keys (rename-safe by bound
    /// id). Returns the projected property object + the title string.
    public static func project(_ row: NotionRow, entity: RegistryEntity) -> (title: String, properties: Value) {
        var out: [String: Value] = [:]
        var title = ""
        for prop in entity.properties {
            guard out[prop.key] == nil,
                  let cell = row.cell(for: prop) else { continue }
            out[prop.key] = cell.value
            if prop.role == .title, case .string(let s) = cell.value { title = s }
        }
        return (title, .object(out))
    }

    /// Project + persist a fetched row into the cache, returning the CachedRow.
    @discardableResult
    public static func store(_ row: NotionRow, entity: RegistryEntity, into cache: RegistryRowCache, now: Date = Date()) async -> CachedRow {
        let (title, props) = project(row, entity: entity)
        let cr = CachedRow(
            entity: entity.key,
            pageId: row.id,
            title: title,
            url: row.url,
            properties: props,
            lastEditedTime: row.lastEditedTime,
            writtenAt: now,
            ttlSeconds: entity.cacheTTLSeconds,
            callCount: 1
        )
        try? await cache.write(cr)
        return cr
    }

    // MARK: - Get (single row)

    /// Cache-first single-row read. Fresh hit → instant; stale → refresh (serve
    /// stale on failure); miss → fetch. `forceRefresh` bypasses the cache.
    public func get(entity: RegistryEntity, pageId: String, forceRefresh: Bool = false) async throws -> CachedRow {
        let norm = CachedRow.normalize(pageId)
        if !forceRefresh, let cached = await cache.read(entity: entity.key, pageId: norm) {
            if !cached.isExpired() {
                // Fresh: serve the cache hit directly (tick the usage counter).
                // No background revalidation kick: an unstructured detached Task
                // resolves the cache path lazily and could, if it outlived a
                // test's `overrideHomeForTesting`, write to the wrong home; a
                // stale entry is refreshed inline on its next read anyway.
                _ = await cache.incrementCallCount(entity: entity.key, pageId: norm)
                return cached
            }
            // Stale: try a live refresh; on failure serve the stale copy (offline).
            do { return try await Self.fetchAndStore(entity: entity, pageId: norm, gateway: gateway, cache: cache) }
            catch { return cached }
        }
        return try await Self.fetchAndStore(entity: entity, pageId: norm, gateway: gateway, cache: cache)
    }

    private static func fetchAndStore(entity: RegistryEntity, pageId: String, gateway: RegistryNotionGateway, cache: RegistryRowCache) async throws -> CachedRow {
        let row = try await gateway.page(pageId: pageId, workspace: entity.workspace)
        // A soft-deleted (trashed) page is still returned by getPage — treat it
        // as not-found and drop any cached copy so a deleted row never reads
        // back as live. An empty id (a malformed response) is likewise treated
        // as not-found rather than cached under an empty/garbage key.
        if row.archived || row.id.isEmpty {
            await cache.evict(entity: entity.key, pageId: pageId)
            throw RegistryReadError.deleted(pageId)
        }
        return await store(row, entity: entity, into: cache)
    }

    // MARK: - List (all rows)

    /// List rows for an entity, caching each projection. PAGINATES — follows
    /// `next_cursor` (100/request) until `limit` rows or the source is
    /// exhausted, so a data source with >100 rows is never silently truncated.
    /// A page-count backstop prevents a runaway if a source keeps returning a
    /// cursor. On a network failure, serve the on-disk cache (offline reads);
    /// rethrow only if nothing cached.
    public func list(entity: RegistryEntity, limit: Int = 100) async throws -> [CachedRow] {
        let cap = max(1, limit)
        let perRequest = min(100, cap)
        do {
            var out: [CachedRow] = []
            var cursor: String? = nil
            var pages = 0
            repeat {
                let result = try await gateway.query(
                    dataSourceId: entity.dataSourceId, workspace: entity.workspace,
                    pageSize: perRequest, startCursor: cursor)
                for row in result.rows {
                    out.append(await Self.store(row, entity: entity, into: cache))
                    if out.count >= cap { break }
                }
                cursor = result.nextCursor
                pages += 1
            } while cursor != nil && out.count < cap && pages < 200
            return out
        } catch {
            let cached = await cache.readAll(entity: entity.key)
            if cached.isEmpty { throw error }
            return cached
        }
    }

    // MARK: - Find (convergent lookup — resolve-before-write)

    /// Resolve EXISTING rows by canonical field predicates BEFORE a blind
    /// `create` — the convergence primitive that eliminates duplicate rows.
    /// Read-only: matches `predicates` (canonical KEY → value) against the
    /// entity's projected rows, which are keyed rename-safe by BOUND PROPERTY
    /// ID (projection resolves each cell via `cell(for:)`, id-first), so a
    /// Notion rename never breaks the match. Unlike `list`, the caller's
    /// `limit` is only a RETURN cap: the live source is paginated to exhaustion
    /// before matching, so rows beyond the first list window remain findable.
    /// The scan preserves the same read-through cache + offline fallback
    /// contract as `list`.
    ///
    /// Semantics: ALL predicates must match (AND). A row matches a predicate
    /// when the projected value for that key equals the predicate value —
    /// scalar values compared as case-insensitive strings; array values
    /// (multi_select / relation / people) match when ANY element equals. An
    /// absent key never matches. Zero matches is a valid, non-error result
    /// (empty array). Ambiguous input naturally yields multiple rows.
    public func find(entity: RegistryEntity, predicates: [String: Value], limit: Int = 100) async throws -> [CachedRow] {
        let returnCap = max(1, limit)
        let rows = try await scanAll(entity: entity)
        guard !predicates.isEmpty else { return Array(rows.prefix(returnCap)) }
        return Array(rows.filter { row in
            guard case .object(let props) = row.properties else { return false }
            return predicates.allSatisfy { key, wanted in
                guard let have = props[key] else { return false }
                return Self.valueMatches(have, wanted)
            }
        }.prefix(returnCap))
    }

    /// Exhaustively page the live source for completeness-critical lookups.
    /// A repeated cursor is treated as an invalid gateway response rather than
    /// looping forever. On any live failure, fall back to the entity cache —
    /// identical to `list`'s offline-tolerant contract.
    private func scanAll(entity: RegistryEntity) async throws -> [CachedRow] {
        do {
            var out: [CachedRow] = []
            var cursor: String? = nil
            var seenCursors = Set<String>()
            repeat {
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw RegistryGatewayError.invalidResponse("Notion query repeated cursor \(cursor)")
                }
                let result = try await gateway.query(
                    dataSourceId: entity.dataSourceId, workspace: entity.workspace,
                    pageSize: 100, startCursor: cursor)
                for row in result.rows {
                    out.append(await Self.store(row, entity: entity, into: cache))
                }
                cursor = result.nextCursor
            } while cursor != nil
            return out
        } catch {
            let cached = await cache.readAll(entity: entity.key)
            if cached.isEmpty { throw error }
            return cached
        }
    }

    /// True when `have` (a projected cell value) satisfies the `wanted`
    /// predicate value. Scalars compare as case-insensitive strings so
    /// `"active"` matches a `.string("Active")` status; arrays match when ANY
    /// element satisfies `wanted` (a relation/multi_select membership test).
    static func valueMatches(_ have: Value, _ wanted: Value) -> Bool {
        if case .array(let elems) = have {
            return elems.contains { valueMatches($0, wanted) }
        }
        // If the predicate itself is an array, match when ANY wanted element hits.
        if case .array(let wants) = wanted {
            return wants.contains { valueMatches(have, $0) }
        }
        guard let h = scalarString(have), let w = scalarString(wanted) else { return false }
        return h.compare(w, options: .caseInsensitive) == .orderedSame
    }

    /// Render a scalar `Value` to a comparable string; `nil` for containers.
    private static func scalarString(_ v: Value) -> String? {
        switch v {
        case .string(let s): return s
        case .int(let n): return String(n)
        case .double(let d):
            // Match the number codec's integral rendering (3.0 → "3").
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        case .array, .object, .data: return nil
        }
    }

    // MARK: - Body (possess — Decision 2)

    /// Load an entity's page BODY on demand (the `possess`/`fetch_skill` verb).
    /// Not cached here — bodies are loaded on demand, not eagerly (Decision 4);
    /// Skills' own `SkillBodyCacheStore` remains the body-cache for that path.
    public func body(entity: RegistryEntity, pageId: String) async throws -> String {
        guard entity.hasBody else { return "" }
        return try await gateway.markdown(pageId: pageId, workspace: entity.workspace)
    }

    // MARK: - Hydrate (packet-registry-v1 envelope — FR-1 / §8.3)

    /// Hydrate one entity row into the `packet-registry-v1` envelope: primary
    /// non-relation properties + page body + curated ONE-HOP relation
    /// projections + provenance + unresolved-relation warnings (PRD FR-1, §8.3).
    ///
    /// One hop only — each related page is fetched once for its compact
    /// projection; its relations and body are never loaded (FR-1 "Deeper reads
    /// are explicit"). A missing / inaccessible / archived target is omitted and
    /// a warning appended, never guessed (FR-4, §8.3). The primary read reuses
    /// `get` (warm-cache + offline-tolerant); the body is best-effort so an
    /// offline cycle still yields a valid envelope.
    public func hydrate(entity: RegistryEntity, pageId: String, forceRefresh: Bool = false, now: Date = Date()) async throws -> PacketRegistryEnvelope {
        let primaryRow = try await get(entity: entity, pageId: pageId, forceRefresh: forceRefresh)

        // Split the flat projection: relation props → one-hop slots; everything
        // else except the title (surfaced as primary.title) → primary.properties.
        let relationKeys = Set(entity.properties.filter { $0.role == .relation }.map { $0.key })
        let titleKeys = Set(entity.properties.filter { $0.role == .title }.map { $0.key })
        var primaryProps: [String: Value] = [:]
        var relationIds: [String: [String]] = [:]
        if case .object(let all) = primaryRow.properties {
            for (k, v) in all {
                if relationKeys.contains(k) {
                    if case .array(let arr) = v {
                        relationIds[k] = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                    }
                } else if !titleKeys.contains(k) {
                    primaryProps[k] = v
                }
            }
        }

        var warnings: [String] = []
        var body = ""
        if entity.hasBody {
            do {
                body = try await self.body(entity: entity, pageId: pageId)
            } catch {
                warnings.append("primary body could not be fetched — mission evidence incomplete")
            }
        }

        // One-hop relation projection (fetch each distinct target once).
        var relations: [String: [Value]] = [:]
        for (key, ids) in relationIds {
            guard let slot = PacketRelationProjection.slotForKey[key] else { continue }
            var items: [Value] = []
            var seen = Set<String>()
            for rid in ids {
                guard seen.insert(CachedRow.normalize(rid)).inserted else { continue }   // dedup
                do {
                    let target = try await gateway.page(pageId: rid, workspace: entity.workspace)
                    if target.archived || target.id.isEmpty {
                        warnings.append("relation ‘\(slot)’: target \(rid) is archived or inaccessible — omitted")
                        continue
                    }
                    items.append(PacketRelationProjection.projectTarget(target, slot: slot))
                } catch {
                    warnings.append("relation ‘\(slot)’: target \(rid) could not be fetched — omitted")
                }
            }
            relations[slot] = items
        }

        let primary = PacketRegistryEnvelope.Primary(
            id: PacketRegistryEnvelope.dashedId(primaryRow.pageId),
            title: primaryRow.title,
            lastEditedTime: primaryRow.lastEditedTime,
            properties: .object(primaryProps))
        let stringProps = primaryProps.reduce(into: [String: String]()) { result, item in
            if case .string(let value) = item.value { result[item.key] = value }
        }
        // Mission identity comes from the primary row's raw relation IDs, not
        // from successfully projected target pages. A missing/archived target
        // must not collapse to the same hash as an intentionally empty relation.
        let relationIdentity = ["project", "skills", "blockedBy", "blocking"]
            .reduce(into: [String: [String]]()) { result, key in
                result[key] = relationIds[key] ?? []
            }
        let revision: Int? = {
            switch primaryProps["missionRevision"] {
            case .int(let value)?: return value > 0 ? value : nil
            case .double(let value)?: return value.rounded() == value && value > 0 ? Int(value) : nil
            default: return nil
            }
        }()
        let storedHash: String? = {
            if case .string(let value)? = primaryProps["missionHash"] { return value }
            return nil
        }()
        let canonical = PacketMissionIntegrity.canonical(
            title: primary.title, properties: stringProps,
            relations: relationIdentity, body: body)
        let conflicts = PacketMissionIntegrity.conflictFields(properties: stringProps, body: body)
        let evidenceComplete = warnings.isEmpty
        let consistency = PacketMissionIntegrity.classify(
            storedRevision: revision, storedHash: storedHash, canonical: canonical,
            properties: stringProps, body: body, evidenceComplete: evidenceComplete)
        let evidence: Value = .object([
            "classification": .string(consistency.rawValue),
            "canonicalHash": .string(PacketMissionIntegrity.hash(canonical: canonical)),
            "storedHash": storedHash.map(Value.string) ?? .null,
            "revision": revision.map { .int($0) } ?? .null,
            "conflictFields": .array(conflicts.map(Value.string)),
            "evidenceComplete": .bool(evidenceComplete),
        ])
        return PacketRegistryEnvelope(
            primary: primary, body: body, relations: relations,
            fetchedAt: CachedRow.iso8601.string(from: now), warnings: warnings,
            missionIntegrity: evidence)
    }
}
