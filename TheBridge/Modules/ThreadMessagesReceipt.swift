// ThreadMessagesReceipt.swift — THREAD → Messages recoverable receipt transaction (M1)
//
// One existing THREAD, one explicitly approved one-to-one Messages action,
// one exact local Messages ROWID, two append-only THREAD journal entries,
// and zero lifecycle/property mutation.

import CryptoKit
import Foundation
import MCP

public enum MessagesDeliveryVerificationStatus: String, Sendable, Equatable {
    case verified = "VERIFIED"
    case notFound = "NOT_FOUND"
    case ambiguous = "AMBIGUOUS"
    case deliveryError = "DELIVERY_ERROR"
}

public struct MessagesDeliveryVerification: Sendable, Equatable {
    public var status: MessagesDeliveryVerificationStatus
    public var messageRowId: Int?
    public var service: String?
    public var verifiedAt: Date?
    public var candidateRowIds: [Int]
    public var error: String?

    public init(
        status: MessagesDeliveryVerificationStatus,
        messageRowId: Int? = nil,
        service: String? = nil,
        verifiedAt: Date? = nil,
        candidateRowIds: [Int] = [],
        error: String? = nil
    ) {
        self.status = status
        self.messageRowId = messageRowId
        self.service = service
        self.verifiedAt = verifiedAt
        self.candidateRowIds = candidateRowIds
        self.error = error
    }

    public var verified: Bool { status == .verified && messageRowId != nil }
    public var deliveryReference: String? { messageRowId.map { "messages:\($0)" } }
}

public struct MessagesDeliveryAttempt: Sendable, Equatable {
    public var invoked: Bool
    public var verification: MessagesDeliveryVerification
    public var service: String?
    public var detectedService: String?
    public var error: String?
    public var errorNumber: Int?

    public init(
        invoked: Bool,
        verification: MessagesDeliveryVerification,
        service: String? = nil,
        detectedService: String? = nil,
        error: String? = nil,
        errorNumber: Int? = nil
    ) {
        self.invoked = invoked
        self.verification = verification
        self.service = service
        self.detectedService = detectedService
        self.error = error
        self.errorNumber = errorNumber
    }
}

public struct ThreadMessagesSnapshot: Sendable, Equatable {
    public var pageId: String
    public var canonicalThreadSource: Bool
    public var managerMode: String
    public var status: String?
    public var nextCheckIn: String?
    public var linkedPersonCount: Int
    public var markdown: String

    public init(
        pageId: String,
        canonicalThreadSource: Bool,
        managerMode: String,
        status: String?,
        nextCheckIn: String?,
        linkedPersonCount: Int,
        markdown: String
    ) {
        self.pageId = pageId
        self.canonicalThreadSource = canonicalThreadSource
        self.managerMode = managerMode
        self.status = status
        self.nextCheckIn = nextCheckIn
        self.linkedPersonCount = linkedPersonCount
        self.markdown = markdown
    }
}

public struct ThreadMessagesReceiptRequest: Sendable, Equatable {
    public var threadPageId: String
    public var actionId: String
    public var recipient: String
    public var body: String
    public var approvalBasis: String
    public var actor: String
    public var confirm: String
    public var serviceOverride: String?

    public init(
        threadPageId: String,
        actionId: String,
        recipient: String,
        body: String,
        approvalBasis: String,
        actor: String = "The Bridge",
        confirm: String,
        serviceOverride: String? = nil
    ) {
        self.threadPageId = threadPageId
        self.actionId = actionId
        self.recipient = recipient
        self.body = body
        self.approvalBasis = approvalBasis
        self.actor = actor
        self.confirm = confirm
        self.serviceOverride = serviceOverride
    }
}

public enum ThreadMessagesReceiptOutcome: String, Sendable, Equatable {
    case verified = "VERIFIED"
    case alreadyCompleted = "ALREADY_COMPLETED"
    case blocked = "BLOCKED"
    case intentWriteFailed = "INTENT_WRITE_FAILED"
    case deliveryStateUnknown = "DELIVERY_STATE_UNKNOWN"
    case ambiguous = "AMBIGUOUS"
    case deliveryError = "DELIVERY_ERROR"
    case deliveredReceiptWriteFailed = "DELIVERED_RECEIPT_WRITE_FAILED"
}

