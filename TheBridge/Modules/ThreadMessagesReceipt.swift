// ThreadMessagesReceipt.swift — governed THREAD → Messages transaction

import CryptoKit
import Foundation
import MCP

public enum MessagesDeliveryVerificationStatus: String, Sendable, Equatable {
    case verified = "LOCAL_OUTBOUND_RECORD_VERIFIED"
    case notFound = "NOT_FOUND"
    case ambiguous = "AMBIGUOUS"
    case deliveryError = "DELIVERY_ERROR"
}

public struct MessagesDeliveryVerification: Sendable, Equatable {
    public var status: MessagesDeliveryVerificationStatus
    public var messageRowId: Int?
    public var messageGuid: String?
    public var chatGuid: String?
    public var messageDate: Date?
    public var service: String?
    public var verifiedAt: Date?
    public var candidateRowIds: [Int]
    public var error: String?

    public init(
        status: MessagesDeliveryVerificationStatus,
        messageRowId: Int? = nil,
        messageGuid: String? = nil,
        chatGuid: String? = nil,
        messageDate: Date? = nil,
        service: String? = nil,
        verifiedAt: Date? = nil,
        candidateRowIds: [Int] = [],
        error: String? = nil
    ) {
        self.status = status
        self.messageRowId = messageRowId
        self.messageGuid = messageGuid
        self.chatGuid = chatGuid
        self.messageDate = messageDate
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

public struct ThreadLinkedPersonSnapshot: Sendable, Equatable {
    public var entity: String
    public var pageId: String
    public var name: String?
    public var status: String?
    public var phone: String?
    public var email: String?
    public var nextAction: String?
    public var lastActivity: String?

    public init(
        entity: String,
        pageId: String,
        name: String? = nil,
        status: String? = nil,
        phone: String? = nil,
        email: String? = nil,
        nextAction: String? = nil,
        lastActivity: String? = nil
    ) {
        self.entity = entity
        self.pageId = Self.normalizeId(pageId)
        self.name = name
        self.status = status
        self.phone = phone
        self.email = email
        self.nextAction = nextAction
        self.lastActivity = lastActivity
    }

    public var authorizedHandles: [String] {
        [phone, email].compactMap { $0 }.compactMap(ThreadMessagesIdentity.canonicalHandle)
    }

    public var lifecycleFingerprint: String {
        ThreadMessagesReceiptJournal.fingerprint([
            entity,
            pageId,
            status ?? "",
            nextAction ?? "",
            lastActivity ?? ""
        ].joined(separator: "\u{1F}"))
    }

    private static func normalizeId(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

public struct ThreadMessagesSnapshot: Sendable, Equatable {
    public var pageId: String
    public var canonicalThreadSource: Bool
    public var managerMode: String
    public var status: String?
    public var nextCheckIn: String?
    public var linkedPerson: ThreadLinkedPersonSnapshot?
    public var linkedPersonCount: Int
    public var markdown: String

    public init(
        pageId: String,
        canonicalThreadSource: Bool,
        managerMode: String,
        status: String?,
        nextCheckIn: String?,
        linkedPerson: ThreadLinkedPersonSnapshot? = nil,
        linkedPersonCount: Int? = nil,
        markdown: String
    ) {
        self.pageId = pageId
        self.canonicalThreadSource = canonicalThreadSource
        self.managerMode = managerMode
        self.status = status
        self.nextCheckIn = nextCheckIn
        self.linkedPerson = linkedPerson
        self.linkedPersonCount = linkedPersonCount ?? (linkedPerson == nil ? 0 : 1)
        self.markdown = markdown
    }

    public var lifecycleFingerprint: String {
        ThreadMessagesReceiptJournal.fingerprint([
            status ?? "",
            nextCheckIn ?? "",
            linkedPerson?.entity ?? "",
            linkedPerson?.pageId ?? "",
            linkedPerson?.lifecycleFingerprint ?? ""
        ].joined(separator: "\u{1F}"))
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
    public var approvalReceiptId: String
    public var approvalArgumentsDigest: String
    public var approvalPrincipal: String?
    public var approvedAt: Date

    public init(
        threadPageId: String,
        actionId: String,
        recipient: String,
        body: String,
        approvalBasis: String,
        actor: String = "The Bridge",
        confirm: String,
        serviceOverride: String? = nil,
        approvalReceiptId: String = "test-approval",
        approvalArgumentsDigest: String = "test-arguments-digest",
        approvalPrincipal: String? = "test-principal",
        approvedAt: Date = Date()
    ) {
        self.threadPageId = threadPageId
        self.actionId = actionId
        self.recipient = recipient
        self.body = body
        self.approvalBasis = approvalBasis
        self.actor = actor
        self.confirm = confirm
        self.serviceOverride = serviceOverride
        self.approvalReceiptId = approvalReceiptId
        self.approvalArgumentsDigest = approvalArgumentsDigest
        self.approvalPrincipal = approvalPrincipal
        self.approvedAt = approvedAt
    }
}

public enum ThreadMessagesReceiptOutcome: String, Sendable, Equatable {
    case verified = "LOCAL_OUTBOUND_RECORD_VERIFIED"
    case alreadyCompleted = "ALREADY_COMPLETED"
    case inProgress = "IN_PROGRESS"
    case blocked = "BLOCKED"
    case intentWriteFailed = "INTENT_WRITE_FAILED"
    case deliveryStateUnknown = "DELIVERY_STATE_UNKNOWN"
    case ambiguous = "AMBIGUOUS"
    case deliveryError = "DELIVERY_ERROR"
    case lifecycleDrift = "LIFECYCLE_DRIFT"
    case deliveredReceiptWriteFailed = "DELIVERED_RECEIPT_WRITE_FAILED"
}

public struct ThreadMessagesReceiptResult: Sendable, Equatable {
    public var outcome: ThreadMessagesReceiptOutcome
    public var actionId: String
    public var deliveryInvoked: Bool
    public var verified: Bool
    public var messageRowId: Int?
    public var messageGuid: String?
    public var chatGuid: String?
    public var messageDate: Date?
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
        messageGuid: String? = nil,
        chatGuid: String? = nil,
        messageDate: Date? = nil,
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
        self.messageGuid = messageGuid
        self.chatGuid = chatGuid
        self.messageDate = messageDate
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
            "sent": .bool(verified),
            "deliveryInvoked": .bool(deliveryInvoked),
            "localOutboundRecordVerified": .bool(verified),
            "providerDeliveryConfirmed": .bool(false),
            "lifecycleWriterScope": .string("none")
        ]
        object["verified"] = .bool(verified) // compatibility alias; local record only
        object["messageRowId"] = messageRowId.map(Value.int) ?? .null
        object["messageGuid"] = messageGuid.map(Value.string) ?? .null
        object["chatGuid"] = chatGuid.map(Value.string) ?? .null
        object["messageDate"] = messageDate.map { .string(ThreadMessagesReceiptJournal.iso($0)) } ?? .null
        object["deliveryReference"] = deliveryReference.map(Value.string) ?? .null
        object["service"] = service.map(Value.string) ?? .null
        object["lifecycleUnchanged"] = lifecycleUnchanged.map(Value.bool) ?? .null
        object["repairMarkdown"] = repairMarkdown.map(Value.string) ?? .null
        object["error"] = error.map(Value.string) ?? .null
        return .object(object)
    }
}

public struct ThreadMessagesReceiptDependencies {
    public var store: any ThreadMessagesReceiptStoring
    public var readThread: (String) async throws -> ThreadMessagesSnapshot
    public var appendMarkdown: (String, String) async throws -> Void
    public var currentMaxMessageRowId: () throws -> Int
    public var reconcile: (String, String, Int, Date) -> MessagesDeliveryVerification
    public var send: (String, String, String, String?, Int, Date) -> MessagesDeliveryAttempt
    public var now: () -> Date
    public var operationId: () -> String
    public var leaseToken: () -> String

    public init(
        store: any ThreadMessagesReceiptStoring,
        readThread: @escaping (String) async throws -> ThreadMessagesSnapshot,
        appendMarkdown: @escaping (String, String) async throws -> Void,
        currentMaxMessageRowId: @escaping () throws -> Int,
        reconcile: @escaping (String, String, Int, Date) -> MessagesDeliveryVerification,
        send: @escaping (String, String, String, String?, Int, Date) -> MessagesDeliveryAttempt,
        now: @escaping () -> Date = Date.init,
        operationId: @escaping () -> String = { UUID().uuidString },
        leaseToken: @escaping () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.readThread = readThread
        self.appendMarkdown = appendMarkdown
        self.currentMaxMessageRowId = currentMaxMessageRowId
        self.reconcile = reconcile
        self.send = send
        self.now = now
        self.operationId = operationId
        self.leaseToken = leaseToken
    }
}

public enum ThreadMessagesIdentity {
    public static func canonicalHandle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        if trimmed.contains("@") {
            let lowered = trimmed.lowercased()
            let parts = lowered.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
                  !lowered.contains(where: { $0.isWhitespace }) else { return nil }
            return lowered
        }
        let digits = trimmed.filter(\.isNumber)
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        if trimmed.hasPrefix("+"), (8...15).contains(digits.count) { return "+" + digits }
        return nil
    }

    public static func recipientIsAuthorized(_ recipient: String, person: ThreadLinkedPersonSnapshot) -> Bool {
        guard let canonical = canonicalHandle(recipient) else { return false }
        return person.authorizedHandles.contains(canonical)
    }
}

public enum ThreadMessagesReceiptJournal {
    public static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func actionKey(threadPageId: String, actionId: String) -> String {
        threadPageId.replacingOccurrences(of: "-", with: "").lowercased() + ":" + actionId
    }

    public static func manifestFingerprint(
        request: ThreadMessagesReceiptRequest,
        person: ThreadLinkedPersonSnapshot,
        canonicalRecipient: String
    ) -> String {
        fingerprint([
            request.threadPageId.replacingOccurrences(of: "-", with: "").lowercased(),
            request.actionId,
            person.entity,
            person.pageId,
            canonicalRecipient,
            fingerprint(request.body),
            request.serviceOverride?.lowercased() ?? "auto"
        ].joined(separator: "\u{1F}"))
    }

    public static func intentHeading(actionId: String) -> String { "### THREAD ACTION INTENT · \(actionId)" }
    public static func resultHeading(actionId: String) -> String { "### THREAD ACTION RESULT · \(actionId)" }
    public static func hasIntent(_ markdown: String, actionId: String) -> Bool { hasHeading(markdown, heading: intentHeading(actionId: actionId)) }
    public static func hasResult(_ markdown: String, actionId: String) -> Bool { hasHeading(markdown, heading: resultHeading(actionId: actionId)) }

    public static func isValidActionId(_ actionId: String) -> Bool {
        guard !actionId.isEmpty, actionId.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        return actionId.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func requestMatchesExisting(
        _ markdown: String,
        actionId: String,
        recipient: String,
        body: String,
        person: ThreadLinkedPersonSnapshot
    ) -> Bool {
        let intent = section(markdown, heading: intentHeading(actionId: actionId))
        let result = section(markdown, heading: resultHeading(actionId: actionId))
        let source = intent.isEmpty ? result : intent
        guard !source.isEmpty,
              let storedTarget = field("Target", in: source),
              let storedFingerprint = field("Approved body fingerprint", in: source),
              let storedEntity = field("Linked person entity", in: source),
              let storedPersonId = field("Linked person ID", in: source) else { return false }
        return ThreadMessagesIdentity.canonicalHandle(storedTarget) == ThreadMessagesIdentity.canonicalHandle(recipient)
            && storedFingerprint == fingerprint(body)
            && storedEntity == person.entity
            && storedPersonId.replacingOccurrences(of: "-", with: "").lowercased() == person.pageId
    }

    public static func intentMarkdown(
        request: ThreadMessagesReceiptRequest,
        snapshot: ThreadMessagesSnapshot,
        preparedAt: Date,
        preSendWatermark: Int
    ) -> String {
        let person = snapshot.linkedPerson
        return """

        \(intentHeading(actionId: request.actionId))
        Action ID: \(request.actionId)
        Prepared at: \(iso(preparedAt))
        THREAD ID: \(request.threadPageId)
        Manager Mode: \(snapshot.managerMode)
        Approval receipt ID: \(singleLine(request.approvalReceiptId))
        Approval arguments digest: \(singleLine(request.approvalArgumentsDigest))
        Approval principal: \(singleLine(request.approvalPrincipal ?? "local"))
        Approved at: \(iso(request.approvedAt))
        Approval basis: \(singleLine(request.approvalBasis))
        Actor: \(singleLine(request.actor))
        Linked person entity: \(person?.entity ?? "")
        Linked person ID: \(person?.pageId ?? "")
        Target: \(singleLine(request.recipient))
        Channel: Messages
        Approved body fingerprint: \(fingerprint(request.body))
        Pre-send ROWID watermark: \(preSendWatermark)
        Lifecycle before fingerprint: \(snapshot.lifecycleFingerprint)
        Previous Status: \(snapshot.status ?? "")
        Previous Next Check-in: \(snapshot.nextCheckIn ?? "")
        State: PREPARED
        Approved body JSON: \(jsonString(request.body))
        """
    }

    public static func resultMarkdown(
        request: ThreadMessagesReceiptRequest,
        snapshotAfter: ThreadMessagesSnapshot,
        verification: MessagesDeliveryVerification,
        service: String?,
        completedAt: Date,
        lifecycleUnchanged: Bool,
        recoveryNote: String
    ) -> String {
        let person = snapshotAfter.linkedPerson
        return """

        \(resultHeading(actionId: request.actionId))
        Action ID: \(request.actionId)
        Completed at: \(iso(completedAt))
        Outcome: \(verification.status.rawValue)
        Evidence scope: local outbound Messages database record
        Provider delivery confirmed: false
        Delivery reference: \(verification.deliveryReference ?? "")
        Messages ROWID: \(verification.messageRowId.map(String.init) ?? "")
        Messages GUID: \(singleLine(verification.messageGuid ?? ""))
        Chat GUID: \(singleLine(verification.chatGuid ?? ""))
        Message database date: \(verification.messageDate.map(iso) ?? "")
        Target: \(singleLine(request.recipient))
        Linked person entity: \(person?.entity ?? "")
        Linked person ID: \(person?.pageId ?? "")
        Service: \(singleLine(service ?? verification.service ?? ""))
        Verified at: \(verification.verifiedAt.map(iso) ?? "")
        Approved body fingerprint: \(fingerprint(request.body))
        Approval receipt ID: \(singleLine(request.approvalReceiptId))
        Lifecycle writer scope: none
        Observed lifecycle unchanged: \(lifecycleUnchanged)
        Lifecycle after fingerprint: \(snapshotAfter.lifecycleFingerprint)
        Recovery note: \(singleLine(recoveryNote))
        """
    }

    public static func resultRowId(_ markdown: String, actionId: String) -> Int? {
        field("Messages ROWID", in: section(markdown, heading: resultHeading(actionId: actionId))).flatMap(Int.init)
    }

    private static func hasHeading(_ markdown: String, heading: String) -> Bool {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).contains { String($0) == heading }
    }
    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
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
            .map(String.init).first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func iso(_ date: Date) -> String {
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
        guard request.confirm == "SEND" else { return blocked(request, "confirm must be exactly SEND") }
        guard ThreadMessagesReceiptJournal.isValidActionId(request.actionId),
              !request.threadPageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.body.isEmpty,
              !request.approvalBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.approvalReceiptId.isEmpty,
              !request.approvalArgumentsDigest.isEmpty else {
            return blocked(request, "threadPageId, valid actionId, body, approval metadata, and approvalBasis are required")
        }
        guard let canonicalRecipient = ThreadMessagesIdentity.canonicalHandle(request.recipient) else {
            return blocked(request, "recipient must be one canonical email or E.164-style phone handle")
        }

        let initial: ThreadMessagesSnapshot
        do { initial = try await dependencies.readThread(request.threadPageId) }
        catch { return blocked(request, "THREAD read failed: \(error.localizedDescription)") }
        guard let personError = validateAuthorization(snapshot: initial, canonicalRecipient: canonicalRecipient) else {
            return blocked(request, "THREAD authorization could not be evaluated")
        }
        if !personError.isEmpty { return blocked(request, personError) }
        guard let person = initial.linkedPerson else { return blocked(request, "THREAD linked person could not be resolved") }

        let key = ThreadMessagesReceiptJournal.actionKey(threadPageId: request.threadPageId, actionId: request.actionId)
        let manifest = ThreadMessagesReceiptJournal.manifestFingerprint(
            request: request, person: person, canonicalRecipient: canonicalRecipient
        )
        let leaseToken = dependencies.leaseToken()
        let leaseOwner = request.approvalPrincipal ?? "local"
        var record: ThreadMessagesActionRecord
        do {
            record = try await dependencies.store.claim(
                idempotencyKey: key,
                manifestFingerprint: manifest,
                operationId: dependencies.operationId(),
                leaseOwner: leaseOwner,
                leaseToken: leaseToken,
                leaseDuration: 120
            )
        } catch ThreadMessagesReceiptStoreError.operationActive {
            return .init(outcome: .inProgress, actionId: request.actionId, error: "the same THREAD action is already executing")
        } catch ThreadMessagesReceiptStoreError.idempotencyConflict {
            return blocked(request, "actionId is already bound to a different THREAD, person, target, body, or service")
        } catch {
            return blocked(request, "durable action claim failed: \(error.localizedDescription)")
        }

        if record.stage == .complete {
            return resultFromRecord(record, request: request, outcome: .alreadyCompleted)
        }
        if record.stage == .operatorReview || record.stage == .conflict {
            return .init(
                outcome: .deliveryStateUnknown,
                actionId: request.actionId,
                verified: record.messageRowId != nil,
                messageRowId: record.messageRowId,
                messageGuid: record.messageGuid,
                chatGuid: record.chatGuid,
                messageDate: record.messageDate,
                deliveryReference: record.messageRowId.map { "messages:\($0)" },
                service: record.service,
                lifecycleUnchanged: record.lifecycleUnchanged,
                error: record.lastError ?? "action requires operator review"
            )
        }

        if record.stage != .claimed,
           !ThreadMessagesReceiptJournal.hasIntent(initial.markdown, actionId: request.actionId) {
            record = await markReview(
                record,
                error: "durable action state exists but the THREAD Intent receipt is missing; operator repair is required",
                dependencies: dependencies
            )
            return .init(
                outcome: .deliveryStateUnknown,
                actionId: request.actionId,
                verified: record.messageRowId != nil,
                messageRowId: record.messageRowId,
                messageGuid: record.messageGuid,
                chatGuid: record.chatGuid,
                messageDate: record.messageDate,
                deliveryReference: record.messageRowId.map { "messages:\($0)" },
                service: record.service,
                lifecycleUnchanged: record.lifecycleUnchanged,
                error: record.lastError
            )
        }

        let preparedAt: Date
        let watermark: Int
        if let existingPreparedAt = record.preparedAt, let existingWatermark = record.preSendWatermark {
            preparedAt = existingPreparedAt
            watermark = existingWatermark
        } else {
            do { watermark = try dependencies.currentMaxMessageRowId() }
            catch {
                record = await release(record, dependencies: dependencies)
                return blocked(request, "Could not capture pre-send ROWID watermark: \(error.localizedDescription)")
            }
            preparedAt = dependencies.now()
        }

        if record.stage == .claimed {
            let intent = ThreadMessagesReceiptJournal.intentMarkdown(
                request: request, snapshot: initial, preparedAt: preparedAt, preSendWatermark: watermark
            )
            do {
                try await dependencies.appendMarkdown(request.threadPageId, intent)
                let prepared = try await dependencies.readThread(request.threadPageId)
                guard ThreadMessagesReceiptJournal.hasIntent(prepared.markdown, actionId: request.actionId),
                      ThreadMessagesReceiptJournal.requestMatchesExisting(
                        prepared.markdown,
                        actionId: request.actionId,
                        recipient: request.recipient,
                        body: request.body,
                        person: person
                      ) else { throw ThreadMessagesReceiptInternalError.readBackMissing }
                record.preparedAt = preparedAt
                record.preSendWatermark = watermark
                record.stage = .intentPersisted
                record = try await dependencies.store.save(record)
            } catch {
                record = await release(record, dependencies: dependencies)
                return .init(
                    outcome: .intentWriteFailed,
                    actionId: request.actionId,
                    repairMarkdown: intent,
                    error: error.localizedDescription
                )
            }
        }

        var verification: MessagesDeliveryVerification?
        var deliveryInvoked = false

        if record.stage == .localRecordVerified || record.stage == .resultPersisted {
            verification = verificationFromRecord(record)
        } else if record.stage == .deliveryInvoking {
            let reconciled = dependencies.reconcile(request.recipient, request.body, watermark, preparedAt)
            switch reconciled.status {
            case .verified:
                verification = reconciled
                record = apply(reconciled, to: record)
                record.stage = .localRecordVerified
                do { record = try await dependencies.store.save(record) }
                catch { return blocked(request, "could not persist recovered local record evidence: \(error.localizedDescription)") }
            case .ambiguous:
                record = await markReview(record, error: "reconciliation matched multiple local outbound records", dependencies: dependencies)
                return .init(outcome: .ambiguous, actionId: request.actionId, error: record.lastError)
            case .notFound:
                record = await markReview(record, error: "delivery invocation may have occurred but no exact local outbound record is provable", dependencies: dependencies)
                return .init(outcome: .deliveryStateUnknown, actionId: request.actionId, error: record.lastError)
            case .deliveryError:
                record = await markReview(record, error: reconciled.error ?? "reconciliation failed", dependencies: dependencies)
                return .init(outcome: .deliveryError, actionId: request.actionId, error: record.lastError)
            }
        } else {
            let beforeConsequence: ThreadMessagesSnapshot
            do { beforeConsequence = try await dependencies.readThread(request.threadPageId) }
            catch {
                record = await markReview(record, error: "pre-send authorization re-read failed: \(error.localizedDescription)", dependencies: dependencies)
                return blocked(request, record.lastError ?? "pre-send authorization re-read failed")
            }
            let authorizationError = validateSameAuthorization(
                initial: initial,
                current: beforeConsequence,
                canonicalRecipient: canonicalRecipient
            )
            guard authorizationError == nil else {
                record = await markReview(record, error: authorizationError!, dependencies: dependencies)
                return blocked(request, authorizationError!)
            }

            record.stage = .deliveryInvoking
            do { record = try await dependencies.store.save(record) }
            catch {
                record = await release(record, dependencies: dependencies)
                return blocked(request, "could not fence delivery invocation: \(error.localizedDescription)")
            }

            let attempt = dependencies.send(
                request.recipient,
                request.body,
                request.confirm,
                request.serviceOverride,
                watermark,
                preparedAt
            )
            deliveryInvoked = attempt.invoked
            switch attempt.verification.status {
            case .verified:
                verification = attempt.verification
                record = apply(attempt.verification, to: record)
                record.service = attempt.service ?? attempt.verification.service
                record.stage = .localRecordVerified
                do { record = try await dependencies.store.save(record) }
                catch {
                    record = await release(record, dependencies: dependencies)
                    return .init(
                        outcome: .deliveryStateUnknown,
                        actionId: request.actionId,
                        deliveryInvoked: attempt.invoked,
                        verified: true,
                        messageRowId: attempt.verification.messageRowId,
                        messageGuid: attempt.verification.messageGuid,
                        chatGuid: attempt.verification.chatGuid,
                        messageDate: attempt.verification.messageDate,
                        deliveryReference: attempt.verification.deliveryReference,
                        service: attempt.service,
                        error: "local record verified but durable evidence save failed: \(error.localizedDescription)"
                    )
                }
            case .ambiguous:
                record = await markReview(record, error: "delivery invoked but multiple exact local records matched", dependencies: dependencies)
                return .init(outcome: .ambiguous, actionId: request.actionId, deliveryInvoked: attempt.invoked, error: record.lastError)
            case .notFound:
                record = await markReview(record, error: "delivery invoked but no exact local outbound record was proven", dependencies: dependencies)
                return .init(outcome: .deliveryStateUnknown, actionId: request.actionId, deliveryInvoked: attempt.invoked, error: record.lastError)
            case .deliveryError:
                record = await markReview(record, error: attempt.error ?? attempt.verification.error ?? "delivery failed", dependencies: dependencies)
                return .init(outcome: .deliveryError, actionId: request.actionId, deliveryInvoked: attempt.invoked, error: record.lastError)
            }
        }

        guard let verification, verification.verified else {
            record = await markReview(record, error: "local outbound record evidence is missing", dependencies: dependencies)
            return .init(outcome: .deliveryStateUnknown, actionId: request.actionId, error: record.lastError)
        }

        let afterDelivery: ThreadMessagesSnapshot
        do { afterDelivery = try await dependencies.readThread(request.threadPageId) }
        catch {
            record = await release(record, dependencies: dependencies)
            return .init(
                outcome: .deliveredReceiptWriteFailed,
                actionId: request.actionId,
                deliveryInvoked: deliveryInvoked,
                verified: true,
                messageRowId: verification.messageRowId,
                messageGuid: verification.messageGuid,
                chatGuid: verification.chatGuid,
                messageDate: verification.messageDate,
                deliveryReference: verification.deliveryReference,
                service: record.service,
                error: "local record verified but lifecycle read-back failed: \(error.localizedDescription)"
            )
        }
        let unchanged = lifecycleUnchanged(initial, afterDelivery)
        let resultMarkdown = ThreadMessagesReceiptJournal.resultMarkdown(
            request: request,
            snapshotAfter: afterDelivery,
            verification: verification,
            service: record.service,
            completedAt: dependencies.now(),
            lifecycleUnchanged: unchanged,
            recoveryNote: deliveryInvoked
                ? "Local outbound record verified after guarded delivery."
                : "Recovered from durable invocation state; no resend performed."
        )

        do {
            if record.stage != .resultPersisted {
                try await dependencies.appendMarkdown(request.threadPageId, resultMarkdown)
                let final = try await dependencies.readThread(request.threadPageId)
                guard ThreadMessagesReceiptJournal.hasResult(final.markdown, actionId: request.actionId),
                      ThreadMessagesReceiptJournal.requestMatchesExisting(
                        final.markdown,
                        actionId: request.actionId,
                        recipient: request.recipient,
                        body: request.body,
                        person: person
                      ),
                      ThreadMessagesReceiptJournal.resultRowId(final.markdown, actionId: request.actionId) == verification.messageRowId else {
                    throw ThreadMessagesReceiptInternalError.readBackMissing
                }
                record.lifecycleUnchanged = lifecycleUnchanged(initial, final)
                record.stage = .resultPersisted
                record = try await dependencies.store.save(record)
            }
            record.stage = .complete
            record = try await dependencies.store.save(record)
            _ = try? await dependencies.store.release(record)
            return resultFromRecord(
                record,
                request: request,
                outcome: record.lifecycleUnchanged == false ? .lifecycleDrift : .verified,
                deliveryInvoked: deliveryInvoked
            )
        } catch {
            record = await release(record, dependencies: dependencies)
            return .init(
                outcome: .deliveredReceiptWriteFailed,
                actionId: request.actionId,
                deliveryInvoked: deliveryInvoked,
                verified: true,
                messageRowId: verification.messageRowId,
                messageGuid: verification.messageGuid,
                chatGuid: verification.chatGuid,
                messageDate: verification.messageDate,
                deliveryReference: verification.deliveryReference,
                service: record.service,
                lifecycleUnchanged: unchanged,
                repairMarkdown: resultMarkdown,
                error: error.localizedDescription
            )
        }
    }

    private static func validateAuthorization(snapshot: ThreadMessagesSnapshot, canonicalRecipient: String) -> String? {
        guard snapshot.canonicalThreadSource else { return "page is not in canonical THREADS data source" }
        guard snapshot.linkedPersonCount == 1, let person = snapshot.linkedPerson else {
            return "THREAD must resolve exactly one CONTACT or PROSPECT"
        }
        guard ["Act-with-GO", "Act"].contains(snapshot.managerMode) else {
            return "Manager Mode \(snapshot.managerMode) does not permit delivery"
        }
        guard person.authorizedHandles.contains(canonicalRecipient) else {
            return "recipient is not an authorized phone or email on the THREAD-linked \(person.entity)"
        }
        return ""
    }

    private static func validateSameAuthorization(
        initial: ThreadMessagesSnapshot,
        current: ThreadMessagesSnapshot,
        canonicalRecipient: String
    ) -> String? {
        guard validateAuthorization(snapshot: current, canonicalRecipient: canonicalRecipient) == "" else {
            return validateAuthorization(snapshot: current, canonicalRecipient: canonicalRecipient)
        }
        guard current.managerMode == initial.managerMode else { return "Manager Mode changed after Intent preparation" }
        guard current.linkedPerson?.entity == initial.linkedPerson?.entity,
              current.linkedPerson?.pageId == initial.linkedPerson?.pageId else {
            return "THREAD linked person changed after Intent preparation"
        }
        return nil
    }

    private static func lifecycleUnchanged(_ before: ThreadMessagesSnapshot, _ after: ThreadMessagesSnapshot) -> Bool {
        before.lifecycleFingerprint == after.lifecycleFingerprint
    }

    private static func apply(_ verification: MessagesDeliveryVerification, to record: ThreadMessagesActionRecord) -> ThreadMessagesActionRecord {
        var next = record
        next.messageRowId = verification.messageRowId
        next.messageGuid = verification.messageGuid
        next.chatGuid = verification.chatGuid
        next.messageDate = verification.messageDate
        next.service = verification.service ?? record.service
        return next
    }

    private static func verificationFromRecord(_ record: ThreadMessagesActionRecord) -> MessagesDeliveryVerification {
        .init(
            status: record.messageRowId == nil ? .notFound : .verified,
            messageRowId: record.messageRowId,
            messageGuid: record.messageGuid,
            chatGuid: record.chatGuid,
            messageDate: record.messageDate,
            service: record.service,
            verifiedAt: record.updatedAt,
            candidateRowIds: record.messageRowId.map { [$0] } ?? []
        )
    }

    private static func resultFromRecord(
        _ record: ThreadMessagesActionRecord,
        request: ThreadMessagesReceiptRequest,
        outcome: ThreadMessagesReceiptOutcome,
        deliveryInvoked: Bool = false
    ) -> ThreadMessagesReceiptResult {
        .init(
            outcome: outcome,
            actionId: request.actionId,
            deliveryInvoked: deliveryInvoked,
            verified: record.messageRowId != nil,
            messageRowId: record.messageRowId,
            messageGuid: record.messageGuid,
            chatGuid: record.chatGuid,
            messageDate: record.messageDate,
            deliveryReference: record.messageRowId.map { "messages:\($0)" },
            service: record.service,
            lifecycleUnchanged: record.lifecycleUnchanged,
            error: record.lastError
        )
    }

    private static func markReview(
        _ record: ThreadMessagesActionRecord,
        error: String,
        dependencies: ThreadMessagesReceiptDependencies
    ) async -> ThreadMessagesActionRecord {
        var next = record
        next.stage = .operatorReview
        next.lastError = error
        let saved = (try? await dependencies.store.save(next)) ?? next
        return await release(saved, dependencies: dependencies)
    }

    private static func release(
        _ record: ThreadMessagesActionRecord,
        dependencies: ThreadMessagesReceiptDependencies
    ) async -> ThreadMessagesActionRecord {
        (try? await dependencies.store.release(record)) ?? record
    }

    private static func blocked(_ request: ThreadMessagesReceiptRequest, _ error: String) -> ThreadMessagesReceiptResult {
        .init(outcome: .blocked, actionId: request.actionId, error: error)
    }
}

private enum ThreadMessagesReceiptInternalError: LocalizedError {
    case readBackMissing
    var errorDescription: String? { "THREAD journal append was not present or did not match on read-back" }
}
