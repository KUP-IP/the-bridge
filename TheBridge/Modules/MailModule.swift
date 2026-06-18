// MailModule.swift – v3.7·H (PKT-961) Apple Mail Tools
// TheBridge · Modules
//
// Five tools: mail_list, mail_read, mail_search, mail_draft, mail_send.
// Apple Mail is AppleScript-scriptable (distinct from the Gmail connector).
// All Mail access flows through an INJECTABLE AppleScript seam
// (`MailModule.scriptRunner`) so the read/search/draft/send paths are unit-
// testable against a deterministic mock — no live Mail.app, no real send.
//
// SAFETY POSTURE — drafts by default; send requires confirm:
//   - mail_list / mail_read / mail_search → tier .open   (read-only, no prompt)
//   - mail_draft                          → tier .notify (creates an UNSENT draft)
//   - mail_send                           → tier .request AND requires an
//        explicit confirm token: confirm:'SEND' (exact, uppercase). The handler
//        REFUSES (sent:false, never invokes the send script) when the token is
//        absent or wrong. This mirrors MessagesModule.messages_send exactly.
//        mail_send NEVER auto-sends; the only path to a send is an explicit,
//        operator-confirmed call. mail_draft is the safe default for composing.
//
// TCC: Mail Automation is an operator first-use grant (the existing
// apple-events automation entitlement covers TheBridge; no entitlement
// change). The first live mail_* call triggers the macOS Automation consent
// prompt for Mail — flagged as an operator residual, not handled in code.

import Foundation
import MCP

// MARK: - AppleScript Seam

/// Result of running an AppleScript fragment: either the string the script
/// returned, or an error (message + AppleScript error number).
public enum MailScriptResult: Sendable, Equatable {
    case success(String)
    case failure(message: String, number: Int)
}

/// Injectable AppleScript execution seam. Production runs the script
/// in-process via `NSAppleScript` (same one-grant TCC model as
/// AppleScriptModule); tests inject a deterministic mock so no Mail.app is
/// touched and no mail is ever sent.
public protocol MailScriptRunner: Sendable {
    func run(_ script: String) -> MailScriptResult
}

/// Production runner: executes AppleScript in-process under The Bridge's
/// TCC grants (avoids the osascript child-process TCC re-prompt storm — see
/// AppleScriptModule).
public struct NSAppleScriptMailRunner: MailScriptRunner {
    public init() {}

    public func run(_ script: String) -> MailScriptResult {
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let number = error[NSAppleScript.errorNumber] as? Int ?? -1
            return .failure(message: message, number: number)
        }
        return .success(result?.stringValue ?? "")
    }
}

// MARK: - MailModule

/// Provides Apple Mail read / search / draft tools plus a GUARDED send.
/// Every tool routes through `scriptRunner` (the injectable seam) so the
/// behaviour is identical in production and under test fixtures.
public enum MailModule {

    public static let moduleName = "mail"

    /// Confirm token required by `mail_send`. Exact, uppercase — mirrors
    /// `messages_send`'s 'SEND'. Without it the send handler refuses.
    public static let sendConfirmToken = "SEND"

    /// Injectable AppleScript seam. Production uses `NSAppleScriptMailRunner`;
    /// tests swap in a mock. `nonisolated(unsafe)` mirrors MessagesModule's
    /// shared-static pattern — mutated only at registration / test setup, never
    /// concurrently during a single dispatch.
    nonisolated(unsafe) public static var scriptRunner: MailScriptRunner = NSAppleScriptMailRunner()

    // MARK: - AppleScript escaping

    /// Escape a string for safe interpolation inside an AppleScript double-
    /// quoted literal (backslash + double-quote). Same approach MessagesModule
    /// uses for messages_send recipient/body.
    static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Tool Registration

