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
//     "schemaVersion":  1,
//     "pageId":         "<32-hex Notion uuid>",
//     "slug":           "<human/routing identity>",
//     "version":        "<Notion doctrine version>",
//     "status":         "<Notion lifecycle status>",
//     "maturity":       "<Notion maturity>",
//     "markdown":       "<raw body from skillMarkdownString>",
//     "title":          "<page title>",
//     "url":            "<page url>",
//     "properties":     { ... flattened envelope `properties` map ... },
//     "files":          [ { name, kind, notionFileId?, ... } ],  // optional, #276
//     "filesPropertyPresent": true,
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
    /// Cache wire version. The cache is derived and may be rebuilt at any time.
    public let schemaVersion: Int
    /// Normalized 32-hex Notion id (no dashes, lowercased).
    public let pageId: String
    /// Notion-authored human/routing identity fields. These are duplicated
    /// from `properties` deliberately so UUID-addressed readers do not need
    /// to know the current SKILLS database property names.
    public let slug: String
    public let version: String
    public let status: String
    public let maturity: String
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
    /// Persisted `fetch_skill` `files[]` array (envelope objects). Nil on
    /// legacy cache rows written before #276. Empty array +
    /// `filesPropertyPresent` is honest when Files & media exists.
    public let files: Value?
    /// True when a Files & media / Google Drive File property existed at
    /// cache write. Ignored when `files` is nil (legacy).
    public let filesPropertyPresent: Bool
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
        schemaVersion: Int = 1,
        pageId: String,
        slug: String? = nil,
        version: String? = nil,
        status: String? = nil,
        maturity: String? = nil,
        markdown: String,
        title: String,
        url: String,
        properties: Value,
        files: Value? = nil,
        filesPropertyPresent: Bool = false,
        lastEditedTime: String,
        writtenAt: Date,
        ttlHours: Int = 24,
        callCount: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.pageId = Self.normalize(pageId)
        self.slug = slug ?? Self.propertyString("Slug", in: properties)
        self.version = version ?? Self.propertyString("Version", in: properties)
        self.status = status ?? Self.propertyString("Status", in: properties)
        self.maturity = maturity ?? Self.propertyString("Maturity", in: properties)
        self.markdown = markdown
        self.title = title
        self.url = url
        self.properties = properties
        self.files = files
        self.filesPropertyPresent = filesPropertyPresent
        self.lastEditedTime = lastEditedTime
        self.writtenAt = writtenAt
        self.ttlHours = ttlHours
        self.callCount = callCount
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, pageId, slug, version, status, maturity
        case markdown, title, url, properties, files, filesPropertyPresent, lastEditedTime
        case writtenAt, ttlHours, callCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.pageId = Self.normalize(try c.decodeIfPresent(String.self, forKey: .pageId) ?? "")
        self.markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.properties = try c.decodeIfPresent(Value.self, forKey: .properties) ?? .object([:])
        self.files = try c.decodeIfPresent(Value.self, forKey: .files)
        self.filesPropertyPresent = try c.decodeIfPresent(Bool.self, forKey: .filesPropertyPresent) ?? false
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
            ?? Self.propertyString("Slug", in: properties)
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
            ?? Self.propertyString("Version", in: properties)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? Self.propertyString("Status", in: properties)
        self.maturity = try c.decodeIfPresent(String.self, forKey: .maturity)
            ?? Self.propertyString("Maturity", in: properties)
        self.lastEditedTime = try c.decodeIfPresent(String.self, forKey: .lastEditedTime) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .writtenAt) ?? ""
        self.writtenAt = Self.iso8601.date(from: raw) ?? .distantPast
        self.ttlHours = try c.decodeIfPresent(Int.self, forKey: .ttlHours) ?? 24
        self.callCount = try c.decodeIfPresent(Int.self, forKey: .callCount) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(pageId, forKey: .pageId)
        try c.encode(slug, forKey: .slug)
        try c.encode(version, forKey: .version)
        try c.encode(status, forKey: .status)
        try c.encode(maturity, forKey: .maturity)
        try c.encode(markdown, forKey: .markdown)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
        try c.encode(properties, forKey: .properties)
        try c.encodeIfPresent(files, forKey: .files)
        try c.encode(filesPropertyPresent, forKey: .filesPropertyPresent)
        try c.encode(lastEditedTime, forKey: .lastEditedTime)
        try c.encode(Self.iso8601.string(from: writtenAt), forKey: .writtenAt)
        try c.encode(ttlHours, forKey: .ttlHours)
        try c.encode(callCount, forKey: .callCount)
    }

    /// Return a copy with `callCount` set to `n` (writtenAt/markdown kept).
    public func withCallCount(_ n: Int) -> CachedSkillBody {
        CachedSkillBody(
            schemaVersion: schemaVersion, pageId: pageId, slug: slug,
            version: version, status: status, maturity: maturity,
            markdown: markdown, title: title, url: url,
            properties: properties, files: files,
            filesPropertyPresent: filesPropertyPresent,
            lastEditedTime: lastEditedTime,
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

    /// The minimum Notion-primary doctrine contract from PKT-1131. An
    /// incomplete live fetch may still be returned to its caller, but it must
    /// not replace a complete last-known-good cache entry.
    public var hasMinimumDoctrinePayload: Bool {
        !pageId.isEmpty
            && !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !maturity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Canonical dashed UUID for agent-facing envelopes.
    public var uuid: String {
        Self.canonicalUUID(pageId)
    }

    /// Files catalog persisted at cache write. Nil means a pre-#276 row.
    public var restoredFilesCatalog: SkillFileCatalogResult? {
        SkillFileCatalog.fromPersisted(files: files, propertyPresent: filesPropertyPresent)
    }

    public static func canonicalUUID(_ pageId: String) -> String {
        let id = Self.normalize(pageId)
        guard isNotionUUID(id) else { return id }
        let parts = [8, 4, 4, 4, 12]
        var index = id.startIndex
        var out: [String] = []
        for size in parts {
            let end = id.index(index, offsetBy: size)
            out.append(String(id[index..<end]))
            index = end
        }
        return out.joined(separator: "-")
    }

    public static func isNotionUUID(_ pageId: String) -> Bool {
        let id = normalize(pageId)
        return id.count == 32 && id.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102: return true
            default: return false
            }
        }
    }

    /// Canonical id normalization shared by the store + reader: strip
    /// dashes/whitespace, lowercase. Callers may pass either id shape.
    public static func normalize(_ pageId: String) -> String {
        pageId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    /// Case-insensitive scalar lookup over the already-flattened Notion
    /// properties map. Legacy cache files gain the explicit v1 identity on
    /// decode without requiring an eager migration.
    public static func propertyString(_ key: String, in properties: Value) -> String {
        guard case .object(let dict) = properties,
              let value = dict.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
              case .string(let string) = value else {
            return ""
        }
        return string
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
