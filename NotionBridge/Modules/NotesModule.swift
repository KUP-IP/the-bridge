// NotesModule.swift – v3.7·G  Apple Notes MCP tools
// NotionBridge · Modules
//
// Six tools: notes_list, notes_read, notes_create, notes_update,
// notes_delete, notes_search. Apple Notes is AppleScript-scriptable;
// this module drives Notes.app over the existing apple-events automation
// entitlement (already granted to NotionBridge.app). The per-app Notes
// TCC grant is an operator first-use prompt (System Settings > Privacy &
// Security > Automation > NotionBridge → Notes) — no entitlement change.
//
// DESIGN — injectable osascript seam (testable without live Notes):
//   All Notes interaction funnels through a single `NotesScriptRunner`
//   closure (`(String) -> NotesScriptResult`). Production wires the
//   in-process `NSAppleScript` runner (mirrors AppleScriptModule /
//   MessagesModule — one permanent Automation grant for the app, no
//   osascript child-process TCC storm). Tests inject a mock runner that
//   returns canned script output or a scripting error, so the entire CRUD
//   + search surface is exercised with ZERO contact with Notes.app.
//
// Tiers (per packet): list / read / search → .open (read-only, no prompt);
// create / update → .notify (informational post-hoc notification);
// delete → .request (human-gated, irreversible move-to-Notes-trash).
//
// ADDRESSING: notes are addressed by `noteId` (the AppleScript `id` of the
// note, a stable `x-coredata://…` URL) OR by `noteName` (the note title;
// first case-insensitive match wins). Folders are addressed by `folder`
// name. Plain-text + the note's basic HTML body are the fidelity ceiling
// (rich-text/attachment fidelity + shared-note collaboration are scope-OUT).

import Foundation
import MCP

// MARK: - Script Seam

/// Result of running an AppleScript through the Notes seam.
/// `.ok` carries the script's string return value; `.failure` carries the
/// AppleScript error message + numeric code (e.g. -1743 = Automation TCC
/// denial) so handlers can surface actionable guidance.
public enum NotesScriptResult: Sendable, Equatable {
    case ok(String)
    case failure(message: String, code: Int)
}

/// The injectable seam. A closure that takes AppleScript source and returns
/// a `NotesScriptResult`. Production injects the `NSAppleScript` runner;
/// tests inject a deterministic mock.
public typealias NotesScriptRunner = @Sendable (String) -> NotesScriptResult

// MARK: - NotesModule

public enum NotesModule {

    public static let moduleName = "notes"

    /// Field/record separators used to serialize AppleScript list output
    /// without colliding with note content. ASCII unit/record separators
    /// are control bytes that never appear in user note text.
    /// `public` so the test target can frame fixtures with the same bytes.
    public static let fieldSep = "\u{1F}"   // US — between fields of one record
    public static let recordSep = "\u{1E}"  // RS — between records

    // MARK: Production runner (in-process NSAppleScript)

