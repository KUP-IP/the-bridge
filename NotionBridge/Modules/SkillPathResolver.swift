// SkillPathResolver.swift — PKT-907 (Bridge v3.6 · 10) fetch_skill orchestrator
// NotionBridge · Modules
//
// Pure, network-free helpers for the fetch_skill path + intent surfaces:
//
//   1. SkillPath.parse(_:)                — slash-delimited name parser with
//                                            depth-> 1 guard.
//   2. SkillIntentScorer.bestMatch(...)    — confidence-ranked specialist
//                                            chooser (exact / alias /
//                                            partial / keyword-overlap).
//   3. SkillSpecialistFileResolver         — file-source child resolver:
//                                            primary `<parent_dir>/specialists/
//                                            <child>.md`; fallback to the
//                                            parent's frontmatter `specialists:`
//                                            array (entries map directly to
//                                            child file paths under the same
//                                            parent dir).
//
// The Notion-source child resolver lives in `SkillsModule.swift` because
// it needs the live `NotionClient`. Everything here is pure + testable
// without the network or `Bundle.module`.
//
// Annotation contract (single source of truth):
//   .specialistNotFound  — path resolved syntactically (depth == 2) but
//                           the named child page / file does not exist.
//                           fetch_skill must still return the parent body.
//   .depthGuard          — path has more than one `/`; the resolver
//                           rejects the path and reports parent + this
//                           annotation. fetch_skill must still return the
//                           parent body.
//   .lowConfidence       — intent provided but no candidate scored ≥ 0.4.
//                           fetch_skill returns the parent body + this
//                           annotation; the chosen score is still surfaced
//                           under `matchConfidence` for caller diagnostics.

import Foundation

// MARK: - SkillPath

/// A parsed `fetch_skill(name:)` argument. The grammar is intentionally
/// trivial: either a bare skill name (`"project-keepr"`) or one level of
/// child path (`"project-keepr/update"`). Anything deeper trips the depth
/// guard and is rejected — the caller surfaces a `depthGuard` annotation
/// and returns the parent body.
public struct SkillPath: Equatable, Sendable {
    public let parent: String
    public let child: String?
    /// `true` when input contained MORE than one slash. The parent is
    /// the first segment and `child` is left `nil`; the caller treats
    /// this as a depth-guard rejection.
    public let depthExceeded: Bool

    public init(parent: String, child: String?, depthExceeded: Bool) {
        self.parent = parent
        self.child = child
        self.depthExceeded = depthExceeded
    }

    /// Parse a `fetch_skill` name argument. Leading / trailing whitespace
    /// on each segment is stripped. An empty parent segment yields a
    /// `nil` return — callers fall back to the existing "skill not found"
    /// error path. Pure + deterministic.
    public static func parse(_ raw: String) -> SkillPath? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Fast path: no slash → bare skill name (preserves pre-PKT-907 shape).
        if !trimmed.contains("/") {
            return SkillPath(parent: trimmed, child: nil, depthExceeded: false)
        }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Reject empty parent (`"/foo"` or `"   /foo"`).
        guard let first = segments.first, !first.isEmpty else { return nil }
        let nonEmpty = segments.filter { !$0.isEmpty }
        if nonEmpty.count <= 1 {
            // `"foo/"` → parent only.
            return SkillPath(parent: first, child: nil, depthExceeded: false)
        }
        if nonEmpty.count == 2 {
            return SkillPath(parent: nonEmpty[0], child: nonEmpty[1], depthExceeded: false)
        }
        // Depth > 1 — the path is syntactically over-deep. We still
        // surface the parent so the caller can return its body alongside
        // the depth-guard annotation.
        return SkillPath(parent: nonEmpty[0], child: nil, depthExceeded: true)
    }
}

// MARK: - SkillAnnotation

/// Stable string tags surfaced in the `fetch_skill` envelope under the
/// `annotation` key. Kept as raw strings (rather than an MCP `Value`) so
/// this module has zero `import MCP` weight — the boundary translation
/// happens in `SkillsModule`.
public enum SkillAnnotation: String, Sendable, Equatable {
    case specialistNotFound = "specialist-not-found"
    case depthGuard = "depth-guard"
    case lowConfidence = "low-confidence"
}

// MARK: - SkillIntentScorer

