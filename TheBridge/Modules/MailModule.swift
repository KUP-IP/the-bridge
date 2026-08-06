// MailModule.swift – Apple Mail Tools (PKT-961 + inbox management)
// TheBridge · Modules
//
// Read/compose: mail_list, mail_read, mail_search, mail_draft, mail_send.
// Organize: mail_mailboxes, mail_triage, mail_move, mail_archive, mail_mark, mail_trash.
// All Mail access flows through an INJECTABLE AppleScript seam
// (`MailModule.scriptRunner`) so paths are unit-testable against a mock.
//
// SAFETY POSTURE:
//   - list/read/search/mailboxes/triage → .open
//   - draft / move / archive / mark      → .notify (reversible organize)
//   - send                               → .request + confirm:'SEND'
//   - trash                              → .request + confirm:'DELETE' + neverAutoApprove
// Mutations require messageIds (Mail AS id). Never target by subject/sender alone.
// Batch cap: 25 ids. dryRun previews with zero seam side effects.

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
/// in-process via `NSAppleScript`; tests inject a deterministic mock.
public protocol MailScriptRunner: Sendable {
    func run(_ script: String) -> MailScriptResult
}

/// Production runner: executes AppleScript in-process under The Bridge's TCC grants.
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

/// Apple Mail read / search / draft / send plus identity-safe inbox organize tools.
public enum MailModule {

    public static let moduleName = "mail"

    /// Confirm token required by `mail_send`. Exact, uppercase.
    public static let sendConfirmToken = "SEND"

    /// Confirm token required by `mail_trash`. Exact, uppercase — mirrors notes_delete.
    public static let trashConfirmToken = "DELETE"

    /// Confirm token required for batch `mail_archive` (messageIds.count > 1).
    public static let archiveConfirmToken = "ARCHIVE"

    /// Confirm token required for batch `mail_move` (messageIds.count > 1).
    public static let moveConfirmToken = "MOVE"

    /// Max messageIds accepted by batch organize/trash tools.
    public static let maxBatchIds = 25

    /// Injectable AppleScript seam.
    nonisolated(unsafe) public static var scriptRunner: MailScriptRunner = NSAppleScriptMailRunner()

    // MARK: - AppleScript escaping

    static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Identity helpers

    /// Parse and validate `messageIds` from tool arguments. Dedupes, refuses empty,
    /// enforces `maxBatchIds`. Throws `ToolRouterError.invalidArguments` on failure.
    static func parseMessageIds(_ arguments: Value, toolName: String) throws -> [String] {
        guard case .object(let args) = arguments else {
            throw ToolRouterError.invalidArguments(toolName: toolName, reason: "missing 'messageIds'")
        }
        guard case .array(let arr) = args["messageIds"] else {
            throw ToolRouterError.invalidArguments(toolName: toolName, reason: "missing 'messageIds' (array of Mail message ids)")
        }
        var seen = Set<String>()
        var ids: [String] = []
        for v in arr {
            guard case .string(let s) = v else {
                throw ToolRouterError.invalidArguments(toolName: toolName, reason: "messageIds must be strings (Mail AppleScript ids)")
            }
            let id = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        guard !ids.isEmpty else {
            throw ToolRouterError.invalidArguments(toolName: toolName, reason: "messageIds must contain at least one non-empty id")
        }
        guard ids.count <= maxBatchIds else {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "messageIds exceeds max batch of \(maxBatchIds) (got \(ids.count)); split the batch"
            )
        }
        return ids
    }

    static func optionalString(_ args: [String: Value], _ key: String) -> String? {
        if case .string(let s) = args[key], !s.isEmpty { return s }
        return nil
    }

    /// planOnly (preferred) or dryRun alias — plan only, does not resolve Mail.
    static func planOnlyFlag(_ args: [String: Value]) -> Bool {
        if case .bool(let b) = args["planOnly"] { return b }
        if case .bool(let b) = args["dryRun"] { return b }
        return false
    }