    /// In-process AppleScript runner. Using `NSAppleScript` (not an
    /// `/usr/bin/osascript` child process) means macOS attributes the
    /// Automation grant to NotionBridge.app itself — one permanent grant,
    /// no per-invocation TCC prompt storm (same rationale as
    /// AppleScriptModule / MessagesModule.send).
    public static let liveRunner: NotesScriptRunner = { source in
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let output = script?.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let code = error[NSAppleScript.errorNumber] as? Int ?? -1
            return .failure(message: message, code: code)
        }
        return .ok(output?.stringValue ?? "")
    }

    // MARK: Registration

    /// Register all NotesModule tools on the given router.
    /// - Parameter runner: the AppleScript seam. Defaults to the live
    ///   in-process `NSAppleScript` runner; tests inject a mock.
    public static func register(
        on router: ToolRouter,
        runner: @escaping NotesScriptRunner = liveRunner
    ) async {

        // MARK: 1. notes_list — open
        await router.register(ToolRegistration(
            name: "notes_list",
            module: moduleName,
            tier: .open,
            description: "List Apple Notes folders and notes. Omit `folder` to list every note across all folders; pass `folder` to scope to one folder. Returns note id + name + folder + modification date (not bodies — use notes_read for content).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "folder": .object([
                        "type": .string("string"),
                        "description": .string("Optional folder name to scope the listing. Omit to list notes from every folder.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max notes to return (default: 100).")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Notes: List",
                whenToUse: ["enumerating Apple Notes folders + notes to find a note id/name before notes_read/update/delete",
                            "scoping a listing to one folder via `folder`"],
                whenNotToUse: ["reading a note's body (use notes_read)",
                               "keyword-searching note content (use notes_search)"],
                relatedTools: ["notes_read", "notes_search", "notes_create"]
            ),
            handler: { arguments in
                let args = objectArgs(arguments)
                let folder = stringArg(args, "folder")
                let limit = intArg(args, "limit") ?? 100
                let script = Scripts.list(folder: folder)
                switch runner(script) {
                case .failure(let message, let code):
                    return failureValue(message: message, code: code)
                case .ok(let raw):
                    let notes = parseNoteRecords(raw).prefix(max(0, limit))
                    let rows: [Value] = notes.map { rec in
                        .object([
                            "id": .string(rec.id),
                            "name": .string(rec.name),
                            "folder": .string(rec.folder),
                            "modified": .string(rec.modified)
                        ])
                    }
                    return .object(["notes": .array(rows), "count": .int(rows.count)])
                }
            }
        ))

        // MARK: 2. notes_read — open
        await router.register(ToolRegistration(
            name: "notes_read",
            module: moduleName,
            tier: .open,
            description: "Read one Apple Note's full content. Address it by `noteId` (stable AppleScript id) OR `noteName` (title; first case-insensitive match wins). Returns id, name, folder, plain-text body, and the note's HTML body.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "noteId": .object([
                        "type": .string("string"),
                        "description": .string("The note's AppleScript id (preferred — stable). Mutually exclusive with noteName.")
                    ]),
                    "noteName": .object([
                        "type": .string("string"),
                        "description": .string("The note's title. First case-insensitive match wins. Used when noteId is not provided.")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Notes: Read",
                whenToUse: ["fetching one note's body after notes_list / notes_search surfaced its id or name"],
                whenNotToUse: ["listing notes (use notes_list)", "searching across notes (use notes_search)"],
                relatedTools: ["notes_list", "notes_search", "notes_update"]
            ),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let selector = noteSelector(args) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notes_read",
                        reason: "provide either 'noteId' or 'noteName'"
                    )
                }
                let script = Scripts.read(selector: selector)
                switch runner(script) {
                case .failure(let message, let code):
                    return failureValue(message: message, code: code)
                case .ok(let raw):
                    let fields = raw.components(separatedBy: fieldSep)
                    guard fields.count >= 5, !raw.isEmpty else {
                        return .object([
                            "found": .bool(false),
                            "error": .string("No note matched the given \(selector.kindLabel).")
                        ])
                    }
                    return .object([
                        "found": .bool(true),
                        "id": .string(fields[0]),
                        "name": .string(fields[1]),
                        "folder": .string(fields[2]),
                        "body": .string(fields[3]),
                        "html": .string(fields[4])
                    ])
                }
            }
        ))

        // MARK: 3. notes_create — notify
        await router.register(ToolRegistration(
            name: "notes_create",
            module: moduleName,
            tier: .notify,
            description: "Create a new Apple Note. `title` becomes the first line (Notes derives the note name from it); `body` is the remaining plain-text content. Optionally place it in `folder` (must already exist; otherwise the default folder is used).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Note title — becomes the first line / note name.")
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Plain-text body content (optional).")
                    ]),
                    "folder": .object([
                        "type": .string("string"),
                        "description": .string("Optional target folder name (must already exist). Defaults to the account default folder.")
                    ])
                ]),
                "required": .array([.string("title")])
            ]),
            metadata: ToolMetadata(
                title: "Notes: Create",
                whenToUse: ["adding a new note with a title and optional body / target folder"],
                whenNotToUse: ["editing an existing note (use notes_update)"],
                relatedTools: ["notes_update", "notes_list"]
            ),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let title = stringArg(args, "title"), !title.isEmpty else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notes_create",
                        reason: "missing required 'title'"
                    )
                }
                let body = stringArg(args, "body") ?? ""
                let folder = stringArg(args, "folder")
                let script = Scripts.create(title: title, body: body, folder: folder)
                switch runner(script) {
                case .failure(let message, let code):
                    return failureValue(message: message, code: code)
                case .ok(let raw):
                    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .object([
                        "created": .bool(true),
                        "id": .string(id),
                        "name": .string(title)
                    ])
                }
            }
        ))

        // MARK: 4. notes_update — notify
        await router.register(ToolRegistration(
            name: "notes_update",
            module: moduleName,
            tier: .notify,
            description: "Update an existing Apple Note's body, addressed by `noteId` OR `noteName`. Replaces the note body with `body` (and an optional new `title` first line). This overwrites existing content — read first with notes_read if you need to preserve it.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "noteId": .object([
                        "type": .string("string"),
                        "description": .string("The note's AppleScript id (preferred). Mutually exclusive with noteName.")
                    ]),
                    "noteName": .object([
                        "type": .string("string"),
                        "description": .string("The note's title. First case-insensitive match wins. Used when noteId is not provided.")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Optional new title (first line). Omit to keep the existing title as the first body line.")
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("New plain-text body content. Overwrites the existing note body.")
                    ])
                ]),
                "required": .array([.string("body")])
            ]),
            metadata: ToolMetadata(
                title: "Notes: Update",
                whenToUse: ["replacing the body of an existing note found via notes_list / notes_search"],
                whenNotToUse: ["creating a new note (use notes_create)", "deleting a note (use notes_delete)"],
                relatedTools: ["notes_read", "notes_create", "notes_delete"]
            ),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let selector = noteSelector(args) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notes_update",
                        reason: "provide either 'noteId' or 'noteName' to identify the note"
                    )
                }
                guard let body = stringArg(args, "body") else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notes_update",
                        reason: "missing required 'body'"
                    )
                }
                let title = stringArg(args, "title")
                let script = Scripts.update(selector: selector, title: title, body: body)
                switch runner(script) {
                case .failure(let message, let code):
                    return failureValue(message: message, code: code)
                case .ok(let raw):
                    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if id.isEmpty {
                        return .object([
                            "updated": .bool(false),
                            "error": .string("No note matched the given \(selector.kindLabel).")
                        ])
                    }
                    return .object(["updated": .bool(true), "id": .string(id)])
                }
            }
        ))

        // MARK: 5. notes_delete — request
        await router.register(ToolRegistration(
            name: "notes_delete",
            module: moduleName,
            tier: .request,
            description: "Delete (move to the Notes trash) an Apple Note, addressed by `noteId` OR `noteName`. Requires confirm: 'DELETE' (exact, uppercase). This is irreversible from the API — recover only via the Notes trash UI.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "noteId": .object([
                        "type": .string("string"),
                        "description": .string("The note's AppleScript id (preferred). Mutually exclusive with noteName.")
                    ]),
                    "noteName": .object([
                        "type": .string("string"),
                        "description": .string("The note's title. First case-insensitive match wins. Used when noteId is not provided.")
                    ]),
                    "confirm": .object([
                        "type": .string("string"),
                        "description": .string("Must be exactly 'DELETE' to proceed.")
                    ])
                ]),
                "required": .array([.string("confirm")])
            ]),
            metadata: ToolMetadata(
                title: "Notes: Delete",
                whenToUse: ["removing a note you identified by id/name — pass confirm:'DELETE'"],
                whenNotToUse: ["editing a note (use notes_update)"],
                relatedTools: ["notes_list", "notes_read"]
            ),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let confirm = stringArg(args, "confirm") else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notes_delete",
                        reason: "missing required 'confirm'"
                    )
                }
                guard confirm == "DELETE" else {
                    return .object([
                        "deleted": .bool(false),
                        "error": .string("notes_delete requires confirm: 'DELETE'")
                    ])
                }
                guard let selector = noteSelector(args) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notes_delete",
                        reason: "provide either 'noteId' or 'noteName' to identify the note"
                    )
                }
                let script = Scripts.delete(selector: selector)
                switch runner(script) {
                case .failure(let message, let code):
                    return failureValue(message: message, code: code)
                case .ok(let raw):
                    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if id.isEmpty {
                        return .object([
                            "deleted": .bool(false),
                            "error": .string("No note matched the given \(selector.kindLabel).")
                        ])
                    }
                    return .object(["deleted": .bool(true), "id": .string(id)])
                }
            }
        ))

        // MARK: 6. notes_search — open
        await router.register(ToolRegistration(
            name: "notes_search",
            module: moduleName,
            tier: .open,
            description: "Keyword-search Apple Notes by title and body text (case-insensitive substring). Optionally scope to one `folder`. Returns matching note id + name + folder + modification date.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Keyword/substring to match against note title and body (case-insensitive).")
                    ]),
                    "folder": .object([
                        "type": .string("string"),
                        "description": .string("Optional folder name to scope the search.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max results to return (default: 50).")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            metadata: ToolMetadata(
                title: "Notes: Search",
                whenToUse: ["finding notes that contain a word/phrase across titles + bodies"],
                whenNotToUse: ["listing every note (use notes_list)", "reading one matched note's full body (use notes_read)"],
                relatedTools: ["notes_list", "notes_read"]
            ),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let query = stringArg(args, "query"), !query.isEmpty else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "notes_search",
                        reason: "missing required 'query'"
                    )
                }
                let folder = stringArg(args, "folder")
                let limit = intArg(args, "limit") ?? 50
                let script = Scripts.search(query: query, folder: folder)
                switch runner(script) {
                case .failure(let message, let code):
                    return failureValue(message: message, code: code)
                case .ok(let raw):
                    let notes = parseNoteRecords(raw).prefix(max(0, limit))
                    let rows: [Value] = notes.map { rec in
                        .object([
                            "id": .string(rec.id),
                            "name": .string(rec.name),
                            "folder": .string(rec.folder),
                            "modified": .string(rec.modified)
                        ])
                    }
                    return .object(["notes": .array(rows), "count": .int(rows.count)])
                }
            }
        ))
    }

    // MARK: - Argument helpers

    private static func objectArgs(_ arguments: Value) -> [String: Value] {
        if case .object(let dict) = arguments { return dict }
        return [:]
    }

    private static func stringArg(_ args: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = args[key] { return s }
        return nil
    }

    private static func intArg(_ args: [String: Value], _ key: String) -> Int? {
        if case .int(let i)? = args[key] { return i }
        return nil
    }

    /// Resolve a note selector from arguments. `noteId` wins over `noteName`.
    /// `public` for direct unit testing of the addressing precedence.
    public static func noteSelector(_ args: [String: Value]) -> NoteSelector? {
        if let id = stringArg(args, "noteId"), !id.isEmpty {
            return .id(id)
        }
        if let name = stringArg(args, "noteName"), !name.isEmpty {
            return .name(name)
        }
        return nil
    }

    /// Build the standard structured failure value, with TCC (-1743)
    /// guidance when the error is an Automation denial.
    static func failureValue(message: String, code: Int) -> Value {
        var obj: [String: Value] = [
            "error": .string(message),
            "errorNumber": .int(code)
        ]
        if code == -1743 {
            obj["tccDenied"] = .bool(true)
            obj["guidance"] = .string(
                "NotionBridge does not have Automation permission for Notes. "
                + "This is a macOS TCC restriction (first-use operator grant). "
                + "Open System Settings > Privacy & Security > Automation and grant "
                + "NotionBridge access to Notes, or open the NotionBridge permission panel."
            )
        }
        return .object(obj)
    }

    // MARK: - Output parsing

    /// One serialized note record from a list/search script.
    public struct NoteRecord: Equatable, Sendable {
        public let id: String
        public let name: String
        public let folder: String
        public let modified: String
        public init(id: String, name: String, folder: String, modified: String) {
            self.id = id
            self.name = name
            self.folder = folder
            self.modified = modified
        }
    }

    /// Parse `recordSep`-delimited records of `fieldSep`-delimited fields
    /// (id, name, folder, modified) emitted by the list/search scripts.
    /// Tolerant: short/blank records are skipped. `public` for unit testing.
    public static func parseNoteRecords(_ raw: String) -> [NoteRecord] {
        raw.components(separatedBy: recordSep).compactMap { chunk in
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let f = chunk.components(separatedBy: fieldSep)
            guard f.count >= 4 else { return nil }
            return NoteRecord(id: f[0], name: f[1], folder: f[2], modified: f[3])
        }
    }

    // MARK: - Note selector

    /// How a note is addressed.
    public enum NoteSelector: Sendable, Equatable {
        case id(String)
        case name(String)

        var kindLabel: String {
            switch self {
            case .id: return "noteId"
            case .name: return "noteName"
            }
        }
    }

    // MARK: - AppleScript builders

    /// Escape a Swift string for embedding inside an AppleScript double-
    /// quoted string literal. Backslash first, then the quote — order
    /// matters so an escaped quote's backslash is not double-escaped.
    /// `public` so the escaping contract is directly unit-tested.
    public static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// AppleScript source builders for each Notes operation. Each builder
    /// is pure (string in → string out) so tests can assert the generated
    /// script as well as drive the mock runner. The list/search scripts
    /// serialize with the module's `fieldSep`/`recordSep` control bytes so
    /// note content cannot collide with the framing.
    public enum Scripts {

        /// AppleScript literals for the separators (ASCII 31 / 30).
        static var fieldSepLiteral: String { "(ASCII character 31)" }
        static var recordSepLiteral: String { "(ASCII character 30)" }

        /// List notes (optionally scoped to `folder`), emitting
        /// id‹US›name‹US›folder‹US›modified records joined by RS.
        public static func list(folder: String?) -> String {
            let source: String
            if let folder = folder, !folder.isEmpty {
                source = "notes of folder \"\(escapeAS(folder))\""
            } else {
                source = "notes"
            }
            return """
            set fs to \(fieldSepLiteral)
            set rs to \(recordSepLiteral)
            set out to ""
            tell application "Notes"
                repeat with n in (\(source))
                    set noteFolder to ""
                    try
                        set noteFolder to name of container of n
                    end try
                    set out to out & (id of n) & fs & (name of n) & fs & noteFolder & fs & (modification date of n as string) & rs
                end repeat
            end tell
            return out
            """
        }

        /// Read one note (by id or name): emit
        /// id‹US›name‹US›folder‹US›plaintext‹US›html. Empty string if no match.
        public static func read(selector: NoteSelector) -> String {
            return """
            set fs to \(fieldSepLiteral)
            set out to ""
            tell application "Notes"
                \(resolveNoteClause(selector))
                if theNote is missing value then return ""
                set noteFolder to ""
                try
                    set noteFolder to name of container of theNote
                end try
                set out to (id of theNote) & fs & (name of theNote) & fs & noteFolder & fs & (plaintext of theNote) & fs & (body of theNote)
            end tell
            return out
            """
        }

        /// Create a note (optionally in `folder`); return the new note id.
        public static func create(title: String, body: String, folder: String?) -> String {
            // Notes derives the note name from the first line of the HTML
            // body; we compose <div>title</div><div>body</div>.
            let safeTitle = escapeAS(title)
            let safeBody = escapeAS(body)
            let htmlBody = "<div><b>\(safeTitle)</b></div><div>\(safeBody)</div>"
            if let folder = folder, !folder.isEmpty {
                return """
                tell application "Notes"
                    set theFolder to folder "\(escapeAS(folder))"
                    set theNote to make new note at theFolder with properties {body:"\(htmlBody)"}
                    return id of theNote
                end tell
                """
            }
            return """
            tell application "Notes"
                set theNote to make new note with properties {body:"\(htmlBody)"}
                return id of theNote
            end tell
            """
        }

        /// Update a note's body (by id or name); return the note id (empty
        /// string if no match).
        public static func update(selector: NoteSelector, title: String?, body: String) -> String {
            let safeBody = escapeAS(body)
            let htmlBody: String
            if let title = title, !title.isEmpty {
                htmlBody = "<div><b>\(escapeAS(title))</b></div><div>\(safeBody)</div>"
            } else {
                htmlBody = "<div>\(safeBody)</div>"
            }
            return """
            tell application "Notes"
                \(resolveNoteClause(selector))
                if theNote is missing value then return ""
                set body of theNote to "\(htmlBody)"
                return id of theNote
            end tell
            """
        }

        /// Delete a note (by id or name); return the deleted note id (empty
        /// string if no match).
        public static func delete(selector: NoteSelector) -> String {
            return """
            tell application "Notes"
                \(resolveNoteClause(selector))
                if theNote is missing value then return ""
                set theId to id of theNote
                delete theNote
                return theId
            end tell
            """
        }

        /// Search notes by case-insensitive substring over name + body,
        /// optionally scoped to `folder`. Same record framing as `list`.
        public static func search(query: String, folder: String?) -> String {
            let scope: String
            if let folder = folder, !folder.isEmpty {
                scope = "notes of folder \"\(escapeAS(folder))\""
            } else {
                scope = "notes"
            }
            let needle = escapeAS(query)
            return """
            set fs to \(fieldSepLiteral)
            set rs to \(recordSepLiteral)
            set out to ""
            set q to "\(needle)"
            tell application "Notes"
                repeat with n in (\(scope))
                    set hay to (name of n) & " " & (plaintext of n)
                    ignoring case
                        if hay contains q then
                            set noteFolder to ""
                            try
                                set noteFolder to name of container of n
                            end try
                            set out to out & (id of n) & fs & (name of n) & fs & noteFolder & fs & (modification date of n as string) & rs
                        end if
                    end ignoring
                end repeat
            end tell
            return out
            """
        }

        /// Shared AppleScript fragment that binds `theNote` to the addressed
        /// note (by id or first case-insensitive name match), or
        /// `missing value` if none matched.
        private static func resolveNoteClause(_ selector: NoteSelector) -> String {
            switch selector {
            case .id(let id):
                return """
                set theNote to missing value
                try
                    set theNote to note id "\(escapeAS(id))"
                end try
                """
            case .name(let name):
                return """
                set theNote to missing value
                set wanted to "\(escapeAS(name))"
                ignoring case
                    repeat with n in notes
                        if (name of n) is wanted then
                            set theNote to n
                            exit repeat
                        end if
                    end repeat
                end ignoring
                """
            }
        }
    }
}
