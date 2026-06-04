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
    /// Intent ranking produced two top candidates within the
    /// disambiguation band (their scores are within
    /// `SkillIntentScorer.disambiguationMargin` of each other, OR the top
    /// score is below the confidence threshold). The caller surfaces the
    /// candidate list and asks which to fetch, instead of silently
    /// returning the parent body.
    case disambiguate = "disambiguate"
}

// MARK: - SpecialistFilter

/// Routing-reliability fix (v3.7·routing): the routing index + specialist
/// enumeration surface a parent's *curated* specialist sub-skills, NOT every
/// `child_page` under the parent. Parents in this workspace also carry
/// doc-pages — changelogs, PRDs, "§…"-prefixed sections, test matrices,
/// evolution logs, phase notes, pruning notes, and duplicate stubs — that
/// must never appear as routable specialists (the audit finding).
///
/// PRIMARY SOURCE (v3.7.4 — routing/specialist-relation, now WIRED): the
/// parent's **`Specialist` relation property** (a Notion relation pointing
/// at the curated specialist pages). Verified live on the Keepr/Skills data
/// source — the property is singular `Specialist`
/// (see `NotionJSON.specialistRelationPropertyNames` for the SSOT name +
/// `extractSpecialistRelationIDs` for the reader). Both
/// `SkillsCacheWriter.ChildEnumerator.fetchChildren` and
/// `SkillsModule.listNotionChildPages` now enumerate the relation's target
/// page ids directly; the `child_page` walk survives only as a fallback for
/// pages with no curated relation.
///
/// THIS FILTER is now the DEFENSIVE SECONDARY GUARD (belt + suspenders): it
/// runs on both the relation-sourced and fallback-walk candidates, so any
/// doc-page that slips into the curated relation — or a non-specialist that
/// the fallback walk picks up — is still excluded from the routing surface.
public enum SpecialistFilter {

