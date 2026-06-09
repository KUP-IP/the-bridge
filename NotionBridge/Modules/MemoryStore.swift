// MemoryStore.swift — Unified Memory subsystem · FOUNDATION (Wave 1)
// NotionBridge · Modules
//
// The local store + salience-ranked recall behind the `memory_remember` /
// `memory_recall` MCP tools. This is the FOUNDATION wave only:
//   • SQLite-backed entry store with an FTS5 full-text index over `text`.
//   • `remember` with content-hash + near-duplicate dedup/supersede.
//   • `recall` with a salience score (FTS rank · recency-decay · useCount ·
//     type weight · pinned-to-top) and use-promotion (bump useCount +
//     lastUsedAt on returned rows).
//   • `pin`, `forget` (SOFT — tombstone via expiresAt, never hard-delete),
//     `list`, `get`.
//   • `handshakeSlice(limit:)` — a clean extension point for the NEXT wave
//     (handshake memory-slice / bridge://memory resource): returns pinned +
//     top-salience entries, ready to surface. Nothing in this wave consumes
//     it yet.
//
// EXPLICITLY OUT OF SCOPE for this wave (later waves own these):
//   • the handshake memory-slice wiring + bridge://memory resource,
//   • idle consolidation Job, and any UI.
//
// CONCURRENCY: this is a Swift-6 `actor` wrapping the raw SQLite3 C API,
// mirroring `JobStore` (PKT-340). The actor's serial executor IS the
// single serialized writer the WAL journal mode wants — every prepare/
// step/finalize runs inside actor isolation, so there is no second writer
// and no cross-thread handle sharing. The `sqlite3` handle (`OpaquePointer`)
// never escapes the actor.
//
// DB PATH: alongside the app config (ConfigManager → ~/.config/notion-bridge/)
// as `memory.sqlite`. `MemoryPaths.sqliteURL` derives it from
// `ConfigManager.shared.configFileURL`'s parent so a `BRIDGE_CONFIG_PATH`
// override relocates the memory DB in lockstep with config (tests + CI).
// Tests pass an EXPLICIT temp path to `MemoryStore(path:)` and never touch
// the real DB or the shared singleton.

import Foundation
import SQLite3

// sqlite3 transient-destructor sentinel (re-declared because SQLITE_TRANSIENT
// is a C macro not re-exported as a Swift constant). Same pattern as JobStore.
private let MEM_SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

// MARK: - Paths

public enum MemoryPaths {
    /// `~/.config/notion-bridge/memory.sqlite` — the memory DB lives ALONGSIDE
    /// the app config file (ConfigManager owns that directory). Deriving it from
    /// `configFileURL` means a `BRIDGE_CONFIG_PATH` override relocates the
    /// memory store in lockstep (CI / sandbox / tests).
    public static var sqliteURL: URL {
        ConfigManager.shared.configFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("memory.sqlite")
    }
}

// MARK: - Entry model

/// One memory entry. `scope` is the partition (people / project / mac / time /
/// skill / global / …) and `entity` the optional sub-key within a scope (e.g. a
/// person id, a project slug). `type` weights salience. `pinned` floats an
/// entry to the top of recall. `supersedesId` links a refreshed entry to the
/// row it replaced; `expiresAt` doubles as the soft-delete tombstone.
public struct MemoryEntry: Codable, Sendable, Equatable {
    public enum EntryType: String, Codable, Sendable, CaseIterable {
        case fact, preference, decision, reference
    }

    public var id: String
    public var scope: String
    public var entity: String?
    public var text: String
    public var type: EntryType
    public var pinned: Bool
    public var useCount: Int
    public var createdAt: Date
    public var lastUsedAt: Date
    public var source: String
    public var contentHash: String
    public var supersedesId: String?
    public var expiresAt: Date?

    public init(
        id: String = UUID().uuidString,
        scope: String,
        entity: String? = nil,
        text: String,
        type: EntryType = .fact,
        pinned: Bool = false,
        useCount: Int = 0,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        source: String,
        contentHash: String,
        supersedesId: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.scope = scope
        self.entity = entity
        self.text = text
        self.type = type
        self.pinned = pinned
        self.useCount = useCount
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.source = source
        self.contentHash = contentHash
        self.supersedesId = supersedesId
        self.expiresAt = expiresAt
    }
}

