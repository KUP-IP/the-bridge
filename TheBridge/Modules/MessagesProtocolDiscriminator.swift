import Foundation

/// Outbound Messages protocol discriminator (#303, reopen-class of #198 / #249).
///
/// When chat.db has a clear live 1:1 thread or contact service, inherit it
/// or refuse with an explicit reason. Never silent-remap RCS→SMS,
/// iMessage↔SMS, or first-match AppleScript `services` iteration.
///
/// Authority order for a bound 1:1 target:
/// 1. Latest **inbound** normal row (`is_from_me = 0`, not a tapback/system
///    row) on that 1:1 thread — Veronica specimen (#198 ROWID 54580).
/// 2. Else the **thread identity** (`chat.guid` prefix / `chat.service_name`)
///    when it is unambiguous — Mary specimen (RCS thread, no inbound needed).
/// 3. Else fail closed. Outbound-only history is not an oracle.
///
/// `messages_send` still cannot send RCS; AppleScript has no RCS service
/// type. RCS/unknown live threads refuse on omit and on `service=SMS`
/// unless `allowSmsDespiteLiveService: true`. That flag never unlocks
/// iMessage↔SMS mismatch and never maps omit→SMS.
///
/// 1:1 `chatIdentifier` values (`+1…`, `iMessage;-;+1…`, `SMS;-;+1…`,
/// `RCS;-;+1…`, `any;-;+1…`) use this same bind. Group `chatIdentifier`
/// stays on the existing-chat path and is out of this discriminator.
public enum MessagesProtocolDiscriminator: Sendable {

    public static let unusedLookupSentinel = "__bridge_unused_lookup_key__"
    public static let lookupSlotCount = 12

    public enum Target: Equatable, Sendable {
        /// One-to-one handle. `declaredThreadService` is the chat.guid prefix
        /// when the caller passed `iMessage;-;…` / `SMS;-;…` / `RCS;-;…`.
        /// `any;-;…` is 1:1 with no declared service (inherit lookup).
        case oneToOne(handle: String, declaredThreadService: String?)
        case group(chatIdentifier: String)
    }

    // MARK: - Target parse

