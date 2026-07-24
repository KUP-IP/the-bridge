// ThreadMessagesReceiptStore.swift — durable single-machine idempotency ledger

import Foundation
import SQLite3

private let threadReceiptSQLiteTransient = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
)

public enum ThreadMessagesActionStage: String, Codable, Sendable, CaseIterable {
    case claimed
    case intentPersisted
    case deliveryInvoking
    case localRecordVerified
    case resultPersisted
    case complete
    case operatorReview
    case conflict

    fileprivate var rank: Int? {
        switch self {
        case .claimed: return 0
        case .intentPersisted: return 1
        case .deliveryInvoking: return 2
        case .localRecordVerified: return 3
        case .resultPersisted: return 4
        case .complete: return 5
        case .operatorReview, .conflict: return nil
        }
    }

    fileprivate func permits(_ next: Self) -> Bool {
        if self == next { return true }
        if next == .operatorReview || next == .conflict { return true }
        if self == .operatorReview || self == .conflict || self == .complete { return false }
        guard let current = rank, let target = next.rank else { return false }
        return target >= current
    }
}

public struct ThreadMessagesActionRecord: Sendable, Equatable {
    public var idempotencyKey: String
    public var operationId: String
    public var manifestFingerprint: String
    public var stage: ThreadMessagesActionStage
    public var preparedAt: Date?
    public var preSendWatermark: Int?
    public var messageRowId: Int?
    public var messageGuid: String?
    public var chatGuid: String?
    public var service: String?
    public var messageDate: Date?
    public var lifecycleUnchanged: Bool?
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public var leaseOwner: String?
    public var leaseToken: String?
    public var leaseExpiresAt: Date?

    public init(
        idempotencyKey: String,
        operationId: String,
        manifestFingerprint: String,
        stage: ThreadMessagesActionStage = .claimed,
        preparedAt: Date? = nil,
        preSendWatermark: Int? = nil,
        messageRowId: Int? = nil,
        messageGuid: String? = nil,
        chatGuid: String? = nil,
        service: String? = nil,
        messageDate: Date? = nil,
        lifecycleUnchanged: Bool? = nil,
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 1,
        leaseOwner: String? = nil,
        leaseToken: String? = nil,
        leaseExpiresAt: Date? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.operationId = operationId
        self.manifestFingerprint = manifestFingerprint
        self.stage = stage
        self.preparedAt = preparedAt
        self.preSendWatermark = preSendWatermark
        self.messageRowId = messageRowId
        self.messageGuid = messageGuid
        self.chatGuid = chatGuid
        self.service = service
        self.messageDate = messageDate
        self.lifecycleUnchanged = lifecycleUnchanged
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.leaseOwner = leaseOwner
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
    }
}

public enum ThreadMessagesReceiptStoreError: Error, LocalizedError, Equatable {
    case idempotencyConflict(String)
    case operationActive(String, Date)
    case staleRevision(String)
    case leaseLost(String)
    case stageRegression(String)
    case storageFailure(String)

    public var errorDescription: String? {
        switch self {
        case .idempotencyConflict(let key): return "THREAD action key belongs to a different manifest: \(key)"
        case .operationActive(let key, let until): return "THREAD action is already active for \(key) until \(until)"
        case .staleRevision(let key): return "THREAD action revision is stale: \(key)"
        case .leaseLost(let key): return "THREAD action lease is absent, expired, or fenced: \(key)"
        case .stageRegression(let reason): return "THREAD action stage regression refused: \(reason)"
        case .storageFailure(let reason): return "THREAD action ledger failed: \(reason)"
        }
    }
}

public protocol ThreadMessagesReceiptStoring: Sendable {
    func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        leaseOwner: String,
        leaseToken: String,
        leaseDuration: TimeInterval
    ) async throws -> ThreadMessagesActionRecord
    func get(idempotencyKey: String) async throws -> ThreadMessagesActionRecord?
    func save(_ record: ThreadMessagesActionRecord) async throws -> ThreadMessagesActionRecord
    func release(_ record: ThreadMessagesActionRecord) async throws -> ThreadMessagesActionRecord
}