// MARK: - Errors

public enum MemoryStoreError: LocalizedError, Equatable {
    case storageFailure(String)
    case invalidArgument(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .storageFailure(let m): return "Memory store error: \(m)"
        case .invalidArgument(let m): return "Invalid memory argument: \(m)"
        case .notFound(let id): return "Memory entry not found: \(id)"
        }
    }
}

// MARK: - Schema

enum MemorySchema {
    /// Base table. Timestamps are REAL (unix epoch seconds) so recency decay
    /// is a plain arithmetic delta — no date parsing on the hot recall path.
    static let createMemory = """
    CREATE TABLE IF NOT EXISTS memory (
        id TEXT PRIMARY KEY,
        scope TEXT NOT NULL,
        entity TEXT,
        text TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'fact',
        pinned INTEGER NOT NULL DEFAULT 0,
        useCount INTEGER NOT NULL DEFAULT 0,
        createdAt REAL NOT NULL,
        lastUsedAt REAL NOT NULL,
        source TEXT NOT NULL DEFAULT '',
        contentHash TEXT NOT NULL,
        supersedesId TEXT,
        expiresAt REAL
    );
    """

    static let createScopeIndex = """
    CREATE INDEX IF NOT EXISTS idx_memory_scope_entity ON memory(scope, entity);
    """

    static let createHashIndex = """
    CREATE INDEX IF NOT EXISTS idx_memory_hash ON memory(contentHash);
    """

    /// FTS5 contentless-linked index over `text`. `content='memory'` +
    /// `content_rowid` makes the FTS table an external-content index whose
    /// rows mirror `memory`; triggers keep it in sync. We key on the table's
    /// implicit rowid (`memory` has a TEXT PK, so rowid is the hidden
    /// auto-rowid) — the triggers below carry it across.
    static let createFTS = """
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
        text,
        content='memory',
        content_rowid='rowid'
    );
    """

    // Sync triggers: keep memory_fts row-aligned with memory.rowid.
    static let triggerInsert = """
    CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory BEGIN
        INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    """

    static let triggerDelete = """
    CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory BEGIN
        INSERT INTO memory_fts(memory_fts, rowid, text) VALUES('delete', old.rowid, old.text);
    END;
    """

    static let triggerUpdate = """
    CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE ON memory BEGIN
        INSERT INTO memory_fts(memory_fts, rowid, text) VALUES('delete', old.rowid, old.text);
        INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    """
}

// MARK: - MemoryStore actor