    /// Require a non-empty account for organize mutations (fail closed).
    static func requireAccount(_ args: [String: Value], toolName: String) throws -> String {
        guard let account = optionalString(args, "account") else {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "missing 'account' (required for organize mutations — use mail_mailboxes to discover account names)"
            )
        }
        return account
    }

    /// AppleScript fragment that binds `theMsg` for a single message id.
    /// Organize path: account + mailbox (default Inbox). Read path may omit account.
    /// Never by subject.
    static func resolveMessageLocator(messageId: String, mailbox: String?, account: String?) -> String {
        let mid = escape(messageId)
        let box = mailbox ?? "Inbox"
        if let account {
            return """
                        set theMsg to first message of mailbox "\(escape(box))" of account "\(escape(account))" whose id is "\(mid)"
                """
        }
        if let mailbox {
            return """
                        set theMsg to first message of mailbox "\(escape(mailbox))" of inbox whose id is "\(mid)"
                """
        }
        return """
                        set theMsg to first message of inbox whose id is "\(mid)"
            """
    }

    /// Destination mailbox under a named account (not `of inbox`).
    static func destinationLocator(mailbox: String, account: String) -> String {
        """
                        set destBox to mailbox "\(escape(mailbox))" of account "\(escape(account))"
            """
    }

    /// Batch (>1 unique messageId) archive/move must force SecurityGate `.request`
    /// + neverAutoApprove. Single-id stays at the tool's registered `.notify` tier.
    public static func forcesBatchHumanApproval(toolName: String, arguments: Value) -> Bool {
        guard toolName == "mail_archive" || toolName == "mail_move" else { return false }
        guard case .object(let args) = arguments, case .array(let arr) = args["messageIds"] else {
            return false
        }
        var seen = Set<String>()
        for v in arr {
            guard case .string(let s) = v else { continue }
            let id = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            seen.insert(id)
        }
        return seen.count > 1
    }

    /// Verify destination match: exact (case-insensitive) or Mail Archive↔All Mail aliases.
    public static func destinationMatches(foundIn: String, requested: String) -> Bool {
        if foundIn.caseInsensitiveCompare(requested) == .orderedSame { return true }
        let found = foundIn.lowercased()
        let want = requested.lowercased()
        let allMailAliases: Set<String> = ["all mail", "[gmail]/all mail", "[gmail]all mail"]
        if want == "archive" && allMailAliases.contains(found) { return true }
        if allMailAliases.contains(want) && found == "archive" { return true }
        return false
    }

    /// Refuse payload when a batch confirm token is missing/wrong (no seam).
    static func batchConfirmRefused(action: String, token: String) -> Value {
        .object([
            "ok": .bool(false),
            "action": .string(action),
            "refused": .bool(true),
            "mutated": .array([]),
            "error": .string("Batch \(action) (more than one messageId) requires confirm: '\(token)' (exact, uppercase). Nothing was changed."),
            "requested": .array([]),
            "succeeded": .array([]),
            "failed": .array([]),
            "verified": .array([]),
            "unverified": .array([]),
            "planOnly": .bool(false),
            "dryRun": .bool(false),
            "note": .string("Do not retry a mutate when refused — fix confirm or split to single-id calls.")
        ])
    }

    /// Script that returns `id\\tmailboxName\\tread\\tflagged` for a message.
    static func verifyScript(messageId: String, mailbox: String?, account: String?) -> String {
        """
        tell application "Mail"
        \(resolveMessageLocator(messageId: messageId, mailbox: mailbox, account: account))
            set mbName to name of mailbox of theMsg
            return (id of theMsg as string) & tab & mbName & tab & (read status of theMsg as string) & tab & (flagged status of theMsg as string)
        end tell
        """
    }

    // MARK: - Tool Registration

    public static func register(on router: ToolRouter) async {

        // MARK: 1. mail_list – open
        await router.register(ToolRegistration(
            name: "mail_list",
            module: moduleName,
            tier: .open,
            description: "List recent messages from a Mail mailbox (default: Inbox). Read-only. Returns id, subject, sender, date, read state, and mailbox per message. Use ids for organize tools — never mutate by subject alone.",
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
                            "picking message ids for mail_read / mail_triage / organize tools"],
                whenNotToUse: ["reading one message body (use mail_read)",
                               "advisory preserve/archive buckets (use mail_triage)",
                               "finding messages by keyword (use mail_search)"],
                relatedTools: ["mail_read", "mail_search", "mail_triage", "mail_archive"]
            ),
            handler: { arguments in
                let mailbox: String = {
                    if case .object(let args) = arguments, case .string(let m) = args["mailbox"], !m.isEmpty { return m }
                    return "Inbox"
                }()
                let limit: Int = {
                    if case .object(let args) = arguments, case .int(let l) = args["limit"] { return max(1, min(l, 200)) }
                    return 20
                }()
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
            description: "Read a single Mail message by its AppleScript id (subject, sender, date, plain-text body). Optional mailbox/account scopes resolution outside bare Inbox. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "messageId": .object(["type": .string("string"), "description": .string("Mail message id (from mail_list / mail_search / mail_triage)")]),
                    "mailbox": .object(["type": .string("string"), "description": .string("Optional mailbox name to scope id lookup")]),
                    "account": .object(["type": .string("string"), "description": .string("Optional account name (use with mailbox)")])
                ]),
                "required": .array([.string("messageId")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Read Message",
                whenToUse: ["pulling the full body for a message id before archive/trash decisions"],
                whenNotToUse: ["browsing a mailbox (use mail_list)",
                               "bulk advisory triage (use mail_triage)"],
                relatedTools: ["mail_list", "mail_search", "mail_triage"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let messageId) = args["messageId"], !messageId.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_read", reason: "missing 'messageId'")
                }
                let mailbox = optionalString(args, "mailbox")
                let account = optionalString(args, "account")
                let script = """
                    tell application "Mail"
                    \(resolveMessageLocator(messageId: messageId, mailbox: mailbox, account: account))
                        set theBody to content of theMsg
                        set mbName to name of mailbox of theMsg
                        return (subject of theMsg) & linefeed & (sender of theMsg) & linefeed & (date received of theMsg as string) & linefeed & mbName & linefeed & "---" & linefeed & theBody
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
                        "mailbox": .string(headerLines.indices.contains(3) ? headerLines[3] : (mailbox ?? "Inbox")),
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
            description: "Search Mail subjects or senders for a keyword in a mailbox (default Inbox). Read-only. Returns matching id rows — use those ids for mutations, never subject alone.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Keyword to match against message subject or sender")]),
                    "mailbox": .object(["type": .string("string"), "description": .string("Mailbox to search (default: Inbox)")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max results to return (default: 25)")])
                ]),
                "required": .array([.string("query")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Search",
                whenToUse: ["finding messages whose subject/sender contains a keyword before reading one with mail_read"],
                whenNotToUse: ["listing a whole mailbox in date order (use mail_list)",
                               "mutating messages (use mail_move/archive/trash with ids)"],
                relatedTools: ["mail_list", "mail_read", "mail_triage"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"], !query.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_search", reason: "missing 'query'")
                }
                let mailbox = optionalString(args, "mailbox") ?? "Inbox"
                let limit: Int = {
                    if case .int(let l) = args["limit"] { return max(1, min(l, 200)) }
                    return 25
                }()
                let q = escape(query)
                let script = """
                    tell application "Mail"
                        set theBox to mailbox "\(escape(mailbox))" of inbox
                        set outLines to {}
                        set hits to (messages of theBox whose subject contains "\(q)" or sender contains "\(q)")
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
                return runListLike(script, mailbox: mailbox, limit: limit)
            }
        ))

        // MARK: 4. mail_mailboxes – open
        await router.register(ToolRegistration(
            name: "mail_mailboxes",
            module: moduleName,
            tier: .open,
            description: "Enumerate Mail accounts and mailbox names/paths for use with mail_list / mail_move. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Mail: List Mailboxes",
                whenToUse: ["discovering destination mailbox names before mail_move",
                            "confirming Archive/Trash exist for organize workflows"],
                whenNotToUse: ["listing messages (use mail_list)",
                               "moving messages (use mail_move / mail_archive)"],
                relatedTools: ["mail_list", "mail_move", "mail_archive"]
            ),
            handler: { _ in
                let script = """
                    tell application "Mail"
                        set outLines to {}
                        repeat with acct in accounts
                            set acctName to name of acct
                            repeat with mbox in mailboxes of acct
                                set end of outLines to acctName & tab & (name of mbox)
                            end repeat
                        end repeat
                        set AppleScript's text item delimiters to linefeed
                        set outText to outLines as string
                        set AppleScript's text item delimiters to ""
                        return outText
                    end tell
                    """
                switch scriptRunner.run(script) {
                case .success(let raw):
                    return parseMailboxes(raw)
                case .failure(let message, let number):
                    return scriptError(message: message, number: number, extra: [
                        "accounts": .array([]),
                        "count": .int(0)
                    ])
                }
            }
        ))

        // MARK: 5. mail_triage – open (advisory, never mutates)
        await router.register(ToolRegistration(
            name: "mail_triage",
            module: moduleName,
            tier: .open,
            description: "Advisory inbox triage: scan a mailbox window and bucket messages into preserve / candidateArchive / needsReview using deterministic keyword and sender-domain signals. NEVER mutates Mail. Agents must confirm before organize/trash; use messageIds from the result, not subjects alone.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mailbox": .object(["type": .string("string"), "description": .string("Mailbox to scan (default: Inbox)")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max messages to triage (default: 50, max: 100)")])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Triage (advisory)",
                whenToUse: ["inbox-zero / cleanup passes — get preserve vs archive candidates with reasons",
                            "before calling mail_archive or mail_trash on a batch of ids"],
                whenNotToUse: ["actually moving or deleting mail (use mail_archive / mail_move / mail_trash)",
                               "full body analysis of one message (use mail_read)"],
                relatedTools: ["mail_list", "mail_read", "mail_archive", "mail_trash"]
            ),
            handler: { arguments in
                let mailbox: String = {
                    if case .object(let args) = arguments, case .string(let m) = args["mailbox"], !m.isEmpty { return m }
                    return "Inbox"
                }()
                let limit: Int = {
                    if case .object(let args) = arguments, case .int(let l) = args["limit"] {
                        return max(1, min(l, 100))
                    }
                    return 50
                }()
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
                switch scriptRunner.run(script) {
                case .success(let raw):
                    let fieldRows = parseRowFields(raw)
                    let classified = MailTriageSignals.classifyRows(fieldRows)
                    var preserve: [Value] = []
                    var candidateArchive: [Value] = []
                    var needsReview: [Value] = []
                    for row in classified {
                        let v = triageRowValue(row)
                        switch row.recommendation {
                        case .preserve: preserve.append(v)
                        case .candidateArchive: candidateArchive.append(v)
                        case .needsReview: needsReview.append(v)
                        }
                    }
                    return .object([
                        "mailbox": .string(mailbox),
                        "advisory": .bool(true),
                        "note": .string("Triage is advisory only — confirm before mail_archive / mail_trash. Target by messageId."),
                        "preserve": .array(preserve),
                        "candidateArchive": .array(candidateArchive),
                        "needsReview": .array(needsReview),
                        "count": .int(classified.count)
                    ])
                case .failure(let message, let number):
                    return scriptError(message: message, number: number, extra: [
                        "preserve": .array([]),
                        "candidateArchive": .array([]),
                        "needsReview": .array([]),
                        "count": .int(0)
                    ])
                }
            }
        ))

        // MARK: 6. mail_draft – notify
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
                whenNotToUse: ["actually sending an already-approved message (use mail_send with confirm:'SEND')",
                               "organizing the inbox (use mail_archive / mail_move)"],
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

        // MARK: 7. mail_move – notify (batch requires confirm:'MOVE')
        await router.register(ToolRegistration(
            name: "mail_move",
            module: moduleName,
            tier: .notify,
            description: "Move Mail messages by AppleScript id. Requires account + destinationMailbox + messageIds (max 25). Single-id is Notify-tier; batch (>1 id) forces Request + neverAutoApprove (human modal) and confirm:'MOVE'. planOnly/dryRun is plan-only. Prefer mail_archive for standard cleanup.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "messageIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Mail AppleScript message ids (required; max 25)")
                    ]),
                    "account": .object(["type": .string("string"), "description": .string("Mail account name (required — from mail_mailboxes)")]),
                    "destinationMailbox": .object(["type": .string("string"), "description": .string("Destination mailbox name under account")]),
                    "sourceMailbox": .object(["type": .string("string"), "description": .string("Source mailbox to scope id lookup (default: Inbox)")]),
                    "confirm": .object(["type": .string("string"), "description": .string("Required when messageIds.count > 1: exactly 'MOVE'")]),
                    "planOnly": .object(["type": .string("boolean"), "description": .string("If true, plan only — no AppleScript side effects (alias of dryRun)")]),
                    "dryRun": .object(["type": .string("boolean"), "description": .string("Alias of planOnly — plan only, does not resolve existence")])
                ]),
                "required": .array([.string("messageIds"), .string("account"), .string("destinationMailbox")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Move Messages",
                whenToUse: ["relocating messages to a named mailbox by id after triage",
                            "plan-only a batch move before applying (pass confirm:'MOVE' for batches)"],
                whenNotToUse: ["standard Archive cleanup (prefer mail_archive)",
                               "trashing (use mail_trash with confirm:'DELETE')",
                               "matching by subject alone (refused — need messageIds)"],
                relatedTools: ["mail_archive", "mail_mailboxes", "mail_triage", "mail_trash"]
            ),
            handler: { arguments in
                let ids = try parseMessageIds(arguments, toolName: "mail_move")
                guard case .object(let args) = arguments,
                      case .string(let dest) = args["destinationMailbox"], !dest.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_move", reason: "missing 'destinationMailbox'")
                }
                let account = try requireAccount(args, toolName: "mail_move")
                if ids.count > 1 {
                    let confirm = optionalString(args, "confirm")
                    guard confirm == moveConfirmToken else {
                        return batchConfirmRefused(action: "move", token: moveConfirmToken)
                    }
                }
                return performOrganize(
                    action: "move",
                    ids: ids,
                    destinationMailbox: dest,
                    sourceMailbox: optionalString(args, "sourceMailbox") ?? "Inbox",
                    account: account,
                    planOnly: planOnlyFlag(args),
                    mode: .move
                )
            }
        ))

        // MARK: 8. mail_archive – notify (batch requires confirm:'ARCHIVE')
        await router.register(ToolRegistration(
            name: "mail_archive",
            module: moduleName,
            tier: .notify,
            description: "Archive Mail messages by id into account's Archive mailbox (Gmail may surface as All Mail). Requires account + messageIds (max 25). Single-id is Notify-tier; batch (>1 id) forces Request + neverAutoApprove (human modal) and confirm:'ARCHIVE'. planOnly/dryRun is plan-only. Triage candidateArchive is advisory — not mutate authority.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "messageIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Mail AppleScript message ids (required; max 25)")
                    ]),
                    "account": .object(["type": .string("string"), "description": .string("Mail account name (required — from mail_mailboxes)")]),
                    "sourceMailbox": .object(["type": .string("string"), "description": .string("Source mailbox to scope id lookup (default: Inbox)")]),
                    "confirm": .object(["type": .string("string"), "description": .string("Required when messageIds.count > 1: exactly 'ARCHIVE'")]),
                    "planOnly": .object(["type": .string("boolean"), "description": .string("If true, plan only — no AppleScript side effects")]),
                    "dryRun": .object(["type": .string("boolean"), "description": .string("Alias of planOnly")])
                ]),
                "required": .array([.string("messageIds"), .string("account")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Archive Messages",
                whenToUse: ["reversible cleanup after human/agent review of triage candidates",
                            "plan-only archive of a bounded id batch (confirm:'ARCHIVE' when >1 id)"],
                whenNotToUse: ["treating mail_triage candidateArchive as automatic mutate authority",
                               "moving to a custom mailbox (use mail_move)",
                               "deleting to Trash (use mail_trash)",
                               "acting on subject/sender without ids"],
                relatedTools: ["mail_triage", "mail_move", "mail_trash", "mail_list", "mail_mailboxes"]
            ),
            handler: { arguments in
                let ids = try parseMessageIds(arguments, toolName: "mail_archive")
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_archive", reason: "invalid arguments")
                }
                let account = try requireAccount(args, toolName: "mail_archive")
                if ids.count > 1 {
                    let confirm = optionalString(args, "confirm")
                    guard confirm == archiveConfirmToken else {
                        return batchConfirmRefused(action: "archive", token: archiveConfirmToken)
                    }
                }
                return performOrganize(
                    action: "archive",
                    ids: ids,
                    destinationMailbox: "Archive",
                    sourceMailbox: optionalString(args, "sourceMailbox") ?? "Inbox",
                    account: account,
                    planOnly: planOnlyFlag(args),
                    mode: .move
                )
            }
        ))

        // MARK: 9. mail_mark – notify
        await router.register(ToolRegistration(
            name: "mail_mark",
            module: moduleName,
            tier: .notify,
            description: "Set read and/or flagged status on Mail messages by id. Requires account + messageIds (max 25) and at least one of read/flagged. planOnly/dryRun is plan-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "messageIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Mail AppleScript message ids (required; max 25)")
                    ]),
                    "account": .object(["type": .string("string"), "description": .string("Mail account name (required)")]),
                    "read": .object(["type": .string("boolean"), "description": .string("Set read status")]),
                    "flagged": .object(["type": .string("boolean"), "description": .string("Set flagged status")]),
                    "sourceMailbox": .object(["type": .string("string"), "description": .string("Mailbox to scope id lookup (default: Inbox)")]),
                    "planOnly": .object(["type": .string("boolean"), "description": .string("If true, plan only — no AppleScript side effects")]),
                    "dryRun": .object(["type": .string("boolean"), "description": .string("Alias of planOnly")])
                ]),
                "required": .array([.string("messageIds"), .string("account")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Mark Read/Flagged",
                whenToUse: ["marking a batch read after triage",
                            "flagging messages that need follow-up"],
                whenNotToUse: ["moving/archiving (use mail_move / mail_archive)",
                               "trashing (use mail_trash)"],
                relatedTools: ["mail_list", "mail_triage", "mail_archive"]
            ),
            handler: { arguments in
                let ids = try parseMessageIds(arguments, toolName: "mail_mark")
                guard case .object(let args) = arguments else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_mark", reason: "invalid arguments")
                }
                let account = try requireAccount(args, toolName: "mail_mark")
                let read: Bool? = { if case .bool(let b) = args["read"] { return b }; return nil }()
                let flagged: Bool? = { if case .bool(let b) = args["flagged"] { return b }; return nil }()
                guard read != nil || flagged != nil else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_mark", reason: "provide at least one of 'read' or 'flagged'")
                }
                return performOrganize(
                    action: "mark",
                    ids: ids,
                    destinationMailbox: nil,
                    sourceMailbox: optionalString(args, "sourceMailbox") ?? "Inbox",
                    account: account,
                    planOnly: planOnlyFlag(args),
                    mode: .mark(read: read, flagged: flagged)
                )
            }
        ))

        // MARK: 10. mail_trash – request + DELETE confirm + neverAutoApprove
        await router.register(ToolRegistration(
            name: "mail_trash",
            module: moduleName,
            tier: .request,
            neverAutoApprove: true,
            description: "Move Mail messages to Trash by id. GUARDED: confirm:'DELETE' + .request + neverAutoApprove. Requires account. Does NOT empty Trash. planOnly/dryRun is plan-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "messageIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Mail AppleScript message ids (required; max 25)")
                    ]),
                    "account": .object(["type": .string("string"), "description": .string("Mail account name (required)")]),
                    "sourceMailbox": .object(["type": .string("string"), "description": .string("Source mailbox to scope id lookup (default: Inbox)")]),
                    "planOnly": .object(["type": .string("boolean"), "description": .string("If true, plan only — no AppleScript side effects (still requires confirm:'DELETE')")]),
                    "dryRun": .object(["type": .string("boolean"), "description": .string("Alias of planOnly")]),
                    "confirm": .object(["type": .string("string"), "description": .string("Must be exactly 'DELETE' to proceed")])
                ]),
                "required": .array([.string("messageIds"), .string("account"), .string("confirm")])
            ]),
            metadata: ToolMetadata(
                title: "Mail: Trash (guarded)",
                whenToUse: ["moving confirmed-safe junk to Trash by id — pass confirm:'DELETE'",
                            "plan-only trash of a bounded batch after triage"],
                whenNotToUse: ["reversible cleanup (prefer mail_archive)",
                               "emptying Trash / permanent purge (not supported)",
                               "any unconfirmed speculative delete"],
                relatedTools: ["mail_archive", "mail_triage", "mail_move"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let confirm) = args["confirm"] else {
                    throw ToolRouterError.invalidArguments(toolName: "mail_trash", reason: "missing required parameters (messageIds, account, confirm)")
                }
                guard confirm == trashConfirmToken else {
                    return .object([
                        "ok": .bool(false),
                        "action": .string("trash"),
                        "refused": .bool(true),
                        "mutated": .array([]),
                        "error": .string("mail_trash requires confirm: '\(trashConfirmToken)' (exact, uppercase). Nothing was changed. Prefer mail_archive for reversible cleanup."),
                        "requested": .array([]),
                        "succeeded": .array([]),
                        "failed": .array([]),
                        "verified": .array([]),
                        "unverified": .array([]),
                        "planOnly": .bool(false),
                        "dryRun": .bool(false)
                    ])
                }
                let account = try requireAccount(args, toolName: "mail_trash")
                let ids = try parseMessageIds(arguments, toolName: "mail_trash")
                return performOrganize(
                    action: "trash",
                    ids: ids,
                    destinationMailbox: "Trash",
                    sourceMailbox: optionalString(args, "sourceMailbox") ?? "Inbox",
                    account: account,
                    planOnly: planOnlyFlag(args),
                    mode: .trash
                )
            }
        ))

        // MARK: 11. mail_send – request + SEND confirm
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
                               "organizing the inbox (use mail_archive / mail_move / mail_trash)",
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

    // MARK: - Organize engine

    private enum OrganizeMode {
        case move
        case trash
        case mark(read: Bool?, flagged: Bool?)
    }

    private static func performOrganize(
        action: String,
        ids: [String],
        destinationMailbox: String?,
        sourceMailbox: String?,
        account: String?,
        planOnly: Bool,
        mode: OrganizeMode
    ) -> Value {
        let dest = destinationMailbox ?? ""
        let planned: [Value] = ids.map { id in
            var obj: [String: Value] = [
                "messageId": .string(id),
                "account": .string(account ?? "")
            ]
            if let sourceMailbox { obj["from"] = .string(sourceMailbox) }
            switch mode {
            case .move, .trash:
                obj["to"] = .string(dest)
            case .mark(let read, let flagged):
                if let read { obj["read"] = .bool(read) }
                if let flagged { obj["flagged"] = .bool(flagged) }
            }
            return .object(obj)
        }

        if planOnly {
            return .object([
                "ok": .bool(true),
                "action": .string(action),
                "planOnly": .bool(true),
                "dryRun": .bool(true),
                "mutated": .array([]),
                "requested": .array(ids.map { .string($0) }),
                "planned": .array(planned),
                "succeeded": .array([]),
                "failed": .array([]),
                "verified": .array([]),
                "unverified": .array([]),
                "note": .string("planOnly does not resolve message/mailbox existence in Mail — it only echoes intent.")
            ])
        }

        guard let account else {
            return .object([
                "ok": .bool(false),
                "action": .string(action),
                "error": .string("account is required"),
                "mutated": .array([]),
                "requested": .array(ids.map { .string($0) }),
                "succeeded": .array([]),
                "failed": .array([]),
                "verified": .array([]),
                "unverified": .array([]),
                "planOnly": .bool(false),
                "dryRun": .bool(false)
            ])
        }

        var mutated: [Value] = []
        var succeeded: [Value] = []
        var failed: [Value] = []
        var verified: [Value] = []
        var unverified: [Value] = []

        for id in ids {
            let mutateScript: String
            switch mode {
            case .move:
                mutateScript = """
                    tell application "Mail"
                    \(resolveMessageLocator(messageId: id, mailbox: sourceMailbox, account: account))
                        set srcName to name of mailbox of theMsg
                    \(destinationLocator(mailbox: dest, account: account))
                        move theMsg to destBox
                        return "OK" & tab & "\(escape(id))" & tab & srcName & tab & "\(escape(dest))"
                    end tell
                    """
            case .trash:
                mutateScript = """
                    tell application "Mail"
                    \(resolveMessageLocator(messageId: id, mailbox: sourceMailbox, account: account))
                        set srcName to name of mailbox of theMsg
                        delete theMsg
                        return "OK" & tab & "\(escape(id))" & tab & srcName & tab & "Trash"
                    end tell
                    """
            case .mark(let read, let flagged):
                var sets = ""
                if let read {
                    sets += "\n                        set read status of theMsg to \(read ? "true" : "false")"
                }
                if let flagged {
                    sets += "\n                        set flagged status of theMsg to \(flagged ? "true" : "false")"
                }
                mutateScript = """
                    tell application "Mail"
                    \(resolveMessageLocator(messageId: id, mailbox: sourceMailbox, account: account))
                        set srcName to name of mailbox of theMsg\(sets)
                        return "OK" & tab & "\(escape(id))" & tab & srcName & tab & srcName & tab & (read status of theMsg as string) & tab & (flagged status of theMsg as string)
                    end tell
                    """
            }

            switch scriptRunner.run(mutateScript) {
            case .success(let raw):
                let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\t")
                if fields.first == "OK" {
                    let from = fields.indices.contains(2) ? fields[2] : (sourceMailbox ?? "")
                    let to = fields.indices.contains(3) ? fields[3] : dest
                    let mutateRow: Value = .object([
                        "messageId": .string(id),
                        "from": .string(from),
                        "to": .string(to),
                        "mutated": .bool(true)
                    ])
                    mutated.append(mutateRow)
                    // succeeded is verify-confirmed only (not aliased to mutated).

                    // Verify is independent of mutate — miss must NOT look like "retry mutate".
                    let verifyMailbox: String? = {
                        switch mode {
                        case .move: return dest
                        case .trash: return dest // Trash / Deleted Messages
                        case .mark: return sourceMailbox
                        }
                    }()
                    let vScript = verifyScript(messageId: id, mailbox: verifyMailbox, account: account)
                    switch scriptRunner.run(vScript) {
                    case .success(let vraw):
                        let vf = vraw.trimmingCharacters(in: .whitespacesAndNewlines)
                            .components(separatedBy: "\t")
                        let foundIn = vf.indices.contains(1) ? vf[1] : ""
                        let readStatus = vf.indices.contains(2) ? vf[2] : ""
                        let flaggedStatus = vf.indices.contains(3) ? vf[3] : ""
                        let verifyOk: Bool
                        switch mode {
                        case .move:
                            verifyOk = destinationMatches(foundIn: foundIn, requested: dest)
                        case .trash:
                            let lower = foundIn.lowercased()
                            verifyOk = lower.contains("trash") || lower.contains("deleted")
                        case .mark(let wantRead, let wantFlagged):
                            var markOk = true
                            if let wantRead {
                                markOk = markOk && ((readStatus.lowercased() == "true") == wantRead)
                            }
                            if let wantFlagged {
                                markOk = markOk && ((flaggedStatus.lowercased() == "true") == wantFlagged)
                            }
                            verifyOk = markOk
                        }
                        verified.append(.object([
                            "messageId": .string(id),
                            "foundIn": .string(foundIn),
                            "read": .string(readStatus),
                            "flagged": .string(flaggedStatus),
                            "status": .string(verifyOk ? "verified" : "partial_or_unverified")
                        ]))
                        if verifyOk {
                            succeeded.append(mutateRow)
                        } else {
                            unverified.append(.object([
                                "messageId": .string(id),
                                "status": .string("partial_or_unverified"),
                                "note": .string("Mutated already — do not retry mutate; reconcile or inspect in Mail.")
                            ]))
                        }
                    case .failure(let message, _):
                        // Trash often leaves the message unfindable via the old locator — still mutated.
                        if case .trash = mode {
                            verified.append(.object([
                                "messageId": .string(id),
                                "foundIn": .string("Trash"),
                                "status": .string("assumed_after_delete"),
                                "note": .string("Delete returned OK; post-delete resolve failed (\(message)). Treat as mutated; do not retry.")
                            ]))
                            succeeded.append(mutateRow)
                        } else {
                            unverified.append(.object([
                                "messageId": .string(id),
                                "error": .string(message),
                                "status": .string("partial_or_unverified"),
                                "note": .string("Mutated already — do not retry mutate; reconcile or inspect in Mail.")
                            ]))
                        }
                    }
                } else {
                    failed.append(.object([
                        "messageId": .string(id),
                        "error": .string(raw.isEmpty ? "unexpected mutate result" : raw),
                        "mutated": .bool(false)
                    ]))
                }
            case .failure(let message, let number):
                failed.append(.object([
                    "messageId": .string(id),
                    "error": .string(message),
                    "errorNumber": .int(number),
                    "mutated": .bool(false)
                ]))
            }
        }

        let mutateOk = failed.isEmpty && mutated.count == ids.count
        let verifyOk = unverified.isEmpty
        return .object([
            "ok": .bool(mutateOk && verifyOk),
            "action": .string(action),
            "planOnly": .bool(false),
            "dryRun": .bool(false),
            "mutated": .array(mutated),
            "requested": .array(ids.map { .string($0) }),
            "succeeded": .array(succeeded),
            "failed": .array(failed),
            "verified": .array(verified),
            "unverified": .array(unverified),
            "note": .string(verifyOk
                ? "Mutate and verify agree."
                : "Some items mutated but verify disagreed — do not retry mutate on those ids.")
        ])
    }

    // MARK: - Parse helpers

    private static func runListLike(_ script: String, mailbox: String, limit: Int) -> Value {
        switch scriptRunner.run(script) {
        case .success(let raw):
            let rows = parseRows(raw, mailbox: mailbox)
            return .object([
                "mailbox": .string(mailbox),
                "rows": .array(rows),
                "count": .int(rows.count)
            ])
        case .failure(let message, let number):
            return scriptError(message: message, number: number, extra: ["rows": .array([]), "count": .int(0)])
        }
    }

    /// Parse `id<tab>isRead<tab>date<tab>sender<tab>subject` rows into MCP objects.
    static func parseRows(_ raw: String, mailbox: String? = nil) -> [Value] {
        parseRowFields(raw).map { f in
            var obj: [String: Value] = [
                "id": .string(f["id"] ?? ""),
                "read": .string(f["read"] ?? ""),
                "date": .string(f["date"] ?? ""),
                "sender": .string(f["sender"] ?? ""),
                "subject": .string(f["subject"] ?? "")
            ]
            if let mailbox {
                obj["mailbox"] = .string(mailbox)
            }
            return .object(obj)
        }
    }

    static func parseRowFields(_ raw: String) -> [[String: String]] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if l.isEmpty { return nil }
            let f = l.components(separatedBy: "\t")
            return [
                "id": f.indices.contains(0) ? f[0] : "",
                "read": f.indices.contains(1) ? f[1] : "",
                "date": f.indices.contains(2) ? f[2] : "",
                "sender": f.indices.contains(3) ? f[3] : "",
                "subject": f.indices.contains(4) ? f[4] : ""
            ]
        }
    }

    static func parseMailboxes(_ raw: String) -> Value {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var byAccount: [String: [Value]] = [:]
        var order: [String] = []
        if !trimmed.isEmpty {
            for line in trimmed.components(separatedBy: "\n") {
                let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if l.isEmpty { continue }
                let f = l.components(separatedBy: "\t")
                let acct = f.indices.contains(0) ? f[0] : ""
                let name = f.indices.contains(1) ? f[1] : ""
                if byAccount[acct] == nil {
                    byAccount[acct] = []
                    order.append(acct)
                }
                byAccount[acct]?.append(.object([
                    "name": .string(name),
                    "path": .string("\(acct)/\(name)")
                ]))
            }
        }
        let accounts: [Value] = order.map { acct in
            .object([
                "name": .string(acct),
                "mailboxes": .array(byAccount[acct] ?? [])
            ])
        }
        let total = accounts.reduce(0) { sum, v in
            guard case .object(let o) = v, case .array(let m) = o["mailboxes"] else { return sum }
            return sum + m.count
        }
        return .object([
            "accounts": .array(accounts),
            "count": .int(total)
        ])
    }

    private static func triageRowValue(_ row: MailTriageRow) -> Value {
        .object([
            "messageId": .string(row.messageId),
            "subject": .string(row.subject),
            "sender": .string(row.sender),
            "date": .string(row.date),
            "read": .string(row.read),
            "reasons": .array(row.reasons.map { .string($0) }),
            "recommendation": .string(row.recommendation.rawValue)
        ])
    }

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
