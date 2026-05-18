// MentionResolver.swift — cmd-w2 (Commands data layer)
// NotionBridge · Modules · Commands
//
// Shared, standalone transform of Notion `/markdown` mention tags into
// portable Markdown. Designed to be reusable: Commands wires it here; a
// later slice may reuse it for fetch_skill body rendering.
//
// Verified renderings emitted by GET /v1/pages/{id}/markdown (Notion API
// 2026-03-11), per the cmd-w2 brief:
//   page → <mention-page url="https://www.notion.so/<id>"/>
//   user → <mention-user url="user://<id>"/>
//
// Rule:
//   <mention-page url=U> → [Title](U), Title resolved via an injectable,
//                          cached title-lookup (one lookup per distinct
//                          page URL). If the title can't be resolved →
//                          [link](U).
//   Any other mention subtype (user / date / database / inline-link / an
//   unrecognized `<mention-*/>` tag) → [link](U) when a url= is present,
//   otherwise the original tag text is passed through verbatim.
//
// Invariants (asserted by CommandsDataTests):
//   • NEVER drops content — unmatched / unknown input survives byte-for-byte.
//   • NEVER throws — there is no `throws` on the API surface; lookup
//     failures degrade to [link](U), they do not propagate.
//
// SUBTYPE-MODELLING HONESTY (see brief return item 4): only the page and
// user tag shapes are stated as VERIFIED in the brief. date / database /
// inline-link tag shapes are modelled from the spec ("unknown subtype")
// — this resolver intentionally treats every non-page `<mention-*/>` (and
// any unknown attribute layout) through the same safe [link](U) /
// pass-through path, so it is correct regardless of the exact wire shape
// of those unverified subtypes.

import Foundation

/// Stateless, reusable Notion-mention → Markdown transformer.
///
/// Usage:
/// ```
/// let out = await MentionResolver.resolve(markdown: body) { url async in
///     await titleStore.title(forPageURL: url)   // nil if unknown
/// }
/// ```
public enum MentionResolver: Sendable {

    /// Async title lookup. Receives the exact `url=` value of a
    /// `<mention-page>` tag; returns the page title, or `nil` if it
    /// cannot be resolved (→ caller emits `[link](U)`). Must not throw —
    /// model "unresolved" as `nil`.
    public typealias TitleLookup = @Sendable (_ pageURL: String) async -> String?

    /// A resolved mention occurrence (internal; exposed for tests via
    /// `scan`).
    public struct Mention: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case page, user, date, database, link, unknown
        }
        /// Tag kind as classified from the tag name + attributes.
        public let kind: Kind
        /// The raw `url=` attribute value, if the tag carried one.
        public let url: String?
        /// The full original tag text (e.g. `<mention-page url="…"/>`).
        public let raw: String
    }

    // MARK: - Public API

    /// Resolve every mention tag in `markdown`. Page mentions become
    /// `[Title](url)` (Title via `titleLookup`, cached one lookup per
    /// distinct url); every other subtype becomes `[link](url)` or, if no
    /// url, is passed through unchanged. Never throws; never drops content.
    public static func resolve(
        markdown: String,
        titleLookup: TitleLookup
    ) async -> String {
        let mentions = scan(markdown)
        guard !mentions.isEmpty else { return markdown }

        // One lookup per distinct page URL (the brief's caching rule).
        var titleCache: [String: String?] = [:]
        for m in mentions where m.kind == .page {
            guard let u = m.url else { continue }
            if titleCache[u] == nil {
                titleCache[u] = await titleLookup(u)
            }
        }

        // Rebuild the string, replacing each tag occurrence in order.
        // We replace by scanning ranges so adjacent markdown / repeated
        // identical tags are all handled and nothing is dropped.
        var result = ""
        result.reserveCapacity(markdown.count)
        var idx = markdown.startIndex
        for m in mentions {
            guard let r = markdown.range(of: m.raw, range: idx..<markdown.endIndex) else {
                continue
            }
            result += markdown[idx..<r.lowerBound]
            result += render(m, titleCache: titleCache)
            idx = r.upperBound
        }
        result += markdown[idx..<markdown.endIndex]
        return result
    }

    /// Classify (without resolving) every mention tag. Pure + synchronous
    /// — exposed so tests can assert the subtype matrix deterministically.
    public static func scan(_ markdown: String) -> [Mention] {
        guard !markdown.isEmpty else { return [] }
        var out: [Mention] = []
        // Matches <mention-WORD ... /> or <mention-WORD ...></mention-WORD>
        // self-closing is the form Notion emits; the closed form is
        // tolerated defensively. Attribute block captured loosely.
        let pattern = #"<mention-([a-zA-Z][\w-]*)\b([^>]*?)/?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let raw = ns.substring(with: match.range)
            let name = (match.range(at: 1).location != NSNotFound)
                ? ns.substring(with: match.range(at: 1)).lowercased()
                : ""
            let attrs = (match.range(at: 2).location != NSNotFound)
                ? ns.substring(with: match.range(at: 2))
                : ""
            let url = extractURL(from: attrs)
            let kind: Mention.Kind
            switch name {
            case "page": kind = .page
            case "user": kind = .user
            case "date": kind = .date
            case "database", "data-source", "datasource": kind = .database
            case "link", "inline-link": kind = .link
            default: kind = .unknown
            }
            out.append(Mention(kind: kind, url: url, raw: raw))
        }
        return out
    }

    // MARK: - Rendering

    private static func render(_ m: Mention, titleCache: [String: String?]) -> String {
        switch m.kind {
        case .page:
            guard let u = m.url else {
                // page tag with no url — never drop; pass through.
                return m.raw
            }
            if let cached = titleCache[u], let title = cached,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "[\(sanitizeLinkText(title))](\(u))"
            }
            // Unresolved title → safe [link](U) (brief rule).
            return "[link](\(u))"
        case .user, .date, .database, .link, .unknown:
            // Unknown / non-page subtype: [link](U) if a url is present,
            // else pass the original tag through verbatim (never drop).
            if let u = m.url, !u.isEmpty {
                return "[link](\(u))"
            }
            return m.raw
        }
    }

    // MARK: - Attribute parsing

    /// Pull `url="..."` (or `url='...'`) from a tag's attribute block.
    /// Returns nil when absent — callers must treat that as "no url".
    private static func extractURL(from attrs: String) -> String? {
        for quote in ["\"", "'"] {
            let pat = "url\\s*=\\s*\(quote)([^\(quote)]*)\(quote)"
            if let rx = try? NSRegularExpression(pattern: pat),
               let m = rx.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
               let r = Range(m.range(at: 1), in: attrs) {
                let v = String(attrs[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Keep link text from breaking the `[..]` markdown construct: collapse
    /// newlines and neutralize unbalanced brackets. Never empties content.
    private static func sanitizeLinkText(_ s: String) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "[", with: "\\[")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? s : trimmed
    }
}
