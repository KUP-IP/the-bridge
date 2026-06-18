// SkillBodyCacheModels.swift — Bridge (feat/backend-remediation)
// TheBridge · Modules · Skills
//
// On-disk shape for the per-skill BODY cache. SEPARATE and ADDITIVE to the
// per-PARENT routing cache (CachedParent/CachedSpecialist): the routing
// cache stores list+summaries+aliases for specialist enumeration; THIS
// cache stores the rendered skill BODY (markdown) so `fetch_skill` can
// rebuild its return envelope without the live `getPageMarkdown` call on
// every request, surviving restarts / cold-start.
//
// Keying: by the RESOLVED `envelopePageId` (parent OR specialist child),
// so `parent` and `parent/child` get distinct entries — mirrors the
// `pathSelectorKey` reasoning in SkillsModule.
//
// Wire format (per file `<normalized-pageId>.json` under
// `BridgePaths.applicationSupport(.skillsBodyCache)`):
//
//   {
//     "pageId":         "<32-hex Notion uuid>",
//     "markdown":       "<raw body from skillMarkdownString>",
//     "title":          "<page title>",
//     "url":            "<page url>",
//     "properties":     { ... flattened envelope `properties` map ... },
//     "lastEditedTime": "<getPage JSON last_edited_time>",
//     "writtenAt":      "2026-06-11T10:00:00Z",  // ISO-8601, UTC
//     "ttlHours":       24,
//     "callCount":      1
//   }
//
// Decoding is forwards-tolerant: unknown top-level keys are ignored and
// missing fields default to empty values — protects older readers against
// future writer revisions (mirrors CachedSpecialist).

import Foundation
import MCP

/// One cached skill body keyed by its resolved Notion page id.
///
/// `properties` is the ALREADY-FLATTENED envelope `properties` map (the
/// `.object(...)` `SkillsModule.flattenProperties` produces), stored as an
/// MCP `Value` so a cache-served envelope can carry a byte-identical
/// `properties` key without re-flattening — and without persisting the
/// (large) verbatim getPage properties blob. `Value` is `Codable`.
public struct CachedSkillBody: Codable, Sendable, Equatable {
    /// Normalized 32-hex Notion id (no dashes, lowercased).
    public let pageId: String
    /// Raw body markdown as returned by `SkillsModule.skillMarkdownString`
    /// (pre-section-slice, pre-mention-resolution — the exact input the
    /// network path feeds `buildSkillResult`).
    public let markdown: String
    /// Page title for the envelope (from the resolved page's properties).
    public let title: String
    /// Page url for the envelope.
    public let url: String
    /// Flattened envelope `properties` map (the `.object` form). Stored as
    /// a `Value` so the cache-served envelope's `properties` key is
    /// byte-identical to the network path without re-running the flatten.
    public let properties: Value
    /// `last_edited_time` from the getPage JSON. The freshness anchor for
    /// stale-while-revalidate: a changed value means the body is stale.
    public let lastEditedTime: String
    /// When this entry was last (re)written.
    public let writtenAt: Date
    /// TTL hours — drives the read-time `stale` derivation (parallel to
    /// CachedParent). Reads past TTL still return; they're labelled stale.
    public let ttlHours: Int
    /// Monotonic per-entry call counter — drives the revalidation cadence
    /// (`callCount % 5 == 0` kicks a background freshness check).
    public let callCount: Int

    public init(
        pageId: String,
        markdown: String,
        title: String,
        url: String,
        properties: Value,
        lastEditedTime: String,
        writtenAt: Date,
        ttlHours: Int = 24,
        callCount: Int = 1
    ) {
        self.pageId = Self.normalize(pageId)
        self.markdown = markdown
        self.title = title
        self.url = url
        self.properties = properties
        self.lastEditedTime = lastEditedTime
        self.writtenAt = writtenAt
        self.ttlHours = ttlHours
        self.callCount = callCount
    }

    enum CodingKeys: String, CodingKey {
        case pageId, markdown, title, url, properties, lastEditedTime
        case writtenAt, ttlHours, callCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pageId = try c.decodeIfPresent(String.self, forKey: .pageId) ?? ""
        self.markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.properties = try c.decodeIfPresent(Value.self, forKey: .properties) ?? .object([:])
        self.lastEditedTime = try c.decodeIfPresent(String.self, forKey: .lastEditedTime) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .writtenAt) ?? ""
        self.writtenAt = Self.iso8601.date(from: raw) ?? .distantPast
        self.ttlHours = try c.decodeIfPresent(Int.self, forKey: .ttlHours) ?? 24
        self.callCount = try c.decodeIfPresent(Int.self, forKey: .callCount) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pageId, forKey: .pageId)
        try c.encode(markdown, forKey: .markdown)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
        try c.encode(properties, forKey: .properties)
        try c.encode(lastEditedTime, forKey: .lastEditedTime)
        try c.encode(Self.iso8601.string(from: writtenAt), forKey: .writtenAt)
        try c.encode(ttlHours, forKey: .ttlHours)
        try c.encode(callCount, forKey: .callCount)
    }

    /// Return a copy with `callCount` set to `n` (writtenAt/markdown kept).
    public func withCallCount(_ n: Int) -> CachedSkillBody {
        CachedSkillBody(
            pageId: pageId, markdown: markdown, title: title, url: url,
            properties: properties, lastEditedTime: lastEditedTime,
            writtenAt: writtenAt, ttlHours: ttlHours, callCount: n
        )
    }

    /// True iff this entry has outlived its TTL. Non-positive `ttlHours`
    /// means "never expires" (defensive — a hand-corrupted file should not
    /// flap to stale). Mirrors CachedParent.isExpired.
    public func isExpired(now: Date = Date()) -> Bool {
        guard ttlHours > 0 else { return false }
        let ttl = TimeInterval(ttlHours) * 3600
        return now.timeIntervalSince(writtenAt) > ttl
    }

    /// Canonical id normalization shared by the store + reader: strip
    /// dashes/whitespace, lowercase. Callers may pass either id shape.
    public static func normalize(_ pageId: String) -> String {
        pageId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    /// ISO-8601 with fractional seconds + UTC — strings round-trip
    /// byte-identically across machines. Constructed per call because
    /// `ISO8601DateFormatter` is not `Sendable` (caching as `static let`
    /// would trip strict-concurrency). Mirrors CachedParent.iso8601.
    static var iso8601: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}
