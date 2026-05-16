// MessagesModule.swift – V1-PATCH-004 iMessage Tools
// NotionBridge · Modules
//
// Six tools: messages_search, messages_recent, messages_chat,
// messages_content, messages_participants, messages_send.
// Read tools use native SQLite C API on ~/Library/Messages/chat.db.
// Send uses in-process AppleScript (NSAppleScript). Tier: request (5 open, 1 request).
//
// V1-PATCH-001 changes:
// - Replaced runSQLite CLI helper with SQLiteConnection (native sqlite3 C API)
// - Single persistent read-only connection with WAL journal mode
// - Added extractText() fallback: text → NSKeyedUnarchiver(attributedBody) → nil
// - All 4 read queries now SELECT m.attributedBody for decoding
// - messages_search WHERE clause includes attributedBody CAST fallback
//
// V1-PATCH-002 changes (crash fix + decode improvement):
// - BUGFIX: Added NSLock serialization around shared SQLiteConnection to prevent
//   EXC_BAD_ACCESS (SIGSEGV) from concurrent sqlite3_prepare_v2 calls on shared
//   db handle from Swift cooperative thread pool (5 crashes on 2026-03-17)
// - BUGFIX: Improved attributedBody decoding with Messages framework class
//   substitution + raw blob text extraction fallback for null text gap
// - Added performQuery() serialized query method
// - Removed direct getConnection().query() calls from all handler closures
//
// V1-PATCH-004 changes (decode-boundary sanitizer — Messages-suite audit):
// - BUGFIX: messages_recent / messages_chat / messages_content / messages_search
//   previews carried a stray leading C0 control byte (e.g. "\u{0001}Sup dude",
//   "\u{0001}Hello Isaiah") plus U+FFFC object-replacement glyphs. Root cause:
//   the typedstream length-prefix heuristic miscounts 1–2 framing/object-version
//   bytes into the text slice; trimmingCharacters(.whitespacesAndNewlines) does
//   NOT remove control chars or U+FFFC.
// - FIX: added sanitizeDecodedText() applied at the single decodeAttributedBody
//   boundary (covers all three decode stages → all four read tools, one site).
//   Strips leading/trailing C0/C1 control scalars (keeps \n \r \t) and removes
//   U+FFFC anywhere. Behaviour-preserving for clean bodies.
// - DEFERRAL (named): the *deeper* fix is an exact Apple typedstream
//   length-framing parser so the framing prefix is never sliced into the
//   payload (vs. stripped after). Deferred: the current parser handles ~99%
//   of live blobs; a full rewrite risks regressing that 99% for a cosmetic
//   gain the boundary sanitizer already neutralizes. Reason recorded here +
//   in the executor return. Re-open if a non-prefix framing artifact surfaces.
//
// V1-PATCH-003 changes (typedstream decoder):
// - BUGFIX: Replaced broken NSKeyedUnarchiver decode (silently fails on typedstream blobs)
//   with proper typedstream binary parser that extracts NSString payload directly
// - Root cause: ALL iMessage attributedBody blobs use Apple typedstream format (0x04 0x0B
//   "streamtyped"), NOT bplist/NSKeyedArchiver. NSKeyedUnarchiver.init(forReadingFrom:)
//   silently fails, falling through to raw blob scan which leaked bplist header bytes
//   ("X$versionY$archiverT$topX$objects") from embedded calendar event detector results
// - New decode priority: typedstream parser → NSKeyedUnarchiver fallback → raw scan
// - Typedstream parser locates NSString class marker (0x84 0x01 0x2B) and reads
//   length-prefixed UTF-8 payload with proper multi-byte length decoding

import Foundation
import SQLite3
import MCP

// MARK: - SQLiteConnection

/// Persistent read-only SQLite connection using native C API.
/// Replaces per-query sqlite3 CLI process spawning to eliminate
/// "database is locked" errors from concurrent tool calls.
/// Thread safety: Callers MUST serialize access externally (see MessagesModule.dbLock).
/// The underlying sqlite3 handle is NOT safe for concurrent access from multiple threads.
final class SQLiteConnection {
    private var db: OpaquePointer?

