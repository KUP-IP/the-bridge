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
    /// Optional KEEP review metadata mirrored from Notion (D10 / D19).
    /// Populated when the cached row represents a Memory entity row with review fields.
    public var reviewMetadata: KeepReviewMetadata?

    public init(id: String, title: String, reviewMetadata: KeepReviewMetadata? = nil) {
        self.id = id
        self.title = title
        self.reviewMetadata = reviewMetadata
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

    // MARK: — KEEP Review Schema (D43)

    /// Map a Notion property dictionary to a `KeepReviewMetadata` value.
    /// Expects `properties` in the same shape returned by RegistryPropertyCodec /
    /// Notion list responses — string values for `reviewStatus`, ISO-8601 for dates,
    /// and a numeric value for `recallScore`.
    ///
    /// Returns `nil` when none of the 4 required KEEP fields are present (i.e. the
    /// Notion database schema has not yet had review fields added).
    public static func keepReviewMetadata(from notionProperties: [String: Any]) -> KeepReviewMetadata? {
        let statusRaw  = notionProperties[KeepSchemaContract.notionPropReviewStatus] as? String
        let nextRaw    = notionProperties[KeepSchemaContract.notionPropNextReviewAt] as? String
        let lastRaw    = notionProperties[KeepSchemaContract.notionPropLastReviewedAt] as? String
        let scoreRaw   = notionProperties[KeepSchemaContract.notionPropRecallScore] as? Double

        // If none of the four KEEP fields are present, the schema hasn't been migrated yet.
        guard statusRaw != nil || nextRaw != nil || lastRaw != nil || scoreRaw != nil else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        let status: KeepReviewStatus = statusRaw.flatMap { KeepReviewStatus(rawValue: $0) } ?? .unknown
        return KeepReviewMetadata(
            reviewStatus: status,
            nextReviewAt: nextRaw.flatMap { iso.date(from: $0) },
            lastReviewedAt: lastRaw.flatMap { iso.date(from: $0) },
            recallScore: scoreRaw ?? 0.0
        )
    }

    /// Ensure the Notion Memory database has all 4 required KEEP review fields (D43).
    ///
    /// For each field in `KeepRequiredSchemaField.allRequired` that is absent from the
    /// existing database schema, this method creates it using the Notion API.
    /// The method is idempotent — calling it repeatedly is safe.
    ///
    /// - Parameters:
    ///   - databaseId: The Notion database ID for the Memory data source.
    ///   - client: The `NotionClient` to use for schema reads and property creation.
    ///
    /// - Note: Auto-creation emits a `keepFieldAutoCreated` ACTIVITY event per field
    ///   created (D43). Implementation delegates to `RegistrySchemaBinder` / Notion
    ///   database PATCH once that plumbing is available. Body is stubbed pending
    ///   `NotionClient.updateDatabase(id:properties:)` surface (TODO: wire when available).
    public static func ensureReviewSchema(databaseId: String, client: NotionClient) async throws {
        // TODO: Implement D43 auto-creation of missing KEEP review fields.
        //
        // Algorithm:
        //   1. GET /databases/{databaseId} → inspect existing property names.
        //   2. Diff against KeepRequiredSchemaField.allRequired.
        //   3. For each missing field: PATCH /databases/{databaseId} with the new property
        //      definition (type per KeepRequiredSchemaField.notionType).
        //   4. Emit a `keepFieldAutoCreated` ACTIVITY event for each created field.
        //
        // NotionClient currently exposes `getDatabase(databaseId:)` for step 1.
        // Step 3 requires a `updateDatabaseSchema(id:properties:)` method not yet on
        // NotionClient — add it when wiring this stub.
        //
        // For now this is a compile-verified no-op stub (D43 plumbing packet).
        _ = databaseId
        _ = client
    }
}
