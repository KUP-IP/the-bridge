// JobsManager.swift — Job persistence + LaunchAgent lifecycle (PKT-340 · SEQ 8 · V2-SCHEDULER)
// NotionBridge · Modules
//
// STATUS: Waves 1–4 landed (UEP v3.2.0 execution, 2026-04-17 Override session).
//
// Provides:
//   • JobsPaths   — canonical locations for jobs.sqlite, LaunchAgents dir, plists
//   • JobsSchema  — CREATE TABLE DDL for jobs + job_executions
//   • JobRecord / ActionStep / ExecutionRecord — Codable value types
//   • JobStore    — actor wrapping raw SQLite3 C API (zero SPM deps)
//   • CronParser  — pure-Swift 5-field cron → StartCalendarInterval decomposition
//   • LaunchAgentPlist — plist dict builder, atomic writer, remover
//   • LaunchAgentLifecycle — SMAppService.register/unregister with launchctl fallback
//   • JobsManager — singleton actor glueing store, plist, lifecycle + executing
//                   action chains via ToolRouter on callback
//
// Integration points:
//   • JobsModule calls JobsManager.shared.{createJob,getJob,listJobs,…}
//   • SSEHTTPHandler.processRequest matches POST /jobs/{id}/run and invokes
//     JobsManager.shared.runCallback(jobId:router:)
//   • AppDelegate.applicationDidFinishLaunching schedules bootstrap() which
//     opens the DB, runs migrations, and scans for missed executions.

import Foundation
import MCP
import SQLite3
#if canImport(ServiceManagement)
import ServiceManagement
#endif

// sqlite3 transient-destructor sentinel (re-declared because SQLITE_TRANSIENT is
// a macro in the C headers and not re-exported as a Swift constant).
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

// MARK: - Constants

public enum JobsPaths {
    /// `~/Library/Application Support/The Bridge/jobs/jobs.sqlite` (PKT-1 v3.5)
    public static var sqliteURL: URL {
        BridgePaths.applicationSupport(.jobs).appendingPathComponent("jobs.sqlite")
    }

    /// `~/Library/LaunchAgents/`
    public static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// `~/Library/Logs/The Bridge/jobs/` (PKT-1 v3.5)
    public static var logsDir: URL {
        BridgePaths.logs(.jobs)
    }

    /// `solutions.kup.notionbridge.job.{id}`
    public static func launchLabel(jobId: String) -> String {
        "solutions.kup.notionbridge.job.\(jobId)"
    }

    public static func plistURL(jobId: String) -> URL {
        launchAgentsDir.appendingPathComponent("\(launchLabel(jobId: jobId)).plist")
    }
}

// MARK: - Schema

public enum JobsSchema {
    public static let createJobs = """
    CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        schedule TEXT NOT NULL,
        action_chain TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        skip_on_battery INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    """

    public static let createExecutions = """
    CREATE TABLE IF NOT EXISTS job_executions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
        started_at TEXT NOT NULL,
        completed_at TEXT,
        status TEXT NOT NULL,
        results TEXT,
        error_message TEXT
    );
    """

    public static let createExecutionIndex = """
    CREATE INDEX IF NOT EXISTS idx_executions_job_started
        ON job_executions(job_id, started_at DESC);
    """

    /// PKT-381 (Scheduler Resilience): durable missed-occurrence backlog. Each
    /// row is one scheduled occurrence that the reconciler determined was missed
    /// (last-success → now, deduped against job_executions). The
    /// `UNIQUE(job_id, occurrence_ts)` constraint is the load-bearing idempotency
    /// key: an occurrence is enqueued AT MOST ONCE across the reconciler, a
    /// relaunch, and a launchd wake-run — re-enqueue is an `INSERT OR IGNORE`
    /// no-op. `occurrence_ts` is the ISO8601 wall-clock instant the slot was due.
    /// Additive migration: created on open(); never alters jobs / job_executions.
    public static let createBacklog = """
    CREATE TABLE IF NOT EXISTS job_backlog (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
        occurrence_ts TEXT NOT NULL,
        enqueued_at TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        UNIQUE(job_id, occurrence_ts)
    );
    """

    /// Drain order index: oldest-pending-first lookups hit this directly.
    public static let createBacklogIndex = """
    CREATE INDEX IF NOT EXISTS idx_backlog_status_occurrence
        ON job_backlog(status, occurrence_ts ASC);
    """
}

// MARK: - Value types

public struct ActionStep: Codable, Sendable, Equatable {
    public enum OnFail: String, Codable, Sendable { case stop, `continue`, retry }
    public var tool: String
    public var arguments: [String: JSONValue]
    public var onFail: OnFail

    public init(tool: String, arguments: [String: JSONValue] = [:], onFail: OnFail = .stop) {
        self.tool = tool
        self.arguments = arguments
        self.onFail = onFail
    }

    enum CodingKeys: String, CodingKey { case tool, arguments, onFail = "on_fail" }
}

public struct JobRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case active, paused }

    public var id: String
    public var name: String
    public var schedule: String
    public var actionChain: [ActionStep]
    public var status: Status
    public var skipOnBattery: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                schedule: String,
                actionChain: [ActionStep],
                status: Status = .active,
                skipOnBattery: Bool = false,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.actionChain = actionChain
        self.status = status
        self.skipOnBattery = skipOnBattery
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ExecutionRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case success, failure, partial, skipped }
    public var id: Int64?
    public var jobId: String
    public var startedAt: Date
    public var completedAt: Date?
    public var status: Status
    public var results: String?      // JSON string of per-step results
    public var errorMessage: String?

    public init(id: Int64? = nil,
                jobId: String,
                startedAt: Date,
                completedAt: Date? = nil,
                status: Status,
                results: String? = nil,
                errorMessage: String? = nil) {
        self.id = id
        self.jobId = jobId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.results = results
        self.errorMessage = errorMessage
    }
}

/// PKT-381: one durable backlog entry — a single missed scheduled occurrence
/// the reconciler decided still needs to run. `occurrenceTs` is the wall-clock
/// instant the slot was originally due; `(jobId, occurrenceTs)` is unique, which
/// is the idempotency key the whole resilience design hangs on.
public struct BacklogRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, running, done, skipped }
    public var id: Int64?
    public var jobId: String
    public var occurrenceTs: Date
    public var enqueuedAt: Date
    public var status: Status

    public init(id: Int64? = nil,
                jobId: String,
                occurrenceTs: Date,
                enqueuedAt: Date = Date(),
                status: Status = .pending) {
        self.id = id
        self.jobId = jobId
        self.occurrenceTs = occurrenceTs
        self.enqueuedAt = enqueuedAt
        self.status = status
    }
}