public actor SQLiteThreadMessagesReceiptStore: ThreadMessagesReceiptStoring {
    public static func live() throws -> SQLiteThreadMessagesReceiptStore {
        let url = BridgePaths.applicationSupport(.messages)
            .appendingPathComponent("thread-actions.sqlite", isDirectory: false)
        return try SQLiteThreadMessagesReceiptStore(url: url)
    }

    private let url: URL
    nonisolated(unsafe) private var db: OpaquePointer?

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 rc=\(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw ThreadMessagesReceiptStoreError.storageFailure(message)
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 10_000)
        func bootstrapExec(_ sql: String) throws {
            var error: UnsafeMutablePointer<Int8>?
            let result = sqlite3_exec(handle, sql, nil, nil, &error)
            guard result == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
                if let error { sqlite3_free(error) }
                throw ThreadMessagesReceiptStoreError.storageFailure(message)
            }
        }
        do {
            try bootstrapExec("PRAGMA journal_mode=WAL;")
            try bootstrapExec("PRAGMA synchronous=FULL;")
            try bootstrapExec("""
            CREATE TABLE IF NOT EXISTS thread_message_actions (
                idempotency_key TEXT PRIMARY KEY NOT NULL,
                operation_id TEXT NOT NULL,
                manifest_fingerprint TEXT NOT NULL,
                stage TEXT NOT NULL,
                prepared_at REAL,
                pre_send_watermark INTEGER,
                message_row_id INTEGER,
                message_guid TEXT,
                chat_guid TEXT,
                service TEXT,
                message_date REAL,
                lifecycle_unchanged INTEGER,
                last_error TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                revision INTEGER NOT NULL,
                lease_owner TEXT,
                lease_token TEXT,
                lease_expires_at REAL
            );
            """)
        } catch {
            sqlite3_close_v2(handle)
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    public func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        leaseOwner: String,
        leaseToken: String,
        leaseDuration: TimeInterval
    ) throws -> ThreadMessagesActionRecord {
        guard !idempotencyKey.isEmpty, !manifestFingerprint.isEmpty,
              !operationId.isEmpty, !leaseOwner.isEmpty, !leaseToken.isEmpty,
              leaseDuration > 0 else {
            throw ThreadMessagesReceiptStoreError.storageFailure("claim arguments are incomplete")
        }
        try exec("BEGIN IMMEDIATE;")
        do {
            let now = Date()
            if var existing = try select(idempotencyKey) {
                guard existing.manifestFingerprint == manifestFingerprint else {
                    throw ThreadMessagesReceiptStoreError.idempotencyConflict(idempotencyKey)
                }
                if existing.stage == .complete || existing.stage == .operatorReview || existing.stage == .conflict {
                    try exec("COMMIT;")
                    return existing
                }
                if let until = existing.leaseExpiresAt,
                   until > now,
                   existing.leaseToken != leaseToken {
                    throw ThreadMessagesReceiptStoreError.operationActive(idempotencyKey, until)
                }
                existing.operationId = operationId
                existing.leaseOwner = leaseOwner
                existing.leaseToken = leaseToken
                existing.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
                existing.updatedAt = now
                existing.revision += 1
                try update(existing, expectedRevision: existing.revision - 1, requireLease: false)
                try exec("COMMIT;")
                return existing
            }

            let record = ThreadMessagesActionRecord(
                idempotencyKey: idempotencyKey,
                operationId: operationId,
                manifestFingerprint: manifestFingerprint,
                createdAt: now,
                updatedAt: now,
                leaseOwner: leaseOwner,
                leaseToken: leaseToken,
                leaseExpiresAt: now.addingTimeInterval(leaseDuration)
            )
            try insert(record)
            try exec("COMMIT;")
            return record
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func get(idempotencyKey: String) throws -> ThreadMessagesActionRecord? {
        try select(idempotencyKey)
    }

    public func save(_ record: ThreadMessagesActionRecord) throws -> ThreadMessagesActionRecord {
        guard let current = try select(record.idempotencyKey) else {
            throw ThreadMessagesReceiptStoreError.storageFailure("missing action \(record.idempotencyKey)")
        }
        guard current.revision == record.revision else {
            throw ThreadMessagesReceiptStoreError.staleRevision(record.idempotencyKey)
        }
        guard current.leaseToken == record.leaseToken,
              let expires = current.leaseExpiresAt,
              expires > Date() else {
            throw ThreadMessagesReceiptStoreError.leaseLost(record.idempotencyKey)
        }
        guard current.stage.permits(record.stage) else {
            throw ThreadMessagesReceiptStoreError.stageRegression("\(current.stage.rawValue) → \(record.stage.rawValue)")
        }
        var next = record
        next.updatedAt = Date()
        next.revision += 1
        try update(next, expectedRevision: record.revision, requireLease: true)
        return next
    }

    public func release(_ record: ThreadMessagesActionRecord) throws -> ThreadMessagesActionRecord {
        guard let current = try select(record.idempotencyKey) else {
            throw ThreadMessagesReceiptStoreError.storageFailure("missing action \(record.idempotencyKey)")
        }
        if current.leaseToken == nil { return current }
        guard current.leaseToken == record.leaseToken else {
            throw ThreadMessagesReceiptStoreError.leaseLost(record.idempotencyKey)
        }
        var next = current
        next.leaseOwner = nil
        next.leaseToken = nil
        next.leaseExpiresAt = nil
        next.updatedAt = Date()
        next.revision += 1
        try update(next, expectedRevision: current.revision, requireLease: false)
        return next
    }

    private func insert(_ r: ThreadMessagesActionRecord) throws {
        let sql = """
        INSERT INTO thread_message_actions(
            idempotency_key, operation_id, manifest_fingerprint, stage,
            prepared_at, pre_send_watermark, message_row_id, message_guid,
            chat_guid, service, message_date, lifecycle_unchanged, last_error,
            created_at, updated_at, revision, lease_owner, lease_token, lease_expires_at
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        try execute(sql) { stmt in bind(r, to: stmt) }
    }

    private func update(_ r: ThreadMessagesActionRecord, expectedRevision: Int, requireLease: Bool) throws {
        let leaseClause = requireLease ? " AND lease_token=?21" : ""
        let sql = """
        UPDATE thread_message_actions SET
            operation_id=?2, manifest_fingerprint=?3, stage=?4,
            prepared_at=?5, pre_send_watermark=?6, message_row_id=?7,
            message_guid=?8, chat_guid=?9, service=?10, message_date=?11,
            lifecycle_unchanged=?12, last_error=?13, created_at=?14,
            updated_at=?15, revision=?16, lease_owner=?17, lease_token=?18,
            lease_expires_at=?19
        WHERE idempotency_key=?1 AND revision=?20\(leaseClause);
        """
        try execute(sql) { stmt in
            bind(r, to: stmt)
            sqlite3_bind_int64(stmt, 20, sqlite3_int64(expectedRevision))
            if requireLease { bindText(r.leaseToken, stmt, 21) }
        }
        guard sqlite3_changes(db) == 1 else {
            throw ThreadMessagesReceiptStoreError.staleRevision(r.idempotencyKey)
        }
    }

    private func bind(_ r: ThreadMessagesActionRecord, to stmt: OpaquePointer) {
        bindText(r.idempotencyKey, stmt, 1)
        bindText(r.operationId, stmt, 2)
        bindText(r.manifestFingerprint, stmt, 3)
        bindText(r.stage.rawValue, stmt, 4)
        bindDate(r.preparedAt, stmt, 5)
        bindInt(r.preSendWatermark, stmt, 6)
        bindInt(r.messageRowId, stmt, 7)
        bindText(r.messageGuid, stmt, 8)
        bindText(r.chatGuid, stmt, 9)
        bindText(r.service, stmt, 10)
        bindDate(r.messageDate, stmt, 11)
        if let value = r.lifecycleUnchanged { sqlite3_bind_int(stmt, 12, value ? 1 : 0) } else { sqlite3_bind_null(stmt, 12) }
        bindText(r.lastError, stmt, 13)
        sqlite3_bind_double(stmt, 14, r.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 15, r.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 16, sqlite3_int64(r.revision))
        bindText(r.leaseOwner, stmt, 17)
        bindText(r.leaseToken, stmt, 18)
        bindDate(r.leaseExpiresAt, stmt, 19)
    }

    private func select(_ key: String) throws -> ThreadMessagesActionRecord? {
        let sql = "SELECT * FROM thread_message_actions WHERE idempotency_key=? LIMIT 1;"
        var result: ThreadMessagesActionRecord?
        try query(sql, bind: { stmt in bindText(key, stmt, 1) }) { stmt in
            result = decode(stmt)
        }
        return result
    }

    private func decode(_ stmt: OpaquePointer) -> ThreadMessagesActionRecord? {
        guard let key = text(stmt, 0),
              let operation = text(stmt, 1),
              let fingerprint = text(stmt, 2),
              let rawStage = text(stmt, 3),
              let stage = ThreadMessagesActionStage(rawValue: rawStage) else { return nil }
        return ThreadMessagesActionRecord(
            idempotencyKey: key,
            operationId: operation,
            manifestFingerprint: fingerprint,
            stage: stage,
            preparedAt: date(stmt, 4),
            preSendWatermark: int(stmt, 5),
            messageRowId: int(stmt, 6),
            messageGuid: text(stmt, 7),
            chatGuid: text(stmt, 8),
            service: text(stmt, 9),
            messageDate: date(stmt, 10),
            lifecycleUnchanged: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 11) != 0,
            lastError: text(stmt, 12),
            createdAt: date(stmt, 13) ?? .distantPast,
            updatedAt: date(stmt, 14) ?? .distantPast,
            revision: Int(sqlite3_column_int64(stmt, 15)),
            leaseOwner: text(stmt, 16),
            leaseToken: text(stmt, 17),
            leaseExpiresAt: date(stmt, 18)
        )
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error"
            if let error { sqlite3_free(error) }
            throw ThreadMessagesReceiptStoreError.storageFailure(message)
        }
    }

    private func execute(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let db else { throw ThreadMessagesReceiptStoreError.storageFailure("database closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ThreadMessagesReceiptStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ThreadMessagesReceiptStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> Void) throws {
        guard let db else { throw ThreadMessagesReceiptStoreError.storageFailure("database closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ThreadMessagesReceiptStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { row(stmt); return }
        guard rc == SQLITE_DONE else {
            throw ThreadMessagesReceiptStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ value: String?, _ stmt: OpaquePointer, _ index: Int32) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, threadReceiptSQLiteTransient) }
        else { sqlite3_bind_null(stmt, index) }
    }
    private func bindInt(_ value: Int?, _ stmt: OpaquePointer, _ index: Int32) {
        if let value { sqlite3_bind_int64(stmt, index, sqlite3_int64(value)) }
        else { sqlite3_bind_null(stmt, index) }
    }
    private func bindDate(_ value: Date?, _ stmt: OpaquePointer, _ index: Int32) {
        if let value { sqlite3_bind_double(stmt, index, value.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, index) }
    }
    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }
    private func int(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, index))
    }
    private func date(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }
}
