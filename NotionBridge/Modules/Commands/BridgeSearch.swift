// BridgeSearch.swift — PKT-1006 R2 (Command Bridge v4 · multi-entity search)
// NotionBridge · Modules · Commands
//
// The Command Bridge bar used to search ONLY CommandStore commands. This
// file is the from-scratch multi-entity search MODEL that lets the bar
// surface Commands + Skills + Jobs + Tools in one ranked, grouped, typed
// result list, each row carrying a TYPE TAG + COLOR indicator and a
// type-specific DESTINATION action.
//
// PURE BY DESIGN — every type here is value-only (no AppKit, no SwiftUI, no
// live store I/O). The aggregator takes lightweight `SearchEntity`
// descriptors (the view-model adapts the live SkillsManager / JobStore /
// StatusBarController into these) and a query string, and returns the
// ranked + grouped `[BridgeSearchResult]`. That keeps fuzzy matching,
// scoring, ranking, and grouping fully unit-testable headlessly (the W3 GUI
// ceiling never touches this layer). The view-model owns the store reads;
// this owns the logic.

import Foundation

// ============================================================
// MARK: - Result kind (type tag + color indicator)
// ============================================================

/// The entity kind a search result represents. Drives the row's TYPE TAG
/// label and its COLOR indicator (R2). The four kinds the v4 launcher
/// searches — no Connections/Credentials this packet (out of scope).
public enum BridgeSearchKind: String, Sendable, Equatable, CaseIterable, Codable {
    case command
    case skill
    case job
    case tool

    /// Short uppercase tag rendered on the row (`.cb-type`).
    public var tag: String {
        switch self {
        case .command: return "CMD"
        case .skill:   return "SKILL"
        case .job:     return "JOB"
        case .tool:    return "TOOL"
        }
    }

    /// The color-indicator token name (maps to NotionPalette in the view).
    /// Each kind gets a distinct hue so the operator can tell types apart at
    /// a glance: commands stay the accent-blue they already are, skills are
    /// purple, jobs are green, tools are orange.
    public var colorTag: String {
        switch self {
        case .command: return "blue"
        case .skill:   return "purple"
        case .job:     return "green"
        case .tool:    return "orange"
        }
    }

    /// Stable group ordering in the results panel (commands first — the
    /// historical bar contents — then skills, jobs, tools).
    public var groupOrder: Int {
        switch self {
        case .command: return 0
        case .skill:   return 1
        case .job:     return 2
        case .tool:    return 3
        }
    }

    /// Group section header shown above each kind's rows.
    public var groupHeader: String {
        switch self {
        case .command: return "Commands"
        case .skill:   return "Skills"
        case .job:     return "Jobs"
        case .tool:    return "Tools"
        }
    }
}

// ============================================================
// MARK: - Destination (typed per-kind action)
// ============================================================

/// The single, typed destination model fired when a result is selected
/// (R2 self-critique W2: ONE destination protocol, not 4 ad-hoc branches).
/// Pure — it carries only the data the controller needs to route; the
/// controller (CommandBridgeController) performs the side-effecting open.
public enum BridgeSearchDestination: Sendable, Equatable {
    /// Command → copy its markdown body to the clipboard (existing behaviour),
    /// fired by slug.
    case command(slug: String)

    /// Skill → open its SOURCE. The view-model resolves the skill's
    /// source/platform into ONE of these concrete opens:
    ///   • notion(pageId) — a Notion page  → notion:// or notion.so URL
    ///   • googleDoc(url) — a Google Doc    → the doc URL
    ///   • file(path)     — a local file    → reveal/open the file
    /// `url` carries the original click-to-open URL when present.
    case skillNotion(pageId: String, url: String?)
    case skillGoogleDoc(url: String)
    case skillFile(path: String)
    /// Fallback when a skill has no resolvable source (manual/no URL): just
    /// open Settings → Skills scrolled to the skill row.
    case skillSettings(anchor: String)

