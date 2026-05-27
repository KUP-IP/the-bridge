// CommandStore.swift — Markdown-backed store for user-authored Commands.
// PKT-6 (v3.5).
//
// Layout:
//   ~/Library/Application Support/The Bridge/commands/
//       index.json                      (ordered metadata + slot map)
//       <slug>.md                       (one markdown file per command)
//
// Why markdown-per-command:
//   • Diffable in git if the user version-controls their config
//   • Hand-editable in any text editor
//   • Matches the "literal markdown payload" design — what's on disk is
//     exactly what the Command Bridge popup copies to the clipboard
//
// The index.json carries metadata (icon, color, key slot, lastUsed) so
// the list view can render without parsing every body. Source of truth
// for the body remains the .md file.

import Foundation

public final class CommandStore: @unchecked Sendable {
    public static let shared = CommandStore()

    // MARK: - Public model

    public struct Command: Equatable, Sendable, Codable {
        public var slug: String           // derived from name; immutable post-create
        public var name: String           // display name
        public var icon: Icon
        public var color: NotionColor?    // applies only when icon is .symbol
        public var keySlot: Int?          // 0…9, or nil
        public var lastUsedAt: Date?
        public var body: String           // markdown payload

        public init(
            slug: String,
            name: String,
            icon: Icon,
            color: NotionColor? = nil,
            keySlot: Int? = nil,
            lastUsedAt: Date? = nil,
            body: String
        ) {
            self.slug = slug
            self.name = name
            self.icon = icon
            self.color = color
            self.keySlot = keySlot
            self.lastUsedAt = lastUsedAt
            self.body = body
        }
    }

    /// Two icon kinds; first-class enum so the editor + popup can render
    /// the right glyph without sniffing strings.
    public enum Icon: Equatable, Sendable, Codable {
        case emoji(String)
        case symbol(String) // SF Symbol name

        public var displayHint: String {
            switch self {
            case .emoji(let s): return s
            case .symbol(let n): return "⌘\(n)"
            }
        }
    }

    public enum NotionColor: String, CaseIterable, Sendable, Codable {
        case gray, brown, orange, yellow, green, blue, purple, pink, red
    }

    public enum StoreError: Error, LocalizedError {
        case slugTaken(String)
        case slugNotFound(String)
        case invalidName(String)
        case slotOutOfRange(Int)
        case ioFailure(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .slugTaken(let s): return "A command with slug '\(s)' already exists."
            case .slugNotFound(let s): return "No command with slug '\(s)'."
            case .invalidName(let n): return "Invalid command name: '\(n)'."
            case .slotOutOfRange(let s): return "Key slot must be 0–9 (got \(s))."
            case .ioFailure(let e): return "Command store I/O failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Paths

    private var dir: URL { BridgePaths.applicationSupport(.commands) }
    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private func bodyURL(_ slug: String) -> URL { dir.appendingPathComponent("\(slug).md") }

    // MARK: - Lifecycle

    public func resetForTesting() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
    }

    /// First-run seed: populate slots 1–5 with example commands if the
    /// store is empty. Idempotent.
    public func seedIfEmpty() throws {
        try ensureDir()
        if FileManager.default.fileExists(atPath: indexURL.path) { return }
        for (slot, seed) in Self.firstRunSeeds.enumerated() {
            _ = try create(
                name: seed.name,
                icon: seed.icon,
                color: seed.color,
                body: seed.body,
                keySlot: slot + 1   // slots 1…5
            )
        }
    }

    // MARK: - List / read

    /// All commands, sorted by lastUsedAt desc (most-recent first); names
    /// without lastUsedAt sort alphabetically at the end.
    public func list() throws -> [Command] {
        try ensureDir()
        let index = try loadIndex()
        return try index.map { try loadCommand(slug: $0.slug) }.sortedByRecency()
    }

    public func get(slug: String) throws -> Command? {
        try ensureDir()
        let index = try loadIndex()
        guard index.contains(where: { $0.slug == slug }) else { return nil }
        return try loadCommand(slug: slug)
    }