    /// Register all MailModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. mail_list – open
        await router.register(ToolRegistration(
            name: "mail_list",
            module: moduleName,
            tier: .open,
            description: "List recent messages from a Mail mailbox (default: Inbox). Read-only. Returns id, subject, sender, date, and read state per message.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name to list (default: 'Inbox')")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max messages to return (default: 20)")])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Mail: List Messages",
                whenToUse: ["triaging a mailbox — most recent messages with subject/sender/date",
                            "picking a message id to then read in full with mail_read"],
                whenNotToUse: ["reading one message body (use mail_read)",
                               "finding messages by keyword/sender across mailboxes (use mail_search)"],
                relatedTools: ["mail_read", "mail_search", "mail_draft"]
            ),
            handler: { arguments in
                let mailbox: String = {
                    if case .object(let args) = arguments, case .string(let m) = args["mailbox"], !m.isEmpty { return m }
                    return "Inbox"
                }()
                let limit: Int = {
                    if case .object(let args) = arguments, case .int(let l) = args["limit"] { return max(1, l) }
                    return 20
                }()
                // Build an AppleScript that emits one record per line:
                //   id|isRead|date|sender|subject  (fields are tab-joined; rows newline-joined)
                let script = """
                    tell application "Mail"
                        set theBox to mailbox "\(escape(mailbox))" of inbox
                        set outLines to {}
                        set msgs to messages of theBox
                        set n to count of msgs
                        if n > \(limit) then set n to \(limit)
                        repeat with i from 1 to n
                            set m to item i of msgs
                            set theLine to (id of m as string) & tab & (read status of m as string) & tab & (date received of m as string) & tab & (sender of m) & tab & (subject of m)
                            set end of outLines to theLine
                        end repeat
                        set AppleScript's text item delimiters to linefeed
                        set outText to outLines as string
                        set AppleScript's text item delimiters to ""
                        return outText
                    end tell
                    """
                return runListLike(script, mailbox: mailbox, limit: limit)
            }
        ))

        // MARK: 2. mail_read – open
        await router.register(ToolRegistration(
            name: "mail_read",
            module: moduleName,
            tier: .open,
            description: "Read a single Mail message by its id (full subject, sender, recipients, date, and plain-text body). Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "messageId": .object(["type": .string("string"), "description": .string("Mail message id (from mail_list / mail_search)")])
                ]),
                "required": .array([.string("messageId")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Read Message",
                whenToUse: ["pulling the full body + headers for a message id surfaced by mail_list or mail_search"],
                whenNotToUse: ["browsing a mailbox (use mail_list)",
                               "you have a keyword but not an id (use mail_search)"],
                relatedTools: ["mail_list", "mail_search"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let messageId) = args["messageId"], !messageId.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_read", reason: "missing 'messageId'")
                }
                let script = """
                    tell application "Mail"
                        set theMsg to first message of inbox whose id is "\(escape(messageId))"
                        set theBody to content of theMsg
                        return (subject of theMsg) & linefeed & (sender of theMsg) & linefeed & (date received of theMsg as string) & linefeed & "---" & linefeed & theBody
                    end tell
                    """
                switch scriptRunner.run(script) {
                case .success(let raw):
                    let parts = raw.components(separatedBy: "\n---\n")
                    let header = parts.first ?? raw
                    let body = parts.count > 1 ? parts[1] : ""
                    let headerLines = header.components(separatedBy: "\n")
                    return .object([
                        "messageId": .string(messageId),
                        "subject": .string(headerLines.indices.contains(0) ? headerLines[0] : ""),
                        "sender": .string(headerLines.indices.contains(1) ? headerLines[1] : ""),
                        "date": .string(headerLines.indices.contains(2) ? headerLines[2] : ""),
                        "body": .string(body)
                    ])
                case .failure(let message, let number):
                    return scriptError(message: message, number: number)
                }
            }
        ))

        // MARK: 3. mail_search – open
        await router.register(ToolRegistration(
            name: "mail_search",
            module: moduleName,
            tier: .open,
            description: "Search Mail message subjects (and optionally senders) for a keyword across the inbox. Read-only. Returns matching id/subject/sender/date rows.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Keyword to match against message subject (and sender)")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max results to return (default: 25)")])
                ]),
                "required": .array([.string("query")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Search",
                whenToUse: ["finding messages whose subject/sender contains a keyword before reading one with mail_read"],
                whenNotToUse: ["listing a whole mailbox in date order (use mail_list)",
                               "reading a specific message body (use mail_read)"],
                relatedTools: ["mail_list", "mail_read"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"], !query.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_search", reason: "missing 'query'")
                }
                let limit: Int = {
                    if case .int(let l) = args["limit"] { return max(1, l) }
                    return 25
                }()
                let q = escape(query)
                let script = """
                    tell application "Mail"
                        set outLines to {}
                        set hits to (messages of inbox whose subject contains "\(q)")
                        set n to count of hits
                        if n > \(limit) then set n to \(limit)
                        repeat with i from 1 to n
                            set m to item i of hits
                            set theLine to (id of m as string) & tab & (read status of m as string) & tab & (date received of m as string) & tab & (sender of m) & tab & (subject of m)
                            set end of outLines to theLine
                        end repeat
                        set AppleScript's text item delimiters to linefeed
                        set outText to outLines as string
                        set AppleScript's text item delimiters to ""
                        return outText
                    end tell
                    """
                return runListLike(script, mailbox: "Inbox", limit: limit)
            }
        ))

        // MARK: 4. mail_draft – notify (creates an UNSENT draft; never sends)
        await router.register(ToolRegistration(
            name: "mail_draft",
            module: moduleName,
            tier: .notify,
            description: "Create an UNSENT Mail draft (to / subject / body; optional cc). The draft is saved in Mail for the operator to review and send manually — this tool NEVER sends. Drafting is the safe default; sending requires the separate, confirm-gated mail_send.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "to": .object(["type": .string("string"), "description": .string("Recipient email address")]),
                    "subject": .object(["type": .string("string"), "description": .string("Subject line")]),
                    "body": .object(["type": .string("string"), "description": .string("Message body (plain text)")]),
                    "cc": .object(["type": .string("string"), "description": .string("Optional cc email address")])
                ]),
                "required": .array([.string("to"), .string("subject"), .string("body")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Create Draft",
                whenToUse: ["composing an email for the operator to review and send manually",
                            "the default, safe way to write mail — produces an unsent draft, never sends"],
                whenNotToUse: ["actually sending an already-approved message (use mail_send with confirm:'SEND')"],
                relatedTools: ["mail_send"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let to) = args["to"],
                      case .string(let subject) = args["subject"],
                      case .string(let body) = args["body"] else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_draft", reason: "missing required parameters (to, subject, body)")
                }
                let cc: String? = { if case .string(let c) = args["cc"], !c.isEmpty { return c }; return nil }()

                // Build a draft WITHOUT a send command. `visible:true` so the
                // operator sees it; the message is saved unsent.
                var script = """
                    tell application "Mail"
                        set newMsg to make new outgoing message with properties {subject:"\(escape(subject))", content:"\(escape(body))", visible:true}
                        tell newMsg
                            make new to recipient at end of to recipients with properties {address:"\(escape(to))"}
                    """
                if let cc = cc {
                    script += """

                            make new cc recipient at end of cc recipients with properties {address:"\(escape(cc))"}
                    """
                }
                script += """

                        end tell
                        save newMsg
                        return (id of newMsg as string)
                    end tell
                    """
                switch scriptRunner.run(script) {
                case .success(let draftId):
                    return .object([
                        "drafted": .bool(true),
                        "sent": .bool(false),
                        "draftId": .string(draftId),
                        "to": .string(to),
                        "subject": .string(subject),
                        "note": .string("Draft saved unsent. mail_draft never sends; use mail_send with confirm:'SEND' to deliver.")
                    ])
                case .failure(let message, let number):
                    return scriptError(message: message, number: number, extra: ["drafted": .bool(false), "sent": .bool(false)])
                }
            }
        ))

        // MARK: 5. mail_send – request + EXPLICIT confirm token (GUARDED)
        await router.register(ToolRegistration(
            name: "mail_send",
            module: moduleName,
            tier: .request,
            description: "Send an email via Mail. GUARDED: requires confirm:'SEND' (exact, uppercase) AND is tier .request (operator approval). NEVER auto-sends — without the confirm token the call is refused and nothing is sent. Prefer mail_draft (drafts by default); only call this for an explicitly approved send.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "to": .object(["type": .string("string"), "description": .string("Recipient email address")]),
                    "subject": .object(["type": .string("string"), "description": .string("Subject line")]),
                    "body": .object(["type": .string("string"), "description": .string("Message body (plain text)")]),
                    "cc": .object(["type": .string("string"), "description": .string("Optional cc email address")]),
                    "confirm": .object(["type": .string("string"), "description": .string("Must be exactly 'SEND' to proceed. Absent/wrong → refused, nothing sent.")])
                ]),
                "required": .array([.string("to"), .string("subject"), .string("body"), .string("confirm")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Send (guarded)",
                whenToUse: ["delivering an email the operator has explicitly approved — pass confirm:'SEND'"],
                whenNotToUse: ["composing/iterating on a message (use mail_draft — drafts by default)",
                               "any unapproved or speculative send (the confirm gate will refuse it)"],
                relatedTools: ["mail_draft"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let to) = args["to"],
                      case .string(let subject) = args["subject"],
                      case .string(let body) = args["body"],
                      case .string(let confirm) = args["confirm"] else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_send", reason: "missing required parameters (to, subject, body, confirm)")
                }

                // SEND-GUARD: refuse unless the exact confirm token is present.
                // This returns BEFORE any AppleScript is built or run, so an
                // unconfirmed call can never reach Mail.app.
                guard confirm == sendConfirmToken else {
                    return .object([
                        "sent": .bool(false),
                        "error": .string("mail_send requires confirm: '\(sendConfirmToken)' (exact, uppercase). Nothing was sent. To compose without sending, use mail_draft."),
                        "refused": .bool(true)
                    ])
                }

                let cc: String? = { if case .string(let c) = args["cc"], !c.isEmpty { return c }; return nil }()

                var script = """
                    tell application "Mail"
                        set newMsg to make new outgoing message with properties {subject:"\(escape(subject))", content:"\(escape(body))", visible:false}
                        tell newMsg
                            make new to recipient at end of to recipients with properties {address:"\(escape(to))"}
                    """
                if let cc = cc {
                    script += """

                            make new cc recipient at end of cc recipients with properties {address:"\(escape(cc))"}
                    """
                }
                script += """

                        end tell
                        send newMsg
                        return "sent"
                    end tell
                    """
                switch scriptRunner.run(script) {
                case .success:
                    return .object([
                        "sent": .bool(true),
                        "to": .string(to),
                        "subject": .string(subject),
                        "bodyLength": .int(body.utf8.count)
                    ])
                case .failure(let message, let number):
                    return scriptError(message: message, number: number, extra: ["sent": .bool(false)])
                }
            }
        ))
    }

    // MARK: - Helpers

    /// Run a list/search script and parse the tab/newline-delimited rows into
    /// structured MCP objects. Shared by mail_list and mail_search.
    private static func runListLike(_ script: String, mailbox: String, limit: Int) -> Value {
        switch scriptRunner.run(script) {
        case .success(let raw):
            let rows = parseRows(raw)
            return .object([
                "mailbox": .string(mailbox),
                "rows": .array(rows),
                "count": .int(rows.count)
            ])
        case .failure(let message, let number):
            return scriptError(message: message, number: number, extra: ["rows": .array([]), "count": .int(0)])
        }
    }

    /// Parse `id<tab>isRead<tab>date<tab>sender<tab>subject` rows (newline-
    /// separated) into MCP objects. Blank lines are skipped.
    static func parseRows(_ raw: String) -> [Value] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if l.isEmpty { return nil }
            let f = l.components(separatedBy: "\t")
            return .object([
                "id": .string(f.indices.contains(0) ? f[0] : ""),
                "read": .string(f.indices.contains(1) ? f[1] : ""),
                "date": .string(f.indices.contains(2) ? f[2] : ""),
                "sender": .string(f.indices.contains(3) ? f[3] : ""),
                "subject": .string(f.indices.contains(4) ? f[4] : "")
            ])
        }
    }

    /// Build a structured AppleScript-error result. `-1743` is the macOS TCC
    /// Automation denial (Mail not yet granted) — surfaced with guidance, the
    /// same actionable shape AppleScriptModule uses.
    private static func scriptError(message: String, number: Int, extra: [String: Value] = [:]) -> Value {
        var obj: [String: Value] = [
            "error": .string(message),
            "errorNumber": .int(number)
        ]
        if number == -1743 {
            obj["tccDenied"] = .bool(true)
            obj["guidance"] = .string(
                "The Bridge does not have Automation permission for Mail. "
                + "Grant it in System Settings > Privacy & Security > Automation "
                + "(Mail access is an operator first-use grant; no entitlement change required)."
            )
        }
        for (k, v) in extra { obj[k] = v }
        return .object(obj)
    }
}
