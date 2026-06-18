// CommandsManager.swift — cmd-w2 (Commands data layer)
// TheBridge · Modules · Commands
//
// DATA LAYER ONLY. No UI, no hotkey, no MCP tool registration here — that
// is later-slice work. This file owns:
//   • the documented Commands data-source contract (mirrors how SKILLS
//     DS works — see docs/operator/commands-datasource.md),
//   • a `Command` model (Snippet-shaped, per brief item 0),
//   • an in-memory TTL `CommandCache` actor (cloned from SkillsModule's
//     SkillCache; extended with offline-fallback semantics),
//   • `CommandsManager`: fetches a command page BODY via the /markdown
//     path through an INJECTABLE fetcher, runs the body through the
//     shared MentionResolver, caches it, and falls back to the last good
//     cache when a refresh fails (offline-fallback).
//
// ── Commands data-source contract ───────────────────────────────────
// The operator will create a Notion data source (NOT created here — no
// live Notion calls). Schema, mirroring the proven SKILLS-DS pattern
// (config rows in app storage → page body fetched on demand):
//
//   Property        | Notion type | Required | Maps to Command field
//   ----------------|-------------|----------|----------------------
//   Name            | title       | yes      | name
//   Abbreviation    | rich_text   | yes      | abbreviation (unique trigger)
//   Group           | select      | no       | group (default "General")
//   Tags            | multi_select| no       | tags
//   (page body)     | blocks      | yes      | text (the command body —
//                   |             |          |  fetched via /markdown,
//                   |             |          |  mention tags resolved)
//
// The BODY of the command lives in the page content (blocks), exactly
// like a SKILL page body. It is retrieved with
// `NotionClient.getPageMarkdown(pageId:)` → JSON `{ "markdown": String }`
// and then passed through `MentionResolver` so Notion `<mention-*/>`
// tags become portable Markdown. Real-DS query/validation is a deferred
// operator dependency (out of scope for cmd-w2): this layer is verified
// entirely against SYNTHETIC recorded `/markdown` JSON via the injectable
// fetcher.

import Foundation

// MARK: - Model (Snippet-shaped per brief item 0)

/// One resolved command. Shares the Snippet field shape (`id, name,
/// text, tags, source, created, updated`) plus command-specific
/// `abbreviation` / `group`. `text` is the mention-resolved page body.
public struct Command: Codable, Sendable, Equatable {
    public let id: String              // Notion page id (dashed UUID)
    public var name: String
    public var abbreviation: String    // unique trigger / short form
    public var group: String
    public var text: String            // mention-resolved markdown body
    public var tags: [String]
    public let created: Date
    public var updated: Date
    public var source: String          // "notion" | "synthetic" | "manual"

    public init(
        id: String,
        name: String,
        abbreviation: String,
        group: String = "General",
        text: String,
        tags: [String] = [],
        created: Date = Date(),
        updated: Date = Date(),
        source: String = "notion"
    ) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
        self.group = group
        self.text = text
        self.tags = tags
        self.created = created
        self.updated = updated
        self.source = source
    }
}

// MARK: - Errors

public enum CommandsFetchError: Error, Sendable, Equatable {
    /// Fetcher failed AND there was no prior cache to fall back to.
    case unavailable(String)
    /// Page id failed validation before any fetch was attempted.
    case invalidPageId(String)
}

// MARK: - Cache (cloned from SkillsModule.SkillCache, + offline-fallback)

/// Cached command-body entry. Same shape as SkillsModule's `CachedSkill`
/// (content + fetchedAt + TTL), extended so an EXPIRED entry can still be
/// served as an offline fallback when a refresh fails.
struct CachedCommand: Sendable, Equatable {
    let body: String
    let fetchedAt: Date

    /// 10-minute TTL — identical to SkillCache.
    func isExpired(now: Date = Date(), ttl: TimeInterval = CommandCache.ttlSeconds) -> Bool {
        now.timeIntervalSince(fetchedAt) > ttl
    }
}