public struct ThreadMessagesReceiptResult: Sendable, Equatable {
    public var outcome: ThreadMessagesReceiptOutcome
    public var actionId: String
    public var deliveryInvoked: Bool
    public var verified: Bool
    public var messageRowId: Int?
    public var deliveryReference: String?
    public var service: String?
    public var lifecycleUnchanged: Bool?
    public var repairMarkdown: String?
    public var error: String?

    public init(
        outcome: ThreadMessagesReceiptOutcome,
        actionId: String,
        deliveryInvoked: Bool = false,
        verified: Bool = false,
        messageRowId: Int? = nil,
        deliveryReference: String? = nil,
        service: String? = nil,
        lifecycleUnchanged: Bool? = nil,
        repairMarkdown: String? = nil,
        error: String? = nil
    ) {
        self.outcome = outcome
        self.actionId = actionId
        self.deliveryInvoked = deliveryInvoked
        self.verified = verified
        self.messageRowId = messageRowId
        self.deliveryReference = deliveryReference
        self.service = service
        self.lifecycleUnchanged = lifecycleUnchanged
        self.repairMarkdown = repairMarkdown
        self.error = error
    }

    public func mcpValue() -> Value {
        var object: [String: Value] = [
            "outcome": .string(outcome.rawValue),
            "actionId": .string(actionId),
            "sent": .bool(deliveryInvoked),
            "deliveryInvoked": .bool(deliveryInvoked),
            "verified": .bool(verified)
        ]
        object["messageRowId"] = messageRowId.map(Value.int) ?? .null
        object["deliveryReference"] = deliveryReference.map(Value.string) ?? .null
        object["service"] = service.map(Value.string) ?? .null
        object["lifecycleUnchanged"] = lifecycleUnchanged.map(Value.bool) ?? .null
        object["repairMarkdown"] = repairMarkdown.map(Value.string) ?? .null
        object["error"] = error.map(Value.string) ?? .null
        return .object(object)
    }
}

public struct ThreadMessagesReceiptDependencies {
    public var readThread: (String) async throws -> ThreadMessagesSnapshot
    public var appendMarkdown: (String, String) async throws -> Void
    public var currentMaxMessageRowId: () throws -> Int
    public var reconcile: (String, String, Int) -> MessagesDeliveryVerification
    public var send: (String, String, String, String?, Int) -> MessagesDeliveryAttempt
    public var now: () -> Date

    public init(
        readThread: @escaping (String) async throws -> ThreadMessagesSnapshot,
        appendMarkdown: @escaping (String, String) async throws -> Void,
        currentMaxMessageRowId: @escaping () throws -> Int,
        reconcile: @escaping (String, String, Int) -> MessagesDeliveryVerification,
        send: @escaping (String, String, String, String?, Int) -> MessagesDeliveryAttempt,
        now: @escaping () -> Date = Date.init
    ) {
        self.readThread = readThread
        self.appendMarkdown = appendMarkdown
        self.currentMaxMessageRowId = currentMaxMessageRowId
        self.reconcile = reconcile
        self.send = send
        self.now = now
    }
}