    /// Prefer `chatIdentifier` when both are set (same as `messages_send`).
    /// A raw `chatNNNN` **recipient** is not parsed here — the handler keeps
    /// the ghost-thread refusal. A raw `chatNNNN` **chatIdentifier** is a group.
    public static func parseTarget(recipient: String?, chatIdentifier: String?) -> Target? {
        if let chatIdentifier {
            let trimmed = chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return parseChatIdentifier(trimmed) }
        }
        if let recipient {
            let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if MessagesSendCatalogTier.isRawGroupChatIdentifier(trimmed) { return nil }
            if let prefixed = parseServicePrefixed(trimmed) {
                return .oneToOne(handle: prefixed.handle, declaredThreadService: prefixed.declaredService)
            }
            return .oneToOne(handle: trimmed, declaredThreadService: nil)
        }
        return nil
    }

    public static func parseChatIdentifier(_ raw: String) -> Target {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefixed = parseServicePrefixed(trimmed) {
            return .oneToOne(handle: prefixed.handle, declaredThreadService: prefixed.declaredService)
        }
        if isPhoneHandle(trimmed) || isEmailHandle(trimmed) {
            return .oneToOne(handle: trimmed, declaredThreadService: nil)
        }
        return .group(chatIdentifier: trimmed)
    }

    public static func parseServicePrefixed(_ raw: String) -> (declaredService: String?, handle: String)? {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "-" else { return nil }
        let handle = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty, isPhoneHandle(handle) || isEmailHandle(handle) else { return nil }
        let prefix = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        if prefix.lowercased() == "any" {
            return (nil, handle)
        }
        return (canonicalServiceName(prefix), handle)
    }

    /// Exact chat.db keys only — never `LIKE '%'`. Includes the raw value,
    /// canonical E.164/email, common national variants, and constructed
    /// `iMessage|SMS|RCS;-;<handle>` guids.
    public static func exactLookupKeys(for raw: String) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != unusedLookupSentinel, !seen.contains(trimmed) else { return }
            seen.insert(trimmed)
            keys.append(trimmed)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        add(trimmed)
        let handle: String
        if let prefixed = parseServicePrefixed(trimmed) {
            add(prefixed.handle)
            handle = prefixed.handle
            if let declared = prefixed.declaredService {
                add("\(declared);-;\(prefixed.handle)")
            }
        } else {
            handle = trimmed
        }

        var bases: [String] = []
        func addBase(_ value: String) {
            let trimmedBase = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBase.isEmpty else { return }
            add(trimmedBase)
            if !bases.contains(trimmedBase) { bases.append(trimmedBase) }
        }
        addBase(handle)
        if let canonical = ThreadMessagesIdentity.canonicalHandle(handle) {
            addBase(canonical)
            if canonical.hasPrefix("+1"), canonical.count == 12 {
                let national = String(canonical.dropFirst(2))
                addBase(national)
                addBase("1" + national)
            }
        }

        for base in bases {
            add("iMessage;-;\(base)")
            add("SMS;-;\(base)")
            add("RCS;-;\(base)")
        }
        return keys
    }

    public static func paddedLookupKeys(_ keys: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for key in keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != unusedLookupSentinel, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            unique.append(trimmed)
            if unique.count == lookupSlotCount { break }
        }
        while unique.count < lookupSlotCount {
            unique.append(unusedLookupSentinel)
        }
        return unique
    }

    // MARK: - Live service from chat.db rows

    /// Live service string for `resolveSendService` (iMessage / SMS / RCS / …).
    /// Returns nil when inherit cannot bind — caller must pass explicit
    /// iMessage/SMS or refuse.
    public static func liveService(from rows: [[String: Any]], target: Target) -> String? {
        switch target {
        case .group:
            return nil
        case .oneToOne(let handle, let declared):
            let candidates = rows.filter { rowMatchesOneToOne($0, handle: handle) }
            if let declared, isSendableOrRCSName(declared) {
                let labeled = candidates.filter { rowThreadService($0)?.caseInsensitiveCompare(declared) == .orderedSame }
                if let inbound = latestInboundServiceName(from: labeled) { return inbound }
                return declared
            }
            if let inbound = latestInboundServiceName(from: candidates) { return inbound }
            let identities = uniqueThreadServices(from: candidates)
            if identities.count == 1 { return identities[0] }
            return nil
        }
    }

    /// True when two 1:1 chats disagree and there is no inbound to break the
    /// tie — fail closed rather than pick a service.
    public static func isAmbiguousThreadIdentity(from rows: [[String: Any]], handle: String) -> Bool {
        let candidates = rows.filter { rowMatchesOneToOne($0, handle: handle) }
        if latestInboundServiceName(from: candidates) != nil { return false }
        return uniqueThreadServices(from: candidates).count > 1
    }

    public static func latestInboundServiceName(from rows: [[String: Any]]) -> String? {
        for row in rows {
            guard !isTapbackOrSystem(row), !isGroupChat(row) else { continue }
            let fromMe = intValue(row["is_from_me"]) ?? 1
            guard fromMe == 0 else { continue }
            if let service = stringValue(row["service"]) { return service }
            if let named = rowThreadService(row) { return named }
        }
        return nil
    }

    public static func rowMatchesOneToOne(_ row: [String: Any], handle: String) -> Bool {
        guard !isTapbackOrSystem(row), !isGroupChat(row) else { return false }
        let keys = Set(exactLookupKeys(for: handle))
        let canonical = ThreadMessagesIdentity.canonicalHandle(handle)
        let fields = [
            stringValue(row["handle_id"]),
            stringValue(row["chat_identifier"]),
            stringValue(row["chat_guid"])
        ]
        for field in fields {
            guard let field else { continue }
            if keys.contains(field) { return true }
            if let fieldCanonical = ThreadMessagesIdentity.canonicalHandle(handlePart(field) ?? field),
               fieldCanonical == canonical {
                return true
            }
            if keys.contains(where: { $0.caseInsensitiveCompare(field) == .orderedSame }) {
                return true
            }
        }
        return false
    }

    public static func ambiguousThreadsRefuseReason(handle: String) -> String {
        "messages_send cannot inherit a single live 1:1 service for \(handle) — iMessage and SMS/RCS threads both exist without a live inbound; pass exactly 'iMessage' or 'SMS' (RCS/unknown SMS needs allowSmsDespiteLiveService:true)"
    }

    // MARK: - Row helpers

    public static func isTapbackOrSystem(_ row: [String: Any]) -> Bool {
        if let type = intValue(row["associated_message_type"]), type != 0 { return true }
        if let type = intValue(row["item_type"]), type != 0 { return true }
        return false
    }

    public static func isGroupChat(_ row: [String: Any]) -> Bool {
        if let count = intValue(row["participant_count"]), count > 1 { return true }
        if let chatId = stringValue(row["chat_identifier"]),
           MessagesSendCatalogTier.isRawGroupChatIdentifier(chatId) {
            return true
        }
        return false
    }

    public static func rowThreadService(_ row: [String: Any]) -> String? {
        if let guid = stringValue(row["chat_guid"]), let prefix = servicePrefix(fromGuid: guid) {
            return prefix
        }
        if let named = stringValue(row["service_name"]), named.lowercased() != "any" {
            return canonicalServiceName(named)
        }
        return nil
    }

    public static func servicePrefix(fromGuid guid: String) -> String? {
        let parts = guid.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "-" else { return nil }
        let prefix = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, prefix.lowercased() != "any" else { return nil }
        return canonicalServiceName(prefix)
    }

    public static func canonicalServiceName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "imessage": return "iMessage"
        case "sms": return "SMS"
        case "rcs": return "RCS"
        default: return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static func isSendableOrRCSName(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "imessage", "sms", "rcs": return true
        default: return false
        }
    }

    public static func uniqueThreadServices(from rows: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows {
            guard !isTapbackOrSystem(row), !isGroupChat(row) else { continue }
            guard let name = rowThreadService(row) ?? stringValue(row["service"]) else { continue }
            let canonical = canonicalServiceName(name)
            let key = canonical.lowercased()
            if seen.insert(key).inserted {
                ordered.append(canonical)
            }
        }
        return ordered
    }

    public static func handlePart(_ raw: String) -> String? {
        if let prefixed = parseServicePrefixed(raw) { return prefixed.handle }
        return raw
    }

    public static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? Bool { return value ? 1 : 0 }
        return nil
    }

    public static func stringValue(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isPhoneHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("@") else { return false }
        let allowed = CharacterSet(charactersIn: "+0123456789().- ")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return trimmed.filter(\.isNumber).count >= 7
    }

    public static func isEmailHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), let at = trimmed.firstIndex(of: "@") else { return false }
        let local = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        return !local.isEmpty && domain.contains(".")
    }
}