/// Confidence-ranked match against a list of specialist candidates.
public struct SkillIntentCandidate: Sendable, Equatable {
    /// Canonical name (path segment + envelope title).
    public let name: String
    /// Optional aliases (file-source `aliases:` frontmatter array, Notion
    /// title aliases). Empty for callers that don't carry aliases.
    public let aliases: [String]
    /// Optional summary text — first sentence of the body / frontmatter
    /// `summary` / `description` field. Used as a low-weight keyword pool
    /// when nothing else matched.
    public let summary: String

    public init(name: String, aliases: [String] = [], summary: String = "") {
        self.name = name
        self.aliases = aliases
        self.summary = summary
    }
}

public struct SkillIntentScore: Sendable, Equatable {
    public let candidate: SkillIntentCandidate
    public let score: Double
    /// Human-readable rationale (`"exact title"`, `"alias"`, `"partial title"`,
    /// `"keyword overlap"`). Helps the operator interpret the
    /// `matchConfidence` value when it is borderline.
    public let reason: String

    public init(candidate: SkillIntentCandidate, score: Double, reason: String) {
        self.candidate = candidate
        self.score = score
        self.reason = reason
    }
}

public enum SkillIntentScorer {

    /// Confidence threshold below which we surface a `lowConfidence`
    /// annotation and fall back to the parent body. Locked at 0.4 by the
    /// dispatch packet.
    public static let confidenceThreshold: Double = 0.4

    /// Score every candidate against the intent string and return them
    /// sorted descending by score. The winner is `result.first` when its
    /// score meets `confidenceThreshold`. Pure + deterministic; ties
    /// break on the candidate's name (alpha ascending) so the wire
    /// output is stable across runs.
    public static func rank(intent: String, candidates: [SkillIntentCandidate]) -> [SkillIntentScore] {
        let needle = intent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, !candidates.isEmpty else { return [] }

        let intentTokens = Self.tokenize(needle)

        var scored: [SkillIntentScore] = []
        for c in candidates {
            let lowerName = c.name.lowercased()
            // 1) Exact title match — 1.0
            if lowerName == needle {
                scored.append(SkillIntentScore(candidate: c, score: 1.0, reason: "exact title"))
                continue
            }
            // 2) Alias match — 0.85 (any alias equal to the intent)
            if c.aliases.contains(where: { $0.lowercased() == needle }) {
                scored.append(SkillIntentScore(candidate: c, score: 0.85, reason: "alias"))
                continue
            }
            // 3) Partial title (substring either direction) — 0.7
            if lowerName.contains(needle) || needle.contains(lowerName) {
                scored.append(SkillIntentScore(candidate: c, score: 0.7, reason: "partial title"))
                continue
            }
            // 4) Token overlap on title + aliases + summary — 0.4–0.6
            let pool = Self.tokenPool(name: c.name, aliases: c.aliases, summary: c.summary)
            let overlap = intentTokens.intersection(pool)
            if !overlap.isEmpty {
                // Map ratio of overlap to [0.4, 0.6]: 1 token → 0.4,
                // every additional token bumps 0.05 up to 0.6.
                let raw = 0.4 + 0.05 * Double(overlap.count - 1)
                let s = min(raw, 0.6)
                scored.append(SkillIntentScore(candidate: c, score: s, reason: "keyword overlap"))
                continue
            }
            // No signal — omit entirely (saves the caller from
            // surfacing zero-score noise).
        }
        // Sort by score desc, then name asc for stable ordering.
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name) == .orderedAscending
        }
        return scored
    }

    /// Pick the best match if its score clears `confidenceThreshold`.
    /// Returns `nil` when no candidate qualifies — caller surfaces a
    /// `lowConfidence` annotation and the parent body.
    public static func bestMatch(intent: String, candidates: [SkillIntentCandidate]) -> SkillIntentScore? {
        let ranked = rank(intent: intent, candidates: candidates)
        guard let top = ranked.first, top.score >= confidenceThreshold else { return nil }
        return top
    }

    // MARK: tokenization

    /// Tokenize a string into a lowercased set of significant words.
    /// Strips stop words ("the", "a", "an", "of", "for", "to", "and",
    /// "with", "or", "is") so a 2-word intent like "the update" maps to
    /// `["update"]` and matches a `name: "update"` specialist via overlap.
    static func tokenize(_ s: String) -> Set<String> {
        let lower = s.lowercased()
        let tokens = lower.unicodeScalars.split(whereSeparator: { sc in
            !(sc.properties.isAlphabetic || (sc.value >= 0x30 && sc.value <= 0x39))
        }).map { String(String.UnicodeScalarView($0)) }
        return Set(tokens.filter { !$0.isEmpty && !Self.stopWords.contains($0) })
    }

    /// Combine a candidate's name + aliases + summary into one tokenized
    /// pool for the keyword-overlap pass.
    private static func tokenPool(name: String, aliases: [String], summary: String) -> Set<String> {
        var out = tokenize(name)
        for a in aliases { out.formUnion(tokenize(a)) }
        if !summary.isEmpty { out.formUnion(tokenize(summary)) }
        return out
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "for", "to", "and", "with", "or", "is",
        "on", "in", "by", "at", "as", "be", "this", "that", "from"
    ]
}

