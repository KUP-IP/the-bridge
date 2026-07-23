// ThreadMessagesReceiptTests.swift — M1 exact delivery + recoverable THREAD journal

import Foundation
import MCP
import TheBridgeLib

private enum ThreadReceiptTestError: Error { case forcedAppendFailure }

private final class ThreadReceiptHarness: @unchecked Sendable {
    private let lock = NSLock()
    var markdown: String
    var managerMode: String
    var status: String?
    var nextCheckIn: String?
    var linkedPersonCount: Int
    var canonical: Bool
    var watermark: Int
    var reconcileResult: MessagesDeliveryVerification
    var sendResult: MessagesDeliveryAttempt
    var failAppendNumber: Int?
    private(set) var appendCount = 0
    private(set) var sendCount = 0

    init(
        markdown: String = "# Existing THREAD",
        managerMode: String = "Act-with-GO",
        status: String? = "Open",
        nextCheckIn: String? = "2026-07-24T15:00:00.000Z",
        linkedPersonCount: Int = 1,
        canonical: Bool = true,
        watermark: Int = 40,
        reconcileResult: MessagesDeliveryVerification = .init(status: .notFound),
        sendResult: MessagesDeliveryAttempt = .init(
            invoked: true,
            verification: .init(status: .verified, messageRowId: 41, service: "iMessage", verifiedAt: Date(timeIntervalSince1970: 100)),
            service: "iMessage"
        )
    ) {
        self.markdown = markdown
        self.managerMode = managerMode
        self.status = status
        self.nextCheckIn = nextCheckIn
        self.linkedPersonCount = linkedPersonCount
        self.canonical = canonical
        self.watermark = watermark
        self.reconcileResult = reconcileResult
        self.sendResult = sendResult
    }

    func snapshot(pageId: String) -> ThreadMessagesSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(
            pageId: pageId,
            canonicalThreadSource: canonical,
            managerMode: managerMode,
            status: status,
            nextCheckIn: nextCheckIn,
            linkedPersonCount: linkedPersonCount,
            markdown: markdown
        )
    }

    func append(_ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        appendCount += 1
        if failAppendNumber == appendCount { throw ThreadReceiptTestError.forcedAppendFailure }
        markdown += value
    }

    func send() -> MessagesDeliveryAttempt {
        lock.lock(); defer { lock.unlock() }
        sendCount += 1
        return sendResult
    }

    func dependencies() -> ThreadMessagesReceiptDependencies {
        .init(
            readThread: { [self] pageId in snapshot(pageId: pageId) },
            appendMarkdown: { [self] _, value in try append(value) },
            currentMaxMessageRowId: { [self] in watermark },
            reconcile: { [self] _, _, _ in reconcileResult },
            send: { [self] _, _, _, _, _ in send() },
            now: { Date(timeIntervalSince1970: 200) }
        )
    }
}

private func receiptRequest(actionId: String = "act-1") -> ThreadMessagesReceiptRequest {
    .init(
        threadPageId: "thread-page",
        actionId: actionId,
        recipient: "+16055550123",
        body: "Approved body",
        approvalBasis: "Operator GO in governed chat",
        confirm: "SEND"
    )
}

