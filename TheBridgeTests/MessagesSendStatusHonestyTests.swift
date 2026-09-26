// MessagesSendStatusHonestyTests.swift
// TheBridge · Tests
//
// #302: messages_send must not claim failure when a local outbound row
// correlates after a premature AppleScript/Messages error. `error` is
// claimable send failure only — a string there trips ToolRouter
// dispatchFormatted isError. scriptError / macErrorCode are observational.
// Continuity-dead SMS (empty destination_caller_id + is_sent=0 + error≠0)
// is the exception: sent=false. Does not implement #303 protocol pick.
// No live Messages.app send.

import Foundation
import MCP
import TheBridgeLib

func runMessagesSendStatusHonestyTests() async {
    print("\n📬 Messages send status honesty (#302)")

    final class HonestyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _services: [MessagesService] = []
        private var _verifyCount = 0
        var result = MessagesAppleScriptInvocationResult()
        var verification = MessagesDeliveryVerification(status: .notFound)

        var services: [MessagesService] { lock.withLock { _services } }
        var verifyCount: Int { lock.withLock { _verifyCount } }

        func invoke(_ service: MessagesService, _ recipient: String, _ body: String) -> MessagesAppleScriptInvocationResult {
            lock.withLock { _services.append(service) }
            return result
        }
        func verify(_ recipient: String, _ body: String, _ watermark: Int, _ preparedAt: Date) -> MessagesDeliveryVerification {
            lock.withLock { _verifyCount += 1 }
            return verification
        }
    }

    func hasClaimableError(_ fields: [String: Value]) -> Bool {
        if case .string = fields["error"] { return true }
        return false
    }

    await test("#302 script error + correlated local row is sent true, not a claimable failure") {
        let probe = HonestyProbe()
        probe.result = .init(error: "Messages got an error: failed to send. Try again.", errorNumber: -1708)
        probe.verification = .init(
            status: .verified,
            messageRowId: 54695,
            messageGuid: "msg-guid-54695",
            chatGuid: "any;-;+15551234567",
            service: "iMessage",
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            candidateRowIds: [54695]
        )
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+15551234567",
            body: "hello",
            confirm: "SEND",
            serviceOverride: "iMessage",
            afterId: 54000,
            preparedAt: Date(),
            invoke: probe.invoke,
            verify: probe.verify
        )
        try expect(probe.services == [.iMessage], "must not fall back to SMS after script error")
        try expect(probe.verifyCount == 1)
        try expect(attempt.invoked)
        try expect(attempt.dispatchSucceeded, "correlated local outbound is dispatch success")
        try expect(attempt.verification.verified)
        try expect(attempt.error == nil, "claimable error must be cleared when correlation succeeds")
        try expect(attempt.scriptError?.contains("failed to send") == true)
        try expect(attempt.scriptErrorNumber == -1708)

        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15551234567", body: "hello", attempt: attempt
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let invoked) = fields["deliveryInvoked"],
              case .bool(let correlated) = fields["correlatedLocalRecord"],
              case .bool(let verified) = fields["verified"],
              case .bool(let provider) = fields["providerDeliveryConfirmed"],
              case .bool(let macUi) = fields["macUiMayShowFalseFailure"],
              case .string(let guidance) = fields["agentGuidance"],
              case .string(let scriptError) = fields["scriptError"],
              case .int(let rowId) = fields["messageRowId"] else {
            throw TestError.assertion("expected #302 honesty envelope, got \(fields.keys.sorted())")
        }
        try expect(sent)
        try expect(invoked)
        try expect(correlated)
        try expect(verified)
        try expect(!provider, "local correlation must never flip providerDeliveryConfirmed")
        try expect(macUi)
        try expect(guidance == MessagesModule.correlatedDespiteScriptErrorGuidance)
        try expect(scriptError.contains("failed to send"))
        try expect(rowId == 54695)
        try expect(!hasClaimableError(fields), "MCP error string would mark the tool isError")
    }

    await test("#302 script error + NOT_FOUND stays sent false with claimable error") {
        let probe = HonestyProbe()
        probe.result = .init(error: "Can't get buddy", errorNumber: -1728)
        probe.verification = .init(status: .notFound)
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+15551234567", body: "hello", confirm: "SEND",
            serviceOverride: "SMS", afterId: 1, preparedAt: Date(),
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(probe.services == [.sms])
        try expect(probe.verifyCount == 1)
        try expect(attempt.invoked)
        try expect(!attempt.dispatchSucceeded)
        try expect(attempt.error == "Can't get buddy")
        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15551234567", body: "hello", attempt: attempt
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let correlated) = fields["correlatedLocalRecord"] else {
            throw TestError.assertion("expected unconfirmed-error envelope")
        }
        try expect(!sent)
        try expect(!correlated)
        try expect(hasClaimableError(fields))
        if case .bool(let macUi) = fields["macUiMayShowFalseFailure"] {
            try expect(!macUi, "no local row → do not claim a false Mac UI")
        }
    }

    await test("#302 reconcileInvokedSend discriminator (script × correlation)") {
        let verified = MessagesDeliveryVerification(
            status: .verified,
            messageRowId: 10,
            service: "iMessage",
            macErrorCode: 15,
            macIsDelivered: false
        )
        let notFound = MessagesDeliveryVerification(status: .notFound)
        let scriptFail = MessagesAppleScriptInvocationResult(error: "try again", errorNumber: 8)
        let scriptOK = MessagesAppleScriptInvocationResult()

        let recovered = MessagesModule.reconcileInvokedSend(
            invocation: scriptFail, verification: verified, service: "iMessage"
        )
        try expect(recovered.dispatchSucceeded)
        try expect(recovered.error == nil)
        try expect(recovered.scriptError == "try again")
        try expect(recovered.detectedService == "iMessage")
        try expect(recovered.verification.macErrorCode == 15)
        try expect(recovered.verification.macIsDelivered == false)

        let unconfirmed = MessagesModule.reconcileInvokedSend(
            invocation: scriptFail, verification: notFound, service: "iMessage"
        )
        try expect(!unconfirmed.dispatchSucceeded)
        try expect(unconfirmed.error == "try again")

        let dispatched = MessagesModule.reconcileInvokedSend(
            invocation: scriptOK, verification: notFound, service: "iMessage"
        )
        try expect(dispatched.dispatchSucceeded)
        try expect(dispatched.error == nil)
        try expect(dispatched.scriptError == nil)

        let clean = MessagesModule.reconcileInvokedSend(
            invocation: scriptOK, verification: verified, service: "iMessage"
        )
        try expect(clean.dispatchSucceeded)
        try expect(clean.error == nil)
        try expect(clean.scriptError == nil)
    }

    await test("#302 classifier surfaces Mac error/is_delivered as observability only") {
        let classified = MessagesModule.classifyDeliveryCandidates(
            [[
                "ROWID": 99,
                "is_from_me": 1,
                "text": "hello",
                "handle_id": "+15551234567",
                "chat_identifier": "+15551234567",
                "service": "iMessage",
                "mac_error": 15,
                "mac_is_delivered": 0,
                "message_unix_seconds": 1_800_000_000.0
            ]],
            expectedTarget: "+15551234567",
            expectedBody: "hello"
        )
        try expect(classified.verified)
        try expect(classified.macErrorCode == 15)
        try expect(classified.macIsDelivered == false)
        let attempt = MessagesModule.reconcileInvokedSend(
            invocation: .init(),
            verification: classified,
            service: "iMessage"
        )
        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15551234567", body: "hello", attempt: attempt
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let provider) = fields["providerDeliveryConfirmed"],
              case .int(let macError) = fields["macErrorCode"],
              case .bool(let macDelivered) = fields["macIsDelivered"],
              case .bool(let macUi) = fields["macUiMayShowFalseFailure"] else {
            throw TestError.assertion("expected Mac observability fields")
        }
        try expect(sent)
        try expect(!provider, "mac_is_delivered must not become providerDeliveryConfirmed")
        try expect(macError == 15)
        try expect(!macDelivered)
        try expect(macUi)
        try expect(!hasClaimableError(fields))
    }

    await test("#302 chatIdentifier envelope is honest after script error + local row") {
        let verification = MessagesDeliveryVerification(
            status: .verified,
            messageRowId: 77,
            service: "iMessage"
        )
        let fields = MessagesModule.chatIdentifierSendMCPFields(
            chatIdentifier: "iMessage;-;+15551234567",
            body: "hello",
            verification: verification,
            invocation: .init(error: "failed to send", errorNumber: -1708)
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let correlated) = fields["correlatedLocalRecord"],
              case .bool(let provider) = fields["providerDeliveryConfirmed"] else {
            throw TestError.assertion("expected chatIdentifier honesty envelope")
        }
        try expect(sent)
        try expect(correlated)
        try expect(!provider)
        try expect(!hasClaimableError(fields))
        if case .string(let scriptError) = fields["scriptError"] {
            try expect(scriptError.contains("failed to send"))
        } else {
            throw TestError.assertion("scriptError must remain observational")
        }
    }

    await test("#302 dispatchFormatted isError is false when error is null after correlation") {
        let recovered = MessagesModule.reconcileInvokedSend(
            invocation: .init(error: "try again", errorNumber: 8),
            verification: .init(status: .verified, messageRowId: 12, service: "iMessage"),
            service: "iMessage"
        )
        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15551234567", body: "hello", attempt: recovered
        )
        let structuredFailure: Bool = {
            if case .bool(let success) = fields["success"], success == false { return true }
            if case .string(let status) = fields["status"],
               ["failed", "error", "partial_or_unverified"].contains(status) { return true }
            if case .string = fields["error"] { return true }
            return false
        }()
        try expect(!structuredFailure, "correlated success must not trip MCP isError")
        try expect(fields["scriptError"] != nil)
    }

    await test("#302 catalog documents correlation-after-script-error honesty") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await MessagesModule.register(on: router)
        let send = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }!
        try expect(send.description.localizedCaseInsensitiveContains("do not report send failure"))
        try expect(send.description.localizedCaseInsensitiveContains("scriptError"))
        try expect(send.description.localizedCaseInsensitiveContains("Continuity-dead"))
        try expect(send.description.contains("Does not change host Auto-review"))
        try expect(send.metadata?.whenNotToUse.contains(where: {
            $0.localizedCaseInsensitiveContains("correlatedLocalRecord")
        }) == true)
        try expect(send.metadata?.whenNotToUse.contains(where: {
            $0.localizedCaseInsensitiveContains("destination_caller_id")
        }) == true)
    }

    await test("SMS Continuity-dead signature is sent=false with claimable error") {
        let classified = MessagesModule.classifyDeliveryCandidates(
            [[
                "ROWID": 56550,
                "is_from_me": 1,
                "text": "hello",
                "handle_id": "+15551234567",
                "chat_identifier": "+15551234567",
                "service": "SMS",
                "mac_error": 4,
                "mac_is_delivered": 0,
                "mac_is_sent": 0,
                "destination_caller_id": "",
                "message_unix_seconds": 1_800_000_000.0
            ]],
            expectedTarget: "+15551234567",
            expectedBody: "hello"
        )
        try expect(classified.verified)
        try expect(classified.macErrorCode == 4)
        try expect(classified.macIsSent == false)
        try expect(classified.macIsDelivered == false)
        try expect(classified.destinationCallerIdPresent == false)
        try expect(MessagesModule.smsContinuityHandoffFailed(classified))

        let attempt = MessagesModule.reconcileInvokedSend(
            invocation: .init(),
            verification: classified,
            service: "SMS"
        )
        try expect(!attempt.dispatchSucceeded)
        try expect(attempt.error == MessagesModule.smsContinuityHandoffFailedError)

        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15551234567", body: "hello", attempt: attempt
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let correlated) = fields["correlatedLocalRecord"],
              case .bool(let provider) = fields["providerDeliveryConfirmed"],
              case .bool(let handedOff) = fields["continuityHandoffObserved"],
              case .bool(let destPresent) = fields["destinationCallerIdPresent"],
              case .bool(let macSent) = fields["macIsSent"],
              case .bool(let macUi) = fields["macUiMayShowFalseFailure"],
              case .string(let guidance) = fields["agentGuidance"] else {
            throw TestError.assertion("expected Continuity-dead envelope, got \(fields.keys.sorted())")
        }
        try expect(!sent, "Continuity-dead SMS must not claim sent=true")
        try expect(correlated, "local row still correlates")
        try expect(!provider)
        try expect(!handedOff)
        try expect(!destPresent)
        try expect(!macSent)
        try expect(!macUi, "Not Delivered is a real missed handoff, not a Mac UI lie")
        try expect(guidance == MessagesModule.smsContinuityHandoffFailedGuidance)
        try expect(hasClaimableError(fields))
    }

    await test("SMS dest-present + is_sent=1 keeps #302 sent=true even with mac error") {
        let classified = MessagesModule.classifyDeliveryCandidates(
            [[
                "ROWID": 56454,
                "is_from_me": 1,
                "text": "hello",
                "handle_id": "+15557654321",
                "chat_identifier": "+15557654321",
                "service": "SMS",
                "mac_error": 4,
                "mac_is_delivered": 1,
                "mac_is_sent": 1,
                "destination_caller_id": "+15550001111",
                "message_unix_seconds": 1_800_000_000.0
            ]],
            expectedTarget: "+15557654321",
            expectedBody: "hello"
        )
        try expect(classified.destinationCallerIdPresent == true)
        try expect(classified.macIsSent == true)
        try expect(!MessagesModule.smsContinuityHandoffFailed(classified))

        let attempt = MessagesModule.reconcileInvokedSend(
            invocation: .init(error: "failed to send", errorNumber: -1708),
            verification: classified,
            service: "SMS"
        )
        try expect(attempt.dispatchSucceeded)
        try expect(attempt.error == nil)
        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15557654321", body: "hello", attempt: attempt
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let handedOff) = fields["continuityHandoffObserved"],
              case .bool(let macUi) = fields["macUiMayShowFalseFailure"] else {
            throw TestError.assertion("expected dest-present SMS honesty envelope")
        }
        try expect(sent)
        try expect(handedOff)
        try expect(macUi)
        try expect(!hasClaimableError(fields))
    }

    await test("SMS Continuity helper stays false when dest/is_sent evidence is missing") {
        let incomplete = MessagesDeliveryVerification(
            status: .verified,
            messageRowId: 99,
            service: "SMS",
            macErrorCode: 4,
            macIsDelivered: false
        )
        try expect(!MessagesModule.smsContinuityHandoffFailed(incomplete))
        let iMessageDeadLooking = MessagesDeliveryVerification(
            status: .verified,
            messageRowId: 100,
            service: "iMessage",
            macErrorCode: 4,
            macIsDelivered: false,
            macIsSent: false,
            destinationCallerIdPresent: false
        )
        try expect(!MessagesModule.smsContinuityHandoffFailed(iMessageDeadLooking))
    }

    await test("chatIdentifier SMS Continuity-dead envelope is sent=false") {
        let verification = MessagesDeliveryVerification(
            status: .verified,
            messageRowId: 56549,
            service: "SMS",
            macErrorCode: 3,
            macIsDelivered: false,
            macIsSent: false,
            destinationCallerIdPresent: false
        )
        let fields = MessagesModule.chatIdentifierSendMCPFields(
            chatIdentifier: "SMS;-;+15551234567",
            body: "hello",
            verification: verification,
            invocation: .init()
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let correlated) = fields["correlatedLocalRecord"],
              case .bool(let handedOff) = fields["continuityHandoffObserved"] else {
            throw TestError.assertion("expected chatIdentifier Continuity-dead envelope")
        }
        try expect(!sent)
        try expect(correlated)
        try expect(!handedOff)
        try expect(hasClaimableError(fields))
    }
}