// MARK: - SkillSpecialistFileResolver (W1 file-source path resolution)

/// Resolves file-source specialists for a parent `SKILL.md`. Two
/// resolution surfaces (Q4 ratified):
///
///   1. Primary — `<parent_dir>/specialists/<child>.md` (or `.markdown`).
///   2. Fallback — frontmatter `specialists:` array on the parent. Each
///      entry is treated as a relative path under the parent dir; a bare
///      name (no extension) is resolved against `specialists/<name>.md`.
///
/// Pure + filesystem-only. The body is parsed with `FrontmatterParser`
/// so existing SKILL.md conventions apply (the body is everything after
/// the closing `---`).
public enum SkillSpecialistFileResolver {

    /// One resolved specialist file. The caller wraps this into the
    /// `fetch_skill` envelope shape via `SkillsModule.buildFileSkillResult`.
    public struct Resolved: Sendable, Equatable {
        public let name: String
        public let path: URL
        public let frontmatter: [String: FrontmatterValue]
        public let body: String

        public init(name: String, path: URL, frontmatter: [String: FrontmatterValue], body: String) {
            self.name = name
            self.path = path
            self.frontmatter = frontmatter
            self.body = body
        }
    }

    /// Look for a specialist child of a file-source parent. Returns nil
    /// when no resolution surface finds it; the caller emits a
    /// `specialistNotFound` annotation.
    public static func resolve(parent: ParsedSkill, child: String) -> Resolved? {
        let needle = child.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let parentDir = parent.path.deletingLastPathComponent()

        // Primary: <parentDir>/specialists/<child>.md (case-insensitive
        // dir match on `specialists`).
        if let hit = findInSpecialistsDir(parentDir: parentDir, child: needle) {
            return hit
        }

        // Fallback: frontmatter `specialists:` array entries.
        guard case .array(let entries) = parent.frontmatter["specialists"] else {
            return nil
        }
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Match the entry by leaf name (case-insensitive) — operators
            // typically write `specialists: [update, triage, close]`.
            let leaf = (trimmed as NSString).lastPathComponent
            let leafNoExt = (leaf as NSString).deletingPathExtension
            if leafNoExt.lowercased() == needle.lowercased() {
                let candidatePath: URL
                if (trimmed as NSString).pathExtension.isEmpty {
                    candidatePath = parentDir
                        .appendingPathComponent("specialists", isDirectory: true)
                        .appendingPathComponent("\(trimmed).md")
                } else {
                    candidatePath = parentDir.appendingPathComponent(trimmed)
                }
                if let r = readSpecialistFile(at: candidatePath, name: needle) {
                    return r
                }
            }
        }
        return nil
    }

    /// List every specialist file declared under a parent skill. Used by
    /// the W3 routing index surfacing to populate the `specialists:`
    /// array. Combines the dir-scan with frontmatter declarations,
    /// deduplicated by leaf name (case-insensitive).
    public static func listAll(parent: ParsedSkill) -> [Resolved] {
        let parentDir = parent.path.deletingLastPathComponent()
        var out: [Resolved] = []
        var seen: Set<String> = []

        // 1. Dir scan
        for r in scanSpecialistsDir(parentDir: parentDir) {
            let key = r.name.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                out.append(r)
            }
        }

        // 2. Frontmatter `specialists:` array
        if case .array(let entries) = parent.frontmatter["specialists"] {
            for entry in entries {
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let leaf = (trimmed as NSString).lastPathComponent
                let leafNoExt = (leaf as NSString).deletingPathExtension
                let key = leafNoExt.lowercased()
                if seen.contains(key) { continue }
                let candidatePath: URL
                if (trimmed as NSString).pathExtension.isEmpty {
                    candidatePath = parentDir
                        .appendingPathComponent("specialists", isDirectory: true)
                        .appendingPathComponent("\(trimmed).md")
                } else {
                    candidatePath = parentDir.appendingPathComponent(trimmed)
                }
                if let r = readSpecialistFile(at: candidatePath, name: leafNoExt) {
                    seen.insert(key)
                    out.append(r)
                }
            }
        }
        // Stable ordering — alpha by name.
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return out
    }

    // MARK: - Internals

    private static func findInSpecialistsDir(parentDir: URL, child: String) -> Resolved? {
        let specialistsDir = parentDir.appendingPathComponent("specialists", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: specialistsDir.path) else { return nil }
        // First try the obvious exact filenames (fast path).
        for ext in ["md", "markdown"] {
            let candidate = specialistsDir.appendingPathComponent("\(child).\(ext)")
            if fm.fileExists(atPath: candidate.path),
               let r = readSpecialistFile(at: candidate, name: child) {
                return r
            }
        }
        // Case-insensitive directory scan as a slower fallback (operator
        // typed "Update" but the file is `update.md`).
        guard let entries = try? fm.contentsOfDirectory(at: specialistsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let needleLower = child.lowercased()
        for e in entries {
            let leafNoExt = e.deletingPathExtension().lastPathComponent
            let ext = e.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            if leafNoExt.lowercased() == needleLower {
                if let r = readSpecialistFile(at: e, name: leafNoExt) {
                    return r
                }
            }
        }
        return nil
    }

    /// Enumerate every `*.md` / `*.markdown` file in a parent's
    /// `specialists/` directory. Used by the routing-index surfacing.
    private static func scanSpecialistsDir(parentDir: URL) -> [Resolved] {
        let specialistsDir = parentDir.appendingPathComponent("specialists", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: specialistsDir.path),
              let entries = try? fm.contentsOfDirectory(at: specialistsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [Resolved] = []
        for e in entries {
            let ext = e.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            let leafNoExt = e.deletingPathExtension().lastPathComponent
            if let r = readSpecialistFile(at: e, name: leafNoExt) {
                out.append(r)
            }
        }
        return out
    }

    private static func readSpecialistFile(at path: URL, name: String) -> Resolved? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let parsed = FrontmatterParser.parse(text)
        // Frontmatter `name:` overrides directory-derived name when present.
        let resolvedName: String = {
            if case .string(let s) = parsed.frontmatter["name"], !s.isEmpty { return s }
            return name
        }()
        return Resolved(
            name: resolvedName,
            path: path,
            frontmatter: parsed.frontmatter,
            body: parsed.body
        )
    }
}

// MARK: - SpecialistSummary (W3 routing index surfacing)

/// One row of the `specialists` array surfaced in `skills_routing_list`.
/// Pure value type so the wire-shape test can assert it directly.
public struct SpecialistSummary: Sendable, Equatable {
    public let path: String   // "parent-name/child-name"
    public let title: String
    public let summary: String

    public init(path: String, title: String, summary: String) {
        self.path = path
        self.title = title
        self.summary = summary
    }
}

/// Pure builder: extract the first sentence of a body as the specialist
/// summary. Falls back to the first 160 chars when no terminator is
/// found. Empty body → empty string.
public enum SpecialistSummaryExtractor {
    public static func firstSentence(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Skip heading lines (start with `#`) — we want the prose first.
        let lines = trimmed.split(whereSeparator: \.isNewline)
        var prose = ""
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("#") { continue }
            prose = String(l)
            break
        }
        if prose.isEmpty { return String(trimmed.prefix(160)) }
        // First sentence terminator (., !, ?) — punctuation kept.
        let terminators: Set<Character> = [".", "!", "?"]
        var sentence = ""
        for ch in prose {
            sentence.append(ch)
            if terminators.contains(ch) { break }
            if sentence.count >= 160 { break }
        }
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