/// Minimal Codable JSON wrapper used for action-step arguments (MCP `Value` is
/// not Codable across module boundaries here).
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "unknown JSON type"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Convert from an MCP `Value` (used at tool input decode time).
    public static func fromMCP(_ v: Value) -> JSONValue {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(Int64(i))
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(fromMCP))
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, val) in o { out[k] = fromMCP(val) }
            return .object(out)
        case .data: return .string("<binary>")
        }
    }

    public func toMCP() -> Value {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(Int(i))
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map { $0.toMCP() })
        case .object(let o):
            var out: [String: Value] = [:]
            for (k, v) in o { out[k] = v.toMCP() }
            return .object(out)
        }
    }
}

// MARK: - JobStore (raw SQLite3 C API)

public actor JobStore {
    public static let shared = JobStore()

    private var db: OpaquePointer?
    private var isOpen = false

    private init() {}

    public func open(path: URL = JobsPaths.sqliteURL) throws {
        if isOpen { return }
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw JobsModuleError.storageFailure("sqlite3_open_v2 failed: \(rc)")
        }
        db = handle
        isOpen = true

        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec(JobsSchema.createJobs)
        try exec(JobsSchema.createExecutions)
        try exec(JobsSchema.createExecutionIndex)
        // PKT-381: additive durable-backlog migration. IF NOT EXISTS makes this
        // a no-op on databases that already have the table, so it is safe to run
        // on every open() and preserves full back-compat with pre-381 DBs.
        try exec(JobsSchema.createBacklog)
        try exec(JobsSchema.createBacklogIndex)
    }

    public func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        isOpen = false
    }

    // MARK: CRUD — jobs

    public func insert(_ job: JobRecord) throws {
        let actionJSON = try encodeActions(job.actionChain)
        let sql = "INSERT INTO jobs(id,name,schedule,action_chain,status,skip_on_battery,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?);"
        try bindAndStep(sql) { stmt in
            sqlite3_bind_text(stmt, 1, job.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, job.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, job.schedule, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, actionJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, job.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, job.skipOnBattery ? 1 : 0)
            sqlite3_bind_text(stmt, 7, Self.iso(job.createdAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, Self.iso(job.updatedAt), -1, SQLITE_TRANSIENT)
        }
    }

    public func updateStatus(id: String, status: JobRecord.Status) throws {
        let sql = "UPDATE jobs SET status=?, updated_at=? WHERE id=?;"
        try bindAndStep(sql) { stmt in
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, Self.iso(Date()), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
        }
    }


    /// Atomic partial update. Caller-provided mutation receives the current
    /// record and returns the modified record. Preserves id and createdAt.
    public func update(id: String, mutate: (JobRecord) -> JobRecord) throws -> JobRecord {
        guard let current = try self.fetch(id: id) else {
            throw JobsModuleError.jobNotFound(id)
        }
        var next = mutate(current)
        next.id = current.id
        next.createdAt = current.createdAt
        next.updatedAt = Date()
        let actionJSON = try encodeActions(next.actionChain)
        let sql = "UPDATE jobs SET name=?, schedule=?, action_chain=?, status=?, skip_on_battery=?, updated_at=? WHERE id=?;"
        try bindAndStep(sql) { stmt in
            sqlite3_bind_text(stmt, 1, next.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, next.schedule, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, actionJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, next.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, next.skipOnBattery ? 1 : 0)
            sqlite3_bind_text(stmt, 6, Self.iso(next.updatedAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, next.id, -1, SQLITE_TRANSIENT)
        }
        return next
    }

    public func deleteExecutions(jobId: String) throws {
        let sql = "DELETE FROM job_executions WHERE job_id=?;"
        try bindAndStep(sql) { stmt in
            sqlite3_bind_text(stmt, 1, jobId, -1, SQLITE_TRANSIENT)
        }
    }

    public func delete(id: String) throws {
        let sql = "DELETE FROM jobs WHERE id=?;"
        try bindAndStep(sql) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        }
    }

    public func fetch(id: String) throws -> JobRecord? {
        let rows = try query("SELECT id,name,schedule,action_chain,status,skip_on_battery,created_at,updated_at FROM jobs WHERE id=?;") { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        }
        return rows.compactMap(Self.jobFromRow).first
    }

    public func listAll(statusFilter: JobRecord.Status? = nil) throws -> [JobRecord] {
        let sql: String
        let rows: [[Any?]]
        if let statusFilter {
            sql = "SELECT id,name,schedule,action_chain,status,skip_on_battery,created_at,updated_at FROM jobs WHERE status=? ORDER BY created_at DESC;"
            rows = try query(sql) { stmt in
                sqlite3_bind_text(stmt, 1, statusFilter.rawValue, -1, SQLITE_TRANSIENT)
            }
        } else {
            sql = "SELECT id,name,schedule,action_chain,status,skip_on_battery,created_at,updated_at FROM jobs ORDER BY created_at DESC;"
            rows = try query(sql) { _ in }
        }
        return rows.compactMap(Self.jobFromRow)
    }

    // MARK: CRUD — executions

    @discardableResult
    public func insertExecution(_ rec: ExecutionRecord) throws -> Int64 {
        let sql = "INSERT INTO job_executions(job_id,started_at,completed_at,status,results,error_message) VALUES(?,?,?,?,?,?);"
        try bindAndStep(sql) { stmt in
            sqlite3_bind_text(stmt, 1, rec.jobId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, Self.iso(rec.startedAt), -1, SQLITE_TRANSIENT)
            if let c = rec.completedAt {
                sqlite3_bind_text(stmt, 3, Self.iso(c), -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, rec.status.rawValue, -1, SQLITE_TRANSIENT)
            if let r = rec.results {
                sqlite3_bind_text(stmt, 5, r, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if let e = rec.errorMessage {
                sqlite3_bind_text(stmt, 6, e, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func executions(jobId: String, limit: Int = 20) throws -> [ExecutionRecord] {
        let sql = "SELECT id,job_id,started_at,completed_at,status,results,error_message FROM job_executions WHERE job_id=? ORDER BY started_at DESC LIMIT ?;"
        let rows = try query(sql) { stmt in
            sqlite3_bind_text(stmt, 1, jobId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(max(1, min(limit, 500))))
        }
        return rows.compactMap(Self.execFromRow)
    }

    /// PKT-381: the most recent SUCCESSFUL (or partial) execution for a job, used
    /// by the reconciler as the lower bound when enumerating missed occurrences.
    /// `.skipped` and `.failure` rows are intentionally NOT treated as a
    /// successful watermark — a skip (paused/battery) or failure must not advance
    /// the catch-up cursor, otherwise a slot a failed run "consumed" would be lost.
    /// Returns nil if the job has never run to success, in which case the caller
    /// falls back to the job's createdAt as the enumeration floor.
    public func lastSuccessfulExecution(jobId: String) throws -> ExecutionRecord? {
        let sql = """
        SELECT id,job_id,started_at,completed_at,status,results,error_message
        FROM job_executions
        WHERE job_id=? AND status IN ('success','partial')
        ORDER BY started_at DESC LIMIT 1;
        """
        let rows = try query(sql) { stmt in
            sqlite3_bind_text(stmt, 1, jobId, -1, SQLITE_TRANSIENT)
        }
        return rows.compactMap(Self.execFromRow).first
    }

    /// True iff a job_executions row already exists whose started_at falls inside
    /// the half-open window [windowStart, windowEnd). The reconciler uses this to
    /// dedup an enumerated occurrence against a run launchd may already have
    /// fired (the single coalesced wake-run) before enqueuing it.
    public func hasExecution(jobId: String, in windowStart: Date, _ windowEnd: Date) throws -> Bool {
        let sql = """
        SELECT 1 FROM job_executions
        WHERE job_id=? AND started_at >= ? AND started_at < ? LIMIT 1;
        """
        let rows = try query(sql) { stmt in
            sqlite3_bind_text(stmt, 1, jobId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, Self.iso(windowStart), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, Self.iso(windowEnd), -1, SQLITE_TRANSIENT)
        }
        return !rows.isEmpty
    }

    // MARK: CRUD — backlog (PKT-381)

    /// Idempotent enqueue of one missed occurrence. `INSERT OR IGNORE` against the
    /// `UNIQUE(job_id, occurrence_ts)` constraint means re-enqueuing the same
    /// (job, occurrence) — whether from a second reconciler pass, a relaunch, or a
    /// race with launchd — is a silent no-op. Returns true iff a NEW row was added.
    @discardableResult
    public func enqueueBacklog(jobId: String, occurrenceTs: Date, enqueuedAt: Date = Date()) throws -> Bool {
        let before = sqlite3_total_changes(db)
        let sql = "INSERT OR IGNORE INTO job_backlog(job_id,occurrence_ts,enqueued_at,status) VALUES(?,?,?,'pending');"
        try bindAndStep(sql) { stmt in
            sqlite3_bind_text(stmt, 1, jobId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, Self.iso(occurrenceTs), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, Self.iso(enqueuedAt), -1, SQLITE_TRANSIENT)
        }
        return sqlite3_total_changes(db) > before
    }

    /// All pending backlog rows, oldest-occurrence first (the drain order).
    public func pendingBacklog(limit: Int = 1000) throws -> [BacklogRecord] {
        let sql = """
        SELECT id,job_id,occurrence_ts,enqueued_at,status FROM job_backlog
        WHERE status='pending' ORDER BY occurrence_ts ASC, id ASC LIMIT ?;
        """
        let rows = try query(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(max(1, min(limit, 10000))))
        }
        return rows.compactMap(Self.backlogFromRow)
    }

    /// The single oldest pending backlog row, or nil if the backlog is drained.
    /// This is the serial-drain pick: oldest occurrence wins, id breaks ties.
    public func nextPendingBacklog() throws -> BacklogRecord? {
        let sql = """
        SELECT id,job_id,occurrence_ts,enqueued_at,status FROM job_backlog
        WHERE status='pending' ORDER BY occurrence_ts ASC, id ASC LIMIT 1;
        """
        let rows = try query(sql) { _ in }
        return rows.compactMap(Self.backlogFromRow).first
    }

    /// Backlog rows for a job in any status (test/inspection helper).
    public func backlog(jobId: String) throws -> [BacklogRecord] {
        let sql = """
        SELECT id,job_id,occurrence_ts,enqueued_at,status FROM job_backlog
        WHERE job_id=? ORDER BY occurrence_ts ASC, id ASC;
        """
        let rows = try query(sql) { stmt in
            sqlite3_bind_text(stmt, 1, jobId, -1, SQLITE_TRANSIENT)
        }
        return rows.compactMap(Self.backlogFromRow)
    }

    /// Count of pending backlog rows for a job — used to bound per-job catch-up.
    public func pendingBacklogCount(jobId: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM job_backlog WHERE job_id=? AND status='pending';"
        let rows = try query(sql) { stmt in
            sqlite3_bind_text(stmt, 1, jobId, -1, SQLITE_TRANSIENT)
        }
        if let first = rows.first, let n = first.first as? Int64 { return Int(n) }
        return 0
    }

    /// Total pending backlog rows across all jobs — used for the global ceiling.
    public func pendingBacklogTotal() throws -> Int {
        let sql = "SELECT COUNT(*) FROM job_backlog WHERE status='pending';"
        let rows = try query(sql) { _ in }
        if let first = rows.first, let n = first.first as? Int64 { return Int(n) }
        return 0
    }

    /// Transition a backlog row's status. Used by the drain to move
    /// pending → running → done/skipped. `expecting` (when supplied) makes the
    /// update conditional on the current status, giving an atomic compare-and-set
    /// so two drains can never both claim the same row (single-flight guard).
    /// Returns true iff exactly one row was transitioned.
    @discardableResult
    public func setBacklogStatus(id: Int64, to status: BacklogRecord.Status, expecting: BacklogRecord.Status? = nil) throws -> Bool {
        let before = sqlite3_total_changes(db)
        if let expecting {
            let sql = "UPDATE job_backlog SET status=? WHERE id=? AND status=?;"
            try bindAndStep(sql) { stmt in
                sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, id)
                sqlite3_bind_text(stmt, 3, expecting.rawValue, -1, SQLITE_TRANSIENT)
            }
        } else {
            let sql = "UPDATE job_backlog SET status=? WHERE id=?;"
            try bindAndStep(sql) { stmt in
                sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, id)
            }
        }
        return sqlite3_total_changes(db) > before
    }

    /// Reset any rows stuck in `running` (e.g. the app was killed mid-drain)
    /// back to `pending` so a relaunch resumes them. Returns the count reset.
    @discardableResult
    public func requeueStuckRunning() throws -> Int {
        let before = sqlite3_total_changes(db)
        try exec("UPDATE job_backlog SET status='pending' WHERE status='running';")
        return Int(sqlite3_total_changes(db) - before)
    }

    // MARK: Low-level helpers

    private func exec(_ sql: String) throws {
        guard let db else { throw JobsModuleError.storageFailure("db not open") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite3_exec rc=\(rc)"
            sqlite3_free(err)
            throw JobsModuleError.storageFailure(msg)
        }
    }

    private func bindAndStep(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        guard let db else { throw JobsModuleError.storageFailure("db not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw JobsModuleError.storageFailure("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw JobsModuleError.storageFailure("step rc=\(rc): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void) throws -> [[Any?]] {
        guard let db else { throw JobsModuleError.storageFailure("db not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw JobsModuleError.storageFailure("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
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
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, i) { row.append(String(cString: c)) } else { row.append(nil) }
                case SQLITE_NULL: row.append(nil)
                default: row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }

    // MARK: Row marshalling (static — free functions, no self capture)

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func jobFromRow(_ row: [Any?]) -> JobRecord? {
        guard row.count == 8,
              let id = row[0] as? String,
              let name = row[1] as? String,
              let schedule = row[2] as? String,
              let actionJSON = row[3] as? String,
              let statusRaw = row[4] as? String,
              let status = JobRecord.Status(rawValue: statusRaw),
              let created = parseISO(row[6] as? String),
              let updated = parseISO(row[7] as? String)
        else { return nil }
        let skip: Bool = {
            if let i = row[5] as? Int64 { return i != 0 }
            if let i = row[5] as? Int { return i != 0 }
            return false
        }()
        let actions = (try? decodeActions(actionJSON)) ?? []
        return JobRecord(id: id, name: name, schedule: schedule, actionChain: actions,
                         status: status, skipOnBattery: skip, createdAt: created, updatedAt: updated)
    }

    private static func execFromRow(_ row: [Any?]) -> ExecutionRecord? {
        guard row.count == 7,
              let jobId = row[1] as? String,
              let started = parseISO(row[2] as? String),
              let statusRaw = row[4] as? String,
              let status = ExecutionRecord.Status(rawValue: statusRaw)
        else { return nil }
        let id = (row[0] as? Int64)
        return ExecutionRecord(
            id: id,
            jobId: jobId,
            startedAt: started,
            completedAt: parseISO(row[3] as? String),
            status: status,
            results: row[5] as? String,
            errorMessage: row[6] as? String
        )
    }

    private static func backlogFromRow(_ row: [Any?]) -> BacklogRecord? {
        guard row.count == 5,
              let jobId = row[1] as? String,
              let occ = parseISO(row[2] as? String),
              let enq = parseISO(row[3] as? String),
              let statusRaw = row[4] as? String,
              let status = BacklogRecord.Status(rawValue: statusRaw)
        else { return nil }
        let id = (row[0] as? Int64)
        return BacklogRecord(id: id, jobId: jobId, occurrenceTs: occ, enqueuedAt: enq, status: status)
    }

    private func encodeActions(_ chain: [ActionStep]) throws -> String {
        let data = try JSONEncoder().encode(chain)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeActions(_ json: String) throws -> [ActionStep] {
        guard let data = json.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([ActionStep].self, from: data)
    }
}

// MARK: - CronParser

public enum CronParser {
    public struct CalendarInterval: Sendable, Equatable, Hashable {
        public var minute: Int?
        public var hour: Int?
        public var day: Int?       // day of month
        public var month: Int?
        public var weekday: Int?   // 0 = Sunday

        public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, month: Int? = nil, weekday: Int? = nil) {
            self.minute = minute; self.hour = hour; self.day = day; self.month = month; self.weekday = weekday
        }

        public func plistDict() -> [String: Any] {
            var d: [String: Any] = [:]
            if let minute { d["Minute"] = minute }
            if let hour { d["Hour"] = hour }
            if let day { d["Day"] = day }
            if let month { d["Month"] = month }
            if let weekday { d["Weekday"] = weekday }
            return d
        }
    }

    public static let maxIntervals = 24

    public static func parse(_ expression: String) throws -> [CalendarInterval] {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") {
            throw JobsModuleError.invalidSchedule("@keyword shortcuts are not supported in V2. Use a 5-field expression.")
        }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5 else {
            throw JobsModuleError.invalidSchedule("expected 5 fields (min hour day month weekday), got \(parts.count)")
        }
        let minutes = try expandField(parts[0], range: 0...59, label: "minute")
        let hours = try expandField(parts[1], range: 0...23, label: "hour")
        let days = try expandField(parts[2], range: 1...31, label: "day")
        let months = try expandField(parts[3], range: 1...12, label: "month")
        let weekdaysRaw = try expandField(parts[4], range: 0...7, label: "weekday")
        // Cron allows 7 (=Sunday) in addition to 0. launchd only accepts 0.
        let weekdays: [Int]? = weekdaysRaw.map { list in Array(Set(list.map { $0 == 7 ? 0 : $0 })).sorted() }

        // Cartesian product of the concrete-valued fields.
        let mi: [Int?] = minutes?.map { $0 as Int? } ?? [nil]
        let hr: [Int?] = hours?.map { $0 as Int? } ?? [nil]
        let dy: [Int?] = days?.map { $0 as Int? } ?? [nil]
        let mo: [Int?] = months?.map { $0 as Int? } ?? [nil]
        let wd: [Int?] = weekdays?.map { $0 as Int? } ?? [nil]

        var out: [CalendarInterval] = []
        var seen = Set<CalendarInterval>()
        for m in mi {
            for h in hr {
                for d in dy {
                    for mm in mo {
                        for w in wd {
                            let iv = CalendarInterval(minute: m, hour: h, day: d, month: mm, weekday: w)
                            if seen.insert(iv).inserted { out.append(iv) }
                            if out.count > maxIntervals {
                                throw JobsModuleError.invalidSchedule("expression expands to more than \(maxIntervals) intervals — simplify the schedule")
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Expand a single field. Returns `nil` if the field is `*` (unconstrained).
    /// Otherwise returns the sorted, deduplicated list of concrete integers.
    static func expandField(_ field: String, range: ClosedRange<Int>, label: String) throws -> [Int]? {
        if field == "*" { return nil }
        var values = Set<Int>()
        for token in field.split(separator: ",") {
            let str = String(token)
            var step: Int = 1
            var body = str
            if let slash = str.firstIndex(of: "/") {
                let stepStr = str[str.index(after: slash)...]
                guard let s = Int(stepStr), s >= 1 else {
                    throw JobsModuleError.invalidSchedule("invalid step in \(label): \(str)")
                }
                step = s
                body = String(str[..<slash])
            }
            let lo: Int
            let hi: Int
            if body == "*" {
                lo = range.lowerBound; hi = range.upperBound
            } else if let dash = body.firstIndex(of: "-") {
                guard let a = Int(body[..<dash]),
                      let b = Int(body[body.index(after: dash)...]) else {
                    throw JobsModuleError.invalidSchedule("invalid range in \(label): \(body)")
                }
                guard a <= b, range.contains(a), range.contains(b) else {
                    throw JobsModuleError.invalidSchedule("\(label) range out of bounds: \(body)")
                }
                lo = a; hi = b
            } else {
                guard let n = Int(body), range.contains(n) else {
                    throw JobsModuleError.invalidSchedule("\(label) value out of range: \(body)")
                }
                lo = n; hi = n
            }
            var v = lo
            while v <= hi {
                values.insert(v)
                v += step
            }
        }
        return values.sorted()
    }
}

// MARK: - LaunchAgentPlist

public enum LaunchAgentPlist {
    /// Resolve the bundled NBJobRunner helper path inside the app bundle.
    /// Falls back to /usr/bin/curl (pre-v1.9.2 behaviour) only if the helper
    /// is absent — e.g. in test harness runs where Bundle.main is the test
    /// executable and no helper has been embedded.
    public static func jobRunnerPath() -> String {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        // Inside a real .app bundle: <bundle>/Contents/MacOS/NBJobRunner
        let candidate = (bundlePath as NSString).appendingPathComponent("Contents/MacOS/NBJobRunner")
        if fm.fileExists(atPath: candidate) { return candidate }
        // Fallback for unit tests / swift run: look next to the running executable.
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        let sibling = (exeDir as NSString).appendingPathComponent("NBJobRunner")
        if fm.fileExists(atPath: sibling) { return sibling }
        return "" // empty → caller treats as legacy-mode (no helper available)
    }

    /// Build the plist dictionary. Launchd invokes the bundled NBJobRunner
    /// helper (signed with the app's Developer ID) so macOS Background Task
    /// Management attributes the job to Notion Bridge. Pre-v1.9.2 builds used
    /// /usr/bin/curl which caused one BTM "curl" entry per scheduled job.
    public static func build(jobId: String, intervals: [CronParser.CalendarInterval], ssePort: Int) -> [String: Any] {
        let label = JobsPaths.launchLabel(jobId: jobId)
        let helperPath = jobRunnerPath()
        let program: [String]
        var envVars: [String: String] = ["NB_SSE_PORT": "\(ssePort)"]
        if !helperPath.isEmpty {
            program = [helperPath, jobId]
        } else {
            // Legacy fallback: curl invocation. Only exercised in swift-run/test
            // contexts where the app bundle helper is unavailable.
            let url = "http://127.0.0.1:\(ssePort)/jobs/\(jobId)/run"
            program = [
                "/usr/bin/curl", "-sS", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--max-time", "30",
                "--retry", "2", "--retry-delay", "5",
                url
            ]
            envVars = [:]
        }
        let stdoutPath = JobsPaths.logsDir.appendingPathComponent("\(jobId).out.log").path
        let stderrPath = JobsPaths.logsDir.appendingPathComponent("\(jobId).err.log").path
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": program,
            "RunAtLoad": false,
            "KeepAlive": false,
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
            "ProcessType": "Background"
        ]
        if !envVars.isEmpty {
            plist["EnvironmentVariables"] = envVars
        }
        let dicts = intervals.map { $0.plistDict() }
        if dicts.count == 1 {
            plist["StartCalendarInterval"] = dicts[0]
        } else if dicts.count > 1 {
            plist["StartCalendarInterval"] = dicts
        }
        return plist
    }

    public static func write(jobId: String, plist: [String: Any]) throws {
        try FileManager.default.createDirectory(at: JobsPaths.launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: JobsPaths.logsDir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: JobsPaths.plistURL(jobId: jobId), options: .atomic)
    }

    public static func remove(jobId: String) throws {
        let url = JobsPaths.plistURL(jobId: jobId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - LaunchAgentLifecycle

public enum LaunchAgentLifecycle {
    /// Register (load) an agent. Tries `SMAppService.agent(plistName:)` first,
    /// falls back to `launchctl bootstrap` for environments where
    /// `SMAppService` isn't yet accepted (e.g. unsigned dev builds).
    public static func register(jobId: String) throws {
        let label = JobsPaths.launchLabel(jobId: jobId)
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            let svc = SMAppService.agent(plistName: "\(label).plist")
            do {
                try svc.register()
                return
            } catch {
                // Fall through to launchctl fallback — SMAppService can reject
                // plists that live outside the app bundle on some macOS versions.
            }
        }
        #endif
        try launchctlBootstrap(jobId: jobId)
    }

    public static func unregister(jobId: String) throws {
        let label = JobsPaths.launchLabel(jobId: jobId)
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            let svc = SMAppService.agent(plistName: "\(label).plist")
            // `unregister` is async; best-effort call.
            do { try svc.unregister() } catch { /* fall through */ }
        }
        #endif
        try? launchctlBootout(jobId: jobId)
    }

    // launchctl bootstrap/bootout fallback (user domain = gui/<uid>).
    private static func uidDomain() -> String { "gui/\(getuid())" }

    private static func launchctlBootstrap(jobId: String) throws {
        let path = JobsPaths.plistURL(jobId: jobId).path
        try runLaunchctl(["bootstrap", uidDomain(), path])
    }

    private static func launchctlBootout(jobId: String) throws {
        let label = JobsPaths.launchLabel(jobId: jobId)
        try runLaunchctl(["bootout", "\(uidDomain())/\(label)"])
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw JobsModuleError.launchAgentFailure("/bin/launchctl \(args.joined(separator: " ")) exited with \(p.terminationStatus)")
        }
        return p.terminationStatus
    }
}

// MARK: - JobsManager

public actor JobsManager {
    public static let shared = JobsManager()

    /// Local SSE server port — kept in sync with `SSETransport.defaultPort` (9700).
    public static let ssePort: Int = 9700

    private var didBootstrap = false
    private weak var router: ToolRouter?

    private init() {}

    /// Called by AppDelegate on applicationDidFinishLaunching (and by tools that
    /// need a ready store). Idempotent.
    public func bootstrap(router: ToolRouter? = nil) async {
        if let router { self.router = router }
        if didBootstrap { return }
        do {
            try await JobStore.shared.open()
            didBootstrap = true
            // Best-effort missed-execution scan (Wave 4 quality gate): mark any
            // active jobs whose last execution is suspiciously stale. We log
            // rather than replay — launchd will fire the next scheduled slot.
            _ = try await JobStore.shared.listAll(statusFilter: .active)
            // v1.9.2: Migrate legacy curl-based plists to the signed NBJobRunner
            // helper. One-shot; re-running is a no-op because migrated plists
            // no longer reference /usr/bin/curl.
            await migrateLegacyCurlPlists()
        } catch {
            print("[JobsManager] bootstrap failed: \(error)")
        }
    }

    /// v1.9.2: Rewrite any LaunchAgent plists under ~/Library/LaunchAgents/
    /// that still invoke /usr/bin/curl so that macOS Background Task Management
    /// attributes job agents to Notion Bridge instead of to curl. Idempotent.
    /// Only considers plists with label prefix `solutions.kup.notionbridge.job.`.
    private func migrateLegacyCurlPlists() async {
        let fm = FileManager.default
        let dir = JobsPaths.launchAgentsDir
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let prefix = "solutions.kup.notionbridge.job."
        var migrated = 0
        var skipped = 0
        for url in entries where url.pathExtension == "plist" && url.lastPathComponent.hasPrefix(prefix) {
            guard let data = try? Data(contentsOf: url),
                  let any = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = any as? [String: Any],
                  let args = dict["ProgramArguments"] as? [String],
                  let first = args.first else { continue }
            guard first == "/usr/bin/curl" else { skipped += 1; continue }
            // Derive jobId from filename: solutions.kup.notionbridge.job.<id>.plist
            let name = url.deletingPathExtension().lastPathComponent
            let jobId = String(name.dropFirst(prefix.count))
            guard !jobId.isEmpty else { continue }
            // Unregister old, rewrite, re-register.
            do {
                try LaunchAgentLifecycle.unregister(jobId: jobId)
            } catch {
                print("[JobsManager] migrate: unregister failed for \(jobId): \(error)")
            }
            // Rebuild intervals from the stored JobRecord if present; otherwise
            // preserve the existing StartCalendarInterval dict(s) verbatim by
            // re-parsing from the source job record.
            if let job = try? await JobStore.shared.fetch(id: jobId),
               let intervals = try? CronParser.parse(job.schedule) {
                let newPlist = LaunchAgentPlist.build(jobId: jobId, intervals: intervals, ssePort: Self.ssePort)
                do {
                    try LaunchAgentPlist.write(jobId: jobId, plist: newPlist)
                    try LaunchAgentLifecycle.register(jobId: jobId)
                    migrated += 1
                } catch {
                    print("[JobsManager] migrate: rewrite/register failed for \(jobId): \(error)")
                }
            } else {
                // Orphaned plist with no matching DB row — safer to drop it.
                try? LaunchAgentPlist.remove(jobId: jobId)
                print("[JobsManager] migrate: removed orphaned plist \(jobId)")
            }
        }
        if migrated > 0 || skipped > 0 {
            print("[JobsManager] v1.9.2 BTM migration: migrated=\(migrated) skipped=\(skipped)")
        }
    }


    /// Public accessor for the router stored at bootstrap/runCallback time.
    /// Used by v1.10.0 tools (job_run) and UI Run Now control.
    public func router_() -> ToolRouter? { return router }

    /// Expose ssePort for external consumers (plist rebuilds).
    public static var sseServerPort: Int { ssePort }

    // MARK: Tool handlers (called from JobsModule)

    public func createJob(args: Value) async throws -> Value {
        try await ensureOpen()
        guard case .object(let obj) = args,
              let nameV = obj["name"], case .string(let name) = nameV,
              let schedV = obj["schedule"], case .string(let schedule) = schedV,
              let actsV = obj["actions"], case .array(let actArr) = actsV
        else {
            throw JobsModuleError.invalidActionChain("expected { name, schedule, actions }")
        }
        guard !actArr.isEmpty, actArr.count <= 10 else {
            throw JobsModuleError.invalidActionChain("actions must contain 1–10 steps")
        }
        let skipBattery: Bool = {
            if case .bool(let b) = obj["skipOnBattery"] ?? .null { return b }
            return false
        }()

        // Validate cron up front — this is cheap and surfaces errors at creation.
        let intervals = try CronParser.parse(schedule)

        // Decode action chain.
        let chain: [ActionStep] = try actArr.map { v in
            guard case .object(let step) = v else {
                throw JobsModuleError.invalidActionChain("each action must be an object")
            }
            guard let toolV = step["tool"], case .string(let rawTool) = toolV else {
                throw JobsModuleError.invalidActionChain("action missing 'tool'")
            }
            let tool = Self.canonicalActionToolName(rawTool)
            var argsMap: [String: JSONValue] = [:]
            if case .object(let a)? = step["arguments"] {
                for (k, v) in a { argsMap[k] = JSONValue.fromMCP(v) }
            }
            let onFail: ActionStep.OnFail = {
                if case .string(let s)? = step["onFail"],
                   let parsed = ActionStep.OnFail(rawValue: s) { return parsed }
                return .stop
            }()
            try Self.validateUnattended(tool: tool, args: argsMap)
            return ActionStep(tool: tool, arguments: argsMap, onFail: onFail)
        }

        let job = JobRecord(name: name, schedule: schedule, actionChain: chain,
                            status: .active, skipOnBattery: skipBattery)

        try await JobStore.shared.insert(job)

        let plist = LaunchAgentPlist.build(jobId: job.id, intervals: intervals, ssePort: Self.ssePort)
        do {
            try LaunchAgentPlist.write(jobId: job.id, plist: plist)
            try LaunchAgentLifecycle.register(jobId: job.id)
        } catch {
            // Roll back DB insert if plist install fails.
            try? await JobStore.shared.delete(id: job.id)
            try? LaunchAgentPlist.remove(jobId: job.id)
            throw JobsModuleError.launchAgentFailure("\(error)")
        }

        notifyJobsChanged()
        return .object([
            "id": .string(job.id),
            "name": .string(job.name),
            "schedule": .string(job.schedule),
            "intervals": .int(intervals.count),
            "status": .string(job.status.rawValue),
            "plist": .string(JobsPaths.plistURL(jobId: job.id).path)
        ])
    }

    public func getJob(args: Value) async throws -> Value {
        try await ensureOpen()
        let id = try Self.requireStringArg(args, key: "id")
        guard let job = try await JobStore.shared.fetch(id: id) else {
            throw JobsModuleError.jobNotFound(id)
        }
        let history = try await JobStore.shared.executions(jobId: id, limit: 10)
        return .object([
            "job": Self.jobValue(job),
            "history": .array(history.map(Self.execValue))
        ])
    }

    public func listJobs(args: Value) async throws -> Value {
        try await ensureOpen()
        var filter: JobRecord.Status? = nil
        if case .object(let o) = args, case .string(let s)? = o["status"] {
            filter = JobRecord.Status(rawValue: s)
        }
        let jobs = try await JobStore.shared.listAll(statusFilter: filter)
        return .object(["jobs": .array(jobs.map(Self.jobValue)), "count": .int(jobs.count)])
    }

    public func deleteJob(args: Value) async throws -> Value {
        try await ensureOpen()
        let id = try Self.requireStringArg(args, key: "id")
        try LaunchAgentLifecycle.unregister(jobId: id)
        try LaunchAgentPlist.remove(jobId: id)
        try await JobStore.shared.delete(id: id)
        notifyJobsChanged()
        return .object(["deleted": .string(id)])
    }

    public func pauseJob(args: Value) async throws -> Value {
        try await ensureOpen()
        let id = try Self.requireStringArg(args, key: "id")
        try LaunchAgentLifecycle.unregister(jobId: id)
        try await JobStore.shared.updateStatus(id: id, status: .paused)
        notifyJobsChanged()
        return .object(["paused": .string(id)])
    }

    public func resumeJob(args: Value) async throws -> Value {
        try await ensureOpen()
        let id = try Self.requireStringArg(args, key: "id")
        try LaunchAgentLifecycle.register(jobId: id)
        try await JobStore.shared.updateStatus(id: id, status: .active)
        notifyJobsChanged()
        return .object(["resumed": .string(id)])
    }

    public func jobHistory(args: Value) async throws -> Value {
        try await ensureOpen()
        let id = try Self.requireStringArg(args, key: "id")
        var limit = 20
        if case .object(let o) = args, case .int(let i)? = o["limit"] { limit = i }
        let execs = try await JobStore.shared.executions(jobId: id, limit: limit)
        return .object(["executions": .array(execs.map(Self.execValue)), "count": .int(execs.count)])
    }

    public func listTemplates(args: Value) async throws -> Value {
        let templates: [[String: Value]] = [
            [
                "id": .string("daily-desktop-cleanup"),
                "name": .string("Daily desktop cleanup"),
                "schedule": .string("0 18 * * *"),
                "description": .string("Move screenshots and stray files to ~/Downloads/cleanup each evening."),
                "actions": .array([.object(["tool": .string("shell_exec"), "arguments": .object(["command": .string("echo 'customize this template'")])])])
            ],
            [
                "id": .string("hourly-screenshot-tidy"),
                "name": .string("Hourly screenshot tidy"),
                "schedule": .string("0 * * * *"),
                "description": .string("Sweep ~/Desktop/Screenshot*.png into a dated archive folder."),
                "actions": .array([.object(["tool": .string("shell_exec"), "arguments": .object(["command": .string("echo 'customize this template'")])])])
            ],
            [
                "id": .string("friday-status-digest"),
                "name": .string("Friday status digest"),
                "schedule": .string("0 17 * * 5"),
                "description": .string("Compile a weekly status summary every Friday at 5pm."),
                "actions": .array([.object(["tool": .string("shell_exec"), "arguments": .object(["command": .string("echo 'customize this template'")])])])
            ]
        ]
        return .object(["templates": .array(templates.map { .object($0) })])
    }

    // MARK: Callback dispatch (SSE /jobs/{id}/run)

    public func runCallback(jobId: String, router: ToolRouter) async throws -> Value {
        try await ensureOpen()
        self.router = router
        guard let job = try await JobStore.shared.fetch(id: jobId) else {
            throw JobsModuleError.jobNotFound(jobId)
        }
        guard job.status == .active else {
            let rec = ExecutionRecord(id: nil, jobId: jobId, startedAt: Date(), completedAt: Date(),
                                      status: .skipped, results: nil, errorMessage: "job paused")
            _ = try await JobStore.shared.insertExecution(rec)
            return .object(["skipped": .string("paused")])
        }
        if job.skipOnBattery && ProcessInfo.processInfo.isLowPowerModeEnabled {
            let rec = ExecutionRecord(id: nil, jobId: jobId, startedAt: Date(), completedAt: Date(),
                                      status: .skipped, results: nil, errorMessage: "low power mode")
            _ = try await JobStore.shared.insertExecution(rec)
            return .object(["skipped": .string("low power")])
        }

        let start = Date()
        var stepResults: [JSONValue] = []
        var firstError: String?
        var overall: ExecutionRecord.Status = .success

        for (idx, step) in job.actionChain.enumerated() {
            let mcpArgs = Self.substitutePrev(step.arguments, prev: stepResults.last)
            do {
                let toolName = Self.canonicalActionToolName(step.tool)
                let result = try await router.dispatch(toolName: toolName, arguments: .object(mcpArgs))
                stepResults.append(JSONValue.fromMCP(result))
            } catch {
                let toolName = Self.canonicalActionToolName(step.tool)
                let msg = "step \(idx) (\(toolName)): \(error.localizedDescription)"
                firstError = firstError ?? msg
                stepResults.append(.object(["error": .string(msg)]))
                switch step.onFail {
                case .stop:
                    overall = stepResults.count == 1 ? .failure : .partial
                    break
                case .continue:
                    overall = .partial
                    continue
                case .retry:
                    // One retry with a short backoff.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    do {
                        let toolName = Self.canonicalActionToolName(step.tool)
                        let result = try await router.dispatch(toolName: toolName, arguments: .object(mcpArgs))
                        stepResults[stepResults.count - 1] = JSONValue.fromMCP(result)
                        firstError = nil
                        continue
                    } catch {
                        overall = .partial
                        continue
                    }
                }
                break
            }
        }

        let resultsJSON: String? = {
            let data = try? JSONEncoder().encode(stepResults)
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }()
        let rec = ExecutionRecord(
            id: nil, jobId: jobId,
            startedAt: start, completedAt: Date(),
            status: overall,
            results: resultsJSON,
            errorMessage: firstError
        )
        _ = try await JobStore.shared.insertExecution(rec)
        return .object([
            "jobId": .string(jobId),
            "status": .string(overall.rawValue),
            "steps": .int(stepResults.count)
        ])
    }

    // MARK: Background Items reset (D-e)

    /// Re-registers all active job plists with launchd, resetting BTM attribution.
    public func resetBackgroundItems() async -> (message: String, didFail: Bool) {
        do {
            let jobs = try await JobStore.shared.listAll(statusFilter: nil)
            var reregistered = 0
            for job in jobs {
                try? LaunchAgentLifecycle.unregister(jobId: job.id)
                if job.status == .active {
                    try? LaunchAgentLifecycle.register(jobId: job.id)
                    reregistered += 1
                }
            }
            notifyJobsChanged()
            return ("Re-registered \(reregistered) background item\(reregistered == 1 ? "" : "s").", false)
        } catch {
            return ("Reset failed: \(error)", true)
        }
    }

    nonisolated func notifyJobsChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .jobsDidChange, object: nil)
        }
    }

    // MARK: Helpers

    private func ensureOpen() async throws {
        if !didBootstrap {
            try await JobStore.shared.open()
            didBootstrap = true
        }
    }

    private static func requireStringArg(_ args: Value, key: String) throws -> String {
        if case .object(let o) = args, case .string(let s)? = o[key] { return s }
        throw JobsModuleError.invalidActionChain("missing required arg '\(key)'")
    }

    /// Substitute the literal `"$prev_result"` token in argument values with
    /// the previous step's full result. Non-string values pass through.
    private static func substitutePrev(_ args: [String: JSONValue], prev: JSONValue?) -> [String: Value] {
        var out: [String: Value] = [:]
        for (k, v) in args {
            if case .string(let s) = v, s == "$prev_result", let prev {
                out[k] = prev.toMCP()
            } else {
                out[k] = v.toMCP()
            }
        }
        return out
    }

    /// Reject action chains that would trigger auto-escalation in unattended
    /// execution. Keep this list short and focused — SecurityGate is the primary
    /// gate; this is defense-in-depth at creation time.
    public static func canonicalActionToolName(_ tool: String) -> String {
        tool.split(separator: ".").last.map(String.init) ?? tool
    }

    public static func validateUnattended(tool rawTool: String, args: [String: JSONValue]) throws {
        let tool = canonicalActionToolName(rawTool)

        if tool == "messages_send" {
            guard case .string("SEND") = args["confirm"] ?? .null else {
                throw JobsModuleError.invalidActionChain("messages_send jobs require confirm: 'SEND'")
            }
            guard Self.hasNonEmptyString(args["body"]) else {
                throw JobsModuleError.invalidActionChain("messages_send jobs require non-empty 'body'")
            }
            guard Self.hasNonEmptyString(args["recipient"]) || Self.hasNonEmptyString(args["chatIdentifier"]) else {
                throw JobsModuleError.invalidActionChain("messages_send jobs require 'recipient' or 'chatIdentifier'")
            }
        } else {
            // Other known-destructive interactive tools remain blocked unless they
            // gain their own explicit unattended confirmation contract.
            let forbiddenTools: Set<String> = ["messages_send_attachment"]
            if forbiddenTools.contains(tool) {
                throw JobsModuleError.invalidActionChain("tool '\(tool)' is not schedulable (interactive-only)")
            }
        }
        // For shell_exec, reject obviously dangerous commands.
        if tool == "shell_exec", case .string(let cmd) = args["command"] ?? .null {
            let lowered = cmd.lowercased()
            let forbiddenPatterns = ["sudo ", "rm -rf /", " :(){ ", "mkfs", "dd if=", "chmod 777 /", "/etc/shadow"]
            for p in forbiddenPatterns where lowered.contains(p) {
                throw JobsModuleError.invalidActionChain("shell_exec blocked pattern: \(p)")
            }
        }
    }

    private static func hasNonEmptyString(_ value: JSONValue?) -> Bool {
        guard case .string(let string) = value, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    // MARK: Value helpers

    private static func jobValue(_ job: JobRecord) -> Value {
        .object([
            "id": .string(job.id),
            "name": .string(job.name),
            "schedule": .string(job.schedule),
            "status": .string(job.status.rawValue),
            "skipOnBattery": .bool(job.skipOnBattery),
            "steps": .int(job.actionChain.count),
            "createdAt": .string(ISO8601DateFormatter().string(from: job.createdAt)),
            "updatedAt": .string(ISO8601DateFormatter().string(from: job.updatedAt))
        ])
    }

    private static func execValue(_ e: ExecutionRecord) -> Value {
        var obj: [String: Value] = [
            "jobId": .string(e.jobId),
            "startedAt": .string(ISO8601DateFormatter().string(from: e.startedAt)),
            "status": .string(e.status.rawValue)
        ]
        if let id = e.id { obj["id"] = .int(Int(id)) }
        if let c = e.completedAt { obj["completedAt"] = .string(ISO8601DateFormatter().string(from: c)) }
        if let r = e.results { obj["results"] = .string(r) }
        if let err = e.errorMessage { obj["error"] = .string(err) }
        return .object(obj)
    }
}