    /// Open a read-only SQLite connection with WAL journal mode.
    /// - Parameter path: Absolute path to the database file.
    /// - Throws: `SQLiteConnectionError.openFailed` if the database cannot be opened.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, db != nil else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw SQLiteConnectionError.openFailed(msg)
        }
        // Enable WAL journal mode for concurrent read access
        executeRaw("PRAGMA journal_mode=WAL")
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    /// Execute a raw SQL statement (no results expected).
    private func executeRaw(_ sql: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Execute a read-only query with positional string parameters (?1, ?2, ...).
    /// Returns an array of dictionaries mapping column names to values.
    /// BLOB columns are returned as `Data`. NULL columns are returned as `NSNull`.
    func query(_ sql: String, params: [String] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        let prepResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepResult == SQLITE_OK, let statement = stmt else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Prepare failed"
            throw SQLiteConnectionError.queryFailed(msg)
        }
        defer { sqlite3_finalize(statement) }

        // Bind string parameters (1-indexed)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), param, -1, SQLITE_TRANSIENT)
        }

        var rows: [[String: Any]] = []
        let colCount = sqlite3_column_count(statement)

        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT:
                    if let cStr = sqlite3_column_text(statement, i) {
                        row[name] = String(cString: cStr)
                    } else {
                        row[name] = NSNull()
                    }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, i) {
                        let length = Int(sqlite3_column_bytes(statement, i))
                        row[name] = Data(bytes: bytes, count: length)
                    } else {
                        row[name] = NSNull()
                    }
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    row[name] = NSNull()
                }
            }
            rows.append(row)
        }

        return rows
    }
}

enum SQLiteConnectionError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .queryFailed(let msg): return "SQLite query failed: \(msg)"
        }
    }
}

// MARK: - MessagesModule

/// Provides iMessage/SMS read and send tools.
/// Read operations query chat.db via native SQLite C API (read-only, WAL).
/// Send uses in-process AppleScript through NSAppleScript.
public enum MessagesModule {

    public static let moduleName = "messages"