    /// Title-pattern predicates that mark a child page as a DOC-PAGE
    /// (changelog / PRD / section / matrix / log / phase / pruning /
    /// duplicate stub) rather than a curated specialist. A child whose
    /// title matches ANY of these is excluded from the specialist surface.
    ///
    /// Patterns (case-insensitive, anchored where the packet specified):
    ///   • `^§`                — section pages ("§ 3.2 Foo")
    ///   • `Changelog`         — changelogs / change logs
    ///   • `PRD`               — product requirement docs
    ///   • `Test Matrix`       — test matrices
    ///   • `Evolution Log`     — evolution / history logs
    ///   • `Phase \d`          — "Phase 1", "Phase 2", … planning pages
    ///   • `Pruning`           — pruning notes
    /// Plus a few defensive doc-noise siblings the audit observed:
    ///   • `^Archive`, `(duplicate)`/`(dup)`/`(stub)` suffixes, `Scratch`,
    ///     `Notes`-only pages, `Backlog`, `Roadmap`, `Decision Log`.
    public static func isDocPage(title rawTitle: String) -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true } // an untitled child is not a curated specialist
        let lower = title.lowercased()

        // Anchored: section marker.
        if title.hasPrefix("§") { return true }
        // Anchored: archive container pages.
        if lower.hasPrefix("archive") { return true }

        // Substring doc-markers.
        let substringMarkers = [
            "changelog", "change log",
            "prd",
            "test matrix",
            "evolution log",
            "pruning",
            "decision log",
            "roadmap",
            "backlog"
        ]
        for m in substringMarkers where lower.contains(m) {
            return true
        }

        // Duplicate / stub suffix markers.
        let suffixMarkers = ["(duplicate)", "(dup)", "(stub)", "(wip)", "(draft)"]
        for m in suffixMarkers where lower.contains(m) {
            return true
        }

        // `Phase \d` — "Phase 1", "Phase 2.5", etc.
        if matchesPhasePattern(lower) { return true }

        return false
    }

    /// Convenience inverse: true when the child title is a plausible
    /// CURATED SPECIALIST (i.e. not a doc-page).
    public static func isSpecialist(title: String) -> Bool {
        !isDocPage(title: title)
    }

    /// Pure scan for a `phase <digit>` token (case-insensitive; the input
    /// is already lowercased by the caller). Matches "phase 1", "phase  2",
    /// "phase 3.2"; does NOT match "rephrase" or "phased" alone.
    private static func matchesPhasePattern(_ lower: String) -> Bool {
        guard let range = lower.range(of: "phase") else { return false }
        // Require a word boundary before "phase" (start or non-letter).
        if range.lowerBound != lower.startIndex {
            let before = lower[lower.index(before: range.lowerBound)]
            if before.isLetter { return false }
        }
        // Scan past "phase" + whitespace, expect a digit.
        var idx = range.upperBound
        var sawSpace = false
        while idx < lower.endIndex, lower[idx] == " " {
            sawSpace = true
            idx = lower.index(after: idx)
        }
        guard sawSpace, idx < lower.endIndex else { return false }
        return lower[idx].isNumber
    }

    // MARK: Active-status guard (v3.7.6 — routing/specialist-active-status)

    /// Lifecycle predicate (fast-follow to v3.7.4's relation source). A
    /// curated specialist may stay a MEMBER of a parent's `Specialist`
    /// relation for history even after it is retired (e.g. focus-keepr's
    /// deprecation-dated `retro`). Routing must never surface such a row.
    /// `isActiveSpecialist` inspects the specialist PAGE's own properties and
    /// returns `false` ONLY on a confident inactive signal:
    ///   • a populated `Deprecation Date` (or common aliases), OR
    ///   • a lifecycle `Status`/`Lifecycle`/`State`/`Maturity`/`Stage`
    ///     select/status/multi_select whose value is an inactive token.
    ///
    /// It FAILS OPEN: an absent, empty, or unrecognized status leaves the
    /// specialist ACTIVE, so a missing or oddly-named property can never
    /// silently empty the routing surface — the same reliability bias as the
    /// relation reader's "empty → fall back" contract. Pairs with
    /// `isSpecialist(title:)` as the second hydration-time guard.
    /// Pure + deterministic; never throws.
    public static func isActiveSpecialist(properties: [String: Any]) -> Bool {
        // 1) An explicit deprecation / sunset / retirement DATE retires the row.
        if hasPopulatedDate(in: properties,
                            keys: ["Deprecation Date", "Deprecated On", "Deprecated",
                                   "Sunset Date", "Sunset", "Retired On", "Archived On"]) {
            return false
        }
        // 2) A lifecycle status/select in a known inactive state.
        for key in ["Status", "Lifecycle", "State", "Maturity", "Stage"] {
            for token in statusTokens(in: properties, key: key)
            where inactiveStatusTokens.contains(token) {
                return false
            }
        }
        return true
    }

    /// Lower-cased status values that mark a specialist INACTIVE for routing.
    /// Conservative on purpose (exact-match, not substring): only unambiguous
    /// retirement words, so an in-flight status — "Active", "Stable", "Beta",
    /// "Draft", "Experimental", "Production" — never hides a live specialist.
    static let inactiveStatusTokens: Set<String> = [
        "deprecated", "archived", "folded", "retired",
        "sunset", "sunsetted", "removed", "obsolete", "inactive", "merged"
    ]

    /// Lower-cased display name(s) of a `status` / `select` / `multi_select`
    /// property, matched case-insensitively by key. Empty when the property
    /// is absent or a different type. Pure.
    static func statusTokens(in properties: [String: Any], key: String) -> [String] {
        var out: [String] = []
        for (k, v) in properties where k.caseInsensitiveCompare(key) == .orderedSame {
            guard let prop = v as? [String: Any],
                  let type = prop["type"] as? String else { continue }
            switch type {
            case "status":
                if let s = prop["status"] as? [String: Any], let name = s["name"] as? String {
                    out.append(name.lowercased())
                }
            case "select":
                if let s = prop["select"] as? [String: Any], let name = s["name"] as? String {
                    out.append(name.lowercased())
                }
            case "multi_select":
                if let arr = prop["multi_select"] as? [[String: Any]] {
                    for opt in arr {
                        if let name = opt["name"] as? String {
                            out.append(name.lowercased())
                        }
                    }
                }
            default:
                continue
            }
        }
        return out
    }

    /// True when any of `keys` resolves to a `date`-typed property whose
    /// `start` is a non-empty string (Notion's representation of a set date).
    /// Case-insensitive on the key. Pure.
    static func hasPopulatedDate(in properties: [String: Any], keys: [String]) -> Bool {
        for key in keys {
            for (k, v) in properties where k.caseInsensitiveCompare(key) == .orderedSame {
                guard let prop = v as? [String: Any],
                      (prop["type"] as? String) == "date",
                      let date = prop["date"] as? [String: Any],
                      let start = date["start"] as? String else { continue }
                if !start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            }
        }
        return false
    }
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

    /// Margin within which the top two candidates are considered "too
    /// close to call". When the #1 and #2 scores differ by ≤ this, the
    /// dispatcher returns a DISAMBIGUATION instead of silently picking #1.
    public static let disambiguationMargin: Double = 0.1

    /// Routing-reliability (confidence → clarify). Decide what the
    /// dispatcher should do for an intent rank.
    ///
    ///   • `.confident(score)`     — top clears the threshold AND is not in
    ///                               the disambiguation band → fetch it.
    ///   • `.disambiguate(top)`    — either the top is below threshold but
    ///                               there ARE candidates, or the top two
    ///                               are within `disambiguationMargin` of
    ///                               each other → ask the caller to pick.
    ///   • `.none`                 — no candidate scored at all (no signal).
    ///
    /// This makes a low-confidence result ACTIONABLE: rather than returning
    /// the bare parent body (which the agent then has to interpret), the
    /// caller lists the close candidates and asks which to fetch.
    public enum IntentDecision: Sendable, Equatable {
        case confident(SkillIntentScore)
        case disambiguate([SkillIntentScore])
        case none
    }

    /// Classify an intent rank into the `IntentDecision` the dispatcher
    /// acts on. `maxCandidates` caps how many close candidates the
    /// disambiguation surface lists.
    public static func decide(
        intent: String,
        candidates: [SkillIntentCandidate],
        maxCandidates: Int = 3
    ) -> IntentDecision {
        let ranked = rank(intent: intent, candidates: candidates)
        guard let top = ranked.first else { return .none }

        // Are the top two within the disambiguation band?
        let ambiguousPair: Bool = {
            guard ranked.count >= 2 else { return false }
            return (top.score - ranked[1].score) <= disambiguationMargin
        }()

        // Confident path: clears threshold AND is a clear winner.
        if top.score >= confidenceThreshold && !ambiguousPair {
            return .confident(top)
        }

        // Otherwise clarify. Surface the close band: every candidate within
        // `disambiguationMargin` of the top, capped, but always at least the
        // top one (so a single sub-threshold candidate still gets listed).
        let band = ranked.filter { (top.score - $0.score) <= disambiguationMargin }
        let surfaced = Array((band.isEmpty ? [top] : band).prefix(max(1, maxCandidates)))
        return .disambiguate(surfaced)
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
