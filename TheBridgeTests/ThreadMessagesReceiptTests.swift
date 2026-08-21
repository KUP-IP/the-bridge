// ThreadMessagesReceiptTests.swift — hardened exact-action THREAD Messages M1

import Foundation
import MCP
import TheBridgeLib

private enum ThreadReceiptTestError: Error { case forcedAppendFailure }

private final class ThreadReceiptHarness: @unchecked Sendable {
    private let lock = NSLock()
    let store: SQLiteThreadMessagesReceiptStore
    var markdown = "# Existing THREAD"
    var managerMode = "Act-with-GO"
    var status: String? = "Open"
    var nextCheckIn: String? = "2026-07-24T15:00:00.000Z"
    var canonical = true
    var person = ThreadLinkedPersonSnapshot(
        entity: "contact",
        pageId: "person-1",
        name: "Alice Example",
        status: "Reach",
        phone: "+16055550123",
        email: "alice@example.com",
        nextAction: "Follow up",
        lastActivity: "2026-07-20"
    )
    var linkedPersonCount = 1
    var watermark = 40
    var reconcileResult = MessagesDeliveryVerification(status: .notFound)
    var sendResult = MessagesDeliveryAttempt(
        invoked: true,
        verification: .init(
            status: .verified,
            messageRowId: 41,
            messageGuid: "msg-guid-41",
            chatGuid: "chat-guid-1",
            messageDate: Date(timeIntervalSince1970: 190),
            service: "iMessage",
            verifiedAt: Date(timeIntervalSince1970: 200)
        ),
        service: "iMessage"
    )
    var failAppendNumber: Int?
    var intentAppendDelay: TimeInterval = 0
    var revokeManagerModeOnReadNumber: Int?
    var replacePersonOnReadNumber: Int?
    var mutateLifecycleOnSend = false
    private(set) var appendCount = 0
    private(set) var sendCount = 0
    private(set) var readCount = 0

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-m1-tests-\(UUID().uuidString)", isDirectory: true)
        store = try SQLiteThreadMessagesReceiptStore(
            url: dir.appendingPathComponent("actions.sqlite", isDirectory: false)
        )
    }

    func snapshot(pageId: String) -> ThreadMessagesSnapshot {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        if revokeManagerModeOnReadNumber == readCount { managerMode = "Off" }
        if replacePersonOnReadNumber == readCount {
            person = .init(
                entity: "contact",
                pageId: "person-2",
                name: "Bob Example",
                status: "Reach",
                phone: "+16055550999",
                email: "bob@example.com"
            )
        }
        return .init(
            pageId: pageId,
            canonicalThreadSource: canonical,
            managerMode: managerMode,
            status: status,
            nextCheckIn: nextCheckIn,
            linkedPerson: linkedPersonCount == 1 ? person : nil,
            linkedPersonCount: linkedPersonCount,
            markdown: markdown
        )
    }

    func append(_ value: String) throws {
        lock.lock()
        appendCount += 1
        let number = appendCount
        lock.unlock()
        if number == 1, intentAppendDelay > 0 { Thread.sleep(forTimeInterval: intentAppendDelay) }
        lock.lock(); defer { lock.unlock() }
        if failAppendNumber == number { throw ThreadReceiptTestError.forcedAppendFailure }
        markdown += value
    }

    func send() -> MessagesDeliveryAttempt {
        lock.lock(); defer { lock.unlock() }
        sendCount += 1
        if mutateLifecycleOnSend {
            person.status = "Waiting"
            person.nextAction = "Await reply"
        }
        return sendResult
    }

    func dependencies() -> ThreadMessagesReceiptDependencies {
        .init(
            store: store,
            readThread: { [self] pageId in snapshot(pageId: pageId) },
            appendMarkdown: { [self] _, value in try append(value) },
            currentMaxMessageRowId: { [self] in watermark },
            reconcile: { [self] _, _, _, _ in reconcileResult },
            send: { [self] _, _, _, _, _, _ in send() },
            now: { Date(timeIntervalSince1970: 200) },
            operationId: { UUID().uuidString },
            leaseToken: { UUID().uuidString }
        )
    }
}

