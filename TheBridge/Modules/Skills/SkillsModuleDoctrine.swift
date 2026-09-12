// Extracted from SkillsModule.swift by PKT-1126. Pure decomposition; behavior unchanged.

import Foundation
import MCP

extension SkillsModule {
    // MARK: - fb-resultsize: section selector (granular / partial fetch)

    /// Pure, network-free markdown section slicer for the `fetch_skill`
    /// `section` selector (fb-resultsize). Large skill bodies blow token
    /// caps and spill to disk; passing `section="<heading>"` returns ONLY
    /// that heading's slice (the heading line through the line before the
    /// next heading at the SAME or a SHALLOWER level), so an agent can do a
    /// granular partial fetch instead of pulling the whole document.
    ///
    /// Matching is case-insensitive and ignores leading `#` markers and
    /// surrounding whitespace, so `section="Setup"` matches `## Setup`,
    /// `### setup`, etc. Order: exact title → unique prefix (heading starts
    /// with the query, e.g. `Thread Handoff` → `Thread Handoff — A · Bridge…`).
    /// Ambiguous prefixes miss (return nil + heading index). The FIRST exact
    /// match wins; unique prefix is only used when exact fails. A nested
    /// subsection (deeper level) is included in its parent's slice; a
    /// sibling or shallower heading terminates it.
    ///
    /// Returns `nil` when no heading matches — callers return a compact
    /// heading index rather than the full body, so a typo cannot trigger the
    /// same oversized response the section selector was meant to avoid.
    public static func extractMarkdownSection(_ markdown: String, section rawSection: String) -> String? {
        let target = rawSection
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !target.isEmpty else { return nil }

        // Split preserving structure; a markdown heading is a line whose
        // first non-space run is one-to-six `#` followed by a space.
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)

        func headingLevel(_ line: String) -> Int? {
            let t = line.drop(while: { $0 == " " })
            var hashes = 0
            for ch in t {
                if ch == "#" { hashes += 1 } else { break }
            }
            guard hashes >= 1, hashes <= 6 else { return nil }
            let after = t.dropFirst(hashes)
            // ATX headings require a space after the hashes ("# Title").
            guard after.first == " " else { return nil }
            return hashes
        }

        func headingText(_ line: String, level: Int) -> String {
            let t = line.drop(while: { $0 == " " })
            return t.dropFirst(level)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }

        // A line that opens/closes a fenced code block (``` or ~~~). `#`
        // lines INSIDE a fence are shell comments, not headings — tracking
        // fence state stops a code comment from being mistaken for a section
        // boundary (or an addressable section).
        func isFence(_ line: String) -> Bool {
            let t = line.drop(while: { $0 == " " })
            return t.hasPrefix("```") || t.hasPrefix("~~~")
        }

        var startIndex: Int? = nil
        var startLevel = 0
        var inFence = false
        var prefixCandidates: [(index: Int, level: Int)] = []
        for (i, line) in lines.enumerated() {
            if isFence(line) { inFence.toggle(); continue }
            guard !inFence, let level = headingLevel(line) else { continue }
            let text = headingText(line, level: level)
            if text == target {
                startIndex = i
                startLevel = level
                break
            }
            // Calibrate 2026-07-23: unique prefix match for long hub handoff titles.
            if text.hasPrefix(target) {
                prefixCandidates.append((i, level))
            }
        }
        if startIndex == nil, prefixCandidates.count == 1 {
            startIndex = prefixCandidates[0].index
            startLevel = prefixCandidates[0].level
        }

        guard let start = startIndex else { return nil }

        var endIndex = lines.count
        if start + 1 < lines.count {
            var endFence = false
            for i in (start + 1)..<lines.count {
                if isFence(lines[i]) { endFence.toggle(); continue }
                if !endFence, let level = headingLevel(lines[i]), level <= startLevel {
                    endIndex = i
                    break
                }
            }
        }

        let slice = lines[start..<endIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return slice
    }

    /// Return addressable markdown headings while ignoring fenced-code lines.
    /// Used for bounded section-miss responses and by notion_page_markdown_read.
    public static func markdownHeadings(_ markdown: String) -> [String] {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var headings: [String] = []
        var inFence = false
        for rawLine in lines {
            let line = rawLine.drop(while: { $0 == " " })
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            var hashes = 0
            for character in line {
                if character == "#" { hashes += 1 } else { break }
            }
            guard (1...6).contains(hashes) else { continue }
            let remainder = line.dropFirst(hashes)
            guard remainder.first == " " else { continue }
            let title = remainder.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { headings.append(title) }
        }
        return headings
    }