func runThreadMessagesReceiptTests() async {
    print("\n🧾 THREAD Messages Receipt Tests")

    await test("delivery classifier returns exact ROWID for one body+target match") {
        let rows: [[String: Any]] = [[
            "ROWID": 77,
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
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        try expect(result.status == .verified)
        try expect(result.messageRowId == 77)
        try expect(result.deliveryReference == "messages:77")
    }

    await test("delivery classifier refuses wrong body or target") {
        let rows: [[String: Any]] = [[
            "ROWID": 78,
            "text": "Different body",
            "is_from_me": 1,
            "handle_id": "+16055550123",
            "chat_identifier": "+16055550123"
        ], [
            "ROWID": 79,
            "text": "Approved body",
            "is_from_me": 1,
            "handle_id": "+16055559999",
            "chat_identifier": "+16055559999"
        ]]
        let result = MessagesModule.classifyDeliveryCandidates(rows, expectedTarget: "+16055550123", expectedBody: "Approved body")
        try expect(result.status == .notFound)
        try expect(result.messageRowId == nil)
    }

    await test("delivery classifier normalizes US 10-digit and +1 handles") {
        let rows: [[String: Any]] = [[
            "ROWID": 79,
            "text": "Approved body",
            "is_from_me": 1,
            "handle_id": "+16055550123",
            "chat_identifier": "+16055550123"
        ]]
        let result = MessagesModule.classifyDeliveryCandidates(rows, expectedTarget: "605-555-0123", expectedBody: "Approved body")
        try expect(result.status == .verified)
        try expect(result.messageRowId == 79)
    }

    await test("delivery classifier deduplicates repeated join rows for one message") {
        let row: [String: Any] = [
            "ROWID": 80,
            "text": "Approved body",
            "is_from_me": 1,
            "handle_id": "+16055550123",
            "chat_identifier": "+16055550123"
        ]
        let result = MessagesModule.classifyDeliveryCandidates([row, row], expectedTarget: "+16055550123", expectedBody: "Approved body")
        try expect(result.status == .verified)
        try expect(result.messageRowId == 80)
    }

    await test("delivery classifier fails closed on multiple exact matches") {
        let rows: [[String: Any]] = [80, 81].map { rowId in [
            "ROWID": rowId,
            "text": "Approved body",
            "is_from_me": 1,
            "handle_id": "+16055550123",
            "chat_identifier": "+16055550123"
        ] }
        let result = MessagesModule.classifyDeliveryCandidates(rows, expectedTarget: "+16055550123", expectedBody: "Approved body")
        try expect(result.status == .ambiguous)
        try expect(result.candidateRowIds == [80, 81])
        try expect(result.messageRowId == nil)
    }

    await test("THREAD snapshot parser enforces live Manager Mode and one linked person") {
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
        let snapshot = try MessagesModule.threadSnapshot(
            pageResult: .object([
                "id": .string("thread-1"),
                "properties": .string(properties),
                "parent": .string(parent)
            ]),
            markdownResult: .object(["markdown": .string("# Thread")])
        )
        try expect(snapshot.canonicalThreadSource)
        try expect(snapshot.managerMode == "Act-with-GO")
        try expect(snapshot.status == "Waiting")
        try expect(snapshot.linkedPersonCount == 1)
    }

    await test("Manager Mode Off blocks before Intent or send") {
        let harness = ThreadReceiptHarness(managerMode: "Off")
        let result = await ThreadMessagesReceiptEngine.execute(request: receiptRequest(), dependencies: harness.dependencies())
        try expect(result.outcome == .blocked)
        try expect(harness.appendCount == 0)
        try expect(harness.sendCount == 0)
    }

    await test("Intent append failure blocks external delivery") {
        let harness = ThreadReceiptHarness()
        harness.failAppendNumber = 1
        let result = await ThreadMessagesReceiptEngine.execute(request: receiptRequest(), dependencies: harness.dependencies())
        try expect(result.outcome == .intentWriteFailed)
        try expect(harness.sendCount == 0)
        try expect(result.repairMarkdown?.contains("THREAD ACTION INTENT") == true)
    }

    await test("completed action is idempotent and never resends") {
        let request = receiptRequest(actionId: "done-1")
        let verification = MessagesDeliveryVerification(
            status: .verified,
            messageRowId: 91,
            service: "iMessage",
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        let resultEntry = ThreadMessagesReceiptJournal.resultMarkdown(
            request: request,
            verification: verification,
            service: "iMessage",
            completedAt: Date(timeIntervalSince1970: 2),
            recoveryNote: "done"
        )
        let harness = ThreadReceiptHarness(markdown: "# Thread\n\(resultEntry)")
        let result = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try expect(result.outcome == .alreadyCompleted)
        try expect(result.messageRowId == 91)
        try expect(harness.sendCount == 0)
        try expect(harness.appendCount == 0)
    }

    await test("completed action rejects changed body under the same actionId") {
        let original = receiptRequest(actionId: "bound-1")
        let verification = MessagesDeliveryVerification(
            status: .verified,
            messageRowId: 92,
            service: "iMessage",
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        let resultEntry = ThreadMessagesReceiptJournal.resultMarkdown(
            request: original,
            verification: verification,
            service: "iMessage",
            completedAt: Date(timeIntervalSince1970: 2),
            recoveryNote: "done"
        )
        let changed = ThreadMessagesReceiptRequest(
            threadPageId: original.threadPageId,
            actionId: original.actionId,
            recipient: original.recipient,
            body: "Changed body",
            approvalBasis: original.approvalBasis,
            confirm: "SEND"
        )
        let harness = ThreadReceiptHarness(markdown: "# Thread\n\(resultEntry)")
        let result = await ThreadMessagesReceiptEngine.execute(request: changed, dependencies: harness.dependencies())
        try expect(result.outcome == .blocked)
        try expect(harness.sendCount == 0)
        try expect(harness.appendCount == 0)
    }

    await test("Intent-only action rejects changed target before reconciliation") {
        let original = receiptRequest(actionId: "bound-2")
        let seed = ThreadMessagesSnapshot(
            pageId: original.threadPageId,
            canonicalThreadSource: true,
            managerMode: "Act-with-GO",
            status: "Open",
            nextCheckIn: nil,
            linkedPersonCount: 1,
            markdown: ""
        )
        let intent = ThreadMessagesReceiptJournal.intentMarkdown(
            request: original,
            snapshot: seed,
            preparedAt: Date(timeIntervalSince1970: 1),
            preSendWatermark: 100
        )
        let changed = ThreadMessagesReceiptRequest(
            threadPageId: original.threadPageId,
            actionId: original.actionId,
            recipient: "+16055550999",
            body: original.body,
            approvalBasis: original.approvalBasis,
            confirm: "SEND"
        )
        let harness = ThreadReceiptHarness(markdown: intent)
        let result = await ThreadMessagesReceiptEngine.execute(request: changed, dependencies: harness.dependencies())
        try expect(result.outcome == .blocked)
        try expect(harness.sendCount == 0)
        try expect(harness.appendCount == 0)
    }

    await test("invalid actionId is blocked before any write or send") {
        let harness = ThreadReceiptHarness()
        let result = await ThreadMessagesReceiptEngine.execute(request: receiptRequest(actionId: "bad\naction"), dependencies: harness.dependencies())
        try expect(result.outcome == .blocked)
        try expect(harness.appendCount == 0)
        try expect(harness.sendCount == 0)
    }

    await test("Intent-only recovery appends Result without resend") {
        let request = receiptRequest(actionId: "recover-1")
        let seed = ThreadMessagesSnapshot(
            pageId: request.threadPageId,
            canonicalThreadSource: true,
            managerMode: "Act-with-GO",
            status: "Waiting",
            nextCheckIn: "2026-07-25T10:00:00.000Z",
            linkedPersonCount: 1,
            markdown: ""
        )
        let intent = ThreadMessagesReceiptJournal.intentMarkdown(
            request: request,
            snapshot: seed,
            preparedAt: Date(timeIntervalSince1970: 1),
            preSendWatermark: 100
        )
        let harness = ThreadReceiptHarness(
            markdown: intent,
            status: "Waiting",
            reconcileResult: .init(status: .verified, messageRowId: 101, service: "SMS", verifiedAt: Date(timeIntervalSince1970: 3))
        )
        let result = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try expect(result.outcome == .verified)
        try expect(result.messageRowId == 101)
        try expect(harness.sendCount == 0)
        try expect(harness.appendCount == 1)
        try expect(harness.markdown.contains(ThreadMessagesReceiptJournal.resultHeading(actionId: request.actionId)))
    }

    await test("Intent-only no-match requires operator decision before resend") {
        let request = receiptRequest(actionId: "unknown-1")
        let seed = ThreadMessagesSnapshot(
            pageId: request.threadPageId,
            canonicalThreadSource: true,
            managerMode: "Act-with-GO",
            status: "Open",
            nextCheckIn: nil,
            linkedPersonCount: 1,
            markdown: ""
        )
        let intent = ThreadMessagesReceiptJournal.intentMarkdown(
            request: request,
            snapshot: seed,
            preparedAt: Date(timeIntervalSince1970: 1),
            preSendWatermark: 110
        )
        let harness = ThreadReceiptHarness(markdown: intent, reconcileResult: .init(status: .notFound))
        let result = await ThreadMessagesReceiptEngine.execute(request: request, dependencies: harness.dependencies())
        try expect(result.outcome == .deliveryStateUnknown)
        try expect(harness.sendCount == 0)
        try expect(harness.appendCount == 0)
    }

    await test("verified delivery writes Intent then Result and preserves lifecycle fields") {
        let harness = ThreadReceiptHarness(status: "Open", nextCheckIn: "2026-07-30T12:00:00.000Z")
        let result = await ThreadMessagesReceiptEngine.execute(request: receiptRequest(), dependencies: harness.dependencies())
        try expect(result.outcome == .verified)
        try expect(result.messageRowId == 41)
        try expect(result.deliveryReference == "messages:41")
        try expect(result.lifecycleUnchanged == true)
        try expect(harness.sendCount == 1)
        try expect(harness.appendCount == 2)
        try expect(harness.markdown.contains("THREAD ACTION INTENT"))
        try expect(harness.markdown.contains("THREAD ACTION RESULT"))
    }

    await test("post-send Result failure returns repair payload and never resends") {
        let harness = ThreadReceiptHarness()
        harness.failAppendNumber = 2
        let result = await ThreadMessagesReceiptEngine.execute(request: receiptRequest(actionId: "repair-1"), dependencies: harness.dependencies())
        try expect(result.outcome == .deliveredReceiptWriteFailed)
        try expect(result.verified)
        try expect(result.messageRowId == 41)
        try expect(result.repairMarkdown?.contains("THREAD ACTION RESULT") == true)
        try expect(harness.sendCount == 1)
    }
}