private func receiptRequest(
    actionId: String = "act-1",
    recipient: String = "+16055550123",
    body: String = "Approved body",
    service: String? = "iMessage"
) -> ThreadMessagesReceiptRequest {
    .init(
        threadPageId: "thread-page",
        actionId: actionId,
        recipient: recipient,
        body: body,
        approvalBasis: "Fresh Bridge approval prompt",
        confirm: "SEND",
        serviceOverride: service,
        approvalReceiptId: "approval-1",
        approvalArgumentsDigest: "digest-1",
        approvalPrincipal: "session-1",
        approvedAt: Date(timeIntervalSince1970: 180)
    )
}

private func seedDeliveryInvoking(
    request: ThreadMessagesReceiptRequest,
    harness: ThreadReceiptHarness,
    preparedAt: Date = Date(timeIntervalSince1970: 180),
    watermark: Int = 100
) async throws {
    let snapshot = harness.snapshot(pageId: request.threadPageId)
    guard let person = snapshot.linkedPerson,
          let target = ThreadMessagesIdentity.canonicalHandle(request.recipient) else {
        throw TestError.assertion("seed identity missing")
    }
    harness.markdown += ThreadMessagesReceiptJournal.intentMarkdown(
        request: request,
        snapshot: snapshot,
        preparedAt: preparedAt,
        preSendWatermark: watermark
    )
    var record = try await harness.store.claim(
        idempotencyKey: ThreadMessagesReceiptJournal.actionKey(
            threadPageId: request.threadPageId,
            actionId: request.actionId
        ),
        manifestFingerprint: ThreadMessagesReceiptJournal.manifestFingerprint(
            request: request,
            person: person,
            canonicalRecipient: target
        ),
        operationId: "seed-operation",
        leaseOwner: "seed",
        leaseToken: "seed-token",
        leaseDuration: 60
    )
    record.preparedAt = preparedAt
    record.preSendWatermark = watermark
    record.stage = .deliveryInvoking
    record = try await harness.store.save(record)
    _ = try await harness.store.release(record)
}