    /// Job → open Settings → Jobs deep-linked (scrolled + selected) to the job.
    case job(id: String)

    /// Tool → open Settings → Tools, opening the tool's GROUPING and scrolling
    /// to the tool so it can be toggled / permission-gated. `group` is the
    /// ModuleGroupID raw value; `tool` is the tool name.
    case tool(group: String, tool: String)
}

// ============================================================
// MARK: - Searchable entity descriptor
// ============================================================

/// A lightweight, store-agnostic descriptor the aggregator ranks. The
/// view-model builds these from the live stores so the matching logic never
/// imports the store types (keeps it pure + testable). `subtitle` is the
/// secondary metadata line (e.g. a skill's platform, a job's schedule).
public struct BridgeSearchEntity: Sendable, Equatable {
    public let kind: BridgeSearchKind
    /// Stable identity within its kind (slug / name / id / tool-name).
    public let id: String
    /// The primary display + match string.
    public let title: String
    /// Optional secondary metadata (shown dimmed; NOT matched against).
    public let subtitle: String?
    /// The typed action fired on select.
    public let destination: BridgeSearchDestination
    /// Optional recency stamp — commands carry lastUsedAt so recency can
    /// break ties (matches the historical recency-sorted bar). nil sorts last.
    public let recency: Date?

    public init(
        kind: BridgeSearchKind,
        id: String,
        title: String,
        subtitle: String? = nil,
        destination: BridgeSearchDestination,
        recency: Date? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.destination = destination
        self.recency = recency
    }
}

// ============================================================
// MARK: - Result (a ranked, typed row)
// ============================================================

/// A single ranked result row. Carries everything the view needs to render
/// the typed row (tag + color from `kind`) and everything the controller
/// needs to act (`destination`).
public struct BridgeSearchResult: Identifiable, Sendable, Equatable {
    public let kind: BridgeSearchKind
    public let id: String          // "<kind>:<entityId>" — unique across groups
    public let entityId: String    // the entity's own id (slug/name/job-id)
    public let title: String
    public let subtitle: String?
    public let destination: BridgeSearchDestination
    public let score: Double       // higher = better match

    public init(entity: BridgeSearchEntity, score: Double) {
        self.kind = entity.kind
        self.id = "\(entity.kind.rawValue):\(entity.id)"
        self.entityId = entity.id
        self.title = entity.title
        self.subtitle = entity.subtitle
        self.destination = entity.destination
        self.score = score
    }
}

// ============================================================
// MARK: - Fuzzy matching + ranking
// ============================================================

/// Pure fuzzy matcher + multi-entity aggregator. All static — no state.
public enum BridgeSearch {

    /// Score `query` against `candidate`. Returns nil when there is NO
    /// subsequence match (the candidate is filtered out). Higher is better.
    ///
    /// Scoring rewards, in order of strength:
    ///   • exact (case-insensitive) equality            — strongest
    ///   • prefix match                                  — strong
    ///   • contiguous substring match                    — good (earlier = better)
    ///   • word-boundary / acronym subsequence           — fair
    ///   • scattered subsequence                         — weak (still a match)
    /// An empty query matches everything with a neutral score (the bar shows
    /// all entities), so the caller can use it for a "browse all" affordance.
    public static func score(query rawQuery: String, candidate rawCandidate: String) -> Double? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = rawCandidate.lowercased()
        if query.isEmpty { return 0 }
        if candidate.isEmpty { return nil }

        // Exact equality — the ceiling.
        if candidate == query { return 1000 }

        // Prefix — very strong, scaled slightly by how much of the candidate
        // the query covers (a shorter candidate with the same prefix is a
        // tighter match).
        if candidate.hasPrefix(query) {
            let coverage = Double(query.count) / Double(candidate.count)
            return 800 + coverage * 100
        }