/// Thread-safe TTL cache for fetched command bodies. In-memory by design
/// (justification, per brief item 4): offline-fallback requires KEEPING
/// expired entries to serve when a refresh fails — the SnippetStore disk
/// substrate would add crash-safe atomic-rename surface that is
/// irrelevant to a process-lifetime TTL cache and would couple this
/// layer to a disk path. The SkillCache it clones is likewise pure
/// in-memory. Persistence is therefore intentionally NOT taken.
public actor CommandCache {

    /// 10-minute TTL (mirrors SkillCache's 600s).
    public static let ttlSeconds: TimeInterval = 600

    private var cache: [String: CachedCommand] = [:]

    public init() {}

    /// Fresh (non-expired) hit only — nil on miss or expiry. Mirrors
    /// `SkillCache.get` (which also evicts on expiry); here we DO NOT
    /// evict on expiry so `lastKnown` can still offline-fallback.
    public func get(_ key: String, now: Date = Date()) -> String? {
        guard let e = cache[key], !e.isExpired(now: now) else { return nil }
        return e.body
    }

    /// Any entry regardless of TTL (offline-fallback source).
    public func lastKnown(_ key: String) -> String? {
        cache[key]?.body
    }

    public func set(_ key: String, body: String, now: Date = Date()) {
        cache[key] = CachedCommand(body: body, fetchedAt: now)
    }

    /// Manual resync entry point — drop one key (next fetch is forced
    /// live). Mirrors the `manage_skill … cache.clear()` resync hook.
    public func invalidate(_ key: String) {
        cache.removeValue(forKey: key)
    }

    /// Manual full resync — drop all (mirrors `SkillCache.clear`).
    public func clear() {
        cache.removeAll()
    }

    /// Test/diagnostic: entry count.
    public func count() -> Int { cache.count }
}

// MARK: - CommandsManager