    private static let chatDBPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
    }()

    /// Shared persistent SQLite connection for all read queries.
    /// Lazy initialization; reconnects if needed via getConnection().
    nonisolated(unsafe) private static var connection: SQLiteConnection? = {
        try? SQLiteConnection(path: chatDBPath)
    }()

    /// Get or re-establish the shared SQLite connection.
    private static func getConnection() throws -> SQLiteConnection {
        if let conn = connection { return conn }
        let conn = try SQLiteConnection(path: chatDBPath)
        connection = conn
        return conn
    }

    // MARK: - Thread-Safe Query Access

    /// Lock serializing all SQLite access from concurrent async tool handlers.
    /// Prevents EXC_BAD_ACCESS (SIGSEGV) from concurrent sqlite3_prepare_v2
    /// on the shared db handle from Swift's cooperative thread pool.
    /// Root cause: nonisolated(unsafe) static var + concurrent async dispatch.
    private static let dbLock = NSLock()

    /// Execute a query with serialized access to the shared connection.
    /// All read tool handlers MUST use this instead of getConnection().query().
    private static func performQuery(_ sql: String, params: [String] = []) throws -> [[String: Any]] {
        dbLock.lock()
        defer { dbLock.unlock() }
        let conn = try getConnection()
        return try conn.query(sql, params: params)
    }

    // MARK: - Text Extraction

    /// Decode an `attributedBody` blob to plain text.
    /// V1-PATCH-003: Three-stage decode — typedstream parser (primary), then
    /// NSKeyedUnarchiver fallback (for rare bplist blobs), then raw scan (last resort).
    ///
    /// iMessage attributedBody blobs are almost always Apple typedstream format:
    ///   Header: 0x04 0x0B "streamtyped"
    ///   NSString class marker: 0x84 0x01 0x2B
    ///   Length-prefixed UTF-8 payload follows the marker
    private static func decodeAttributedBody(_ data: Data) -> String? {
        // Stage 1: Typedstream parser (handles ~99% of iMessage blobs)
        if let text = decodeTypedStream(data) {
            return sanitizeDecodedText(text)
        }

        // Stage 2: NSKeyedUnarchiver fallback (for rare bplist00 format blobs)
        if data.count > 8, data[0...7] == Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30]) {
            if let text = decodeViaNSKeyedUnarchiver(data) {
                return sanitizeDecodedText(text)
            }
        }

        // Stage 3: Raw blob text extraction (last resort)
        return extractTextFromBlob(data).flatMap(sanitizeDecodedText)
    }

    // MARK: - Decode Boundary Sanitizer

    /// Scrub artifacts that the typedstream length-prefix heuristic and the
    /// raw-blob scan can leak into an otherwise-correct decode:
    ///
    ///   1. Leading/trailing C0/C1 control bytes (U+0000–U+001F, U+007F–U+009F,
    ///      except \n \r \t). Live evidence: previews rendered as
    ///      "\u{0001}Sup dude" / "\u{0001}Hello Isaiah" — a stray 1–2 byte
    ///      typedstream framing/object-version prefix the length decode
    ///      miscounts into the slice. These degrade exactly the
    ///      personal-thread previews triage depends on.
    ///   2. U+FFFC OBJECT REPLACEMENT CHARACTER (the `￼` glyph) — emitted by
    ///      iMessage for inline attachments/stickers; pure noise in a text
    ///      preview, never user-authored content.
    ///
    /// This is a deterministic, behaviour-preserving boundary fix: a clean
    /// ASCII/UTF-8 body is returned unchanged (no interior control bytes are
    /// touched — only the leading/trailing framing artifact is stripped, so a
    /// legitimate embedded tab/newline survives). The deeper fix (exact
    /// typedstream length-framing so the prefix is never sliced in) is
    /// recorded as a named deferral — see header DEFERRAL note.
    public static func sanitizeDecodedText(_ raw: String) -> String? {
        func isStrippableControl(_ s: Unicode.Scalar) -> Bool {
            if s == "\n" || s == "\r" || s == "\t" { return false }
            return (s.value <= 0x1F) || (s.value >= 0x7F && s.value <= 0x9F)
        }
        // Remove all U+FFFC object-replacement glyphs anywhere in the string.
        var scalars = Array(raw.unicodeScalars.filter { $0.value != 0xFFFC })
        // Strip leading strippable control scalars (the framing-prefix artifact).
        while let first = scalars.first, isStrippableControl(first) {
            scalars.removeFirst()
        }
        // Strip trailing strippable control scalars (rare trailing framing byte).
        while let last = scalars.last, isStrippableControl(last) {
            scalars.removeLast()
        }
        var out = ""
        out.unicodeScalars.append(contentsOf: scalars)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Public test seam: decode an `attributedBody` blob exactly as the read
    /// tools do (all three stages + boundary sanitizer). Network/chat.db-free,
    /// deterministic — used by MessagesSuiteAuditTests to assert no stray
    /// control/U+FFFC artifacts leak into previews.
    public static func decodeAttributedBodyForTesting(_ data: Data) -> String? {
        decodeAttributedBody(data)
    }

    // MARK: - Typedstream Decoder

    /// Parse Apple typedstream binary format to extract the NSString payload.
    ///
    /// Format structure (verified against live iMessage chat.db):
    ///   Bytes 0-1:   0x04 0x0B (typedstream magic)
    ///   Bytes 2-12:  "streamtyped" (format identifier)
    ///   Bytes 13-69: NSAttributedString class hierarchy + metadata
    ///   Byte  70-72: 0x84 0x01 0x2B (NSString class reference marker)
    ///   Byte  73+:   Length-prefixed UTF-8 string payload:
    ///     - If byte < 0x80: single-byte length, text follows immediately
    ///     - If byte == 0x81: next byte is length (128-255), then 0x00 pad, then text
    ///     - If byte == 0x82: next 2 bytes are big-endian length (256-65535), then 0x00 pad, then text
    private static func decodeTypedStream(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        // Verify typedstream magic header
        guard bytes.count > 75,
              bytes[0] == 0x04,
              bytes[1] == 0x0B else {
            return nil
        }

        // Locate NSString class marker: 0x84 0x01 0x2B
        // Usually at offset 70, but scan a range to be safe
        let marker: [UInt8] = [0x84, 0x01, 0x2B]
        var markerOffset: Int? = nil
        let searchStart = max(0, 60)
        let searchEnd = min(bytes.count - 4, 120)
        for i in searchStart..<searchEnd {
            if bytes[i] == marker[0] && bytes[i+1] == marker[1] && bytes[i+2] == marker[2] {
                markerOffset = i
                break
            }
        }

        guard let offset = markerOffset else { return nil }
        let lengthStart = offset + 3
        guard lengthStart < bytes.count else { return nil }

        // Decode length prefix
        let firstByte = bytes[lengthStart]
        let textLength: Int
        let textStart: Int

        if firstByte < 0x80 {
            // Single-byte length (0-127)
            textLength = Int(firstByte)
            textStart = lengthStart + 1
        } else if firstByte == 0x81 {
            // Two-byte encoding: 0x81 + length byte (128-255)
            guard lengthStart + 2 < bytes.count else { return nil }
            textLength = Int(bytes[lengthStart + 1])
            // Skip optional 0x00 padding byte
            let possiblePad = lengthStart + 2
            if possiblePad < bytes.count && bytes[possiblePad] == 0x00 {
                textStart = possiblePad + 1
            } else {
                textStart = possiblePad
            }
        } else if firstByte == 0x82 {
            // Three-byte encoding: 0x82 + 2-byte big-endian length (256-65535)
            guard lengthStart + 3 < bytes.count else { return nil }
            textLength = (Int(bytes[lengthStart + 1]) << 8) | Int(bytes[lengthStart + 2])
            // Skip optional 0x00 padding byte
            let possiblePad = lengthStart + 3
            if possiblePad < bytes.count && bytes[possiblePad] == 0x00 {
                textStart = possiblePad + 1
            } else {
                textStart = possiblePad
            }
        } else {
            // Unknown length encoding
            return nil
        }

        guard textLength > 0,
              textStart + textLength <= bytes.count else { return nil }

        let textBytes = Array(bytes[textStart..<textStart + textLength])
        guard let text = String(bytes: textBytes, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - NSKeyedUnarchiver Fallback

    /// Decode bplist00 (NSKeyedArchiver) format attributedBody.
    /// Fallback for the rare case where a blob is NOT typedstream.
    private static func decodeViaNSKeyedUnarchiver(_ data: Data) -> String? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        // Substitute Messages.framework private classes -> Foundation equivalents
        unarchiver.setClass(NSAttributedString.self, forClassName: "MessageAttributedString")
        unarchiver.setClass(NSMutableAttributedString.self, forClassName: "MessageMutableAttributedString")
        unarchiver.setClass(NSMutableString.self, forClassName: "NSMutableStringProxyForMutableAttributedString")
        defer { unarchiver.finishDecoding() }
        if let attrStr = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString {
            let text = attrStr.string
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - Raw Blob Scan Fallback

    /// Scan raw blob bytes for the longest contiguous printable UTF-8 run.
    /// Filters out known binary artifact strings (class names, format markers, bplist keys).
    /// Last-resort fallback when both typedstream and NSKeyedUnarchiver fail.
    private static func extractTextFromBlob(_ data: Data) -> String? {
        guard data.count > 10 else { return nil }
        let bytes = [UInt8](data)
        var runs: [String] = []
        var current: [UInt8] = []

        for byte in bytes {
            if byte >= 0x20 && byte <= 0x7E {
                current.append(byte)
            } else if byte >= 0xC2 && byte <= 0xF4 {
                current.append(byte)
            } else if byte >= 0x80 && byte <= 0xBF && !current.isEmpty {
                current.append(byte)
            } else {
                if let run = String(bytes: current, encoding: .utf8), run.count >= 4 {
                    runs.append(run)
                }
                current = []
            }
        }
        if let run = String(bytes: current, encoding: .utf8), run.count >= 4 {
            runs.append(run)
        }

        // Filter known noise (class names, format markers, bplist keys)
        let noise: Set<String> = [
            "streamtyped", "NSString", "NSMutableString", "NSObject",
            "NSAttributedString", "NSMutableAttributedString",
            "NSDictionary", "NSMutableDictionary", "NSMutableData", "NSData",
            "NSValue", "NSNumber", "NSDate", "NSURL", "NSArray", "NSMutableArray",
            "NSParagraphStyle", "NSFont", "NSColor",
            "MessageAttributedString", "MessageMutableAttributedString",
            "bplist00", "$version", "$archiver", "$top", "$objects",
            "X$versionY$archiver", "NSKeyedArchiver",
            "__kIMMessagePartAttributeName", "__kIMCalendarEventAttributeName",
            "__kIMDataDetectedAttributeName", "__kIMFileTransferGUIDAttributeName",
            "NSDictionary", "dd-result", "NS.keys", "NS.objects",
        ]
        let filtered = runs.filter { run in
            let trimmed = run.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count >= 4
                && !noise.contains(where: { trimmed.hasPrefix($0) })
                && !trimmed.hasPrefix("__kIM")
                && !trimmed.hasPrefix("$")
                && !trimmed.hasPrefix("NS.")
        }

        guard let best = filtered.max(by: { $0.count < $1.count }) else {
            return nil
        }
        let trimmed = best.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extract text from a query result row with attributedBody fallback.
    /// Priority: text column → decoded attributedBody → nil.
    private static func extractText(row: [String: Any], textKey: String = "text") -> String? {
        // 1. Try text column
        if let str = row[textKey] as? String, !str.isEmpty {
            return str
        }
        // 2. Try attributedBody decode
        if let data = row["attributedBody"] as? Data {
            return decodeAttributedBody(data)
        }
        return nil
    }

    // MARK: - Result Conversion

    /// Convert query result rows to MCP Value, applying extractText fallback on the text column.
    /// The raw `attributedBody` blob is excluded from output.
    private static func rowsToValue(_ rows: [[String: Any]], textKey: String = "text") -> Value {
        let valueRows: [Value] = rows.map { row in
            var result: [String: Value] = [:]
            for (key, val) in row {
                // Never expose raw attributedBody blob to caller
                if key == "attributedBody" { continue }
                if key == textKey {
                    // Apply text extraction with attributedBody fallback
                    let extracted = extractText(row: row, textKey: textKey)
                    result[key] = extracted.map { .string($0) } ?? .null
                } else if let s = val as? String {
                    result[key] = .string(s)
                } else if let i = val as? Int {
                    result[key] = .int(i)
                } else if let d = val as? Double {
                    result[key] = .double(d)
                } else {
                    result[key] = .null
                }
            }
            return .object(result)
        }
        return .object(["rows": .array(valueRows), "count": .int(valueRows.count)])
    }

    /// Convert query result rows to MCP Value without text extraction (for non-message queries).
    private static func rawRowsToValue(_ rows: [[String: Any]]) -> Value {
        let valueRows: [Value] = rows.map { row in
            var result: [String: Value] = [:]
            for (key, val) in row {
                if let s = val as? String {
                    result[key] = .string(s)
                } else if let i = val as? Int {
                    result[key] = .int(i)
                } else if let d = val as? Double {
                    result[key] = .double(d)
                } else {
                    result[key] = .null
                }
            }
            return .object(result)
        }
        return .object(["rows": .array(valueRows), "count": .int(valueRows.count)])
    }

    // MARK: - Tool Registration

    // MARK: - Delivery Verification

    /// Check if a sent message appears in chat.db within a short window.
    /// Compares messages after preSendMaxId for the given recipient.
    /// Returns true if a matching outbound message is found.
    private static func verifySend(recipient: String, afterId: Int) -> Bool {
        // Brief delay to allow Messages.app to write to chat.db
        Thread.sleep(forTimeInterval: 1.5)

        let sql = """
            SELECT m.ROWID, m.is_from_me
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE m.ROWID > ?1
              AND m.is_from_me = 1
              AND (c.chat_identifier LIKE '%' || ?2 || '%'
                   OR h.id LIKE '%' || ?2 || '%')
            ORDER BY m.ROWID DESC
            LIMIT 1
            """
        let rows = (try? performQuery(sql, params: [String(afterId), recipient])) ?? []
        return !rows.isEmpty
    }

    /// Register all MessagesModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. messages_search – open
        await router.register(ToolRegistration(
            name: "messages_search",
            module: moduleName,
            tier: .open,
            description: "Keyword-search message bodies across all Messages conversations.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Keyword to search for in message text")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max results to return (default: 50)")])
                ]),
                "required": .array([.string("query")])
            ]),
            metadata: ToolMetadata(
                title: "Messages: Search",
                whenToUse: ["finding messages that contain a specific word/phrase across every conversation",
                            "locating a message before fetching its full content with messages_content"],
                whenNotToUse: ["resolving who a phone/email belongs to (use contacts_resolve_handle)",
                               "reading one person's whole thread (use messages_chat)"],
                relatedTools: ["messages_chat", "messages_content", "contacts_resolve_handle"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_search", reason: "missing 'query'")
                }
                let limit: Int = { if case .int(let l) = args["limit"] { return l }; return 50 }()
                // Search text column directly + attributedBody fallback via CAST for blob keyword match
                let sql = """
                    SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.text LIKE '%' || ?1 || '%'
                       OR (m.text IS NULL AND m.attributedBody IS NOT NULL
                           AND CAST(m.attributedBody AS TEXT) LIKE '%' || ?1 || '%')
                    ORDER BY m.date DESC
                    LIMIT ?2
                    """
                let rows = try performQuery(sql, params: [query, String(limit)])
                return rowsToValue(rows)
            }
        ))

        // MARK: 2. messages_recent – open
        await router.register(ToolRegistration(
            name: "messages_recent",
            module: moduleName,
            tier: .open,
            description: "List the N most recently active Messages conversations (chats, not individual messages).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer"), "description": .string("Max conversations to return (default: 20)")])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Messages: Recent Conversations",
                whenToUse: ["triaging inbox — who messaged most recently and the last-message preview",
                            "picking a contact/chat id to then drill into with messages_chat"],
                whenNotToUse: ["reading the full thread for one contact (use messages_chat)",
                               "fetching one specific message body (use messages_content)"],
                relatedTools: ["messages_chat", "messages_content", "messages_participants"]
            ),
            handler: { arguments in
                let limit: Int = {
                    if case .object(let args) = arguments,
                       case .int(let l) = args["limit"] { return l }
                    return 20
                }()
                let sql = """
                    SELECT c.ROWID, c.chat_identifier, c.display_name,
                           m.text AS last_message, m.attributedBody,
                           m.is_from_me,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM chat c
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE m.ROWID = (
                        SELECT cmj2.message_id FROM chat_message_join cmj2
                        JOIN message m2 ON m2.ROWID = cmj2.message_id
                        WHERE cmj2.chat_id = c.ROWID
                        ORDER BY m2.date DESC LIMIT 1
                    )
                    ORDER BY m.date DESC
                    LIMIT ?1
                    """
                let rows = try performQuery(sql, params: [String(limit)])
                return rowsToValue(rows, textKey: "last_message")
            }
        ))

        // MARK: 3. messages_chat – open
        await router.register(ToolRegistration(
            name: "messages_chat",
            module: moduleName,
            tier: .open,
            description: "Read the message thread for one contact (phone or email) in chronological order.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact": .object(["type": .string("string"), "description": .string("Contact phone number or email")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max messages to return (default: 50)")])
                ]),
                "required": .array([.string("contact")])
            ]),
            metadata: ToolMetadata(
                title: "Messages: Read Thread",
                whenToUse: ["reading the back-and-forth history with one person by phone/email",
                            "after messages_recent surfaced the contact you want to drill into"],
                whenNotToUse: ["keyword search across all chats (use messages_search)",
                               "listing who is in a group chat (use messages_participants)"],
                relatedTools: ["messages_recent", "messages_search", "messages_participants", "contacts_resolve_handle"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let contact) = args["contact"] else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_chat", reason: "missing 'contact'")
                }
                let limit: Int = { if case .int(let l) = args["limit"] { return l }; return 50 }()
                let sql = """
                    SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    JOIN chat c ON c.ROWID = cmj.chat_id
                    WHERE c.chat_identifier LIKE '%' || ?1 || '%'
                       OR h.id LIKE '%' || ?1 || '%'
                    ORDER BY m.date DESC
                    LIMIT ?2
                    """
                let rows = try performQuery(sql, params: [contact, String(limit)])
                return rowsToValue(rows)
            }
        ))

        // MARK: 4. messages_content – open
        await router.register(ToolRegistration(
            name: "messages_content",
            module: moduleName,
            tier: .open,
            description: "Fetch a single message by its Messages DB ROWID (full text + metadata).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "messageId": .object(["type": .string("integer"), "description": .string("Message ROWID")])
                ]),
                "required": .array([.string("messageId")])
            ]),
            metadata: ToolMetadata(
                title: "Messages: Message Detail",
                whenToUse: ["pulling full text + service/attachment metadata for a ROWID returned by messages_search or messages_chat"],
                whenNotToUse: ["browsing a conversation (use messages_chat)",
                               "you only have a phone/email, not a ROWID (use messages_chat)"],
                relatedTools: ["messages_search", "messages_chat"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .int(let msgId) = args["messageId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_content", reason: "missing 'messageId'")
                }
                let sql = """
                    SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.service,
                           m.cache_has_attachments,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.ROWID = ?1
                    """
                let rows = try performQuery(sql, params: [String(msgId)])
                return rowsToValue(rows)
            }
        ))

        // MARK: 5. messages_participants – open
        await router.register(ToolRegistration(
            name: "messages_participants",
            module: moduleName,
            tier: .open,
            description: "List all handles (phones/emails) participating in one chat — useful for group-chat attribution.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "chatIdentifier": .object(["type": .string("string"), "description": .string("Chat identifier (phone number, email, or group ID)")])
                ]),
                "required": .array([.string("chatIdentifier")])
            ]),
            metadata: ToolMetadata(
                title: "Messages: Chat Participants",
                whenToUse: ["resolving a group-chat id to the individual phones/emails in it",
                            "before messages_send — turn a raw chatNNN id into real recipients"],
                whenNotToUse: ["reading the messages themselves (use messages_chat)",
                               "looking up a contact name (use contacts_search / contacts_resolve_handle)"],
                relatedTools: ["messages_chat", "messages_send", "contacts_resolve_handle"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let chatId) = args["chatIdentifier"] else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_participants", reason: "missing 'chatIdentifier'")
                }
                let sql = """
                    SELECT h.ROWID, h.id AS handle_id, h.service
                    FROM handle h
                    JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
                    JOIN chat c ON c.ROWID = chj.chat_id
                    WHERE c.chat_identifier LIKE '%' || ?1 || '%'
                    """
                let rows = try performQuery(sql, params: [chatId])
                return rawRowsToValue(rows)
            }
        ))

        // MARK: 6. messages_send – request
        await router.register(ToolRegistration(
            name: "messages_send",
            module: moduleName,
            tier: .request,
            description: "Send an iMessage/SMS to a recipient. Requires confirm: 'SEND' (exact, uppercase). Service auto-detected from chat history unless specified.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recipient": .object(["type": .string("string"), "description": .string("Recipient phone number or email (NOT a raw chatNNN id — resolve those with messages_participants first)")]),
                    "body": .object(["type": .string("string"), "description": .string("Message body text")]),
                    "confirm": .object(["type": .string("string"), "description": .string("Must be exactly 'SEND' to proceed")]),
                    "service": .object(["type": .string("string"), "description": .string("Optional: 'iMessage' or 'SMS'. Auto-detected from chat history if omitted. RCS recipients use 'SMS'.")])
                ]),
                "required": .array([.string("recipient"), .string("body"), .string("confirm")])
            ]),
            metadata: ToolMetadata(
                title: "Messages: Send",
                whenToUse: ["sending an iMessage/SMS to a known phone or email — pass confirm:'SEND'"],
                whenNotToUse: ["recipient is a raw chatNNN group id (resolve via messages_participants first)",
                               "you only have a contact name (resolve via contacts_resolve_handle first)"],
                relatedTools: ["messages_participants", "contacts_resolve_handle", "messages_chat"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let recipient) = args["recipient"],
                      case .string(let body) = args["body"],
                      case .string(let confirm) = args["confirm"] else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "missing required parameters")
                }

                guard confirm == "SEND" else {
                    return .object([
                        "error": .string("messages_send requires confirm: 'SEND'"),
                        "sent": .bool(false)
                    ])
                }

                // A3: Reject raw chat identifiers (e.g. "chat123456789")
                // These create malformed ghost threads in Messages.app
                let chatIdPattern = try! NSRegularExpression(pattern: "^chat[0-9]+$", options: .caseInsensitive)
                if chatIdPattern.firstMatch(in: recipient, range: NSRange(recipient.startIndex..., in: recipient)) != nil {
                    return .object([
                        "error": .string("Raw chat identifiers (e.g. '\(recipient)') cannot be used as recipients. Use messages_participants to resolve the chat to individual phone numbers or emails first."),
                        "sent": .bool(false)
                    ])
                }

                // Determine service type: manual override or auto-detect from chat.db
                let serviceOverride: String? = {
                    if case .string(let s) = args["service"] { return s }
                    return nil
                }()

                let serviceType: String  // "iMessage" or "SMS" for AppleScript
                let detectedService: String  // What we found in chat.db

                if let override = serviceOverride {
                    serviceType = (override.lowercased() == "imessage") ? "iMessage" : "SMS"
                    detectedService = override
                } else {
                    // Auto-detect from chat.db: query most recent chat for this recipient
                    let detectSQL = """
                        SELECT c.service_name
                        FROM chat c
                        WHERE c.chat_identifier LIKE '%' || ?1 || '%'
                        ORDER BY c.ROWID DESC
                        LIMIT 1
                        """
                    let detectRows = (try? performQuery(detectSQL, params: [recipient])) ?? []
                    if let serviceName = detectRows.first?["service_name"] as? String {
                        detectedService = serviceName
                        // Map chat.db service names to AppleScript service types:
                        // "iMessage" -> iMessage, "SMS" -> SMS, "RCS" -> SMS
                        switch serviceName.lowercased() {
                        case "imessage":
                            serviceType = "iMessage"
                        default:
                            serviceType = "SMS"
                        }
                    } else {
                        serviceType = "iMessage"
                        detectedService = "iMessage (no history, default)"
                    }
                }

                // Get the max ROWID before sending (for delivery verification)
                let preRows = (try? performQuery(
                    "SELECT MAX(ROWID) as max_id FROM message", params: []
                )) ?? []
                let preSendMaxId = (preRows.first?["max_id"] as? Int) ?? 0

                // Sanitize inputs for AppleScript
                let safeRecipient = recipient
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let safeBody = body
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

                // Build and execute AppleScript with detected service type
                let script = """
                    tell application "Messages"
                        set targetService to 1st service whose service type = \(serviceType)
                        set targetBuddy to buddy "\(safeRecipient)" of targetService
                        send "\(safeBody)" to targetBuddy
                    end tell
                    """

                let appleScript = NSAppleScript(source: script)
                var errorInfo: NSDictionary?
                _ = appleScript?.executeAndReturnError(&errorInfo)

                if let errorInfo = errorInfo {
                    let errorMessage = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript execution failed"
                    let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int ?? -1

                    // If iMessage failed and we auto-detected, retry with SMS fallback
                    if serviceType == "iMessage" && serviceOverride == nil {
                        let retryScript = """
                            tell application "Messages"
                                set targetService to 1st service whose service type = SMS
                                set targetBuddy to buddy "\(safeRecipient)" of targetService
                                send "\(safeBody)" to targetBuddy
                            end tell
                            """
                        let retryAS = NSAppleScript(source: retryScript)
                        var retryError: NSDictionary?
                        _ = retryAS?.executeAndReturnError(&retryError)

                        if retryError == nil {
                            let verified = verifySend(recipient: recipient, afterId: preSendMaxId)
                            return .object([
                                "sent": .bool(true),
                                "recipient": .string(recipient),
                                "bodyLength": .int(body.utf8.count),
                                "service": .string("SMS (fallback from iMessage)"),
                                "verified": .bool(verified)
                            ])
                        }
                        let retryMsg = retryError?[NSAppleScript.errorMessage] as? String ?? "SMS retry also failed"
                        return .object([
                            "sent": .bool(false),
                            "error": .string("iMessage failed: \(errorMessage). SMS fallback failed: \(retryMsg)"),
                            "errorNumber": .int(errorNumber),
                            "detectedService": .string(detectedService)
                        ])
                    }

                    return .object([
                        "sent": .bool(false),
                        "error": .string(errorMessage),
                        "errorNumber": .int(errorNumber),
                        "service": .string(serviceType),
                        "detectedService": .string(detectedService)
                    ])
                }

                // AppleScript reported success — verify delivery in chat.db
                let verified = verifySend(recipient: recipient, afterId: preSendMaxId)

                return .object([
                    "sent": .bool(true),
                    "recipient": .string(recipient),
                    "bodyLength": .int(body.utf8.count),
                    "service": .string(serviceType),
                    "detectedService": .string(detectedService),
                    "verified": .bool(verified)
                ])
            }
        ))
    }
}
