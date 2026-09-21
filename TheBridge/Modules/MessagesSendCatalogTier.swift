import Foundation
import MCP

/// Payload-aware catalog default for `messages_send` (#298).
///
/// Discriminator (fail-closed to `.request` unless every clause holds):
/// 1. **Single 1:1 handle/chat** — exactly one of `recipient` or
///    `chatIdentifier`, and that value is a phone, email, or a
///    service-prefixed 1:1 chat id (`iMessage;-;<handle>` / `SMS;-;<handle>`).
///    Raw `chatNNNN` group ids, UUID-style chat ids, and dual-target
///    payloads stay `.request`.
/// 2. **Plain text** — non-empty `body` and no non-empty `filePath`
///    (attachments / media stay `.request`).
/// 3. **No SMS-override / conscious override** —
///    `allowSmsDespiteLiveService` is not `true` (that flag stays `.request`).
///
/// Ordinary 1:1 SMS/iMessage text therefore defaults to **notify** (loud,
/// non-blocking; Always Allow still available). Settings per-tool /
/// per-module overrides still win via `ToolRouter.resolveEffectiveTier`.
///
/// This is Bridge catalog / Confirm-tier only. It does **not** clear or
/// change host Auto-review (#294).
public enum MessagesSendCatalogTier: Sendable {
    public static let toolName = "messages_send"

    /// Static registration / Settings-pill default: the ordinary 1:1
    /// plain-text path. Elevated paths raise to `.request` at dispatch.
    public static let registeredToolTier: SecurityTier = .notify

    /// Catalog default for this invocation. Used as `registeredTier` before
    /// Settings overrides. Unknown tools return `.request` (fail closed).
    public static func registeredDefault(toolName: String, arguments: Value) -> SecurityTier {
        guard toolName == Self.toolName else { return .request }
        return isOrdinaryOneToOnePlainText(arguments) ? .notify : .request
    }

    /// Mail-style raise: groups / attachments / SMS-override force Request
    /// as the registered default for that call. Overrides still win.
    public static func forcesRequestHumanApproval(toolName: String, arguments: Value) -> Bool {
        guard toolName == Self.toolName else { return false }
        return registeredDefault(toolName: toolName, arguments: arguments) == .request
    }

    /// True only for a single 1:1 handle/chat with a plain-text body and
    /// no SMS-override flag. Fail-closed: anything we cannot prove is
    /// ordinary 1:1 text stays Request.
    public static func isOrdinaryOneToOnePlainText(_ arguments: Value) -> Bool {
        guard case .object(let args) = arguments else { return false }
        if hasAttachment(args) { return false }
        if hasSmsOverride(args) { return false }
        guard hasPlainTextBody(args) else { return false }
        return oneToOneTarget(args) != nil
    }

    // MARK: - Payload clauses

    private static func hasAttachment(_ args: [String: Value]) -> Bool {
        !string(args, "filePath").isEmpty
    }

    private static func hasPlainTextBody(_ args: [String: Value]) -> Bool {
        !string(args, "body").isEmpty
    }

    /// Conscious SMS override (#249 / #298). Only the live bool `true`
    /// matches the handler; other shapes do not unlock the override path.
    private static func hasSmsOverride(_ args: [String: Value]) -> Bool {
        if case .bool(true)? = args["allowSmsDespiteLiveService"] { return true }
        return false
    }

    /// Exactly one target key, and it must be a 1:1 handle/chat. Dual
    /// recipient+chatIdentifier is fail-closed (the handler prefers
    /// chatIdentifier, which may be a group).
    private static func oneToOneTarget(_ args: [String: Value]) -> String? {
        let recipient = string(args, "recipient")
        let chatIdentifier = string(args, "chatIdentifier")
        let hasRecipient = !recipient.isEmpty
        let hasChat = !chatIdentifier.isEmpty
        guard hasRecipient != hasChat else { return nil }
        let raw = hasRecipient ? recipient : chatIdentifier
        return isOneToOneHandleOrChat(raw) ? raw : nil
    }

    // MARK: - 1:1 vs group

    /// Phone, email, or `iMessage|SMS;-;<phone-or-email>`. Raw `chatNNNN`
    /// and any other identifier are treated as group / unknown → not 1:1.
    public static func isOneToOneHandleOrChat(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isRawGroupChatIdentifier(trimmed) { return false }
        if let handle = servicePrefixedOneToOneHandle(trimmed) {
            return isPhoneHandle(handle) || isEmailHandle(handle)
        }
        return isPhoneHandle(trimmed) || isEmailHandle(trimmed)
    }

    /// Apple group chat ids (`chat123456789`). Same ghost-thread guard
    /// the send handler uses for `recipient`.
    public static func isRawGroupChatIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("chat") else { return false }
        let digits = trimmed.dropFirst(4)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func servicePrefixedOneToOneHandle(_ value: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "-" else { return nil }
        switch parts[0].lowercased() {
        case "imessage", "sms":
            let handle = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            return handle.isEmpty ? nil : handle
        default:
            return nil
        }
    }

    private static func isPhoneHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("@") else { return false }
        let allowed = CharacterSet(charactersIn: "+0123456789().- ")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return trimmed.filter(\.isNumber).count >= 7
    }

    private static func isEmailHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), let at = trimmed.firstIndex(of: "@") else { return false }
        let local = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        return !local.isEmpty && domain.contains(".")
    }

    private static func string(_ args: [String: Value], _ key: String) -> String {
        guard case .string(let value)? = args[key] else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
