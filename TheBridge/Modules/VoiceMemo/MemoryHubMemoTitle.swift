// MemoryHubMemoTitle.swift — progressive AI memo titles (PKT-MEM-114)
// TheBridge · Modules · VoiceMemo
//
// Replaces the raw timestamp memo titles with scannable, cached, editable titles.
// Progressive + local-first (the Phase-0 heuristic→local→cloud, cache-and-upgrade
// pattern, applied to titles):
//   floor   → humanized date ("Thu Jun 25, 8:30 PM"), never a raw id
//   named   → honor a real recording name (not a default/timestamp)
//   Tier-1  → intent-led heuristic from the parsed plan (the elected primary lane)
//   Tier-2  → local Ollama (P3) · Tier-3 → cloud, manual-only (P3)
//   edited  → operator override, pinned (never auto-overwritten)
// Titles are short summaries (privacy parity with activity-log excerpts), cached per
// memo keyed by memoId + transcript hash so a re-transcribe rebuilds the title while a
// human edit survives.

import Foundation

public struct MemoTitle: Codable, Sendable, Equatable {
    public enum Provenance: String, Codable, Sendable {
        case placeholder   // computed date floor — not persisted
        case named         // real recording name
        case heuristic     // Tier-1 parser-derived
        case local         // Tier-2 Ollama
        case cloud         // Tier-3 cloud
        case edited        // operator override (pinned)
    }

    public var title: String
    public var provenance: Provenance
    /// Executable-intent count for the `+N` multi-intent badge (0/1 ⇒ no badge).
    public var intentCount: Int
    /// SHA-256 of the source transcript — the invalidation key (nil for name/date titles).
    public var transcriptHash: String?
    public var generatedAt: String   // ISO-8601

    public init(title: String, provenance: Provenance, intentCount: Int = 0,
                transcriptHash: String? = nil, generatedAt: String) {
        self.title = title
        self.provenance = provenance
        self.intentCount = intentCount
        self.transcriptHash = transcriptHash
        self.generatedAt = generatedAt
    }

    /// True when this cached title is still valid for the given current transcript hash.
    /// Name titles (no hash) are always valid; auto/edited titles are valid only when the
    /// transcript is unchanged (nil current hash ⇒ treat as valid, e.g. list with no transcript loaded).
    public func isFresh(forTranscriptHash current: String?) -> Bool {
        guard let mine = transcriptHash else { return true }
        guard let current else { return true }
        return mine == current
    }
}

/// What the list renders for a memo (the floor logic resolved).
public struct MemoTitleDisplay: Sendable, Equatable {
    public let text: String
    public let provenance: MemoTitle.Provenance
    public let intentCount: Int
    /// True for the computed date floor (no real title yet) — the UI shows it muted.
    public let isPlaceholder: Bool
}

public enum MemoryHubMemoTitleStore {
    /// Bound the cache; `.edited` overrides are always retained.
    public static let maxEntries = 3000

    public static var fileURL: URL {
        BridgePaths.applicationSupport(.memoryHub).appendingPathComponent("memo-titles.json")
    }

    public static func load() -> [String: MemoTitle] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: MemoTitle].self, from: data) else { return [:] }
        return decoded
    }

    public static func title(for memoId: String) -> MemoTitle? { load()[memoId] }

    /// Cache a title. An auto title (heuristic/local/cloud/named) NEVER overwrites an
    /// existing `.edited` override; an `.edited` write always wins.
    public static func put(_ title: MemoTitle, memoId: String) {
        var all = load()
        if all[memoId]?.provenance == .edited, title.provenance != .edited { return }
        all[memoId] = title
        save(prune(all))
    }

    public static func remove(memoId: String) {
        var all = load()
        all[memoId] = nil
        save(all)
    }

    static func save(_ all: [String: MemoTitle]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Keep every `.edited` title + the newest auto titles up to `max`.
    public static func prune(_ all: [String: MemoTitle], max: Int = maxEntries) -> [String: MemoTitle] {
        guard all.count > max else { return all }
        let edited = all.filter { $0.value.provenance == .edited }
        let autos = all.filter { $0.value.provenance != .edited }
            .sorted { $0.value.generatedAt > $1.value.generatedAt }
        var kept = edited
        for (k, v) in autos.prefix(Swift.max(0, max - edited.count)) { kept[k] = v }
        return kept
    }
}

public enum MemoryHubMemoTitler {
    static let maxWords = 8

