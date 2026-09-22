// MessagesModule.swift – V1-PATCH-004 iMessage Tools
// TheBridge · Modules
//
// Six tools: messages_search, messages_recent, messages_chat,
// messages_content, messages_participants, messages_send.
// Read tools use native SQLite C API on ~/Library/Messages/chat.db.
// Send uses in-process AppleScript (NSAppleScript). Catalog default for
// messages_send is notify for ordinary 1:1 plain text; groups / attachments /
// SMS-override raise to request (#298). Settings overrides still win.
// After invoke, always correlate chat.db (#302): a premature AppleScript
// error plus a matching outbound row is dispatch success, not a send failure.
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
public enum MessagesService: String, Sendable, Equatable, CaseIterable {
    case iMessage = "iMessage"
    case sms = "SMS"

    public static func parseStrict(_ value: String?) -> MessagesService? {
        guard let value else { return nil }
        return MessagesService(rawValue: value)
    }
}

/// Ordinary `messages_send` service choice (#198 / #249 / #303): inherit the
/// live 1:1 thread/contact service (inbound first, else unambiguous
/// chat.guid / service_name), or fail closed. Never map RCS/unknown onto
/// SMS on omit, never honor an explicit service that contradicts a live
/// iMessage/SMS channel, and never first-match AppleScript services for a
/// 1:1 chatIdentifier. Explicit SMS on RCS/unknown is allowed only with
/// `allowSmsDespiteLiveService: true` — the flag does not unlock iMessage↔SMS
/// mismatch and does not make RCS a sendable service.
public enum MessagesServiceResolution: Equatable, Sendable {
    case use(MessagesService)
    case refuse(String)
}

extension MessagesModule {
    /// chat.db `message.service` → sendable AppleScript service, or nil when
    /// the raw value is missing / RCS / otherwise not iMessage or SMS.
    public static func classifyChatDbService(_ raw: String?) -> MessagesService? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = MessagesService.parseStrict(trimmed) { return parsed }
        switch trimmed.lowercased() {
        case "imessage": return .iMessage
        case "sms": return .sms
        default: return nil
        }
    }

    /// First inbound (`is_from_me = 0`) service in date-desc rows. Outbound
    /// history is ignored — that was the Veronica guess (#198). Tapbacks,
    /// system rows, and group chats do not set 1:1 inherit (#303).
    public static func latestInboundService(from rows: [[String: Any]]) -> String? {
        MessagesProtocolDiscriminator.latestInboundServiceName(from: rows)
    }

    public static func resolveSendService(
        requested: String?,
        liveInboundRaw: String?,
        allowSmsDespiteLiveService: Bool = false
    ) -> MessagesServiceResolution {
        let live = classifyChatDbService(liveInboundRaw)
        let liveUnsupported: String? = {
            guard let raw = liveInboundRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, live == nil else { return nil }
            return raw
        }()

        if let requested {
            if requested == "auto" {
                return .refuse("service 'auto' is not allowed; inherit live inbound iMessage/SMS or pass exactly 'iMessage' or 'SMS'")
            }
            guard let explicit = MessagesService.parseStrict(requested) else {
                if requested.lowercased() == "rcs" {
                    return .refuse("RCS is not a sendable Messages.app service; do not map it to SMS")
                }
                return .refuse("unsupported Messages service '\(requested)'; expected exactly 'iMessage' or 'SMS', or omit service to inherit live inbound")
            }
            if let liveUnsupported {
                if explicit == .sms, allowSmsDespiteLiveService {
                    return .use(.sms)
                }
                if explicit == .sms {
                    return .refuse("live inbound service is '\(liveUnsupported)' (not iMessage/SMS); pass service=SMS and allowSmsDespiteLiveService:true for operator-authorized SMS on an RCS/unknown thread")
                }
                return .refuse("live inbound service is '\(liveUnsupported)' (not iMessage/SMS); refusing \(explicit.rawValue) as a silent fallback")
            }
            if let live, live != explicit {
                return .refuse("explicit service \(explicit.rawValue) does not match live inbound \(live.rawValue); refuse silent fallback")
            }
            return .use(explicit)
        }

        if let liveUnsupported {
            return .refuse("live inbound service is '\(liveUnsupported)' (not iMessage/SMS); omit is inherit-only — fail closed rather than guess SMS")
        }
        if let live {
            return .use(live)
        }
        return .refuse("messages_send cannot inherit a live inbound iMessage/SMS service for this recipient; pass explicit 'iMessage' or 'SMS'")
    }
}

public struct MessagesAppleScriptInvocationResult: Sendable, Equatable {
    public var error: String?
    public var errorNumber: Int?

    public init(error: String? = nil, errorNumber: Int? = nil) {
        self.error = error
        self.errorNumber = errorNumber
    }

    public var succeeded: Bool { error == nil }
}