/// Fetches command page bodies via the `/markdown` path, resolves Notion
/// mention tags, and caches with TTL + offline-fallback.
///
/// The fetcher and the mention title-lookup are BOTH injectable so tests
/// drive entirely off synthetic fixtures with zero network. The default
/// fetcher uses a live `NotionClient`; the default title-lookup returns
/// nil (→ `[link](U)`), because resolving page titles requires a Notion
/// call that the data layer does not own — a later slice supplies one.
public actor CommandsManager {

    /// Returns the RAW `/markdown` JSON body string for a page id, i.e.
    /// the bytes of `GET /v1/pages/{id}/markdown`
    /// (`{ "markdown": "..." }`). Injected so tests pass recorded JSON.
    public typealias BodyFetcher = @Sendable (_ pageId: String) async throws -> String

    private let fetcher: BodyFetcher
    private let titleLookup: MentionResolver.TitleLookup
    private let cache: CommandCache

    /// - Parameters:
    ///   - cache: shared `CommandCache` (default: a fresh in-memory one).
    ///   - titleLookup: page-title resolver for `<mention-page>` (default:
    ///     always-nil → mentions render as `[link](U)`).
    ///   - fetcher: raw `/markdown` JSON fetcher. Default uses a live
    ///     `NotionClient` — tests MUST inject a synthetic fetcher.
    public init(
        cache: CommandCache = CommandCache(),
        titleLookup: @escaping MentionResolver.TitleLookup = { _ in nil },
        fetcher: BodyFetcher? = nil
    ) {
        self.cache = cache
        self.titleLookup = titleLookup
        self.fetcher = fetcher ?? { pageId in
            let client = try NotionClient()
            let data = try await client.getPageMarkdown(pageId: pageId)
            return Self.markdownString(fromMarkdownJSON: data)
        }
    }

    /// Extracts the `markdown` string from a `/markdown` JSON `Data`
    /// blob, mirroring NotionModule's notion_page_markdown_read decode
    /// (json["markdown"] → fallback to raw UTF-8). Public for tests.
    public static func markdownString(fromMarkdownJSON data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return (json["markdown"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
    }

    /// Convenience: same decode from a JSON string.
    public static func markdownString(fromMarkdownJSON jsonString: String) -> String {
        markdownString(fromMarkdownJSON: Data(jsonString.utf8))
    }

    // MARK: Fetch + resolve + cache

    /// Fetch a command body for `pageId`, mention-resolved.
    ///
    /// Flow: validate id → cache hit (fresh) returns immediately → else
    /// fetch via injected fetcher → MentionResolver → cache → return. On
    /// fetcher failure, fall back to the last-known cached body
    /// (offline-fallback); only if there is none do we surface
    /// `.unavailable`.
    ///
    /// - Parameter forceResync: skip the fresh-cache check and force a
    ///   live fetch (the manual resync entry point). Offline-fallback
    ///   still applies if that live fetch fails.
    @discardableResult
    public func body(forPageId rawPageId: String, forceResync: Bool = false) async throws -> String {
        let normalized: String
        switch NotionPageRef.normalizedPageId(from: rawPageId) {
        case .success(let n): normalized = n
        case .failure(let e): throw CommandsFetchError.invalidPageId(e.message)
        }
        let key = normalized

        if !forceResync, let hit = await cache.get(key) {
            return hit
        }
        // NOTE: a forceResync forces a LIVE fetch but must NOT destroy the
        // existing entry up-front — otherwise a failed live fetch would
        // have nothing to offline-fall-back to. The entry is overwritten
        // only on a *successful* fetch below; `resync(pageId:)` /
        // `resyncAll()` are the explicit eviction entry points.

        do {
            let rawJSONOrMarkdown = try await fetcher(normalized)
            // The fetcher returns the raw /markdown body string. It may
            // be the JSON envelope or already-extracted markdown — decode
            // defensively (same contract as notion_page_markdown_read).
            let markdown = Self.looksLikeMarkdownJSON(rawJSONOrMarkdown)
                ? Self.markdownString(fromMarkdownJSON: rawJSONOrMarkdown)
                : rawJSONOrMarkdown
            let resolved = await MentionResolver.resolve(markdown: markdown, titleLookup: titleLookup)
            await cache.set(key, body: resolved)
            return resolved
        } catch {
            // Offline-fallback: serve the last good body if we have one.
            if let stale = await cache.lastKnown(key) {
                return stale
            }
            throw CommandsFetchError.unavailable(
                "fetch failed and no cached body for page \(normalized): \(error)"
            )
        }
    }

    /// Build a full `Command` from synthetic/known metadata + a fetched,
    /// resolved body. (Metadata comes from the DS row; the body comes
    /// from the page — same split as a SKILL.)
    public func command(
        pageId: String,
        name: String,
        abbreviation: String,
        group: String = "General",
        tags: [String] = [],
        source: String = "notion",
        forceResync: Bool = false
    ) async throws -> Command {
        let resolvedBody = try await body(forPageId: pageId, forceResync: forceResync)
        let normalized = (try? NotionPageRef.normalizedPageId(from: pageId).get()) ?? pageId
        return Command(
            id: normalized,
            name: name,
            abbreviation: abbreviation,
            group: group,
            text: resolvedBody,
            tags: tags,
            source: source
        )
    }

    /// Manual resync of a single page (drops its cache entry; the next
    /// `body(...)` is forced live). Mirrors the skills resync hook.
    public func resync(pageId: String) async {
        guard let n = try? NotionPageRef.normalizedPageId(from: pageId).get() else { return }
        await cache.invalidate(n)
    }

    /// Manual full resync (drop all cached bodies).
    public func resyncAll() async {
        await cache.clear()
    }

    /// Heuristic: is this string the `/markdown` JSON envelope (vs.
    /// already-extracted markdown)? Conservative — only treats it as
    /// JSON when it parses to an object carrying a "markdown" key.
    private static func looksLikeMarkdownJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any]
        else { return false }
        return obj["markdown"] != nil
    }
}