    // MARK: Date floor

    /// Locale-aware, relative humanized date — the list floor. Never a raw id.
    public static func humanizedDate(_ date: Date, now: Date = Date(),
                                     calendar: Calendar = .current, locale: Locale = .current) -> String {
        let timeFmt = DateFormatter()
        timeFmt.locale = locale
        timeFmt.timeZone = calendar.timeZone
        timeFmt.timeStyle = .short
        timeFmt.dateStyle = .none
        let time = timeFmt.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, \(time)" }

        let dateFmt = DateFormatter()
        dateFmt.locale = locale
        dateFmt.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        dateFmt.setLocalizedDateFormatFromTemplate(sameYear ? "EEE MMM d" : "MMM d yyyy")
        return "\(dateFmt.string(from: date)), \(time)"
    }

    // MARK: Naming

    /// A recording filename is a DEFAULT (not a real user name) when it is a timestamp
    /// (mostly digits/separators) or an "New Recording N" placeholder.
    public static func isDefaultName(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.lowercased().hasPrefix("new recording") { return true }
        let allowed = CharacterSet(charactersIn: "0123456789 :.-/")
        let onlyDigitsAndSeps = t.unicodeScalars.allSatisfy { allowed.contains($0) }
        if onlyDigitsAndSeps, t.filter(\.isNumber).count >= 6 { return true }
        return false
    }

    // MARK: Tier-1 heuristic

    /// Intent-led title from the parsed plan: lead with the elected primary lane's action +
    /// entity ("Send Jacob results", "Bridge v4 — trust fixes", "Prefer adversarial reviews").
    public static func heuristicTitle(plan: VoiceMemoPlan, transcript: String, now: Date = Date()) -> MemoTitle {
        let executable = plan.intents.filter { $0.kind != .review }
        let split = VoiceMemoIntentElection.split(plan.intents)
        let primary = split.execute.first { $0.kind != .review } ?? executable.first
        let raw = primary.map { subject(for: $0, plan: plan) } ?? plan.generatedTitle
        return MemoTitle(
            title: clean(raw),
            provenance: .heuristic,
            intentCount: max(executable.count, primary == nil ? 0 : 1),
            transcriptHash: MemoryHubActivityLog.sha256Hex(transcript.trimmingCharacters(in: .whitespacesAndNewlines)),
            generatedAt: ISO8601DateFormatter().string(from: now)
        )
    }

    static func subject(for intent: VoiceMemoIntent, plan: VoiceMemoPlan) -> String {
        switch intent.kind {
        case .reminder:
            return intent.title ?? plan.summary
        case .registryUpdate:
            let entity = intent.entityHint ?? intent.entityKey ?? "Update"
            let gist = intent.fields["summary"]
                ?? intent.fields["brief"]
                ?? intent.fields.keys.sorted().first.flatMap { intent.fields[$0] }
                ?? plan.summary
            let g = clean(gist, maxWords: 5)
            return g.isEmpty ? entity : "\(entity) — \(g)"
        case .memoryKeep, .agentMemory:
            return intent.title ?? intent.body ?? plan.summary
        case .review:
            return plan.generatedTitle
        }
    }

    static func clean(_ raw: String, maxWords: Int = maxWords) -> String {
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return "Untitled memo" }
        var result = words.prefix(maxWords).joined(separator: " ")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?—-"))
        if words.count > maxWords { result += "…" }
        return result.isEmpty ? "Untitled memo" : result
    }

    // MARK: List floor resolution

    /// What the memo list should show, resolving named → cached(fresh) → date floor.
    /// `currentTranscriptHash` is nil in the list (no transcript loaded); a stale cached
    /// title is still shown there and rebuilt on selection.
    public static func listDisplay(recording: VoiceMemoRecording,
                                   cached: MemoTitle?,
                                   now: Date = Date()) -> MemoTitleDisplay {
        if !isDefaultName(recording.title) {
            return MemoTitleDisplay(text: recording.title, provenance: .named,
                                    intentCount: cached?.intentCount ?? 0, isPlaceholder: false)
        }
        if let cached {
            return MemoTitleDisplay(text: cached.title, provenance: cached.provenance,
                                    intentCount: cached.intentCount, isPlaceholder: false)
        }
        return MemoTitleDisplay(text: humanizedDate(recording.recordedAt, now: now),
                                provenance: .placeholder, intentCount: 0, isPlaceholder: true)
    }
}