public actor MemoryStore {
    /// Production singleton bound to the real (config-dir) DB path. Tests must
    /// NOT use this — they instantiate `MemoryStore(path:)` with a temp file.
    public static let shared = MemoryStore()

    private let path: URL
    private var db: OpaquePointer?
    private var isOpen = false

    /// `path` defaults to the config-dir `memory.sqlite`. Tests pass a temp URL.
    public init(path: URL = MemoryPaths.sqliteURL) {
        self.path = path
    }

    // MARK: Lifecycle

    public func open() throws {
        if isOpen { return }
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        // FULLMUTEX is belt-and-suspenders: the actor already serializes access,
        // but the serialized-threading mode costs nothing here and hardens
        // against any future nonisolated handle leak. Mirrors JobStore.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw MemoryStoreError.storageFailure("sqlite3_open_v2 failed: \(rc)")
        }
        db = handle
        isOpen = true

        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec(MemorySchema.createMemory)
        try exec(MemorySchema.createScopeIndex)
        try exec(MemorySchema.createHashIndex)
        try exec(MemorySchema.createFTS)
        try exec(MemorySchema.triggerInsert)
        try exec(MemorySchema.triggerDelete)
        try exec(MemorySchema.triggerUpdate)
    }

    public func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        isOpen = false
    }

    private func ensureOpen() throws {
        if !isOpen { try open() }
    }

    // MARK: Public API — remember

    /// Persist a memory. Computes a content hash and DEDUPS:
    ///   1. exact hash match (same normalized text) anywhere → refresh that row
    ///      (bump useCount, refresh lastUsedAt/source) and return it.
    ///   2. else, a near-duplicate in the SAME scope+entity (high token overlap)
    ///      → insert the new row, point its `supersedesId` at the old row, and
    ///      TOMBSTONE the old row (soft) so recall returns only the fresh text.
    ///   3. else insert fresh.
    @discardableResult
    public func remember(
        text rawText: String,
        scope: String,
        entity: String? = nil,
        type: MemoryEntry.EntryType = .fact,
        source: String
    ) throws -> MemoryEntry {
        try ensureOpen()
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MemoryStoreError.invalidArgument("text is empty") }
        guard !scope.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MemoryStoreError.invalidArgument("scope is empty")
        }
        let hash = Self.contentHash(text)
        let now = Date()

        // Dedup is SCOPED to (scope, entity): identical text about a different
        // entity/scope is a distinct memory, not a duplicate.
        let candidates = try liveEntries(scope: scope, entity: entity)

        // 1. Exact-hash refresh within this scope+entity. Update in place, promote.
        if let existing = candidates.first(where: { $0.contentHash == hash }) {
            try bumpUse(id: existing.id, at: now)
            try refreshSource(id: existing.id, source: source)
            return try get(id: existing.id) ?? existing
        }

        // 2. Near-duplicate within the same scope+entity → supersede.
        let incomingTokens = Self.tokenSet(text)
        if let dup = candidates.first(where: {
            Self.jaccard(incomingTokens, Self.tokenSet($0.text)) >= Self.dedupThreshold
        }) {
            let fresh = MemoryEntry(
                scope: scope, entity: entity, text: text, type: type,
                pinned: dup.pinned, useCount: dup.useCount + 1,
                createdAt: now, lastUsedAt: now, source: source,
                contentHash: hash, supersedesId: dup.id
            )
            try insertRow(fresh)
            try tombstone(id: dup.id, at: now)   // soft-retire the stale text
            return fresh
        }

        // 3. Fresh insert.
        let entry = MemoryEntry(
            scope: scope, entity: entity, text: text, type: type,
            pinned: false, useCount: 0, createdAt: now, lastUsedAt: now,
            source: source, contentHash: hash
        )
        try insertRow(entry)
        return entry
    }

    // MARK: Public API — recall

    /// FTS5 recall ranked by salience, then use-promote the returned rows.
    /// Tombstoned/expired rows are excluded. An empty/`*`-only query falls back
    /// to the salience-ranked recent set (so a bare scope/entity recall works).
    public func recall(
        query rawQuery: String,
        scope: String? = nil,
        entity: String? = nil,
        limit: Int = 8
    ) throws -> [MemoryEntry] {
        try ensureOpen()
        let limit = max(1, min(limit, 100))
        let now = Date()
        let matchExpr = Self.ftsMatchExpression(rawQuery)

        var results: [(entry: MemoryEntry, rank: Double)]
        if let matchExpr {
            results = try ftsRanked(match: matchExpr, scope: scope, entity: entity)
        } else {
            // No usable query terms — rank the live set by salience only.
            results = try liveEntries(scope: scope, entity: entity).map { ($0, 0.0) }
        }

        let scored = results
            .map { (entry: $0.entry, score: Self.salience(entry: $0.entry, ftsRank: $0.rank, now: now)) }
            .sorted { lhs, rhs in
                if lhs.entry.pinned != rhs.entry.pinned { return lhs.entry.pinned }  // pinned → top
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.lastUsedAt > rhs.entry.lastUsedAt                   // tiebreak: recency
            }
            .prefix(limit)
            .map(\.entry)

        // Use-promote: bump useCount + lastUsedAt on every returned row, then
        // return the post-bump snapshot so the caller sees current counters.
        var promoted: [MemoryEntry] = []
        for e in scored {
            try bumpUse(id: e.id, at: now)
            if let refreshed = try get(id: e.id) { promoted.append(refreshed) }
        }
        return promoted
    }

    // MARK: Public API — pin / forget / list / get

    public func pin(id: String, _ pinned: Bool) throws {
        try ensureOpen()
        try bindStep("UPDATE memory SET pinned=? WHERE id=?;") { stmt in
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            sqlite3_bind_text(stmt, 2, id, -1, MEM_SQLITE_TRANSIENT)
        }
    }

    /// SOFT delete: set the `expiresAt` tombstone to now. The row is preserved
    /// (audit / supersede chains stay intact) but excluded from all recall/list.
    public func forget(id: String) throws {
        try ensureOpen()
        try tombstone(id: id, at: Date())
    }

    /// All LIVE entries, optionally scoped. Newest-first. Excludes tombstoned.
    public func list(scope: String? = nil, entity: String? = nil) throws -> [MemoryEntry] {
        try ensureOpen()
        return try liveEntries(scope: scope, entity: entity)
    }

    public func get(id: String) throws -> MemoryEntry? {
        try ensureOpen()
        let rows = try queryRows(
            "SELECT \(Self.columns) FROM memory WHERE id=? LIMIT 1;"
        ) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, MEM_SQLITE_TRANSIENT)
        }
        return rows.compactMap(Self.entryFromRow).first
    }

    // MARK: Extension point — handshake slice (NEXT WAVE)

    /// Pinned + top-salience entries, ready for the future handshake
    /// memory-slice / `bridge://memory` resource to surface. NOT consumed in
    /// this foundation wave — it exists so the next wave has a stable seam and
    /// does NOT use-promote (a passive surface read must not perturb counters).
    public func handshakeSlice(limit: Int = 12) throws -> [MemoryEntry] {
        try ensureOpen()
        let now = Date()
        let all = try liveEntries(scope: nil, entity: nil)
        return all
            .map { (entry: $0, score: Self.salience(entry: $0, ftsRank: 0.0, now: now)) }
            .sorted { lhs, rhs in
                if lhs.entry.pinned != rhs.entry.pinned { return lhs.entry.pinned }
                return lhs.score > rhs.score
            }
            .prefix(max(1, limit))
            .map(\.entry)
    }

    // MARK: Wave 2 — export / import / consolidation

    /// JSON envelope for `memory_export` / `memory_import` (local-only sync seam).
    public struct ExportEnvelope: Codable, Sendable, Equatable {
        public static let currentSchemaVersion = 1
        public var schemaVersion: Int
        public var exportedAt: Date
        public var entries: [MemoryEntry]

        public init(exportedAt: Date = Date(), entries: [MemoryEntry]) {
            self.schemaVersion = Self.currentSchemaVersion
            self.exportedAt = exportedAt
            self.entries = entries
        }
    }

    public struct ImportResult: Sendable, Equatable {
        public var imported: Int
        public var skipped: Int
        public var errors: [String]
    }

    public struct ConsolidationReport: Sendable, Equatable {
        public var referenceDemoted: Int
        public var expiredTombstoned: Int
    }

    /// All live rows as JSON (pretty-printed). Does not include tombstoned rows.
    public func exportJSON() throws -> String {
        try ensureOpen()
        let entries = try liveEntries(scope: nil, entity: nil)
        let envelope = ExportEnvelope(entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope),
              let json = String(data: data, encoding: .utf8) else {
            throw MemoryStoreError.storageFailure("export encode failed")
        }
        return json
    }

    /// Import from a Wave-2 export envelope. Skips rows whose `contentHash` already
    /// exists live in the same scope+entity; otherwise inserts with a fresh id.
    public func importJSON(_ raw: String) throws -> ImportResult {
        try ensureOpen()
        guard let data = raw.data(using: .utf8) else {
            throw MemoryStoreError.invalidArgument("import payload is not valid UTF-8")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ExportEnvelope.self, from: data)
        guard envelope.schemaVersion == ExportEnvelope.currentSchemaVersion else {
            throw MemoryStoreError.invalidArgument("unsupported export schemaVersion \(envelope.schemaVersion)")
        }
        var imported = 0
        var skipped = 0
        var errors: [String] = []
        for entry in envelope.entries {
            do {
                if try liveDuplicateExists(scope: entry.scope, entity: entry.entity, hash: entry.contentHash) {
                    skipped += 1
                    continue
                }
                var row = entry
                row.id = UUID().uuidString
                row.supersedesId = nil
                try insertRow(row)
                imported += 1
            } catch {
                errors.append("\(entry.id): \(error.localizedDescription)")
            }
        }
        return ImportResult(imported: imported, skipped: skipped, errors: errors)
    }

    /// On-launch catch-up: demote-not-delete stale `reference` rows and tombstone
    /// any row whose explicit `expiresAt` is in the past. Pinned rows are never swept.
    public func consolidationSweep(now: Date = Date()) throws -> ConsolidationReport {
        try ensureOpen()
        var referenceDemoted = 0
        var expiredTombstoned = 0
        let all = try liveEntries(scope: nil, entity: nil)
        for entry in all where !entry.pinned {
            if let exp = entry.expiresAt, exp <= now {
                try tombstone(id: entry.id, at: now)
                expiredTombstoned += 1
                continue
            }
            if entry.type == .reference {
                let age = now.timeIntervalSince(entry.lastUsedAt)
                if age >= Self.referenceStaleSeconds {
                    try tombstone(id: entry.id, at: now)
                    referenceDemoted += 1
                }
            }
        }
        return ConsolidationReport(referenceDemoted: referenceDemoted, expiredTombstoned: expiredTombstoned)
    }

    /// ~90 days without use: `reference` entries are soft-tombstoned on consolidation.
    static let referenceStaleSeconds: TimeInterval = 60 * 60 * 24 * 90

    private func liveDuplicateExists(scope: String, entity: String?, hash: String) throws -> Bool {
        try liveEntry(matchingHash: hash).map { existing in
            existing.scope == scope && existing.entity == entity
        } ?? false
    }

    // MARK: - Salience

    /// Salience = weighted sum of:
    ///   • FTS relevance      (bm25 → higher-is-better, normalized)
    ///   • recency decay      (exp(-age / halfLife) over lastUsedAt)
    ///   • use frequency      (log1p(useCount), so the 1st reuse matters most)
    ///   • type weight        (decision > preference > fact > reference)
    /// Pinned is NOT folded in here — it sorts strictly above everything in the
    /// caller (a pin is a hard "always first", not a score nudge).
    static func salience(entry: MemoryEntry, ftsRank: Double, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(entry.lastUsedAt))
        let recency = exp(-age / recencyHalfLifeSeconds)           // 1.0 (fresh) → 0 (old)
        let frequency = log1p(Double(max(0, entry.useCount)))      // 0, 0.69, 1.10, …
        let typeW = typeWeight(entry.type)
        return ftsWeight * ftsRank
             + recencyWeight * recency
             + frequencyWeight * frequency
             + typeWeightFactor * typeW
    }

    static func typeWeight(_ t: MemoryEntry.EntryType) -> Double {
        switch t {
        case .decision:   return 1.0
        case .preference: return 0.8
        case .fact:       return 0.6
        case .reference:  return 0.4
        }
    }

    // Tunable salience coefficients + decay. Centralized so the next wave can
    // adjust ranking without touching the SQL/dedup logic.
    static let ftsWeight: Double = 1.0
    static let recencyWeight: Double = 1.2
    static let frequencyWeight: Double = 0.5
    static let typeWeightFactor: Double = 0.6
    /// ~30 days: an entry untouched for a month has its recency term halved.
    static let recencyHalfLifeSeconds: Double = 60 * 60 * 24 * 30
    /// Token-overlap (Jaccard) at/above which two entries in the same
    /// scope+entity are treated as the same memory and superseded.
    static let dedupThreshold: Double = 0.72

    // MARK: - Dedup helpers

    static func contentHash(_ text: String) -> String {
        // Normalize (lowercase, collapse whitespace) so trivial casing/spacing
        // differences hash identically → exact-dup refresh path. djb2 over the
        // UTF-8 bytes; collisions are dedup false-positives at worst, which the
        // scope+entity Jaccard pass would also have caught — acceptable, and no
        // CryptoKit dependency for a non-security hash.
        let norm = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        var hash: UInt64 = 5381
        for byte in norm.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return String(hash, radix: 16)
    }

    static func tokenSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 1 }
        )
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0.0 : Double(inter) / Double(union)
    }

    // MARK: - FTS query construction

    /// Build a safe FTS5 MATCH expression from free user text. Tokenizes to
    /// alphanumerics, double-quotes each term (so FTS treats it as a literal,
    /// never a syntax operator), and OR-joins them. Returns nil when there is
    /// nothing to match on (caller falls back to salience-only ranking).
    static func ftsMatchExpression(_ raw: String) -> String? {
        let terms = raw.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        // Quote each term to neutralize FTS operators; OR-join for recall breadth.
        return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// FTS5 ranked query → [(entry, normalized-rank)]. bm25() returns a score
    /// where MORE-negative = better; we flip+normalize to higher-is-better.
    private func ftsRanked(
        match: String,
        scope: String?,
        entity: String?
    ) throws -> [(entry: MemoryEntry, rank: Double)] {
        var sql = """
        SELECT \(Self.prefixedColumns) , bm25(memory_fts) AS bm
        FROM memory_fts
        JOIN memory ON memory.rowid = memory_fts.rowid
        WHERE memory_fts MATCH ?
          AND (memory.expiresAt IS NULL OR memory.expiresAt > ?)
        """
        if scope != nil { sql += " AND memory.scope = ?" }
        if entity != nil { sql += " AND memory.entity = ?" }
        sql += " ORDER BY bm LIMIT 200;"

        let now = Date().timeIntervalSince1970
        let rows = try queryRows(sql) { stmt in
            var i: Int32 = 1
            sqlite3_bind_text(stmt, i, match, -1, MEM_SQLITE_TRANSIENT); i += 1
            sqlite3_bind_double(stmt, i, now); i += 1
            if let scope { sqlite3_bind_text(stmt, i, scope, -1, MEM_SQLITE_TRANSIENT); i += 1 }
            if let entity { sqlite3_bind_text(stmt, i, entity, -1, MEM_SQLITE_TRANSIENT); i += 1 }
        }
        return rows.compactMap { row in
            guard let entry = Self.entryFromRow(row) else { return nil }
            // bm column is the last element; flip sign so larger == more relevant.
            let bm = (row.last as? Double) ?? 0.0
            return (entry, -bm)
        }
    }

    // MARK: - Live-row queries (tombstone-aware)

    private func liveEntry(matchingHash hash: String) throws -> MemoryEntry? {
        let rows = try queryRows("""
        SELECT \(Self.columns) FROM memory
        WHERE contentHash=? AND (expiresAt IS NULL OR expiresAt > ?)
        ORDER BY lastUsedAt DESC LIMIT 1;
        """) { stmt in
            sqlite3_bind_text(stmt, 1, hash, -1, MEM_SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        }
        return rows.compactMap(Self.entryFromRow).first
    }

    private func liveEntries(scope: String?, entity: String?) throws -> [MemoryEntry] {
        var sql = "SELECT \(Self.columns) FROM memory WHERE (expiresAt IS NULL OR expiresAt > ?)"
        if scope != nil { sql += " AND scope = ?" }
        if entity != nil { sql += " AND entity = ?" }
        sql += " ORDER BY pinned DESC, lastUsedAt DESC;"
        let rows = try queryRows(sql) { stmt in
            var i: Int32 = 1
            sqlite3_bind_double(stmt, i, Date().timeIntervalSince1970); i += 1
            if let scope { sqlite3_bind_text(stmt, i, scope, -1, MEM_SQLITE_TRANSIENT); i += 1 }
            if let entity { sqlite3_bind_text(stmt, i, entity, -1, MEM_SQLITE_TRANSIENT); i += 1 }
        }
        return rows.compactMap(Self.entryFromRow)
    }

    // MARK: - Mutations

    private func insertRow(_ e: MemoryEntry) throws {
        try bindStep("""
        INSERT INTO memory(id,scope,entity,text,type,pinned,useCount,createdAt,lastUsedAt,source,contentHash,supersedesId,expiresAt)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
        """) { stmt in
            sqlite3_bind_text(stmt, 1, e.id, -1, MEM_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, e.scope, -1, MEM_SQLITE_TRANSIENT)
            if let entity = e.entity { sqlite3_bind_text(stmt, 3, entity, -1, MEM_SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_text(stmt, 4, e.text, -1, MEM_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, e.type.rawValue, -1, MEM_SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, e.pinned ? 1 : 0)
            sqlite3_bind_int(stmt, 7, Int32(e.useCount))
            sqlite3_bind_double(stmt, 8, e.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, e.lastUsedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 10, e.source, -1, MEM_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 11, e.contentHash, -1, MEM_SQLITE_TRANSIENT)
            if let sup = e.supersedesId { sqlite3_bind_text(stmt, 12, sup, -1, MEM_SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 12) }
            if let exp = e.expiresAt { sqlite3_bind_double(stmt, 13, exp.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 13) }
        }
    }

    private func bumpUse(id: String, at now: Date) throws {
        try bindStep("UPDATE memory SET useCount = useCount + 1, lastUsedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id, -1, MEM_SQLITE_TRANSIENT)
        }
    }

    private func refreshSource(id: String, source: String) throws {
        try bindStep("UPDATE memory SET source = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, source, -1, MEM_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, id, -1, MEM_SQLITE_TRANSIENT)
        }
    }

    private func tombstone(id: String, at now: Date) throws {
        try bindStep("UPDATE memory SET expiresAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id, -1, MEM_SQLITE_TRANSIENT)
        }
    }

    // MARK: - Low-level SQLite helpers (mirror JobStore)

    private func exec(_ sql: String) throws {
        guard let db else { throw MemoryStoreError.storageFailure("db not open") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite3_exec rc=\(rc)"
            sqlite3_free(err)
            throw MemoryStoreError.storageFailure(msg)
        }
    }

    private func bindStep(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        guard let db else { throw MemoryStoreError.storageFailure("db not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MemoryStoreError.storageFailure("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw MemoryStoreError.storageFailure("step rc=\(rc): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func queryRows(_ sql: String, bind: (OpaquePointer?) -> Void) throws -> [[Any?]] {
        guard let db else { throw MemoryStoreError.storageFailure("db not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MemoryStoreError.storageFailure("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cols = sqlite3_column_count(stmt)
            var row: [Any?] = []
            for i in 0..<cols {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(Int64(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT:   row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, i) { row.append(String(cString: c)) } else { row.append(nil) }
                case SQLITE_NULL:    row.append(nil)
                default:             row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }

    // MARK: - Column order + row marshalling

    /// Canonical column list, used by every SELECT so `entryFromRow` indexes
    /// line up. Order is fixed; `entryFromRow` depends on it.
    static let columns = "id,scope,entity,text,type,pinned,useCount,createdAt,lastUsedAt,source,contentHash,supersedesId,expiresAt"
    /// Same columns, prefixed for the FTS join (avoids rowid ambiguity).
    static let prefixedColumns = "memory.id,memory.scope,memory.entity,memory.text,memory.type,memory.pinned,memory.useCount,memory.createdAt,memory.lastUsedAt,memory.source,memory.contentHash,memory.supersedesId,memory.expiresAt"

    static func entryFromRow(_ row: [Any?]) -> MemoryEntry? {
        guard row.count >= 13,
              let id = row[0] as? String,
              let scope = row[1] as? String,
              let text = row[3] as? String,
              let typeRaw = row[4] as? String,
              let type = MemoryEntry.EntryType(rawValue: typeRaw),
              let created = doubleAt(row, 7),
              let lastUsed = doubleAt(row, 8),
              let hash = row[10] as? String
        else { return nil }
        let pinned: Bool = (row[5] as? Int64).map { $0 != 0 } ?? false
        let useCount = Int((row[6] as? Int64) ?? 0)
        let source = (row[9] as? String) ?? ""
        let expiresAt = doubleAt(row, 12).map { Date(timeIntervalSince1970: $0) }
        return MemoryEntry(
            id: id, scope: scope, entity: row[2] as? String, text: text, type: type,
            pinned: pinned, useCount: useCount,
            createdAt: Date(timeIntervalSince1970: created),
            lastUsedAt: Date(timeIntervalSince1970: lastUsed),
            source: source, contentHash: hash,
            supersedesId: row[11] as? String, expiresAt: expiresAt
        )
    }

    /// Tolerant REAL read: SQLite may hand back an INTEGER for a whole-number
    /// REAL column, so accept either.
    private static func doubleAt(_ row: [Any?], _ i: Int) -> Double? {
        if let d = row[i] as? Double { return d }
        if let n = row[i] as? Int64 { return Double(n) }
        return nil
    }
}
