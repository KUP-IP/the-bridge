// RegistryRowCacheModels.swift — Data-Source Registry (vertical slice v0)
// TheBridge · Modules · Registry
//
// On-disk shape for the generalized per-entity ROW cache — the Decision 4
// "full-row property projection" layer. Generalizes CachedSkillBody: instead
// of one skill body, this caches one data-source ROW's projected properties
// keyed by (entity, pageId), enabling stale-while-revalidate + offline reads
// for EVERY registry entity (Contacts, Projects, Memory, …), not just Skills.
//
// Wire format (per file `<normalized-pageId>.json` under
// `…/registry-cache/<entity>/`):
//   {
//     "entity":         "skill",
//     "pageId":         "<32-hex Notion uuid>",
//     "title":          "<row title>",
//     "url":            "<page url>",
//     "properties":     { ... projected property map (MCP Value) ... },
//     "lastEditedTime": "<getPage last_edited_time — the freshness anchor>",
//     "writtenAt":      "2026-06-17T10:00:00Z",
//     "ttlSeconds":     3600,
//     "callCount":      1
//   }
//
// Decoding is forwards-tolerant: unknown keys ignored, missing fields default
// (mirrors CachedSkillBody) so older readers survive writer revisions.

import Foundation
import MCP

/// One cached data-source row, keyed by (entity, normalized page id).
public struct CachedRow: Codable, Sendable, Equatable {
    /// The registry entity key this row belongs to (`skill`, `contact`, …).
    public let entity: String
    /// Normalized 32-hex Notion page id (no dashes, lowercased).
    public let pageId: String
    /// Row title (the entity's title property), for list rendering.
    public let title: String
    /// Page url (click-to-open).
    public let url: String
    /// Projected property map (MCP `Value`, `.object`) — the cached row body.
    public let properties: Value
    /// `last_edited_time` — the stale-while-revalidate freshness anchor and
    /// the backwards-sync last-write-wins clock (Decision 3).
    public let lastEditedTime: String
    /// When this entry was last (re)written.
    public let writtenAt: Date
    /// Per-entity TTL in SECONDS (Decision 4 — volatility-based).
    public let ttlSeconds: Int
    /// Monotonic per-entry call counter → drives the revalidation cadence.
    public let callCount: Int

    public init(
        entity: String,
        pageId: String,
        title: String,
        url: String,
        properties: Value,
        lastEditedTime: String,
        writtenAt: Date,
        ttlSeconds: Int,
        callCount: Int = 1
    ) {
        self.entity = entity
        self.pageId = Self.normalize(pageId)
        self.title = title
        self.url = url
        self.properties = properties
        self.lastEditedTime = lastEditedTime
        self.writtenAt = writtenAt
        self.ttlSeconds = ttlSeconds
        self.callCount = callCount
    }

    enum CodingKeys: String, CodingKey {
        case entity, pageId, title, url, properties, lastEditedTime
        case writtenAt, ttlSeconds, callCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.entity = try c.decodeIfPresent(String.self, forKey: .entity) ?? ""
        self.pageId = try c.decodeIfPresent(String.self, forKey: .pageId) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.properties = try c.decodeIfPresent(Value.self, forKey: .properties) ?? .object([:])
        self.lastEditedTime = try c.decodeIfPresent(String.self, forKey: .lastEditedTime) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .writtenAt) ?? ""
        self.writtenAt = Self.iso8601.date(from: raw) ?? .distantPast
        self.ttlSeconds = try c.decodeIfPresent(Int.self, forKey: .ttlSeconds) ?? 3600
        self.callCount = try c.decodeIfPresent(Int.self, forKey: .callCount) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entity, forKey: .entity)
        try c.encode(pageId, forKey: .pageId)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
        try c.encode(properties, forKey: .properties)
        try c.encode(lastEditedTime, forKey: .lastEditedTime)
        try c.encode(Self.iso8601.string(from: writtenAt), forKey: .writtenAt)
        try c.encode(ttlSeconds, forKey: .ttlSeconds)
        try c.encode(callCount, forKey: .callCount)
    }

    /// Copy with `callCount` set to `n`.
    public func withCallCount(_ n: Int) -> CachedRow {
        CachedRow(
            entity: entity, pageId: pageId, title: title, url: url,
            properties: properties, lastEditedTime: lastEditedTime,
            writtenAt: writtenAt, ttlSeconds: ttlSeconds, callCount: n
        )
    }

    /// True iff past TTL. Non-positive `ttlSeconds` ⇒ never expires
    /// (defensive — a hand-corrupted file should not flap to stale). A stale
    /// row is still returned (offline-first); it is just labelled stale so a
    /// background revalidation can be kicked.
    public func isExpired(now: Date = Date()) -> Bool {
        guard ttlSeconds > 0 else { return false }
        return now.timeIntervalSince(writtenAt) > TimeInterval(ttlSeconds)
    }

    /// Canonical id normalization shared by the store + reader: strip
    /// dashes/whitespace, lowercase. Mirrors CachedSkillBody.normalize.
    public static func normalize(_ pageId: String) -> String {
        pageId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    /// ISO-8601 with fractional seconds + UTC. Constructed per call because
    /// `ISO8601DateFormatter` is not `Sendable` (mirrors CachedSkillBody).
    static var iso8601: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}