    /// Substring match on name. Recency-sorted (matching the popup spec).
    public func search(_ query: String) throws -> [Command] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return try list() }
        return try list().filter { $0.name.lowercased().contains(q) }
    }

    /// Returns the command currently bound to a given 0–9 slot, if any.
    public func command(forKeySlot slot: Int) throws -> Command? {
        try list().first(where: { $0.keySlot == slot })
    }

    // MARK: - Mutations

    @discardableResult
    public func create(
        name: String,
        icon: Icon,
        color: NotionColor? = nil,
        body: String,
        keySlot: Int? = nil
    ) throws -> Command {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw StoreError.invalidName(name) }
        let slug = Self.slugify(trimmedName)
        guard !slug.isEmpty else { throw StoreError.invalidName(name) }

        var idx = try loadIndex()
        if idx.contains(where: { $0.slug == slug }) {
            throw StoreError.slugTaken(slug)
        }
        if let slot = keySlot {
            try assertSlotInRange(slot)
            // Evict any current holder.
            idx = idx.map { entry in
                var e = entry
                if e.keySlot == slot { e.keySlot = nil }
                return e
            }
        }

        let cmd = Command(
            slug: slug,
            name: trimmedName,
            icon: icon,
            color: color,
            keySlot: keySlot,
            lastUsedAt: nil,
            body: body
        )
        try ensureDir()
        try writeBody(cmd)
        idx.append(IndexEntry(from: cmd))
        try writeIndex(idx)
        return cmd
    }

    @discardableResult
    public func update(_ command: Command) throws -> Command {
        var idx = try loadIndex()
        guard let row = idx.firstIndex(where: { $0.slug == command.slug }) else {
            throw StoreError.slugNotFound(command.slug)
        }
        if let slot = command.keySlot {
            try assertSlotInRange(slot)
            // Evict any other holder of this slot.
            for i in idx.indices where i != row && idx[i].keySlot == slot {
                idx[i].keySlot = nil
            }
        }
        try writeBody(command)
        idx[row] = IndexEntry(from: command)
        try writeIndex(idx)
        return command
    }

    public func delete(slug: String) throws {
        var idx = try loadIndex()
        guard idx.contains(where: { $0.slug == slug }) else {
            throw StoreError.slugNotFound(slug)
        }
        let fm = FileManager.default
        let body = bodyURL(slug)
        if fm.fileExists(atPath: body.path) {
            try fm.removeItem(at: body)
        }
        idx.removeAll(where: { $0.slug == slug })
        try writeIndex(idx)
    }

    /// Reassign (or clear) a command's key slot. Atomically evicts any
    /// other command currently holding the target slot.
    public func setKeySlot(slug: String, slot: Int?) throws {
        if let s = slot { try assertSlotInRange(s) }
        var idx = try loadIndex()
        guard let row = idx.firstIndex(where: { $0.slug == slug }) else {
            throw StoreError.slugNotFound(slug)
        }
        if let s = slot {
            for i in idx.indices where i != row && idx[i].keySlot == s {
                idx[i].keySlot = nil
            }
        }
        idx[row].keySlot = slot
        try writeIndex(idx)
    }

    /// Stamp lastUsedAt to now. Called when the command fires from the popup.
    public func recordUse(slug: String, at when: Date = Date()) throws {
        var idx = try loadIndex()
        guard let row = idx.firstIndex(where: { $0.slug == slug }) else {
            throw StoreError.slugNotFound(slug)
        }
        idx[row].lastUsedAt = when
        try writeIndex(idx)
    }

    // MARK: - Persistence helpers

    private struct IndexEntry: Codable, Equatable {
        var slug: String
        var name: String
        var icon: Icon
        var color: NotionColor?
        var keySlot: Int?
        var lastUsedAt: Date?

        init(from c: Command) {
            self.slug = c.slug
            self.name = c.name
            self.icon = c.icon
            self.color = c.color
            self.keySlot = c.keySlot
            self.lastUsedAt = c.lastUsedAt
        }
    }

    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func loadIndex() throws -> [IndexEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([IndexEntry].self, from: data)
    }

    private func writeIndex(_ entries: [IndexEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: indexURL, options: .atomic)
    }

    private func loadCommand(slug: String) throws -> Command {
        let idx = try loadIndex()
        guard let entry = idx.first(where: { $0.slug == slug }) else {
            throw StoreError.slugNotFound(slug)
        }
        let body = (try? String(contentsOf: bodyURL(slug), encoding: .utf8)) ?? ""
        return Command(
            slug: entry.slug,
            name: entry.name,
            icon: entry.icon,
            color: entry.color,
            keySlot: entry.keySlot,
            lastUsedAt: entry.lastUsedAt,
            body: body
        )
    }

    private func writeBody(_ c: Command) throws {
        try c.body.write(to: bodyURL(c.slug), atomically: true, encoding: .utf8)
    }

    private func assertSlotInRange(_ slot: Int) throws {
        if slot < 0 || slot > 9 { throw StoreError.slotOutOfRange(slot) }
    }

    // MARK: - Slugification

    /// Lower-case, replace whitespace runs with `-`, strip to ASCII [a-z0-9_-].
    /// v3.6·6 audit: locked to ASCII (was `CharacterSet.lowercaseLetters` =
    /// Unicode Ll). Cyrillic 'а' (U+0430) is visually identical to ASCII 'a'
    /// — accepting both would let two visually-identical command names
    /// produce different slugs, bypassing the duplicate-slug check.
    public static func slugify(_ name: String) -> String {
        let lower = name.lowercased()
        let collapsed = lower.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        let filtered = collapsed.unicodeScalars.filter { scalar in
            let v = scalar.value
            let isAsciiLower = v >= 0x61 && v <= 0x7A   // a-z
            let isAsciiDigit = v >= 0x30 && v <= 0x39   // 0-9
            return isAsciiLower || isAsciiDigit || scalar == "-" || scalar == "_"
        }
        return String(String.UnicodeScalarView(filtered))
    }

    // MARK: - First-run templates

    private struct Seed {
        let name: String
        let icon: Icon
        let color: NotionColor?
        let body: String
    }

    private static let firstRunSeeds: [Seed] = [
        Seed(name: "Execute",     icon: .emoji("⚡"),  color: .orange,
             body: "## Execute\n\nProceed with the plan we just landed. Use minimum tool calls; no narration."),
        Seed(name: "Reflow",      icon: .emoji("🔁"),  color: .blue,
             body: "## Reflow\n\nRe-examine the plan from first principles. What changed? What's new evidence? What would you do differently if starting from scratch?"),
        Seed(name: "Discussion",  icon: .emoji("💬"),  color: .blue,
             body: "## Discussion\n\nWalk me through the tradeoffs before we commit.\n\n- What are we optimizing for?\n- What's the cost of being wrong?\n- What would change your mind?"),
        Seed(name: "Open-loops",  icon: .emoji("📋"),  color: .green,
             body: "## Open-loops\n\nList every open thread from this conversation. Order by importance. Mark which need user input."),
        Seed(name: "Close-loop",  icon: .emoji("✅"),  color: .green,
             body: "## Close-loop\n\nSummarize what shipped, what changed, what's still open. Surface anything I should know that you haven't said yet."),
    ]
}

// MARK: - Sort by recency

private extension Array where Element == CommandStore.Command {
    func sortedByRecency() -> [CommandStore.Command] {
        sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (.some(da), .some(db)): return da > db
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}