    public static func sectionMissMarkdown(requested: String, markdown: String) -> String {
        let headings = markdownHeadings(markdown)
        let available = headings.isEmpty
            ? "(no markdown headings found)"
            : headings.prefix(100).map { "- \($0)" }.joined(separator: "\n")
        return "Section not found: \(requested)\n\nAvailable sections:\n\(available)"
    }

    // MARK: - cmd-w4: /markdown body retrieval + mention resolution

    /// Decode the `markdown` string from a `GET /v1/pages/{id}/markdown`
    /// response (`{ "markdown": String }`). Falls back to the raw UTF-8
    /// bytes when the payload is not the JSON envelope — identical decode
    /// contract to `notion_page_markdown_read` and
    /// `CommandsManager.markdownString(fromMarkdownJSON:)`. Public so the
    /// synthetic-fixture tests exercise the exact production decode.
    public static func skillMarkdownString(fromMarkdownJSON data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return (json["markdown"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
    }

    /// String overload of `skillMarkdownString(fromMarkdownJSON:)`.
    public static func skillMarkdownString(fromMarkdownJSON jsonString: String) -> String {
        skillMarkdownString(fromMarkdownJSON: Data(jsonString.utf8))
    }

    // MARK: - body-cache: stale-while-revalidate

    /// Background freshness check for a cached skill body. Runs DETACHED
    /// off the `fetch_skill` return path (every 5th cache hit), so it never
    /// adds latency to the served result.
    ///
    /// Flow: `getPage(pageId)` → compare `last_edited_time` to the cached
    /// value. If UNCHANGED → no-op (the cached body is still fresh). If
    /// CHANGED → fetch `getPageMarkdown` + rewrite the body cache, then
    /// clear the in-memory result cache so the next call rebuilds from the
    /// new body. A 404 / page-not-found → evict the entry (the page is
    /// gone). All failures degrade to no-op — the cache is a hint.
    static func revalidateBodyCache(
        pageId: String,
        knownLastEdited: String,
        store: SkillBodyCacheStore,
        memCache: SkillCache
    ) async {
        guard let client = try? NotionClient() else { return }
        do {
            let refreshed = try await SkillBodyCacheStore.fetchBody(pageId: pageId, client: client)
            guard refreshed.hasMinimumDoctrinePayload else { return }
            // Same edit timestamp → body unchanged; leave the cache as-is
            // (do NOT rewrite — a rewrite would needlessly bump writtenAt
            // and reset the callCount cadence).
            guard refreshed.lastEditedTime != knownLastEdited else { return }
            try? await store.write(refreshed)
            // Body changed: invalidate the in-memory result cache so the
            // next fetch_skill rebuilds from the new body. (Coarse clear —
            // the in-memory cache is keyed by a composite string, not page
            // id; a full clear is the safe, cheap invalidation.)
            await memCache.clear()
        } catch let error as NotionClientError {
            if case .httpError(let code, _) = error, code == 404 {
                await store.evict(pageId: pageId)
            }
        } catch {
            // Degrade silently — a revalidation failure must never disturb
            // the served path; the stale body remains usable.
        }
    }

    /// Pure, network-free builder for the `fetch_skill` return envelope.
    ///
    /// cmd-w4 behavior delta: `content` is now the *server-rendered*
    /// page markdown (headings / lists / code fences / tables preserved)
    /// run through the shared `MentionResolver`, instead of the old
    /// depth-first block walk joined as bare `extractPlainText` lines
    /// (which flattened structure and rendered `<mention-page>` as plain
    /// title text with no link).
    ///
    /// The envelope SHAPE is preserved byte-for-byte for existing MCP
    /// consumers — same keys (`name`, `title`, `url`, `blockCount`,
    /// `truncated`, `content`, the merged skill metadata, optional
    /// `truncationReason`) in the same value types. `blockCount` no longer
    /// maps to a Notion block count (the /markdown path returns one
    /// document, not a block tree); it is kept for shape stability and
    /// reported honestly as the number of non-empty markdown lines.
    /// `truncated` is always `false` on this path (one server call, no
    /// pagination cap) — `truncationReason` is therefore omitted.
    ///
    /// - Parameters:
    ///   - skill: the resolved skill config (supplies `name` + metadata).
    ///   - title: page title for the envelope (from `getPage` properties).
    ///   - url: page url for the envelope (from `getPage`).
    ///   - markdownJSONOrText: the raw `/markdown` body — either the JSON
    ///     envelope or already-extracted markdown; decoded defensively.
    ///   - titleLookup: injected `<mention-page>` title resolver
    ///     (unresolved → `[link](url)`; never throws, never drops).
    ///   - pageProperties: the verbatim `getPage` `properties` blob
    ///     (already fetched for the title) — flattened into the new,
    ///     additive `properties` envelope key. Empty / non-DB page → an
    ///     empty map (`"properties": {}`), never an error. ALL other
    ///     envelope keys + value types are byte-for-byte unchanged.
    static func buildSkillResult(
        skill: SkillConfig,
        title: String,
        url: String,
        markdownJSONOrText: String,
        titleLookup: MentionResolver.TitleLookup,
        pageProperties: [String: Any] = [:]
    ) async -> Value {
        // cu-sa: flatten the verbatim getPage properties into the additive
        // `properties` envelope key, then hand to the shared builder.
        return await buildSkillResult(
            skill: skill,
            title: title,
            url: url,
            markdownJSONOrText: markdownJSONOrText,
            titleLookup: titleLookup,
            flattenedProperties: .object(flattenProperties(pageProperties)),
            filesCatalog: SkillFileCatalog.fromRawPageProperties(
                pageProperties,
                skillUUID: skill.notionPageId
            )
        )
    }

    /// Shared envelope builder taking the ALREADY-FLATTENED `properties`
    /// map (the `.object(...)` form `flattenProperties` produces) instead
    /// of the verbatim getPage blob. The network path flattens then calls
    /// this; the offline body-cache HIT path passes the pre-flattened
    /// `properties` straight off the `CachedSkillBody` (no re-flatten, and
    /// — critically — no `getPage` blob to re-flatten). The resulting
    /// envelope is byte-identical to the network path for the same input
    /// because the cache PERSISTED exactly `flattenProperties(props)` at
    /// miss time.
    static func buildSkillResult(
        skill: SkillConfig,
        title: String,
        url: String,
        markdownJSONOrText: String,
        titleLookup: MentionResolver.TitleLookup,
        flattenedProperties: Value,
        filesCatalog: SkillFileCatalogResult? = nil
    ) async -> Value {
        let markdown = looksLikeMarkdownJSON(markdownJSONOrText)
            ? skillMarkdownString(fromMarkdownJSON: markdownJSONOrText)
            : markdownJSONOrText

        let resolved = await MentionResolver.resolve(
            markdown: markdown,
            titleLookup: titleLookup
        )

        // Honest non-block "blockCount": count non-empty lines so an
        // empty body still reports 0 and the envelope key stays stable.
        let nonEmptyLineCount = resolved
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .reduce(into: 0) { acc, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { acc += 1 }
            }

        let contentValue: String = resolved.isEmpty ? "(no content)" : resolved

        var resultObj: [String: Value] = [
            "name": .string(skill.name),
            "title": .string(title),
            "url": .string(url),
            "blockCount": .int(nonEmptyLineCount),
            "truncated": .bool(false),
            "content": .string(contentValue)
        ]
        resultObj.merge(mcpMetadataObject(skill)) { _, new in new }
        // cu-sa: additive — a single NEW `properties` key. On the network
        // path this is `flattenProperties(getPage.properties)`; on the
        // cache-hit path it is the verbatim persisted flatten. No
        // pre-existing key is touched.
        resultObj["properties"] = flattenedProperties
        // #254: files catalog when a Files & media (or Google Drive File)
        // property exists — empty array is honest; omit is not. assetRoot
        // is included only when prose names a Mac folder.
        let catalog = filesCatalog ?? SkillFileCatalog.fromFlattenedProperties(
            flattenedProperties,
            skillUUID: skill.notionPageId
        )
        if catalog.propertyPresent {
            resultObj["files"] = .array(catalog.files.map(\.envelopeValue))
        }
        if let root = SkillFileCatalog.assetRoot(fromMarkdown: resolved) {
            resultObj["assetRoot"] = .string(root)
        }
        return .object(resultObj)
    }

    // MARK: - body-cache: offline plain-hit envelope (ZERO network)

    /// Build the `fetch_skill` return envelope ENTIRELY from a cached body,
    /// with NO NotionClient construction and NO network call. Used only for
    /// a PLAIN request (no path, no intent, no section, no depth-guard): on
    /// such a request the live path's `dispatchNotionSpecialist` takes its
    /// bare-parent fast path (no sibling enumeration → no `routingFooter`,
    /// no annotation keys), so the network plain envelope is exactly
    /// `buildSkillResult(...)` with no extra keys. This reproduces that
    /// envelope from `CachedSkillBody` so the two are byte-identical for the
    /// same input — modulo `<mention-page>` resolution, which depends on the
    /// injected `titleLookup` (the offline default resolves nothing → the
    /// shared `[link](url)` fallback, same as the network path when its own
    /// per-fetch lookup misses).
    ///
    /// The cached `body.properties` is the verbatim flatten persisted at
    /// miss time (`.object(flattenProperties(getPageProperties))`), so it is
    /// passed straight through — never re-flattened — and the title/url come
    /// from the cache too. The result is then run through `annotateEnvelope`
    /// with an EMPTY `SpecialistDispatch` purely to prove equivalence with
    /// the live plain path: for a plain request that dispatch contributes
    /// no keys, so this is a structural no-op that keeps the two code paths
    /// provably aligned.
    ///
    /// `titleLookup` defaults to a network-free resolver (always nil) so an
    /// OFFLINE plain hit succeeds even when NotionClient construction would
    /// throw. Callers wanting live mention enrichment may inject a lookup,
    /// but the plain-hit handler path uses the offline default to stay
    /// strictly zero-network.
    static func buildPlainCacheHitEnvelope(
        skill: SkillConfig,
        cachedBody: CachedSkillBody,
        titleLookup: @escaping MentionResolver.TitleLookup = { _ in nil }
    ) async -> Value {
        let envelope = await buildSkillResult(
            skill: skill,
            title: cachedBody.title,
            url: cachedBody.url,
            markdownJSONOrText: cachedBody.markdown,
            titleLookup: titleLookup,
            flattenedProperties: cachedBody.properties
        )
        let identified = annotateDoctrineIdentity(
            envelope,
            pageId: cachedBody.pageId,
            flattenedProperties: cachedBody.properties,
            cachedIdentity: cachedBody
        )
        // Plain request → empty dispatch (bare-parent fast path shape):
        // no resolvedSpecialist, no annotation, no siblings → adds nothing.
        let emptyDispatch = SpecialistDispatch(
            resolvedSpecialist: nil,
            resolvedPath: nil,
            annotation: nil,
            matchScore: nil,
            matchReason: nil
        )
        return annotateEnvelope(identified, parentName: skill.name, dispatch: emptyDispatch)
    }

    /// Add the stable Notion-primary identity contract to a fetched doctrine
    /// envelope. `content` remains the full body; duplicating it under a
    /// second key would double large MCP payloads.
    static func annotateDoctrineIdentity(
        _ value: Value,
        pageId: String,
        flattenedProperties: Value,
        cachedIdentity: CachedSkillBody? = nil
    ) -> Value {
        guard case .object(var dict) = value else { return value }
        let version = cachedIdentity?.version ?? CachedSkillBody.propertyString("Version", in: flattenedProperties)
        let status = cachedIdentity?.status ?? CachedSkillBody.propertyString("Status", in: flattenedProperties)
        let maturity = cachedIdentity?.maturity ?? CachedSkillBody.propertyString("Maturity", in: flattenedProperties)
        dict["uuid"] = .string(CachedSkillBody.canonicalUUID(pageId))
        dict["slug"] = .string(cachedIdentity?.slug ?? CachedSkillBody.propertyString("Slug", in: flattenedProperties))
        dict["version"] = .string(version)
        dict["status"] = .string(status)
        dict["maturity"] = .string(maturity)
        dict["authoritativeMetadataSource"] = .string("notion_properties")

        if case .string(let content) = dict["content"] {
            let propertyValues = ["version": version, "status": status, "maturity": maturity]
            var fields: [Value] = []
            for field in ["version", "status", "maturity"] {
                guard let bodyValue = bodyMetadataValue(field: field, markdown: content),
                      let propertyValue = propertyValues[field],
                      !propertyValue.isEmpty,
                      bodyValue.caseInsensitiveCompare(propertyValue) != .orderedSame else { continue }
                fields.append(.object([
                    "field": .string(field),
                    "body": .string(bodyValue),
                    "property": .string(propertyValue)
                ]))
            }
            if !fields.isEmpty {
                dict["metadataDrift"] = .object([
                    "detected": .bool(true),
                    "authoritativeSource": .string("notion_properties"),
                    "fields": .array(fields),
                    "warning": .string("Skill body metadata differs from Notion properties; routing uses the property-backed envelope values.")
                ])
            }
        }
        return .object(dict)
    }

    /// Extract a simple `Version:`, `Status:`, or `Maturity:` declaration
    /// from the first part of a skill body. This is diagnostic only: Notion
    /// properties remain the routing-authoritative metadata source.
    public static func bodyMetadataValue(field: String, markdown: String) -> String? {
        let wanted = field.lowercased() + ":"
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix(120) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = line.first, "->*#` ".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            guard line.lowercased().hasPrefix(wanted) else { continue }
            let value = String(line.dropFirst(wanted.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Public, network-free entry point mirroring `buildSkillResult` but
    /// taking primitives instead of the private `SkillConfig`, so the
    /// synthetic-fixture suite (separate test target) drives the EXACT
    /// production envelope path: decode → MentionResolver → envelope.
    /// `summary` / `triggerPhrases` / `antiTriggerPhrases` reproduce the
    /// merged skill-metadata block of the live result.
    ///
    /// cu-sa: `pageProperties` drives the new `properties` envelope key
    /// through the EXACT production builder with zero network — pass the
    /// verbatim shape `getPage` returns under `pageJSON["properties"]`.
    /// Default `[:]` keeps every pre-cu-sa test calling this wrapper
    /// byte-for-byte unchanged except for the additive `"properties": {}`.
    public static func buildSkillResultForTesting(
        name: String,
        title: String,
        url: String,
        markdownJSONOrText: String,
        summary: String = "",
        triggerPhrases: [String] = [],
        antiTriggerPhrases: [String] = [],
        pageId: String = "00000000000000000000000000000000",
        pageProperties: [String: Any] = [:],
        titleLookup: @escaping MentionResolver.TitleLookup
    ) async -> Value {
        let cfg = SkillConfig(
            name: name,
            notionPageId: pageId,
            enabled: true,
            visibility: .standard,
            summary: summary,
            triggerPhrases: triggerPhrases,
            antiTriggerPhrases: antiTriggerPhrases
        )
        let flattened: Value = .object(flattenProperties(pageProperties))
        let result = await buildSkillResult(
            skill: cfg,
            title: title,
            url: url,
            markdownJSONOrText: markdownJSONOrText,
            titleLookup: titleLookup,
            pageProperties: pageProperties
        )
        return annotateDoctrineIdentity(
            result,
            pageId: pageId,
            flattenedProperties: flattened
        )
    }

    /// Public, network-free entry point exercising the PRODUCTION
    /// `buildPlainCacheHitEnvelope` from the cross-target test suite (which
    /// only sees the public surface, not the internal `SkillConfig`). Builds
    /// the SkillConfig from primitives — matching `buildSkillResultForTesting`
    /// — then runs the EXACT offline plain-hit builder the handler uses. No
    /// NotionClient is constructed or awaited anywhere on this path, so a
    /// passing assertion proves the warm plain hit is zero-network.
    public static func buildPlainCacheHitEnvelopeForTesting(
        name: String,
        cachedBody: CachedSkillBody,
        summary: String = "",
        triggerPhrases: [String] = [],
        antiTriggerPhrases: [String] = [],
        titleLookup: @escaping MentionResolver.TitleLookup = { _ in nil }
    ) async -> Value {
        let cfg = SkillConfig(
            name: name,
            notionPageId: "00000000000000000000000000000000",
            enabled: true,
            visibility: .standard,
            summary: summary,
            triggerPhrases: triggerPhrases,
            antiTriggerPhrases: antiTriggerPhrases
        )
        return await buildPlainCacheHitEnvelope(
            skill: cfg,
            cachedBody: cachedBody,
            titleLookup: titleLookup
        )
    }

    /// Heuristic: is this the `/markdown` JSON envelope vs. already-
    /// extracted markdown? Conservative — only true when it parses to an
    /// object carrying a `markdown` key (mirrors CommandsManager).
    static func looksLikeMarkdownJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any]
        else { return false }
        return obj["markdown"] != nil
    }

    /// Build the injectable `<mention-page>` title resolver used by
    /// `fetch_skill`. Mirrors the cmd-w2 cached-lookup pattern: one Notion
    /// `getPage` per distinct page URL, title via `NotionJSON.extractTitle`,
    /// failures degrade to `nil` (→ `MentionResolver` emits `[link](url)`).
    /// Never throws.
    static func makeSkillMentionTitleLookup() -> MentionResolver.TitleLookup {
        // Per-fetch cache: one network lookup per distinct page URL.
        let cache = MentionTitleCache()
        return { pageURL in
            if let hit = await cache.get(pageURL) { return hit }
            guard let pid = Self.pageIdFromMentionURL(pageURL) else {
                await cache.set(pageURL, title: nil)
                return nil
            }
            guard let client = try? NotionClient(),
                  let data = try? await client.getPage(pageId: pid),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = json["properties"] as? [String: Any] else {
                await cache.set(pageURL, title: nil)
                return nil
            }
            let t = NotionJSON.extractTitle(from: props)
            let resolved = (t == "Untitled" || t.isEmpty) ? nil : t
            await cache.set(pageURL, title: resolved)
            return resolved
        }
    }

    /// Extract a 32-hex page id from a Notion mention `url=` value
    /// (`https://www.notion.so/<slug-><id>` or a bare id). Returns nil
    /// when no plausible id is present (caller → `[link](url)`).
    static func pageIdFromMentionURL(_ url: String) -> String? {
        let hexset = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        // Last 32-hex run in the string is the page id for notion.so URLs.
        let scalars = url.unicodeScalars
        var run = ""
        var best = ""
        for sc in scalars {
            if hexset.contains(sc) {
                run.unicodeScalars.append(sc)
                if run.count >= 32 { best = String(run.suffix(32)) }
            } else {
                run = ""
            }
        }
        return best.count == 32 ? best : nil
    }

    static func skillRowFields(_ s: SkillConfig) -> [String: Value] {
        var row = mcpMetadataObject(s)
        row["name"] = .string(s.name)
        row["notionPageId"] = .string(s.notionPageId)
        row["platform"] = .string(s.platform.rawValue)
        if let url = s.url {
            row["url"] = .string(url)
        }
        return row
    }

    static func parseStringArrayValue(_ v: Value) -> [String] {
        switch v {
        case .array(let arr):
            return arr.compactMap { item in
                if case .string(let s) = item { return s }
                return nil
            }
        case .string(let s):
            return s.split(whereSeparator: \.isNewline).map { String($0) }
        default:
            return []
        }
    }

    /// Look up a skill from UserDefaults by name with fuzzy matching (v1.7.0, F5).
    /// Tries: exact (case-insensitive) > normalized (strip "sk ", space/hyphen swap)
    /// > unique cached slug alias > substring.
    ///
    /// Slug alias (PKT-FETCH-SKILL-SLUG-ALIAS): a case-insensitive exact match
    /// against a locally cached `CachedSkillBody.slug` that maps uniquely to one
    /// configured Notion skill (same page id). Duplicate slugs and cache-only
    /// hits fail closed. Display-name lookup is unchanged.
    static func lookupSkill(named name: String) async -> SkillConfig? {
        guard let data = UserDefaults.standard.data(forKey: BridgeDefaults.skills),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return nil
        }
        let input = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 1. Exact case-insensitive
        if let exact = skills.first(where: { $0.name.lowercased() == input }) {
            return exact
        }
        // 2. Normalized: strip "sk " prefix, swap spaces and hyphens
        let stripped = input.hasPrefix("sk ") ? String(input.dropFirst(3)) : input
        let variants = [stripped, stripped.replacingOccurrences(of: " ", with: "-"), stripped.replacingOccurrences(of: "-", with: " ")]
        for v in variants {
            if let match = skills.first(where: { $0.name.lowercased() == v }) {
                return match
            }
        }
        // 3. Unique slug → configured skill (same Notion UUID). Before
        // substring so a slug cannot be stolen by a unique name-contains hit.
        if let aliased = await lookupSkillByUniqueCachedSlug(stripped, skills: skills) {
            return aliased
        }
        // 4. Substring: input contained in skill name or vice versa (unique match only)
        let subs = skills.filter {
            $0.name.lowercased().contains(stripped) || stripped.contains($0.name.lowercased())
        }
        if subs.count == 1 { return subs[0] }
        return nil
    }

    /// Test hook: returns the configured display name + page id, or nil.
    public static func lookupSkillNamedForTesting(_ name: String) async -> (name: String, pageId: String)? {
        guard let skill = await lookupSkill(named: name) else { return nil }
        return (skill.name, skill.notionPageId)
    }

    /// Unique case-insensitive slug from the on-disk body cache, bound to
    /// exactly one configured SkillConfig by normalized Notion page id.
    private static func lookupSkillByUniqueCachedSlug(
        _ stripped: String,
        skills: [SkillConfig]
    ) async -> SkillConfig? {
        let wanted = stripped.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let hits = await SkillBodyCacheStore.shared.readAll().filter { body in
            body.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
        guard hits.count == 1 else { return nil }
        let pageId = CachedSkillBody.normalize(hits[0].pageId)
        let configs = skills.filter { CachedSkillBody.normalize($0.notionPageId) == pageId }
        guard configs.count == 1 else { return nil }
        return configs[0]
    }

    /// Exact UUID resolver for PKT-1131. Unlike the human-facing name path,
    /// this never fuzzy-matches: one configured Notion page id maps to one
    /// doctrine record. File-source skills have no Notion UUID and are
    /// intentionally excluded.
    static func lookupSkill(pageId: String) -> SkillConfig? {
        let wanted = CachedSkillBody.normalize(pageId)
        guard CachedSkillBody.isNotionUUID(wanted) else { return nil }
        return readAllSkills().first { skill in
            CachedSkillBody.normalize(skill.notionPageId) == wanted
        }
    }

    /// Resolve a curated specialist UUID from the existing routing cache.
    /// The cache is derived from configured parents and cannot widen this
    /// tool into an arbitrary Notion page reader.
    static func lookupCachedSpecialist(pageId: String) async -> SkillConfig? {
        let wanted = CachedSkillBody.normalize(pageId)
        guard CachedSkillBody.isNotionUUID(wanted) else { return nil }
        for parent in await SkillsCacheReader.shared.readAll() {
            if let child = parent.children.first(where: { CachedSkillBody.normalize($0.id) == wanted }) {
                return SkillConfig(
                    name: child.title,
                    notionPageId: child.id,
                    enabled: true,
                    visibility: .standard,
                    summary: child.summary
                )
            }
        }
        return nil
    }

    /// List all configured skill names.
    static func listAvailableSkillNames() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: BridgeDefaults.skills),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return []
        }
        return skills.filter(\.enabled).map(\.name) // Only enabled skills
    }

    /// C1: Find close matches for a skill name using edit distance.
    static func closestSkillMatches(for input: String, maxResults: Int = 3) -> [String] {
        let available = listAvailableSkillNames()
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped = normalized.hasPrefix("sk ") ? String(normalized.dropFirst(3)) : normalized

        // Score each skill by edit distance to input variants
        let scored = available.map { skill -> (String, Int) in
            let skillLow = skill.lowercased()
            let dist = min(
                editDistance(skillLow, stripped),
                editDistance(skillLow, stripped.replacingOccurrences(of: " ", with: "-")),
                editDistance(skillLow, stripped.replacingOccurrences(of: "-", with: " "))
            )
            return (skill, dist)
        }
        .filter { $0.1 <= max(3, $0.0.count / 2) }  // Only reasonably close matches
        .sorted { $0.1 < $1.1 }

        return Array(scored.prefix(maxResults).map { $0.0 })
    }

    /// Simple Levenshtein edit distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : 1 + min(prev, dp[j], dp[j-1])
                prev = temp
            }
        }
        return dp[n]
    }

}