        // Contiguous substring — good; earlier position scores higher.
        if let r = candidate.range(of: query) {
            let startIdx = candidate.distance(from: candidate.startIndex, to: r.lowerBound)
            let positionPenalty = Double(startIdx) * 2.0
            let coverage = Double(query.count) / Double(candidate.count)
            return 500 + coverage * 100 - positionPenalty
        }

        // Subsequence (fuzzy). Walk the candidate matching query chars in
        // order; reward matches that land on word boundaries (acronym-style).
        guard let sub = subsequenceScore(query: query, candidate: candidate) else {
            return nil
        }
        return sub
    }

    /// Returns a subsequence score, or nil if `query` is not a subsequence of
    /// `candidate`. Bonuses for word-boundary hits + tight clustering.
    private static func subsequenceScore(query: String, candidate: String) -> Double? {
        let q = Array(query)
        let c = Array(candidate)
        var qi = 0
        var matchedAtBoundary = 0
        var totalGap = 0
        var lastMatch = -1
        let boundarySet: Set<Character> = [" ", "-", "_", ".", "/", ":"]

        var i = 0
        while i < c.count && qi < q.count {
            if c[i] == q[qi] {
                let isBoundary = (i == 0) || boundarySet.contains(c[i - 1])
                if isBoundary { matchedAtBoundary += 1 }
                if lastMatch >= 0 { totalGap += (i - lastMatch - 1) }
                lastMatch = i
                qi += 1
            }
            i += 1
        }
        guard qi == q.count else { return nil }   // not all query chars matched

        // Base for a fuzzy hit is below any substring hit. Add boundary bonus
        // (acronym matches like "fr" → "file_read" read intentional) and
        // subtract a gap penalty so tighter matches rank higher.
        let boundaryBonus = Double(matchedAtBoundary) * 40.0
        let gapPenalty = Double(totalGap) * 1.5
        let coverage = Double(q.count) / Double(c.count) * 50.0
        return max(1.0, 200 + boundaryBonus + coverage - gapPenalty)
    }

    /// The aggregate, ranked, grouped result list for `query` across all
    /// `entities`. Results are filtered to matches, then ordered by:
    ///   1. group order (Commands, Skills, Jobs, Tools)
    ///   2. score (desc) within a group
    ///   3. recency (desc, nil last) as a tie-break
    ///   4. title (case-insensitive asc) as a final stable tie-break
    /// `limitPerGroup` caps each group so one noisy kind can't bury the rest.
    public static func rankedResults(
        query: String,
        entities: [BridgeSearchEntity],
        limitPerGroup: Int = 8
    ) -> [BridgeSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Score + filter.
        var scored: [BridgeSearchResult] = []
        for e in entities {
            guard let s = score(query: trimmed, candidate: e.title) else { continue }
            scored.append(BridgeSearchResult(entity: e, score: s))
        }

        // Sort within group by score, then recency, then title.
        // We need the recency for the tie-break, so build a lookup.
        var recencyById: [String: Date] = [:]
        for e in entities where e.recency != nil {
            recencyById["\(e.kind.rawValue):\(e.id)"] = e.recency
        }

        func less(_ a: BridgeSearchResult, _ b: BridgeSearchResult) -> Bool {
            if a.kind.groupOrder != b.kind.groupOrder {
                return a.kind.groupOrder < b.kind.groupOrder
            }
            if a.score != b.score { return a.score > b.score }
            let ra = recencyById[a.id]
            let rb = recencyById[b.id]
            switch (ra, rb) {
            case let (.some(da), .some(db)) where da != db: return da > db
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        scored.sort(by: less)

        // Cap each group.
        guard limitPerGroup > 0 else { return scored }
        var perGroupCount: [BridgeSearchKind: Int] = [:]
        var capped: [BridgeSearchResult] = []
        for r in scored {
            let n = perGroupCount[r.kind, default: 0]
            if n < limitPerGroup {
                capped.append(r)
                perGroupCount[r.kind] = n + 1
            }
        }
        return capped
    }
}