public typealias MessagesServiceInvoker = @Sendable (MessagesService, String, String) -> MessagesAppleScriptInvocationResult
public typealias MessagesLocalRecordVerifier = @Sendable (String, String, Int, Date) -> MessagesDeliveryVerification

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
        let valueRows = rows.map { rowToValue($0, textKey: textKey) }
        return .object(["rows": .array(valueRows), "count": .int(valueRows.count)])
    }

    private static func rowToValue(_ row: [String: Any], textKey: String) -> Value {
        var result: [String: Value] = [:]
        for (key, val) in row {
            if key == "attributedBody" { continue }
            if key == textKey {
                let extracted = extractText(row: row, textKey: textKey)
                result[key] = extracted.map { .string($0) } ?? .null
            } else if key == "is_read" {
                result[key] = MessagesQueryContracts.isReadValue(val)
            } else if key == "date_read" {
                result[key] = MessagesQueryContracts.dateReadValue(val)
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

    public static func attributionFields(
        messagesDisplayName: String?,
        handle: String?,
        contact: ContactsModule.HandleAttribution?
    ) -> [String: Value] {
        if let displayName = messagesDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return [
                "resolvedName": .string(displayName),
                "attributionSource": .string("messages_chat_display_name"),
                "attributionConfidence": .string("exact_chat_metadata"),
                "attributionFailureReason": .null
            ]
        }
        if let contact, let resolvedName = contact.resolvedName {
            return [
                "resolvedName": .string(resolvedName),
                "attributionSource": .string(contact.source),
                "attributionConfidence": .string(contact.confidence),
                "attributionFailureReason": .null
            ]
        }
        return [
            "resolvedName": .null,
            "attributionSource": .string(contact?.source ?? "none"),
            "attributionConfidence": .string(contact?.confidence ?? "none"),
            "attributionFailureReason": .string(
                contact?.failureReason ?? (handle == nil ? "chat_has_no_resolvable_handle" : "no_attribution_available")
            )
        ]
    }

    private static func recentRowsToValue(_ rows: [[String: Any]]) -> Value {
        let valueRows: [Value] = rows.map { row in
            var result: [String: Value]
            if case .object(let object) = rowToValue(row, textKey: "last_message") {
                result = object
            } else {
                result = [:]
            }
            let displayName = row["display_name"] as? String
            let handle = row["chat_identifier"] as? String
            let contact = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? nil
                : handle.map(ContactsModule.exactHandleAttributionIfAuthorized)
            for (key, value) in attributionFields(
                messagesDisplayName: displayName,
                handle: handle,
                contact: contact
            ) {
                result[key] = value
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

    /// Return the current local Messages ROWID watermark. Exposed to the
    /// THREAD receipt engine so it can persist intent before consequence.
    public static func currentMaxMessageRowId() throws -> Int {
        let rows = try performQuery("SELECT MAX(ROWID) AS max_id FROM message", params: [])
        return (rows.first?["max_id"] as? Int) ?? 0
    }

    /// Pure exact-candidate classifier used by tests and the live poller.
    /// A candidate must be outbound, target the expected one-to-one handle,
    /// and reproduce the approved body exactly after normal decoding.
    public static func classifyDeliveryCandidates(
        _ rows: [[String: Any]],
        expectedTarget: String,
        expectedBody: String,
        verifiedAt: Date = Date()
    ) -> MessagesDeliveryVerification {
        struct Match {
            var rowId: Int
            var messageGuid: String?
            var chatGuid: String?
            var messageDate: Date?
            var service: String?
            var macErrorCode: Int?
            var macIsDelivered: Bool?
        }
        var uniqueMatches: [Int: Match] = [:]
        let expectedHandle = ThreadMessagesIdentity.canonicalHandle(expectedTarget)
        let expectedChat = expectedTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expectedHandle != nil || !expectedChat.isEmpty else {
            return .init(status: .deliveryError, error: "expected target is empty")
        }
        for row in rows {
            guard let rowId = row["ROWID"] as? Int,
                  (row["is_from_me"] as? Int) == 1,
                  extractText(row: row) == expectedBody else { continue }
            let targetMatches: Bool
            if let expectedHandle {
                let candidateHandles = [
                    row["handle_id"] as? String,
                    row["chat_identifier"] as? String
                ].compactMap { $0 }.compactMap(ThreadMessagesIdentity.canonicalHandle)
                targetMatches = candidateHandles.contains(expectedHandle)
            } else {
                let chatCandidates = [
                    row["chat_identifier"] as? String,
                    row["chat_guid"] as? String,
                    row["display_name"] as? String
                ].compactMap { $0 }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                targetMatches = chatCandidates.contains(expectedChat)
            }
            guard targetMatches else { continue }
            let unixSeconds: Double? = {
                if let value = row["message_unix_seconds"] as? Double { return value }
                if let value = row["message_unix_seconds"] as? Int { return Double(value) }
                return nil
            }()
            let macErrorCode: Int? = {
                if let value = row["mac_error"] as? Int { return value }
                if let value = row["error"] as? Int { return value }
                return nil
            }()
            let macIsDelivered: Bool? = {
                if let value = row["mac_is_delivered"] as? Int { return value != 0 }
                if let value = row["is_delivered"] as? Int { return value != 0 }
                if let value = row["mac_is_delivered"] as? Bool { return value }
                if let value = row["is_delivered"] as? Bool { return value }
                return nil
            }()
            uniqueMatches[rowId] = Match(
                rowId: rowId,
                messageGuid: row["message_guid"] as? String,
                chatGuid: row["chat_guid"] as? String,
                messageDate: unixSeconds.map(Date.init(timeIntervalSince1970:)),
                service: row["service"] as? String,
                macErrorCode: macErrorCode,
                macIsDelivered: macIsDelivered
            )
        }
        let matches = uniqueMatches.values.sorted { $0.rowId < $1.rowId }
        if matches.isEmpty { return .init(status: .notFound) }
        if matches.count > 1 {
            return .init(status: .ambiguous, candidateRowIds: matches.map(\.rowId))
        }
        let only = matches[0]
        return .init(
            status: .verified,
            messageRowId: only.rowId,
            messageGuid: only.messageGuid,
            chatGuid: only.chatGuid,
            messageDate: only.messageDate,
            service: only.service,
            verifiedAt: verifiedAt,
            candidateRowIds: [only.rowId],
            macErrorCode: only.macErrorCode,
            macIsDelivered: only.macIsDelivered
        )
    }

    /// Bounded chat.db poll after dispatch. Not a provider-delivery claim.
    public static let localCorrelationPollAttempts = 20
    public static let localCorrelationPollInterval: TimeInterval = 0.5
    public static let sendCompatibilityFieldSemantics =
        "sent is dispatch success; verified and correlatedLocalRecord are local chat.db correlation only"
    /// Agent-facing note when a local outbound row exists after a Messages/
    /// AppleScript error or a Mac chat.db error flag (#302). Must not live in
    /// the MCP `error` string — that trips `dispatchFormatted` isError.
    public static let correlatedDespiteScriptErrorGuidance =
        "Local outbound correlated. Do not report send failure. Mac Messages may still show a premature or Continuity false error; that is display, not Bridge send failure."

    /// Poll chat.db for one correlated local outbound record candidate. Evidence is bounded
    /// by the pre-send ROWID and Intent preparation timestamp; it does not
    /// claim provider delivery or remote receipt.
    public static func verifyExactDelivery(
        target: String,
        body: String,
        afterId: Int,
        preparedAt: Date,
        attempts: Int = localCorrelationPollAttempts,
        interval: TimeInterval = localCorrelationPollInterval,
        pageSize: Int = 250,
        maxPages: Int = 20
    ) -> MessagesDeliveryVerification {
        let sql = """
            SELECT m.ROWID, m.guid AS message_guid, m.text, m.attributedBody,
                   m.is_from_me, m.service, m.error AS mac_error,
                   m.is_delivered AS mac_is_delivered,
                   (CAST(m.date AS REAL) / 1000000000.0 + 978307200.0) AS message_unix_seconds,
                   h.id AS handle_id, c.chat_identifier, c.guid AS chat_guid,
                   c.display_name
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE m.ROWID > ?1
              AND m.is_from_me = 1
              AND (CAST(m.date AS REAL) / 1000000000.0 + 978307200.0) >= CAST(?2 AS REAL)
            ORDER BY m.ROWID ASC
            LIMIT ?3
            """
        do {
            let lowerBound = preparedAt.addingTimeInterval(-5).timeIntervalSince1970
            for attempt in 0..<max(1, attempts) {
                var cursor = afterId
                var allRows: [[String: Any]] = []
                var exhausted = false
                for page in 0..<max(1, maxPages) {
                    let rows = try performQuery(sql, params: [
                        String(cursor), String(lowerBound), String(max(1, pageSize))
                    ])
                    allRows.append(contentsOf: rows)
                    if rows.count < pageSize {
                        exhausted = true
                        break
                    }
                    guard let next = rows.compactMap({ $0["ROWID"] as? Int }).max(), next > cursor else {
                        return .init(status: .deliveryError, error: "chat.db verification pagination did not advance")
                    }
                    cursor = next
                    if page == maxPages - 1 {
                        return .init(status: .deliveryError, error: "chat.db verification exceeded the bounded \(pageSize * maxPages)-row window")
                    }
                }
                let classified = classifyDeliveryCandidates(
                    allRows,
                    expectedTarget: target,
                    expectedBody: body
                )
                if classified.status == .verified || classified.status == .ambiguous {
                    return classified
                }
                if !exhausted {
                    return .init(status: .deliveryError, error: "chat.db verification window was not exhausted")
                }
                if attempt < attempts - 1 { Thread.sleep(forTimeInterval: interval) }
            }
            return .init(status: .notFound)
        } catch {
            return .init(status: .deliveryError, error: error.localizedDescription)
        }
    }

    private static func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Latest inbound `message.service` for a one-to-one handle. Outbound
    /// rows are ignored so prior SMS history cannot override a live iMessage
    /// or RCS inbound (#198). Exact handle / chat.guid keys only — no LIKE
    /// (#215 / #303). Tapbacks and group chats are excluded.
    public static func lookupLiveInboundService(recipient: String) throws -> String? {
        try lookupLiveThreadService(
            target: .oneToOne(handle: recipient, declaredThreadService: nil)
        )
    }

    /// Bind the live 1:1 thread/contact service for inherit-or-fail-closed
    /// (#303). Prefers latest inbound on that thread; else the unambiguous
    /// chat.guid / service_name identity.
    public static func lookupLiveThreadService(
        target: MessagesProtocolDiscriminator.Target
    ) throws -> String? {
        let seed: String
        switch target {
        case .oneToOne(let handle, _):
            seed = handle
        case .group(let chatIdentifier):
            seed = chatIdentifier
        }
        let rows = try lookupLiveThreadRows(keys: MessagesProtocolDiscriminator.exactLookupKeys(for: seed))
        return MessagesProtocolDiscriminator.liveService(from: rows, target: target)
    }

    public static func lookupLiveThreadRows(keys: [String]) throws -> [[String: Any]] {
        let slots = MessagesProtocolDiscriminator.paddedLookupKeys(keys)
        let inList = (1...MessagesProtocolDiscriminator.lookupSlotCount).map { "?\($0)" }.joined(separator: ", ")
        let sql = """
            SELECT m.service, m.is_from_me, h.id AS handle_id,
                   c.chat_identifier, c.guid AS chat_guid, c.service_name,
                   (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS participant_count,
                   COALESCE(m.associated_message_type, 0) AS associated_message_type,
                   COALESCE(m.item_type, 0) AS item_type
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE (
                h.id IN (\(inList))
                OR c.chat_identifier IN (\(inList))
                OR c.guid IN (\(inList))
            )
              AND \(MessagesQueryContracts.normalRowPredicate)
              AND (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) <= 1
            ORDER BY m.date DESC
            LIMIT 50
            """
        return try performQuery(sql, params: slots)
    }

    /// One-to-one delivery primitive for ordinary messages_send and the bounded
    /// THREAD M1 receipt engine. It preserves the exact SEND token, inherits
    /// live inbound iMessage/SMS or fails closed (#198), allows explicit SMS
    /// on RCS/unknown only with `allowSmsDespiteLiveService` (#249), invokes
    /// once with no fallback, and returns local-record correlation evidence
    /// without mutating relationship state.
    public static func performOneToOneSend(
        recipient: String,
        body: String,
        confirm: String,
        serviceOverride: String?,
        afterId: Int,
        preparedAt: Date,
        liveInboundRaw: String? = nil,
        allowSmsDespiteLiveService: Bool = false
    ) -> MessagesDeliveryAttempt {
        performOneToOneSend(
            recipient: recipient,
            body: body,
            confirm: confirm,
            serviceOverride: serviceOverride,
            afterId: afterId,
            preparedAt: preparedAt,
            liveInboundRaw: liveInboundRaw,
            allowSmsDespiteLiveService: allowSmsDespiteLiveService,
            invoke: invokeAppleScript,
            verify: { target, approvedBody, watermark, prepared in
                verifyExactDelivery(
                    target: target,
                    body: approvedBody,
                    afterId: watermark,
                    preparedAt: prepared
                )
            }
        )
    }

    public static func performOneToOneSend(
        recipient: String,
        body: String,
        confirm: String,
        serviceOverride: String?,
        afterId: Int,
        preparedAt: Date,
        liveInboundRaw: String? = nil,
        allowSmsDespiteLiveService: Bool = false,
        invoke: MessagesServiceInvoker,
        verify: MessagesLocalRecordVerifier
    ) -> MessagesDeliveryAttempt {
        guard confirm == "SEND" else {
            return .init(
                invoked: false,
                verification: .init(status: .deliveryError, error: "messages_send requires confirm: 'SEND'"),
                error: "messages_send requires confirm: 'SEND'"
            )
        }
        let service: MessagesService
        switch resolveSendService(
            requested: serviceOverride,
            liveInboundRaw: liveInboundRaw,
            allowSmsDespiteLiveService: allowSmsDespiteLiveService
        ) {
        case .refuse(let reason):
            return .init(
                invoked: false,
                verification: .init(status: .deliveryError, error: reason),
                error: reason
            )
        case .use(let resolved):
            service = resolved
        }
        if service == .sms, !isPhoneRecipient(recipient) {
            let reason = "SMS requires a phone-number recipient"
            return .init(
                invoked: false,
                verification: .init(status: .deliveryError, error: reason),
                service: service.rawValue,
                error: reason
            )
        }

        let invocation = invoke(service, recipient, body)
        return reconcileInvokedSend(
            invocation: invocation,
            verification: verify(recipient, body, afterId, preparedAt),
            service: service.rawValue
        )
    }

    /// After AppleScript/Messages invoke, always correlate chat.db. A premature
    /// script error plus a matching outbound row is dispatch success, not a
    /// send failure (#302). One invoke — no iMessage→SMS fallback.
    public static func reconcileInvokedSend(
        invocation: MessagesAppleScriptInvocationResult,
        verification: MessagesDeliveryVerification,
        service: String? = nil
    ) -> MessagesDeliveryAttempt {
        if verification.verified {
            return .init(
                invoked: true,
                verification: verification,
                service: service,
                detectedService: verification.service,
                error: nil,
                errorNumber: nil,
                scriptError: invocation.error,
                scriptErrorNumber: invocation.errorNumber
            )
        }
        if invocation.succeeded {
            return .init(
                invoked: true,
                verification: verification,
                service: service,
                detectedService: verification.service
            )
        }
        return .init(
            invoked: true,
            verification: verification,
            service: service,
            detectedService: verification.service,
            error: invocation.error ?? verification.error,
            errorNumber: invocation.errorNumber,
            scriptError: invocation.error,
            scriptErrorNumber: invocation.errorNumber
        )
    }

    /// MCP envelope for ordinary one-to-one `messages_send`. `sent` is dispatch
    /// success; `verified` / `correlatedLocalRecord` remain chat.db correlation.
    public static func oneToOneSendMCPFields(
        recipient: String,
        body: String,
        attempt: MessagesDeliveryAttempt
    ) -> [String: Value] {
        var result: [String: Value] = [
            "sent": .bool(attempt.dispatchSucceeded),
            "deliveryInvoked": .bool(attempt.invoked),
            "consequencePossible": .bool(attempt.invoked),
            "correlatedLocalRecord": .bool(attempt.verification.verified),
            "providerDeliveryConfirmed": .bool(false),
            "compatibilityFieldSemantics": .string(sendCompatibilityFieldSemantics),
            "recipient": .string(recipient),
            "bodyLength": .int(body.utf8.count),
            "service": attempt.service.map(Value.string) ?? .null,
            "detectedService": attempt.detectedService.map(Value.string) ?? .null,
            "verified": .bool(attempt.verification.verified),
            "verificationStatus": .string(attempt.verification.status.rawValue),
            "messageRowId": attempt.verification.messageRowId.map(Value.int) ?? .null,
            "messageGuid": attempt.verification.messageGuid.map(Value.string) ?? .null,
            "chatGuid": attempt.verification.chatGuid.map(Value.string) ?? .null,
            "messageDate": attempt.verification.messageDate.map { .string(ThreadMessagesReceiptJournal.iso($0)) } ?? .null,
            "deliveryReference": attempt.verification.deliveryReference.map(Value.string) ?? .null,
            "verifiedAt": attempt.verification.verifiedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "candidateRowIds": .array(attempt.verification.candidateRowIds.map(Value.int))
        ]
        applySendHonestyFields(&result, attempt: attempt)
        return result
    }

    /// Shared #302 honesty fields. `error` is claimable send failure only —
    /// never a string when a local outbound row correlated (MCP isError).
    public static func applySendHonestyFields(
        _ result: inout [String: Value],
        attempt: MessagesDeliveryAttempt
    ) {
        result["error"] = attempt.error.map(Value.string) ?? .null
        if let errorNumber = attempt.errorNumber { result["errorNumber"] = .int(errorNumber) }
        result["scriptError"] = attempt.scriptError.map(Value.string) ?? .null
        result["scriptErrorNumber"] = attempt.scriptErrorNumber.map(Value.int) ?? .null
        result["macErrorCode"] = attempt.verification.macErrorCode.map(Value.int) ?? .null
        result["macIsDelivered"] = attempt.verification.macIsDelivered.map(Value.bool) ?? .null
        let macFlagged = (attempt.verification.macErrorCode ?? 0) != 0
        if attempt.verification.verified, attempt.scriptError != nil || macFlagged {
            result["agentGuidance"] = .string(correlatedDespiteScriptErrorGuidance)
            result["macUiMayShowFalseFailure"] = .bool(true)
        } else {
            result["agentGuidance"] = .null
            result["macUiMayShowFalseFailure"] = .bool(false)
        }
    }

    /// MCP envelope after a chatIdentifier AppleScript invoke (correlates
    /// even when the script reported an error — #302).
    public static func chatIdentifierSendMCPFields(
        chatIdentifier: String,
        body: String,
        verification: MessagesDeliveryVerification,
        invocation: MessagesAppleScriptInvocationResult = .init()
    ) -> [String: Value] {
        let attempt = reconcileInvokedSend(
            invocation: invocation,
            verification: verification
        )
        return chatIdentifierSendMCPFields(
            chatIdentifier: chatIdentifier,
            body: body,
            attempt: attempt
        )
    }

    public static func chatIdentifierSendMCPFields(
        chatIdentifier: String,
        body: String,
        attempt: MessagesDeliveryAttempt
    ) -> [String: Value] {
        var result: [String: Value] = [
            "sent": .bool(attempt.dispatchSucceeded),
            "deliveryInvoked": .bool(attempt.invoked),
            "consequencePossible": .bool(attempt.invoked),
            "correlatedLocalRecord": .bool(attempt.verification.verified),
            "providerDeliveryConfirmed": .bool(false),
            "compatibilityFieldSemantics": .string(sendCompatibilityFieldSemantics),
            "chatIdentifier": .string(chatIdentifier),
            "bodyLength": .int(body.utf8.count),
            "target": .string("chatIdentifier"),
            "verified": .bool(attempt.verification.verified),
            "verificationStatus": .string(attempt.verification.status.rawValue),
            "messageRowId": attempt.verification.messageRowId.map(Value.int) ?? .null,
            "deliveryReference": attempt.verification.deliveryReference.map(Value.string) ?? .null,
            "verifiedAt": attempt.verification.verifiedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
        ]
        applySendHonestyFields(&result, attempt: attempt)
        return result
    }

    private static func isPhoneRecipient(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("@") else { return false }
        let allowed = CharacterSet(charactersIn: "+0123456789().- ")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return trimmed.filter(\.isNumber).count >= 7
    }

    private static func invokeAppleScript(
        service: MessagesService,
        recipient: String,
        body: String
    ) -> MessagesAppleScriptInvocationResult {
        let safeRecipient = escapeAppleScriptString(recipient)
        let safeBody = escapeAppleScriptString(body)
        let script = """
            tell application "Messages"
                set targetService to 1st service whose service type = \(service.rawValue)
                set targetBuddy to buddy "\(safeRecipient)" of targetService
                send "\(safeBody)" to targetBuddy
            end tell
            """
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        _ = appleScript?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .init() }
        return .init(
            error: errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript execution failed",
            errorNumber: errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
        )
    }

    /// 1:1 iMessage file send. Separate bubble from body text (#218).
    private static func invokeAppleScriptFile(
        recipient: String,
        filePath: String
    ) -> MessagesAppleScriptInvocationResult {
        let safeRecipient = escapeAppleScriptString(recipient)
        let expanded = (filePath as NSString).expandingTildeInPath
        let safePath = escapeAppleScriptString(expanded)
        let script = """
            tell application "Messages"
                set targetService to 1st service whose service type is iMessage
                set targetBuddy to buddy "\(safeRecipient)" of targetService
                send POSIX file "\(safePath)" to targetBuddy
            end tell
            """
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        _ = appleScript?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .init() }
        return .init(
            error: errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript execution failed",
            errorNumber: errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
        )
    }

    /// Local correlation for an attachment send via `message_attachment_join`.
    public static func verifyFileDelivery(
        recipient: String,
        afterId: Int,
        preparedAt: Date
    ) -> MessagesDeliveryVerification {
        let sql = """
            SELECT m.ROWID, m.guid AS message_guid, m.is_from_me, m.service,
                   m.error AS mac_error, m.is_delivered AS mac_is_delivered,
                   (CAST(m.date AS REAL) / 1000000000.0 + 978307200.0) AS message_unix_seconds,
                   h.id AS handle_id, c.guid AS chat_guid
            FROM message m
            JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE m.ROWID > ?1
              AND m.is_from_me = 1
              AND h.id = ?2
              AND (CAST(m.date AS REAL) / 1000000000.0 + 978307200.0) >= CAST(?3 AS REAL)
            ORDER BY m.ROWID DESC
            LIMIT 2
            """
        do {
            let lowerBound = preparedAt.addingTimeInterval(-5).timeIntervalSince1970
            let rows = try performQuery(sql, params: [String(afterId), recipient, String(lowerBound)])
            if rows.isEmpty { return .init(status: .notFound) }
            if rows.count > 1 {
                return .init(status: .ambiguous, candidateRowIds: rows.compactMap { $0["ROWID"] as? Int })
            }
            let row = rows[0]
            let unixSeconds: Double? = {
                if let value = row["message_unix_seconds"] as? Double { return value }
                if let value = row["message_unix_seconds"] as? Int { return Double(value) }
                return nil
            }()
            let macErrorCode = row["mac_error"] as? Int
            let macIsDelivered: Bool? = {
                if let value = row["mac_is_delivered"] as? Int { return value != 0 }
                return nil
            }()
            return .init(
                status: .verified,
                messageRowId: row["ROWID"] as? Int,
                messageGuid: row["message_guid"] as? String,
                chatGuid: row["chat_guid"] as? String,
                messageDate: unixSeconds.map(Date.init(timeIntervalSince1970:)),
                service: row["service"] as? String,
                verifiedAt: Date(),
                candidateRowIds: (row["ROWID"] as? Int).map { [$0] } ?? [],
                macErrorCode: macErrorCode,
                macIsDelivered: macIsDelivered
            )
        } catch {
            return .init(status: .deliveryError, error: error.localizedDescription)
        }
    }

    /// Parse the Notion page + markdown tool results into the narrow snapshot
    /// the THREAD receipt engine is allowed to inspect.
    public static func threadSnapshot(
        pageResult: Value,
        markdownResult: Value,
        canonicalDataSourceId: String = "a7bd89e9-375a-47bc-875e-706b7b0f2dc0"
    ) throws -> ThreadMessagesSnapshot {
        guard case .object(let page) = pageResult,
              case .string(let pageId)? = page["id"],
              case .string(let propertiesJSON)? = page["properties"],
              case .string(let parentJSON)? = page["parent"],
              case .object(let markdownObject) = markdownResult,
              case .string(let markdown)? = markdownObject["markdown"] else {
            throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "THREAD read returned an unexpected shape")
        }
        guard let propertiesData = propertiesJSON.data(using: .utf8),
              let properties = try JSONSerialization.jsonObject(with: propertiesData) as? [String: Any],
              let parentData = parentJSON.data(using: .utf8),
              let parent = try JSONSerialization.jsonObject(with: parentData) as? [String: Any] else {
            throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "THREAD properties could not be decoded")
        }

        func property(_ name: String) -> [String: Any]? {
            properties.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value as? [String: Any]
        }
        func optionName(_ property: [String: Any]?) -> String? {
            if let status = property?["status"] as? [String: Any] { return status["name"] as? String }
            if let select = property?["select"] as? [String: Any] { return select["name"] as? String }
            return nil
        }
        func relationIds(_ name: String) -> [String] {
            (property(name)?["relation"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }
        func dateStart(_ name: String) -> String? {
            (property(name)?["date"] as? [String: Any])?["start"] as? String
        }
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "-", with: "").lowercased()
        }

        let contacts = relationIds("CONTACT")
        let prospects = relationIds("PROSPECT")
        let total = contacts.count + prospects.count
        let linkedPerson: ThreadLinkedPersonSnapshot? = {
            guard total == 1 else { return nil }
            if let id = contacts.first { return .init(entity: "contact", pageId: id) }
            if let id = prospects.first { return .init(entity: "prospect", pageId: id) }
            return nil
        }()
        let sourceId = (parent["data_source_id"] as? String) ?? (parent["database_id"] as? String) ?? ""
        return .init(
            pageId: pageId,
            canonicalThreadSource: normalized(sourceId) == normalized(canonicalDataSourceId),
            managerMode: optionName(property("Manager Mode")) ?? "",
            status: optionName(property("Status")),
            nextCheckIn: dateStart("Next Check-in"),
            linkedPerson: linkedPerson,
            linkedPersonCount: total,
            markdown: markdown
        )
    }

    public static func enrichThreadSnapshot(
        _ snapshot: ThreadMessagesSnapshot,
        registryResult: Value
    ) throws -> ThreadMessagesSnapshot {
        guard let linked = snapshot.linkedPerson,
              case .object(let row) = registryResult,
              case .string(let entity)? = row["entity"],
              case .string(let pageId)? = row["id"],
              case .object(let properties)? = row["properties"] else {
            throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "linked person registry read returned an unexpected shape")
        }
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "-", with: "").lowercased()
        }
        guard entity == linked.entity, normalized(pageId) == linked.pageId else {
            throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "linked person registry identity did not match the THREAD relation")
        }
        func string(_ key: String) -> String? {
            guard let value = properties.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value else { return nil }
            switch value {
            case .string(let raw): return raw.isEmpty ? nil : raw
            case .object(let object):
                if case .string(let start)? = object["start"] { return start }
                return nil
            default: return nil
            }
        }
        var enriched = snapshot
        enriched.linkedPerson = .init(
            entity: entity,
            pageId: pageId,
            name: {
                if case .string(let title)? = row["title"] { return title }
                return string("name")
            }(),
            status: string("status"),
            phone: string("phone"),
            email: string("email"),
            nextAction: string("nextAction"),
            lastActivity: entity == "contact" ? string("lastContacted") : string("lastTouched")
        )
        return enriched
    }

    private static func appendSucceeded(_ result: Value) -> Bool {
        guard case .object(let object) = result else { return false }
        if case .bool(let success)? = object["success"] { return success }
        return object["error"] == nil
    }

    /// Ordinary 1:1 send after the live thread/contact service has been
    /// bound (#303). Used for `recipient` and 1:1 `chatIdentifier`.
    public static func ordinaryOneToOneSendValue(
        handle: String,
        body: String?,
        filePath: String?,
        confirm: String,
        serviceOverride: String?,
        allowSmsDespiteLiveService: Bool,
        liveInboundRaw: String?,
        liveRows: [[String: Any]] = [],
        chatIdentifier: String? = nil
    ) throws -> Value {
        if serviceOverride == nil,
           liveInboundRaw == nil,
           MessagesProtocolDiscriminator.isAmbiguousThreadIdentity(from: liveRows, handle: handle) {
            return sendClosedEnvelope(
                error: MessagesProtocolDiscriminator.ambiguousThreadsRefuseReason(handle: handle),
                liveInboundRaw: liveInboundRaw,
                chatIdentifier: chatIdentifier
            )
        }
        switch resolveSendService(
            requested: serviceOverride,
            liveInboundRaw: liveInboundRaw,
            allowSmsDespiteLiveService: allowSmsDespiteLiveService
        ) {
        case .refuse(let reason):
            return sendClosedEnvelope(
                error: reason,
                liveInboundRaw: liveInboundRaw,
                chatIdentifier: chatIdentifier
            )
        case .use(let resolved):
            if resolved == .sms, !isPhoneRecipient(handle) {
                return sendClosedEnvelope(
                    error: "SMS requires a phone-number recipient",
                    liveInboundRaw: liveInboundRaw,
                    service: resolved.rawValue,
                    chatIdentifier: chatIdentifier
                )
            }
            if let filePath, let policyError = MessagesQueryContracts.fileSendPolicyError(
                filePath: filePath,
                chatIdentifier: chatIdentifier,
                resolvedService: resolved.rawValue,
                checkFilesystem: true
            ) {
                return sendClosedEnvelope(
                    error: policyError,
                    liveInboundRaw: liveInboundRaw,
                    service: resolved.rawValue,
                    chatIdentifier: chatIdentifier
                )
            }
            if resolved != .iMessage, filePath != nil {
                return sendClosedEnvelope(
                    error: "file attachments are 1:1 iMessage only",
                    liveInboundRaw: liveInboundRaw,
                    service: resolved.rawValue,
                    chatIdentifier: chatIdentifier
                )
            }
        }
        let preSendMaxId: Int
        let preparedAt = Date()
        do {
            preSendMaxId = try currentMaxMessageRowId()
        } catch {
            return sendClosedEnvelope(
                error: "Could not capture pre-send ROWID watermark: \(error.localizedDescription)",
                liveInboundRaw: liveInboundRaw,
                chatIdentifier: chatIdentifier,
                extra: [
                    "verified": .bool(false),
                    "verificationStatus": .string(MessagesDeliveryVerificationStatus.deliveryError.rawValue)
                ]
            )
        }
        if let filePath {
            let invocation = invokeAppleScriptFile(recipient: handle, filePath: filePath)
            let verification = verifyFileDelivery(
                recipient: handle,
                afterId: preSendMaxId,
                preparedAt: preparedAt
            )
            let attempt = reconcileInvokedSend(
                invocation: invocation,
                verification: verification,
                service: "iMessage"
            )
            var result: [String: Value] = [
                "sent": .bool(attempt.dispatchSucceeded),
                "deliveryInvoked": .bool(attempt.invoked),
                "consequencePossible": .bool(attempt.invoked),
                "correlatedLocalRecord": .bool(attempt.verification.verified),
                "providerDeliveryConfirmed": .bool(false),
                "recipient": .string(handle),
                "filePath": .string((filePath as NSString).expandingTildeInPath),
                "liveInboundService": liveInboundRaw.map(Value.string) ?? .null,
                "verified": .bool(attempt.verification.verified),
                "verificationStatus": .string(attempt.verification.status.rawValue),
                "messageRowId": attempt.verification.messageRowId.map(Value.int) ?? .null
            ]
            if let chatIdentifier {
                result["chatIdentifier"] = .string(chatIdentifier)
            }
            applySendHonestyFields(&result, attempt: attempt)
            return .object(result)
        }
        guard let body else {
            throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "missing body or filePath")
        }
        let attempt = performOneToOneSend(
            recipient: handle,
            body: body,
            confirm: confirm,
            serviceOverride: serviceOverride,
            afterId: preSendMaxId,
            preparedAt: preparedAt,
            liveInboundRaw: liveInboundRaw,
            allowSmsDespiteLiveService: allowSmsDespiteLiveService
        )
        var fields = oneToOneSendMCPFields(
            recipient: handle,
            body: body,
            attempt: attempt
        )
        fields["liveInboundService"] = liveInboundRaw.map(Value.string) ?? .null
        if let chatIdentifier {
            fields["chatIdentifier"] = .string(chatIdentifier)
        }
        return .object(fields)
    }

    public static func sendClosedEnvelope(
        error: String,
        liveInboundRaw: String? = nil,
        service: String? = nil,
        chatIdentifier: String? = nil,
        extra: [String: Value] = [:]
    ) -> Value {
        var fields: [String: Value] = [
            "sent": .bool(false),
            "deliveryInvoked": .bool(false),
            "consequencePossible": .bool(false),
            "correlatedLocalRecord": .bool(false),
            "providerDeliveryConfirmed": .bool(false),
            "liveInboundService": liveInboundRaw.map(Value.string) ?? .null,
            "error": .string(error)
        ]
        if let service { fields["service"] = .string(service) }
        if let chatIdentifier { fields["chatIdentifier"] = .string(chatIdentifier) }
        for (key, value) in extra { fields[key] = value }
        return .object(fields)
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
                    SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.service,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE (m.text LIKE '%' || ?1 || '%'
                       OR (m.text IS NULL AND m.attributedBody IS NOT NULL
                           AND CAST(m.attributedBody AS TEXT) LIKE '%' || ?1 || '%'))
                      AND \(MessagesQueryContracts.normalRowPredicate)
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
            description: "List the N most recently active Messages conversations with explicit attribution provenance. Blank chat names get a best-effort exact Contacts lookup when Contacts permission is already granted; loose name inference is never used.",
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
                           m.is_from_me, m.service,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM chat c
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE m.ROWID = (
                        SELECT cmj2.message_id FROM chat_message_join cmj2
                        JOIN message m2 ON m2.ROWID = cmj2.message_id
                        WHERE cmj2.chat_id = c.ROWID
                          AND \(MessagesQueryContracts.normalRowPredicateM2)
                        ORDER BY m2.date DESC LIMIT 1
                    )
                    ORDER BY m.date DESC
                    LIMIT ?1
                    """
                let rows = try performQuery(sql, params: [String(limit)])
                return recentRowsToValue(rows)
            }
        ))

        // MARK: 3. messages_chat – open
        await router.register(ToolRegistration(
            name: "messages_chat",
            module: moduleName,
            tier: .open,
            description: "Read one Messages transcript by exact handle (`contact`) or exact group/chat id (`chatIdentifier`) — XOR, no LIKE. Each row includes chat.db service (iMessage, SMS, RCS, …), is_read, and date_read (0 → null). Default rows are normal messages only (associated_message_type=0 and item_type=0). Inbound is_read means this Mac displayed it; outbound is a recipient read receipt when enabled. No mark-as-read.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact": .object(["type": .string("string"), "description": .string("Exact handle (phone/email). XOR with chatIdentifier. No substring match.")]),
                    "chatIdentifier": .object(["type": .string("string"), "description": .string("Exact chat.chat_identifier from messages_recent/participants. XOR with contact.")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max messages to return (default: 50)")])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Messages: Read Thread",
                whenToUse: ["reading the back-and-forth history with one person by exact phone/email",
                            "reading an existing group via exact chatIdentifier from messages_recent"],
                whenNotToUse: ["keyword search across all chats (use messages_search)",
                               "listing who is in a group chat (use messages_participants)"],
                relatedTools: ["messages_recent", "messages_search", "messages_participants", "contacts_resolve_handle"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_chat", reason: "arguments must be an object")
                }
                let contact: String? = {
                    if case .string(let value) = args["contact"] { return value }
                    return nil
                }()
                let chatIdentifier: String? = {
                    if case .string(let value) = args["chatIdentifier"] { return value }
                    return nil
                }()
                let selector = try MessagesQueryContracts.ChatSelector.parse(
                    contact: contact,
                    chatIdentifier: chatIdentifier
                )
                let limit: Int = { if case .int(let l) = args["limit"] { return l }; return 50 }()
                let sql = """
                    SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.service,
                           m.is_read,
                           CASE WHEN m.date_read IS NULL OR m.date_read = 0 THEN NULL
                                ELSE datetime(m.date_read/1000000000 + 978307200, 'unixepoch', 'localtime')
                           END AS date_read,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    JOIN chat c ON c.ROWID = cmj.chat_id
                    WHERE \(selector.whereClause)
                      AND \(MessagesQueryContracts.normalRowPredicate)
                    ORDER BY m.date DESC
                    LIMIT ?2
                    """
                let rows = try performQuery(sql, params: [selector.sqlParam, String(limit)])
                return rowsToValue(rows)
            }
        ))

        // MARK: 4. messages_content – open
        await router.register(ToolRegistration(
            name: "messages_content",
            module: moduleName,
            tier: .open,
            description: "Fetch one message by Messages DB ROWID, including attachment metadata when present. Attachment bytes are not auto-extracted.",
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
                           m.is_read,
                           CASE WHEN m.date_read IS NULL OR m.date_read = 0 THEN NULL
                                ELSE datetime(m.date_read/1000000000 + 978307200, 'unixepoch', 'localtime')
                           END AS date_read,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.ROWID = ?1
                    """
                let rows = try performQuery(sql, params: [String(msgId)])
                guard case .object(var result) = rowsToValue(rows) else {
                    return rowsToValue(rows)
                }
                do {
                    let attachmentSQL = """
                        SELECT a.ROWID AS attachment_id,
                               a.filename AS file_path,
                               a.mime_type,
                               a.transfer_name
                        FROM attachment a
                        JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                        WHERE maj.message_id = ?1
                        ORDER BY a.ROWID ASC
                        """
                    let attachmentRows = try performQuery(attachmentSQL, params: [String(msgId)])
                    if case .object(let attachmentResult) = rawRowsToValue(attachmentRows),
                       case .array(let attachments) = attachmentResult["rows"] {
                        result["attachments"] = .array(attachments)
                        result["attachmentCount"] = .int(attachments.count)
                    }
                    result["attachmentMode"] = .string("metadata_only")
                    result["attachmentLimitation"] = .string("Attachment bytes are not returned automatically; file_path is provided when Messages stored one locally.")
                } catch {
                    result["attachments"] = .array([])
                    result["attachmentCount"] = .int(0)
                    result["attachmentMode"] = .string("metadata_unavailable")
                    result["attachmentLimitation"] = .string("Attachment metadata query failed: \(error.localizedDescription)")
                }
                return .object(result)
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
                    WHERE c.chat_identifier = ?1
                    """
                let rows = try performQuery(sql, params: [chatId])
                return rawRowsToValue(rows)
            }
        ))

        // MARK: 6. messages_send – notify catalog default, payload-aware (#298)
        // Ordinary 1:1 handle/chat + plain text → .notify (loud, non-blocking).
        // Groups, attachments/media, and SMS-override
        // (`allowSmsDespiteLiveService`) stay .request at dispatch via
        // MessagesSendCatalogTier. neverAutoApprove is false so Settings
        // (tool or module override, Always Allow) can still raise or lower
        // the per-tool tier — including for remote/tunnel sessions.
        // confirm:'SEND' remains handler-required. Ordinary one-to-one
        // (recipient or 1:1 chatIdentifier) inherits live thread/contact
        // service or fails closed (#198 / #303); explicit SMS on
        // RCS/unknown requires allowSmsDespiteLiveService (#249) and that
        // path stays Request. This does not change host Auto-review (#294).
        await router.register(ToolRegistration(
            name: "messages_send",
            module: moduleName,
            tier: MessagesSendCatalogTier.registeredToolTier,
            description: "Send one exact iMessage or SMS after confirm:'SEND'. After invoke, correlate chat.db — a premature AppleScript error plus a matching outbound row is dispatch success; do not report send failure (scriptError is observational). Resolve raw chatNNN via messages_participants; names via contacts_resolve_handle. Omit service to inherit the live 1:1 thread/contact service (latest inbound, else unambiguous chat.guid / service_name). Pass exactly iMessage or SMS. Fail closed on RCS/unknown/mismatch/ambiguous threads — never silent remap or iMessage→SMS fallback. 1:1 chatIdentifier (phone, email, iMessage|SMS|RCS|any;-;handle) uses the same discriminator; do not iterate AppleScript services. Operator-authorized SMS on a live RCS/unknown thread requires service=SMS and allowSmsDespiteLiveService:true; the flag does not unlock iMessage↔SMS mismatch. Optional filePath XOR non-empty body: attachments are 1:1 iMessage only (no SMS/RCS, no chatIdentifier/groups). Existing-group text send uses group chatIdentifier; group create is not built. Bounded THREAD M1 still binds recipient/service/body. Local chat.db correlation is not provider delivery (never providerDeliveryConfirmed). Catalog default is Notify for ordinary 1:1 plain-text sends; group chats, attachments/media, and SMS-override stay Request. Settings can raise or lower the per-tool tier. Does not change host Auto-review.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recipient": .object(["type": .string("string"), "description": .string("Recipient phone number or email (NOT a raw chatNNN id — resolve those with messages_participants first)")]),
                    "chatIdentifier": .object(["type": .string("string"), "description": .string("Existing Messages chat identifier. 1:1 values (phone, email, iMessage|SMS|RCS|any;-;handle) inherit that thread's live service or fail closed — same discriminator as recipient. Group ids send to the existing chat; group create is not built.")]),
                    "body": .object(["type": .string("string"), "description": .string("Message body text. XOR with filePath — do not send caption+file as one bubble.")]),
                    "filePath": .object(["type": .string("string"), "description": .string("Optional local file to send as a separate 1:1 iMessage. XOR with body. Same confirm:'SEND'.")]),
                    "confirm": .object(["type": .string("string"), "description": .string("Must be exactly 'SEND' to proceed")]),
                    "service": .object(["type": .string("string"), "enum": .array([.string("iMessage"), .string("SMS")]), "description": .string("Optional for ordinary one-to-one sends (recipient or 1:1 chatIdentifier). Omit to inherit the live thread/contact service. Exact value only when passed. RCS/unknown, explicit mismatch, or ambiguous iMessage+SMS threads fail closed — no SMS fallback. SMS on RCS/unknown requires allowSmsDespiteLiveService:true.")]),
                    "allowSmsDespiteLiveService": .object(["type": .string("boolean"), "description": .string("Operator-authorized SMS when live inbound is RCS/unknown (unsupported). Required together with service=SMS. Does not unlock iMessage↔SMS mismatch or omit-service inherit. Never auto-maps RCS to SMS. Default false.")]),
                    "threadPageId": .object(["type": .string("string"), "description": .string("Canonical THREAD page ID for the bounded one-to-one M1 transaction.")]),
                    "actionId": .object(["type": .string("string"), "description": .string("Stable idempotency action ID for the bounded M1 transaction.")]),
                    "approvalBasis": .object(["type": .string("string"), "description": .string("Fresh operator approval basis bound to exact recipient, service, and body.")]),
                    "actor": .object(["type": .string("string"), "description": .string("Actor recorded in THREAD M1 receipts.")]),
                    "workspace": .object(["type": .string("string"), "description": .string("Optional Notion workspace connection for THREAD receipt reads and writes.")])
                ]),
                "required": .array([.string("confirm")])
            ]),
            metadata: ToolMetadata(
                title: "Messages: Send",
                whenToUse: ["send to a known phone/email with confirm:'SEND'",
                            "send text to an existing group via chatIdentifier",
                            "send one 1:1 iMessage file via filePath XOR body",
                            "send SMS on an RCS/unknown thread with service=SMS and allowSmsDespiteLiveService:true"],
                whenNotToUse: ["raw chatNNN: resolve with messages_participants",
                               "contact name only: use contacts_resolve_handle",
                               "creating a new Messages group — group create is not built",
                               "treating imessage:open?addresses=… plus UI Return as a successful group create",
                               "silent RCS→SMS or iMessage→SMS fallback — omit still fails closed",
                               "claiming send failure when correlatedLocalRecord is true"],
                relatedTools: ["messages_participants", "contacts_resolve_handle", "messages_chat"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "arguments must be an object")
                }
                guard case .string(let confirm) = args["confirm"] else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "missing required parameters")
                }
                let body: String? = {
                    if case .string(let value) = args["body"] { return value }
                    return nil
                }()
                let filePath: String? = {
                    if case .string(let value) = args["filePath"] { return value }
                    return nil
                }()
                let recipient: String? = {
                    if case .string(let value) = args["recipient"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                    return nil
                }()
                let chatIdentifier: String? = {
                    if case .string(let value) = args["chatIdentifier"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                    return nil
                }()
                guard recipient != nil || chatIdentifier != nil else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "missing recipient or chatIdentifier")
                }
                if let xorError = MessagesQueryContracts.payloadXORError(body: body, filePath: filePath) {
                    return .object([
                        "error": .string(xorError),
                        "sent": .bool(false),
                        "deliveryInvoked": .bool(false),
                        "consequencePossible": .bool(false),
                        "correlatedLocalRecord": .bool(false),
                        "providerDeliveryConfirmed": .bool(false)
                    ])
                }
                if let filePath, let policyError = MessagesQueryContracts.fileSendPolicyError(
                    filePath: filePath,
                    chatIdentifier: chatIdentifier,
                    resolvedService: nil,
                    checkFilesystem: false
                ) {
                    return .object([
                        "error": .string(policyError),
                        "sent": .bool(false),
                        "deliveryInvoked": .bool(false),
                        "consequencePossible": .bool(false),
                        "correlatedLocalRecord": .bool(false),
                        "providerDeliveryConfirmed": .bool(false)
                    ])
                }

                guard confirm == "SEND" else {
                    return .object([
                        "error": .string("messages_send requires confirm: 'SEND'"),
                        "sent": .bool(false)
                    ])
                }
                guard let approvalReceipt = SecurityApprovalReceipt.current,
                      approvalReceipt.validates(toolName: "messages_send", arguments: arguments) else {
                    return .object([
                        "error": .string("messages_send requires a fresh server-issued approval receipt bound to this exact target and body"),
                        "sent": .bool(false),
                        "deliveryInvoked": .bool(false),
                        "consequencePossible": .bool(false),
                        "correlatedLocalRecord": .bool(false),
                        "providerDeliveryConfirmed": .bool(false)
                    ])
                }

                if case .string(let threadPageId)? = args["threadPageId"] {
                    if filePath != nil {
                        return ThreadMessagesReceiptResult(
                            outcome: .blocked,
                            actionId: "",
                            error: "THREAD M1 is text-only; filePath is out of scope"
                        ).mcpValue()
                    }
                    guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return ThreadMessagesReceiptResult(
                            outcome: .blocked,
                            actionId: "",
                            error: "THREAD M1 requires a non-empty body"
                        ).mcpValue()
                    }
                    guard chatIdentifier == nil, let recipient else {
                        return ThreadMessagesReceiptResult(
                            outcome: .blocked,
                            actionId: "",
                            error: "THREAD M1 supports one-to-one recipient delivery only; chatIdentifier is out of scope"
                        ).mcpValue()
                    }
                    guard case .string(let actionId)? = args["actionId"],
                          case .string(let approvalBasis)? = args["approvalBasis"] else {
                        return ThreadMessagesReceiptResult(
                            outcome: .blocked,
                            actionId: "",
                            error: "actionId and approvalBasis are required with threadPageId"
                        ).mcpValue()
                    }
                    let actor: String = {
                        if case .string(let value)? = args["actor"], !value.isEmpty { return value }
                        return "The Bridge"
                    }()
                    let workspace: String? = {
                        if case .string(let value)? = args["workspace"], !value.isEmpty { return value }
                        return nil
                    }()
                    let serviceOverride: String? = {
                        if case .string(let value)? = args["service"] { return value }
                        return nil
                    }()
                    let request = ThreadMessagesReceiptRequest(
                        threadPageId: threadPageId,
                        actionId: actionId,
                        recipient: recipient,
                        body: body,
                        approvalBasis: approvalBasis,
                        actor: actor,
                        confirm: confirm,
                        serviceOverride: serviceOverride,
                        approvalReceiptId: approvalReceipt.receiptId,
                        approvalArgumentsDigest: approvalReceipt.argumentsDigest,
                        approvalPrincipal: approvalReceipt.governancePrincipal ?? approvalReceipt.transportSessionId,
                        approvedAt: approvalReceipt.approvedAt
                    )
                    let receiptStore: SQLiteThreadMessagesReceiptStore
                    do {
                        receiptStore = try SQLiteThreadMessagesReceiptStore.live()
                    } catch {
                        return ThreadMessagesReceiptResult(
                            outcome: .blocked,
                            actionId: actionId,
                            error: "durable THREAD action ledger is unavailable: \(error.localizedDescription)"
                        ).mcpValue()
                    }
                    let dependencies = ThreadMessagesReceiptDependencies(
                        store: receiptStore,
                        readThread: { pageId in
                            var pageArgs: [String: Value] = [
                                "pageId": .string(pageId),
                                "includeBlocks": .bool(false)
                            ]
                            var markdownArgs: [String: Value] = ["pageId": .string(pageId)]
                            if let workspace {
                                pageArgs["workspace"] = .string(workspace)
                                markdownArgs["workspace"] = .string(workspace)
                            }
                            let pageResult = try await router.dispatch(
                                toolName: "notion_page_read",
                                arguments: .object(pageArgs)
                            )
                            let markdownResult = try await router.dispatch(
                                toolName: "notion_page_markdown_read",
                                arguments: .object(markdownArgs)
                            )
                            let snapshot = try threadSnapshot(pageResult: pageResult, markdownResult: markdownResult)
                            guard snapshot.linkedPersonCount == 1, let linked = snapshot.linkedPerson else {
                                return snapshot
                            }
                            let personResult = try await router.dispatch(
                                toolName: "registry_get",
                                arguments: .object([
                                    "entity": .string(linked.entity),
                                    "id": .string(linked.pageId),
                                    "forceRefresh": .bool(true)
                                ])
                            )
                            return try enrichThreadSnapshot(snapshot, registryResult: personResult)
                        },
                        appendMarkdown: { pageId, markdown in
                            var appendArgs: [String: Value] = [
                                "pageId": .string(pageId),
                                "markdown": .string(markdown)
                            ]
                            if let workspace { appendArgs["workspace"] = .string(workspace) }
                            // This append is an internal step of an already route-admitted,
                            // exactly approved M1 transaction. Dispatch without the outer remote
                            // client identity so the nested call does not demand a second,
                            // impossible-to-forward route receipt.
                            let result = try await router.dispatch(
                                toolName: "notion_blocks_append",
                                arguments: .object(appendArgs),
                                context: .localDefault
                            )
                            guard appendSucceeded(result) else {
                                throw ToolRouterError.invalidArguments(
                                    toolName: "messages_send",
                                    reason: "THREAD journal append failed"
                                )
                            }
                        },
                        currentMaxMessageRowId: { try currentMaxMessageRowId() },
                        reconcile: { target, approvedBody, afterId, preparedAt in
                            verifyExactDelivery(
                                target: target,
                                body: approvedBody,
                                afterId: afterId,
                                preparedAt: preparedAt
                            )
                        },
                        send: { target, approvedBody, token, override, afterId, preparedAt in
                            performOneToOneSend(
                                recipient: target,
                                body: approvedBody,
                                confirm: token,
                                serviceOverride: override,
                                afterId: afterId,
                                preparedAt: preparedAt
                            )
                        }
                    )
                    return await ThreadMessagesReceiptEngine.execute(
                        request: request,
                        dependencies: dependencies
                    ).mcpValue()
                }

                let serviceOverride: String? = {
                    if case .string(let value)? = args["service"] { return value }
                    return nil
                }()
                let allowSmsDespiteLiveService: Bool = {
                    if case .bool(let value)? = args["allowSmsDespiteLiveService"] { return value }
                    return false
                }()

                if let chatIdentifier {
                    switch MessagesProtocolDiscriminator.parseChatIdentifier(chatIdentifier) {
                    case .oneToOne(let handle, let declared):
                        let target = MessagesProtocolDiscriminator.Target.oneToOne(
                            handle: handle,
                            declaredThreadService: declared
                        )
                        let rows: [[String: Any]]
                        do {
                            rows = try lookupLiveThreadRows(
                                keys: MessagesProtocolDiscriminator.exactLookupKeys(for: chatIdentifier)
                            )
                        } catch {
                            return sendClosedEnvelope(
                                error: "Could not read live inbound service: \(error.localizedDescription)",
                                chatIdentifier: chatIdentifier
                            )
                        }
                        let liveInboundRaw = MessagesProtocolDiscriminator.liveService(
                            from: rows,
                            target: target
                        )
                        return try ordinaryOneToOneSendValue(
                            handle: handle,
                            body: body,
                            filePath: filePath,
                            confirm: confirm,
                            serviceOverride: serviceOverride,
                            allowSmsDespiteLiveService: allowSmsDespiteLiveService,
                            liveInboundRaw: liveInboundRaw,
                            liveRows: rows,
                            chatIdentifier: chatIdentifier
                        )
                    case .group:
                        guard let body else {
                            throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "missing body or filePath")
                        }
                        let preRows = (try? performQuery(
                            "SELECT MAX(ROWID) as max_id FROM message", params: []
                        )) ?? []
                        let preSendMaxId = (preRows.first?["max_id"] as? Int) ?? 0
                        let preparedAt = Date()

                        let safeChatIdentifier = escapeAppleScriptString(chatIdentifier)
                        let safeBody = escapeAppleScriptString(body)
                        let script = """
                            tell application "Messages"
                                set targetChat to missing value
                                repeat with targetService in services
                                    repeat with candidateChat in chats of targetService
                                        set candidateId to id of candidateChat as text
                                        set candidateName to ""
                                        try
                                            set candidateName to name of candidateChat as text
                                        end try
                                        if candidateId contains "\(safeChatIdentifier)" or candidateName contains "\(safeChatIdentifier)" then
                                            set targetChat to candidateChat
                                            exit repeat
                                        end if
                                    end repeat
                                    if targetChat is not missing value then exit repeat
                                end repeat
                                if targetChat is missing value then error "No existing Messages chat matched chatIdentifier \(safeChatIdentifier)"
                                send "\(safeBody)" to targetChat
                            end tell
                            """
                        let appleScript = NSAppleScript(source: script)
                        var errorInfo: NSDictionary?
                        _ = appleScript?.executeAndReturnError(&errorInfo)
                        let invocation: MessagesAppleScriptInvocationResult
                        if let errorInfo {
                            invocation = .init(
                                error: errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript execution failed",
                                errorNumber: errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
                            )
                        } else {
                            invocation = .init()
                        }
                        let verification = verifyExactDelivery(
                            target: chatIdentifier,
                            body: body,
                            afterId: preSendMaxId,
                            preparedAt: preparedAt
                        )
                        return .object(chatIdentifierSendMCPFields(
                            chatIdentifier: chatIdentifier,
                            body: body,
                            verification: verification,
                            invocation: invocation
                        ))
                    }
                }

                guard let recipient else {
                    throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "missing recipient or chatIdentifier")
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

                let target = MessagesProtocolDiscriminator.Target.oneToOne(
                    handle: recipient,
                    declaredThreadService: nil
                )
                let rows: [[String: Any]]
                let liveInboundRaw: String?
                do {
                    rows = try lookupLiveThreadRows(
                        keys: MessagesProtocolDiscriminator.exactLookupKeys(for: recipient)
                    )
                    liveInboundRaw = MessagesProtocolDiscriminator.liveService(
                        from: rows,
                        target: target
                    )
                } catch {
                    return sendClosedEnvelope(
                        error: "Could not read live inbound service: \(error.localizedDescription)"
                    )
                }
                return try ordinaryOneToOneSendValue(
                    handle: recipient,
                    body: body,
                    filePath: filePath,
                    confirm: confirm,
                    serviceOverride: serviceOverride,
                    allowSmsDespiteLiveService: allowSmsDespiteLiveService,
                    liveInboundRaw: liveInboundRaw,
                    liveRows: rows
                )
            }
        ))
    }
}
