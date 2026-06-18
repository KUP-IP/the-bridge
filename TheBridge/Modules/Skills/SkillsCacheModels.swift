// SkillsCacheModels.swift — Bridge v3.7·1
// TheBridge · Modules · Skills
//
// On-disk shape for the per-parent skills cache that lets the routing
// index, Standing Orders composer, and PKT-907's `surfaceSpecialistsInRows`
// surface Notion-source specialists without paying the cold-start
// N×(getPage + fetchAllSiblingBlocks) cost at connect time.
//
// Wire format (per file `<parent-id>.json` under
// `BridgePaths.applicationSupport(.skillsCache)`):
//
//   {
//     "writtenAt": "2026-05-27T10:00:00Z",   // ISO-8601, UTC
//     "ttlHours":  24,
//     "parentId":  "<32-char Notion uuid>",
//     "parentTitle": "<page title>",
//     "children":  [
//       {
//         "id":      "<32-char Notion uuid>",
//         "title":   "<child title>",
//         "summary": "<one-sentence summary or empty>",
//         "aliases": ["alias-1", "alias-2"]
//       }
//     ]
//   }
//
// Decoding is forwards-tolerant: unknown top-level keys are ignored, and
// missing child fields default to empty values. This protects against
// future writer revisions adding new keys without breaking older readers.

import Foundation

/// One specialist child page, as cached for routing-list enumeration.
public struct CachedSpecialist: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let aliases: [String]

    public init(id: String, title: String, summary: String = "", aliases: [String] = []) {
        self.id = id
        self.title = title
        self.summary = summary
        self.aliases = aliases
    }

    enum CodingKeys: String, CodingKey {
        case id, title, summary, aliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(aliases, forKey: .aliases)
    }
}

/// One cached parent page with its enumerated specialist children.
/// `stale` is a read-time flag set by `SkillsCacheReader` when the
/// `writtenAt` timestamp is older than `ttlHours` — the data is still
/// returned, just labelled stale so callers can choose to surface a
/// "may be stale" annotation rather than block the routing payload.
public struct CachedParent: Codable, Equatable, Sendable {
    public let writtenAt: Date
    public let ttlHours: Int
    public let parentId: String
    public let parentTitle: String
    public let children: [CachedSpecialist]
    /// NOT persisted. Set by the reader after comparing `writtenAt + ttlHours`
    /// against `Date.now`. False on a fresh write; true once the entry has
    /// outlived its TTL but is still being returned as a graceful fallback.
    public var stale: Bool

    public init(
        writtenAt: Date,
        ttlHours: Int,
        parentId: String,
        parentTitle: String,
        children: [CachedSpecialist],
        stale: Bool = false
    ) {
        self.writtenAt = writtenAt
        self.ttlHours = ttlHours
        self.parentId = parentId
        self.parentTitle = parentTitle
        self.children = children
        self.stale = stale
    }

    enum CodingKeys: String, CodingKey {
        case writtenAt, ttlHours, parentId, parentTitle, children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .writtenAt) ?? ""
        self.writtenAt = Self.iso8601.date(from: raw) ?? .distantPast
        self.ttlHours = try c.decodeIfPresent(Int.self, forKey: .ttlHours) ?? 24
        self.parentId = try c.decodeIfPresent(String.self, forKey: .parentId) ?? ""
        self.parentTitle = try c.decodeIfPresent(String.self, forKey: .parentTitle) ?? ""
        self.children = try c.decodeIfPresent([CachedSpecialist].self, forKey: .children) ?? []
        // `stale` is set by the reader after decoding; never persisted.
        self.stale = false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.iso8601.string(from: writtenAt), forKey: .writtenAt)
        try c.encode(ttlHours, forKey: .ttlHours)
        try c.encode(parentId, forKey: .parentId)
        try c.encode(parentTitle, forKey: .parentTitle)
        try c.encode(children, forKey: .children)
        // `stale` is intentionally NOT encoded — it's a derived flag.
    }

    /// ISO-8601 with fractional seconds + UTC. The fixed locale + UTC
    /// posture means strings round-trip byte-identically across machines.
    /// A fresh formatter is constructed per call rather than cached
    /// statically — `ISO8601DateFormatter` is not `Sendable`, so caching
    /// it as a `static let` would trip strict-concurrency. The construction
    /// cost is negligible relative to the disk I/O it accompanies.
    static var iso8601: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    /// True iff this entry has outlived its TTL. Compares against the
    /// supplied `now` (tests inject a fixed clock; production passes
    /// `Date()`). A non-positive `ttlHours` is treated as "never expires"
    /// — defensive: a hand-corrupted file should not flap every entry to
    /// stale.
    public func isExpired(now: Date = Date()) -> Bool {
        guard ttlHours > 0 else { return false }
        let ttl = TimeInterval(ttlHours) * 3600
        return now.timeIntervalSince(writtenAt) > ttl
    }
}