public enum ThreadMessagesReceiptJournal {
    public static func fingerprint(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func intentHeading(actionId: String) -> String {
        "### THREAD ACTION INTENT · \(actionId)"
    }

    public static func resultHeading(actionId: String) -> String {
        "### THREAD ACTION RESULT · \(actionId)"
    }

    public static func hasIntent(_ markdown: String, actionId: String) -> Bool {
        hasHeading(markdown, heading: intentHeading(actionId: actionId))
    }

    public static func hasResult(_ markdown: String, actionId: String) -> Bool {
        hasHeading(markdown, heading: resultHeading(actionId: actionId))
    }

    public static func isValidActionId(_ actionId: String) -> Bool {
        guard !actionId.isEmpty, actionId.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        return actionId.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func requestMatchesExisting(
        _ markdown: String,
        actionId: String,
        recipient: String,
        body: String
    ) -> Bool {
        let intent = section(markdown, heading: intentHeading(actionId: actionId))
        let result = section(markdown, heading: resultHeading(actionId: actionId))
        let source = intent.isEmpty ? result : intent
        guard !source.isEmpty,
              let storedTarget = field("Target", in: source),
              let storedFingerprint = field("Approved body fingerprint", in: source) else {
            return false
        }
        return targetsEquivalent(storedTarget, recipient)
            && storedFingerprint == fingerprint(body)
    }

    public static func preSendWatermark(_ markdown: String, actionId: String) -> Int? {
        field("Pre-send ROWID watermark", in: section(markdown, heading: intentHeading(actionId: actionId)))
            .flatMap(Int.init)
    }

    public static func resultRowId(_ markdown: String, actionId: String) -> Int? {
        field("Messages ROWID", in: section(markdown, heading: resultHeading(actionId: actionId)))
            .flatMap(Int.init)
    }

    public static func intentMarkdown(
        request: ThreadMessagesReceiptRequest,
        snapshot: ThreadMessagesSnapshot,
        preparedAt: Date,
        preSendWatermark: Int
    ) -> String {
        """

        \(intentHeading(actionId: request.actionId))
        Action ID: \(request.actionId)
        Prepared at: \(iso(preparedAt))
        THREAD ID: \(request.threadPageId)
        Manager Mode: \(snapshot.managerMode)
        Approval basis: \(singleLine(request.approvalBasis))
        Actor: \(singleLine(request.actor))
        Target: \(singleLine(request.recipient))
        Channel: Messages
        Approved body fingerprint: \(fingerprint(request.body))
        Pre-send ROWID watermark: \(preSendWatermark)
        Previous Status: \(snapshot.status ?? "")
        Previous Next Check-in: \(snapshot.nextCheckIn ?? "")
        State: PREPARED
        Approved body JSON: \(jsonString(request.body))
        """
    }

    public static func resultMarkdown(
        request: ThreadMessagesReceiptRequest,
        verification: MessagesDeliveryVerification,
        service: String?,
        completedAt: Date,
        recoveryNote: String
    ) -> String {
        """

        \(resultHeading(actionId: request.actionId))
        Action ID: \(request.actionId)
        Completed at: \(iso(completedAt))
        Outcome: \(verification.status.rawValue)
        Delivery reference: \(verification.deliveryReference ?? "")
        Messages ROWID: \(verification.messageRowId.map(String.init) ?? "")
        Target: \(singleLine(request.recipient))
        Service: \(singleLine(service ?? verification.service ?? ""))
        Verified at: \(verification.verifiedAt.map(iso) ?? "")
        Approved body fingerprint: \(fingerprint(request.body))
        THREAD lifecycle mutation: none
        Recovery note: \(singleLine(recoveryNote))
        """
    }

    private static func hasHeading(_ markdown: String, heading: String) -> Bool {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { String($0) == heading }
    }

    private static func targetsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if left.contains("@") || right.contains("@") { return left == right }
        let leftDigits = left.filter(\.isNumber)
        let rightDigits = right.filter(\.isNumber)
        if leftDigits == rightDigits { return true }
        if leftDigits.count == 10, rightDigits.count == 11, rightDigits.hasPrefix("1") {
            return leftDigits == String(rightDigits.dropFirst())
        }
        if rightDigits.count == 10, leftDigits.count == 11, leftDigits.hasPrefix("1") {
            return rightDigits == String(leftDigits.dropFirst())
        }
        return false
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }

    private static func section(_ markdown: String, heading: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: heading) else { return "" }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("### ") }) ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    private static func field(_ name: String, in section: String) -> String? {
        let prefix = "\(name):"
        return section.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public enum ThreadMessagesReceiptEngine {
    public static func execute(
        request: ThreadMessagesReceiptRequest,
        dependencies: ThreadMessagesReceiptDependencies
    ) async -> ThreadMessagesReceiptResult {
        guard request.confirm == "SEND" else {
            return .init(outcome: .blocked, actionId: request.actionId, error: "confirm must be exactly SEND")
        }
        guard ThreadMessagesReceiptJournal.isValidActionId(request.actionId),
              !request.threadPageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.recipient.contains("\n"), !request.recipient.contains("\r"),
              !request.body.isEmpty,
              !request.approvalBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(outcome: .blocked, actionId: request.actionId, error: "threadPageId, valid actionId, single-line recipient, body, and approvalBasis are required")
        }

        let initial: ThreadMessagesSnapshot
        do {
            initial = try await dependencies.readThread(request.threadPageId)
        } catch {
            return .init(outcome: .blocked, actionId: request.actionId, error: "THREAD read failed: \(error.localizedDescription)")
        }

        guard initial.canonicalThreadSource else {
            return .init(outcome: .blocked, actionId: request.actionId, error: "page is not in canonical THREADS data source")
        }
        guard initial.linkedPersonCount == 1 else {
            return .init(outcome: .blocked, actionId: request.actionId, error: "THREAD must link exactly one CONTACT or PROSPECT")
        }
        guard ["Act-with-GO", "Act"].contains(initial.managerMode) else {
            return .init(outcome: .blocked, actionId: request.actionId, error: "Manager Mode \(initial.managerMode) does not permit delivery")
        }

        if ThreadMessagesReceiptJournal.hasResult(initial.markdown, actionId: request.actionId) {
            guard ThreadMessagesReceiptJournal.requestMatchesExisting(
                initial.markdown,
                actionId: request.actionId,
                recipient: request.recipient,
                body: request.body
            ) else {
                return .init(outcome: .blocked, actionId: request.actionId, error: "actionId is already bound to a different target or body")
            }
            let rowId = ThreadMessagesReceiptJournal.resultRowId(initial.markdown, actionId: request.actionId)
            return .init(
                outcome: .alreadyCompleted,
                actionId: request.actionId,
                verified: rowId != nil,
                messageRowId: rowId,
                deliveryReference: rowId.map { "messages:\($0)" },
                lifecycleUnchanged: true
            )
        }

        if ThreadMessagesReceiptJournal.hasIntent(initial.markdown, actionId: request.actionId) {
            guard ThreadMessagesReceiptJournal.requestMatchesExisting(
                initial.markdown,
                actionId: request.actionId,
                recipient: request.recipient,
                body: request.body
            ) else {
                return .init(outcome: .blocked, actionId: request.actionId, error: "actionId is already bound to a different target or body")
            }
            guard let watermark = ThreadMessagesReceiptJournal.preSendWatermark(initial.markdown, actionId: request.actionId) else {
                return .init(outcome: .deliveryStateUnknown, actionId: request.actionId, error: "Intent exists without a readable pre-send ROWID watermark")
            }
            let reconciled = dependencies.reconcile(request.recipient, request.body, watermark)
            switch reconciled.status {
            case .verified:
                let resultMarkdown = ThreadMessagesReceiptJournal.resultMarkdown(
                    request: request,
                    verification: reconciled,
                    service: reconciled.service,
                    completedAt: dependencies.now(),
                    recoveryNote: "Recovered from an Intent-only state; no resend performed."
                )
                do {
                    try await dependencies.appendMarkdown(request.threadPageId, resultMarkdown)
                    let after = try await dependencies.readThread(request.threadPageId)
                    guard ThreadMessagesReceiptJournal.hasResult(after.markdown, actionId: request.actionId) else {
                        throw ThreadMessagesReceiptInternalError.readBackMissing
                    }
                    return .init(
                        outcome: .verified,
                        actionId: request.actionId,
                        verified: true,
                        messageRowId: reconciled.messageRowId,
                        deliveryReference: reconciled.deliveryReference,
                        service: reconciled.service,
                        lifecycleUnchanged: lifecycleUnchanged(initial, after)
                    )
                } catch {
                    return .init(
                        outcome: .deliveredReceiptWriteFailed,
                        actionId: request.actionId,
                        verified: true,
                        messageRowId: reconciled.messageRowId,
                        deliveryReference: reconciled.deliveryReference,
                        service: reconciled.service,
                        repairMarkdown: resultMarkdown,
                        error: error.localizedDescription
                    )
                }
            case .ambiguous:
                return .init(outcome: .ambiguous, actionId: request.actionId, error: "Intent-only reconciliation matched multiple outbound messages")
            case .notFound:
                return .init(outcome: .deliveryStateUnknown, actionId: request.actionId, error: "Intent exists but no exact outbound message is currently provable; operator decision required before resend")
            case .deliveryError:
                return .init(outcome: .deliveryError, actionId: request.actionId, error: reconciled.error)
            }
        }

        let watermark: Int
        do {
            watermark = try dependencies.currentMaxMessageRowId()
        } catch {
            return .init(outcome: .blocked, actionId: request.actionId, error: "Could not capture pre-send ROWID watermark: \(error.localizedDescription)")
        }

        let intentMarkdown = ThreadMessagesReceiptJournal.intentMarkdown(
            request: request,
            snapshot: initial,
            preparedAt: dependencies.now(),
            preSendWatermark: watermark
        )
        do {
            try await dependencies.appendMarkdown(request.threadPageId, intentMarkdown)
            let prepared = try await dependencies.readThread(request.threadPageId)
            guard ThreadMessagesReceiptJournal.hasIntent(prepared.markdown, actionId: request.actionId),
                  ThreadMessagesReceiptJournal.requestMatchesExisting(
                    prepared.markdown,
                    actionId: request.actionId,
                    recipient: request.recipient,
                    body: request.body
                  ) else {
                throw ThreadMessagesReceiptInternalError.readBackMissing
            }
        } catch {
            return .init(
                outcome: .intentWriteFailed,
                actionId: request.actionId,
                repairMarkdown: intentMarkdown,
                error: error.localizedDescription
            )
        }

        let attempt = dependencies.send(request.recipient, request.body, request.confirm, request.serviceOverride, watermark)
        if attempt.verification.status != .verified {
            switch attempt.verification.status {
            case .ambiguous:
                return .init(outcome: .ambiguous, actionId: request.actionId, deliveryInvoked: attempt.invoked, error: "Delivery was invoked but exact verification matched multiple messages")
            case .notFound:
                return .init(outcome: .deliveryStateUnknown, actionId: request.actionId, deliveryInvoked: attempt.invoked, error: "Delivery was invoked but no exact outbound message was proven; do not resend without reconciliation")
            case .deliveryError:
                return .init(outcome: .deliveryError, actionId: request.actionId, deliveryInvoked: attempt.invoked, error: attempt.error ?? attempt.verification.error)
            case .verified:
                return .init(outcome: .deliveryError, actionId: request.actionId, deliveryInvoked: attempt.invoked, error: "unreachable verification state")
            }
        }

        let resultMarkdown = ThreadMessagesReceiptJournal.resultMarkdown(
            request: request,
            verification: attempt.verification,
            service: attempt.service,
            completedAt: dependencies.now(),
            recoveryNote: "Exact outbound row verified after guarded delivery."
        )
        do {
            try await dependencies.appendMarkdown(request.threadPageId, resultMarkdown)
            let final = try await dependencies.readThread(request.threadPageId)
            guard ThreadMessagesReceiptJournal.hasResult(final.markdown, actionId: request.actionId),
                  ThreadMessagesReceiptJournal.requestMatchesExisting(
                    final.markdown,
                    actionId: request.actionId,
                    recipient: request.recipient,
                    body: request.body
                  ),
                  ThreadMessagesReceiptJournal.resultRowId(final.markdown, actionId: request.actionId) == attempt.verification.messageRowId else {
                throw ThreadMessagesReceiptInternalError.readBackMissing
            }
            return .init(
                outcome: .verified,
                actionId: request.actionId,
                deliveryInvoked: attempt.invoked,
                verified: true,
                messageRowId: attempt.verification.messageRowId,
                deliveryReference: attempt.verification.deliveryReference,
                service: attempt.service,
                lifecycleUnchanged: lifecycleUnchanged(initial, final)
            )
        } catch {
            return .init(
                outcome: .deliveredReceiptWriteFailed,
                actionId: request.actionId,
                deliveryInvoked: attempt.invoked,
                verified: true,
                messageRowId: attempt.verification.messageRowId,
                deliveryReference: attempt.verification.deliveryReference,
                service: attempt.service,
                repairMarkdown: resultMarkdown,
                error: error.localizedDescription
            )
        }
    }

    private static func lifecycleUnchanged(_ before: ThreadMessagesSnapshot, _ after: ThreadMessagesSnapshot) -> Bool {
        before.status == after.status && before.nextCheckIn == after.nextCheckIn && before.linkedPersonCount == after.linkedPersonCount
    }
}

private enum ThreadMessagesReceiptInternalError: LocalizedError {
    case readBackMissing
    var errorDescription: String? { "THREAD journal append was not present on read-back" }
}