func runThreadMessagesReceiptTests() async {
    print("\n🧾 THREAD Messages Receipt Tests")

    await test("approval receipt digest binds the complete arguments") {
        let a: Value = .object([
            "recipient": .string("+16055550123"),
            "body": .string("Approved body"),
            "confirm": .string("SEND")
        ])
        let b: Value = .object([
            "confirm": .string("SEND"),
            "body": .string("Approved body"),
            "recipient": .string("+16055550123")
        ])
        let changed: Value = .object([
            "recipient": .string("+16055550123"),
            "body": .string("Changed body"),
            "confirm": .string("SEND")
        ])
        try expect(SecurityApprovalReceipt.digest(a) == SecurityApprovalReceipt.digest(b))
        try expect(SecurityApprovalReceipt.digest(a) != SecurityApprovalReceipt.digest(changed))
    }

    await test("delivery classifier returns exact local row GUID and chat evidence") {
        let rows: [[String: Any]] = [[
            "ROWID": 77,
            "message_guid": "msg-77",
            "chat_guid": "iMessage;-;+16055550123",
            "message_unix_seconds": 190.0,
            "text": "Approved body",
            "is_from_me": 1,
            "service": "iMessage",
            "handle_id": "+1 (605) 555-0123",
            "chat_identifier": "+16055550123"
        ]]
        let result = MessagesModule.classifyDeliveryCandidates(
            rows,
            expectedTarget: "+16055550123",
            expectedBody: "Approved body",
            verifiedAt: Date(timeIntervalSince1970: 200)
        )
        try expect(result.status == .verified)
        try expect(result.messageRowId == 77)
        try expect(result.messageGuid == "msg-77")
        try expect(result.chatGuid == "iMessage;-;+16055550123")
        try expect(result.messageDate == Date(timeIntervalSince1970: 190))
    }

    await test("delivery classifier refuses short substrings and wrong targets") {
        let rows: [[String: Any]] = [[
            "ROWID": 78,
            "text": "Approved body",
            "is_from_me": 1,
            "handle_id": "+16055550123",
            "chat_identifier": "+16055550123"
        ]]
        let malformed = MessagesModule.classifyDeliveryCandidates(
            rows,
            expectedTarget: "5550123",
            expectedBody: "Approved body"
        )
        let wrong = MessagesModule.classifyDeliveryCandidates(
            rows,
            expectedTarget: "+16055559999",
            expectedBody: "Approved body"
        )
        try expect(malformed.status == .notFound)
        try expect(wrong.status == .notFound)
    }

    await test("delivery classifier supports exact existing group identifiers without substring matching") {
        let rows: [[String: Any]] = [[
            "ROWID": 79,
            "text": "Approved group body",
            "is_from_me": 1,
            "chat_identifier": "group-identifier-1",
            "chat_guid": "iMessage;+;group-guid-1",
            "display_name": "Project Team"
        ]]
        let exact = MessagesModule.classifyDeliveryCandidates(
            rows,
            expectedTarget: "Project Team",
            expectedBody: "Approved group body"
        )
        let partial = MessagesModule.classifyDeliveryCandidates(
            rows,
            expectedTarget: "Project",
            expectedBody: "Approved group body"
        )
        try expect(exact.status == .verified)
        try expect(partial.status == .notFound)
    }

    await test("delivery classifier deduplicates joins and fails closed on distinct matches") {
        let row: [String: Any] = [
            "ROWID": 80,
            "text": "Approved body",
            "is_from_me": 1,
            "handle_id": "+16055550123",
            "chat_identifier": "+16055550123"
        ]
        let duplicate = MessagesModule.classifyDeliveryCandidates(
            [row, row], expectedTarget: "+16055550123", expectedBody: "Approved body"
        )
        var second = row
        second["ROWID"] = 81
        let ambiguous = MessagesModule.classifyDeliveryCandidates(
            [row, second], expectedTarget: "+16055550123", expectedBody: "Approved body"
        )
        try expect(duplicate.status == .verified)
        try expect(duplicate.messageRowId == 80)
        try expect(ambiguous.status == .ambiguous)
        try expect(ambiguous.candidateRowIds == [80, 81])
    }

    await test("THREAD parser and Registry enrichment bind one exact person") {
        let properties = """
        {
          "Manager Mode":{"type":"select","select":{"name":"Act-with-GO"}},
          "Status":{"type":"status","status":{"name":"Waiting"}},
          "Next Check-in":{"type":"date","date":{"start":"2026-07-25T10:00:00.000Z"}},
          "CONTACT":{"type":"relation","relation":[{"id":"person-1"}]},
          "PROSPECT":{"type":"relation","relation":[]}
        }
        """
        let parent = "{\"type\":\"data_source_id\",\"data_source_id\":\"a7bd89e9-375a-47bc-875e-706b7b0f2dc0\"}"
        let parsed = try MessagesModule.threadSnapshot(
            pageResult: .object([
                "id": .string("thread-1"),
                "properties": .string(properties),
                "parent": .string(parent)
            ]),
            markdownResult: .object(["markdown": .string("# Thread")])
        )
        let enriched = try MessagesModule.enrichThreadSnapshot(
            parsed,
            registryResult: .object([
                "entity": .string("contact"),
                "id": .string("person-1"),
                "title": .string("Alice Example"),
                "properties": .object([
                    "status": .string("Reach"),
                    "phone": .string("+16055550123"),
                    "email": .string("alice@example.com"),
                    "nextAction": .string("Follow up"),
                    "lastContacted": .string("2026-07-20")
                ])
            ])
        )
        try expect(enriched.canonicalThreadSource)
        try expect(enriched.linkedPerson?.entity == "contact")
        try expect(enriched.linkedPerson?.pageId == "person1")
        try expect(enriched.linkedPerson?.authorizedHandles.contains("+16055550123") == true)
    }

    await test("wrong-person recipient blocks before Intent, claim, or send") {
        let harness = try ThreadReceiptHarness()
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(recipient: "+16055550999"),
            dependencies: harness.dependencies()
        )
        try expect(result.outcome == .blocked)
        try expect(harness.appendCount == 0)
        try expect(harness.sendCount == 0)
    }

    await test("Manager Mode Off blocks before Intent or send") {
        let harness = try ThreadReceiptHarness()
        harness.managerMode = "Off"
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(), dependencies: harness.dependencies()
        )
        try expect(result.outcome == .blocked)
        try expect(harness.appendCount == 0)
        try expect(harness.sendCount == 0)
    }

    await test("missing explicit service blocks before THREAD read, Intent, claim, or send") {
        let harness = try ThreadReceiptHarness()
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(actionId: "missing-service-1", service: nil),
            dependencies: harness.dependencies()
        )
        try expect(result.outcome == .blocked)
        try expect(result.error?.contains("explicit service") == true)
        try expect(harness.readCount == 0)
        try expect(harness.appendCount == 0)
        try expect(harness.sendCount == 0)
    }

    await test("observed local-record service mismatch fails closed after one invocation") {
        let harness = try ThreadReceiptHarness()
        harness.sendResult = .init(
            invoked: true,
            verification: .init(
                status: .verified,
                messageRowId: 42,
                messageGuid: "msg-guid-42",
                chatGuid: "chat-guid-2",
                messageDate: Date(timeIntervalSince1970: 190),
                service: "SMS",
                verifiedAt: Date(timeIntervalSince1970: 200)
            ),
            service: "iMessage"
        )
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(actionId: "service-mismatch-1"),
            dependencies: harness.dependencies()
        )
        try expect(result.outcome == .deliveryStateUnknown)
        try expect(result.error?.contains("service") == true)
        try expect(harness.sendCount == 1)
        try expect(harness.appendCount == 1, "Result must not be written for mismatched service evidence")
    }

    await test("claimed ledger plus existing Intent blocks duplicate Intent and possible resend") {
        let harness = try ThreadReceiptHarness()
        let request = receiptRequest(actionId: "claimed-intent-1")
        let snapshot = harness.snapshot(pageId: request.threadPageId)
        guard let person = snapshot.linkedPerson,
              let target = ThreadMessagesIdentity.canonicalHandle(request.recipient) else {
            throw TestError.assertion("seed identity missing")
        }
        harness.markdown += ThreadMessagesReceiptJournal.intentMarkdown(
            request: request,
            snapshot: snapshot,
            preparedAt: Date(timeIntervalSince1970: 180),
            preSendWatermark: 40
        )
        let claimed = try await harness.store.claim(
            idempotencyKey: ThreadMessagesReceiptJournal.actionKey(
                threadPageId: request.threadPageId,
                actionId: request.actionId
            ),
            manifestFingerprint: ThreadMessagesReceiptJournal.manifestFingerprint(
                request: request,
                person: person,
                canonicalRecipient: target
            ),
            operationId: "seed-claimed-intent",
            leaseOwner: "seed",
            leaseToken: "seed-token",
            leaseDuration: 60
        )
        _ = try await harness.store.release(claimed)

        let result = await ThreadMessagesReceiptEngine.execute(
            request: request,
            dependencies: harness.dependencies()
        )
        try expect(result.outcome == .deliveryStateUnknown)
        try expect(result.error?.contains("duplicate Intent") == true)
        try expect(harness.appendCount == 0)
        try expect(harness.sendCount == 0)
    }

    await test("operatorReview reconciles a matching existing Result without resend or duplicate append") {
        let harness = try ThreadReceiptHarness()
        let request = receiptRequest(actionId: "operator-recover-1")
        harness.sendResult = .init(
            invoked: true,
            verification: .init(status: .notFound),
            service: "iMessage"
        )
        let first = await ThreadMessagesReceiptEngine.execute(
            request: request,
            dependencies: harness.dependencies()
        )
        try expect(first.outcome == .deliveryStateUnknown)
        try expect(harness.sendCount == 1)
        try expect(harness.appendCount == 1)

        let verification = MessagesDeliveryVerification(
            status: .verified,
            messageRowId: 41,
            messageGuid: "msg-guid-41",
            chatGuid: "chat-guid-1",
            messageDate: Date(timeIntervalSince1970: 190),
            service: "iMessage",
            verifiedAt: Date(timeIntervalSince1970: 200)
        )
        harness.reconcileResult = verification
        let after = harness.snapshot(pageId: request.threadPageId)
        harness.markdown += ThreadMessagesReceiptJournal.resultMarkdown(
            request: request,
            snapshotAfter: after,
            verification: verification,
            service: "iMessage",
            completedAt: Date(timeIntervalSince1970: 200),
            lifecycleUnchanged: true,
            recoveryNote: "Exact one-row operator-review reconciliation; no resend performed."
        )

        let second = await ThreadMessagesReceiptEngine.execute(
            request: request,
            dependencies: harness.dependencies()
        )
        try expect(second.outcome == .verified)
        try expect(second.messageRowId == 41)
        try expect(harness.sendCount == 1, "operatorReview recovery must never resend")
        try expect(harness.appendCount == 1, "matching Result must be adopted without a duplicate append")
        let stored = try await harness.store.get(
            idempotencyKey: ThreadMessagesReceiptJournal.actionKey(
                threadPageId: request.threadPageId,
                actionId: request.actionId
            )
        )
        try expect(stored?.stage == .complete)
    }

    await test("Intent append failure blocks external delivery") {
        let harness = try ThreadReceiptHarness()
        harness.failAppendNumber = 1
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(), dependencies: harness.dependencies()
        )
        try expect(result.outcome == .intentWriteFailed)
        try expect(harness.sendCount == 0)
        try expect(result.repairMarkdown?.contains("THREAD ACTION INTENT") == true)
    }

    await test("authorization revocation after Intent blocks before consequence") {
        let harness = try ThreadReceiptHarness()
        harness.revokeManagerModeOnReadNumber = 3
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(actionId: "revoke-1"), dependencies: harness.dependencies()
        )
        try expect(result.outcome == .blocked)
        try expect(harness.appendCount == 1)
        try expect(harness.sendCount == 0)
    }

    await test("linked-person replacement after Intent blocks before consequence") {
        let harness = try ThreadReceiptHarness()
        harness.replacePersonOnReadNumber = 3
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(actionId: "replace-1"), dependencies: harness.dependencies()
        )
        try expect(result.outcome == .blocked)
        try expect(harness.appendCount == 1)
        try expect(harness.sendCount == 0)
    }

    await test("successful action writes Intent and Result with local-only evidence") {
        let harness = try ThreadReceiptHarness()
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(), dependencies: harness.dependencies()
        )
        try expect(result.outcome == .verified)
        try expect(result.messageRowId == 41)
        try expect(result.messageGuid == "msg-guid-41")
        try expect(result.chatGuid == "chat-guid-1")
        try expect(result.lifecycleUnchanged == true)
        try expect(harness.sendCount == 1)
        try expect(harness.appendCount == 2)
        try expect(harness.markdown.contains("Provider delivery confirmed: false"))
        try expect(harness.markdown.contains("Approval receipt ID: approval-1"))
    }

    await test("completed durable action is idempotent and never resends") {
        let harness = try ThreadReceiptHarness()
        let request = receiptRequest(actionId: "done-1")
        let first = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        let second = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try expect(first.outcome == .verified)
        try expect(second.outcome == .alreadyCompleted)
        try expect(second.messageRowId == 41)
        try expect(harness.sendCount == 1)
        try expect(harness.appendCount == 2)
    }

    await test("same actionId rejects changed body through manifest binding") {
        let harness = try ThreadReceiptHarness()
        let original = receiptRequest(actionId: "bound-1")
        _ = await ThreadMessagesReceiptEngine.execute(request: original, dependencies: harness.dependencies())
        let changed = receiptRequest(actionId: "bound-1", body: "Changed body")
        let result = await ThreadMessagesReceiptEngine.execute(request: changed, dependencies: harness.dependencies())
        try expect(result.outcome == .blocked)
        try expect(harness.sendCount == 1)
    }

    await test("durable delivery-invoking recovery reconciles without resend") {
        let harness = try ThreadReceiptHarness()
        let request = receiptRequest(actionId: "recover-1")
        try await seedDeliveryInvoking(request: request, harness: harness)
        harness.reconcileResult = .init(
            status: .verified,
            messageRowId: 101,
            messageGuid: "msg-101",
            chatGuid: "chat-101",
            messageDate: Date(timeIntervalSince1970: 190),
            service: "iMessage",
            verifiedAt: Date(timeIntervalSince1970: 200)
        )
        let result = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try expect(result.outcome == .verified)
        try expect(result.messageRowId == 101)
        try expect(harness.sendCount == 0)
        try expect(harness.appendCount == 1)
    }

    await test("durable recovery refuses a missing THREAD Intent receipt") {
        let harness = try ThreadReceiptHarness()
        let request = receiptRequest(actionId: "missing-intent-1")
        try await seedDeliveryInvoking(request: request, harness: harness)
        harness.markdown = "# Existing THREAD"
        harness.reconcileResult = .init(
            status: .verified,
            messageRowId: 102,
            messageGuid: "msg-102",
            chatGuid: "chat-102",
            messageDate: Date(timeIntervalSince1970: 190),
            service: "iMessage"
        )
        let result = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try expect(result.outcome == .deliveryStateUnknown)
        try expect(result.error?.contains("Intent receipt is missing") == true)
        try expect(harness.sendCount == 0)
        try expect(harness.appendCount == 0)
    }

    await test("delivery-invoking no-match requires operator review without resend") {
        let harness = try ThreadReceiptHarness()
        let request = receiptRequest(actionId: "unknown-1")
        try await seedDeliveryInvoking(request: request, harness: harness)
        harness.reconcileResult = .init(status: .notFound)
        let result = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try expect(result.outcome == .deliveryStateUnknown)
        try expect(harness.sendCount == 0)
        try expect(harness.appendCount == 0)
    }

    await test("concurrent duplicate action produces one consequence") {
        let harness = try ThreadReceiptHarness()
        harness.intentAppendDelay = 0.20
        let request = receiptRequest(actionId: "concurrent-1")
        async let first = ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try? await Task.sleep(for: .milliseconds(20))
        async let second = ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        let results = await [first, second]
        try expect(results.contains(where: { $0.outcome == .verified }))
        try expect(results.contains(where: { $0.outcome == .inProgress || $0.outcome == .alreadyCompleted }))
        try expect(harness.sendCount == 1)
        try expect(harness.appendCount == 2)
    }

    await test("observed person lifecycle drift is reported, not hidden") {
        let harness = try ThreadReceiptHarness()
        harness.mutateLifecycleOnSend = true
        let result = await ThreadMessagesReceiptEngine.execute(
            request: receiptRequest(actionId: "drift-1"), dependencies: harness.dependencies()
        )
        try expect(result.outcome == .lifecycleDrift)
        try expect(result.lifecycleUnchanged == false)
        try expect(harness.sendCount == 1)
    }

    await test("post-send Result failure returns repair payload and does not resend") {
        let harness = try ThreadReceiptHarness()
        harness.failAppendNumber = 2
        let request = receiptRequest(actionId: "repair-1")
        let result = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try expect(result.outcome == .deliveredReceiptWriteFailed)
        try expect(result.verified)
        try expect(result.messageRowId == 41)
        try expect(result.repairMarkdown?.contains("THREAD ACTION RESULT") == true)
        try expect(harness.sendCount == 1)
    }
}
