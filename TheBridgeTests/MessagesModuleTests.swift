// MessagesModuleTests.swift – V1-05 MessagesModule Tests
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

// MARK: - MessagesModule Tests

func runMessagesModuleTests() async {
    print("\n💬 MessagesModule Tests")

    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await MessagesModule.register(on: router)

    // Registration tests
    await test("MessagesModule registers 6 tools") {
        let tools = await router.registrations(forModule: "messages")
        try expect(tools.count == 6, "Expected 6 messages tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names.contains("messages_search"), "Missing messages_search")
        try expect(names.contains("messages_recent"), "Missing messages_recent")
        try expect(names.contains("messages_chat"), "Missing messages_chat")
        try expect(names.contains("messages_content"), "Missing messages_content")
        try expect(names.contains("messages_participants"), "Missing messages_participants")
        try expect(names.contains("messages_send"), "Missing messages_send")
    }

    // Tier tests
    await test("messages_search tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_search" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_recent tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_recent" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_chat tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_chat" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_content tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_content" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_participants tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_participants" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_send tier is request") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_send" })!
        try expect(tool.tier == .request, "Expected request, got \(tool.tier.rawValue)")
    }

    await test("messages_send is non-downgradable and requires fresh approval") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_send" })!
        try expect(tool.neverAutoApprove, "messages_send must not accept Always Allow or tier downgrades")
    }

    // Functional tests — messages_search (requires chat.db access)
    await test("messages_search returns result structure") {
        do {
            let result = try await router.dispatch(
                toolName: "messages_search",
                arguments: .object(["query": .string("test_nonexistent_xyz_notionbridge"), "limit": .int(5)])
            )
            if case .object(let dict) = result {
                // Should have rows and count keys (even if empty)
                try expect(dict["rows"] != nil || dict["error"] != nil,
                           "Expected 'rows' or 'error' key in result")
            } else {
                throw TestError.assertion("Expected object result")
            }
        } catch {
            // Full Disk Access may be missing in CI/dev; treat this as expected environmental gating.
            try expect(error.localizedDescription.localizedCaseInsensitiveContains("authorization denied"),
                       "Unexpected messages_search error: \(error.localizedDescription)")
        }
    }

    // messages_recent returns result structure
    await test("messages_recent returns result structure") {
        do {
            let result = try await router.dispatch(
                toolName: "messages_recent",
                arguments: .object(["limit": .int(3)])
            )
            if case .object(let dict) = result {
                try expect(dict["rows"] != nil || dict["error"] != nil,
                           "Expected 'rows' or 'error' key in result")
            } else {
                throw TestError.assertion("Expected object result")
            }
        } catch {
            try expect(error.localizedDescription.localizedCaseInsensitiveContains("authorization denied"),
                       "Unexpected messages_recent error: \(error.localizedDescription)")
        }
    }

    await test("messages_recent attribution prefers Messages metadata over Contacts") {
        let fields = MessagesModule.attributionFields(
            messagesDisplayName: "Scott",
            handle: "+16055550123",
            contact: .init(resolvedName: "Different Contact", source: "contacts_exact_handle", confidence: "exact", failureReason: nil)
        )
        try expect(fields["resolvedName"] == .string("Scott"))
        try expect(fields["attributionSource"] == .string("messages_chat_display_name"))
        try expect(fields["attributionFailureReason"] == .null)
    }

    await test("messages_recent attribution uses exact Contacts result and exposes failure reason") {
        let resolved = MessagesModule.attributionFields(
            messagesDisplayName: nil,
            handle: "+16055550123",
            contact: .init(resolvedName: "Known Person", source: "contacts_exact_handle", confidence: "exact", failureReason: nil)
        )
        try expect(resolved["resolvedName"] == .string("Known Person"))
        try expect(resolved["attributionConfidence"] == .string("exact"))

        let unresolved = MessagesModule.attributionFields(
            messagesDisplayName: nil,
            handle: "+16055550123",
            contact: .init(resolvedName: nil, source: "contacts", confidence: "none", failureReason: "no_exact_contact_match")
        )
        try expect(unresolved["resolvedName"] == .null)
        try expect(unresolved["attributionFailureReason"] == .string("no_exact_contact_match"))
    }

    // messages_send rejects without confirm
    await test("messages_send rejects without confirm='SEND'") {
        let result = try await router.dispatch(
            toolName: "messages_send",
            arguments: .object([
                "recipient": .string("+15551234567"),
                "body": .string("test"),
                "confirm": .string("NO")
            ])
        )
        if case .object(let dict) = result,
           case .bool(let sent) = dict["sent"] {
            try expect(sent == false, "Expected sent=false without SEND confirm")
        } else {
            throw TestError.assertion("Expected object with sent=false")
        }
    }

    await test("messages_send accepts chatIdentifier before confirm gate") {
        let result = try await router.dispatch(
            toolName: "messages_send",
            arguments: .object([
                "chatIdentifier": .string("677927082d92462b9e1ddc5450b9ae10"),
                "body": .string("test"),
                "confirm": .string("NO")
            ])
        )
        if case .object(let dict) = result,
           case .bool(let sent) = dict["sent"] {
            try expect(sent == false, "Expected sent=false without SEND confirm")
        } else {
            throw TestError.assertion("Expected object with sent=false")
        }
    }

    // messages_search rejects missing query
    await test("messages_search rejects missing query") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_search",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing query")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // messages_chat rejects missing contact
    await test("messages_chat rejects missing contact") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_chat",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing contact")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // messages_content rejects missing messageId
    await test("messages_content rejects missing messageId") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_content",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing messageId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // messages_participants rejects missing chatIdentifier
    await test("messages_participants rejects missing chatIdentifier") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_participants",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing chatIdentifier")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // messages_send rejects missing params
    await test("messages_send rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_send",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }


    await test("partial THREAD transaction arguments fail before any M1 side-effect seam") {
        let keys = ["threadPageId", "actionId", "approvalBasis", "actor", "workspace"]
        for key in keys {
            do {
                _ = try await router.dispatch(
                    toolName: "messages_send",
                    arguments: .object([key: .string("hostile-value")])
                )
                throw TestError.assertion("partial THREAD argument unexpectedly executed for \(key)")
            } catch is ToolRouterError {
                // Required body/confirm/target validation fails before the M1 branch.
            }
        }
    }

    await test("THREAD approval receipt guard is structurally before every M1 side-effect seam") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("TheBridge/Modules/MessagesModule.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let guardIndex = source.range(of: "approvalReceipt.validates(toolName: \"messages_send\", arguments: arguments)")?.lowerBound,
              let branchIndex = source.range(of: "if case .string(let threadPageId)? = args[\"threadPageId\"]")?.lowerBound else {
            throw TestError.assertion("M1 approval or branch guard missing")
        }
        try expect(guardIndex < branchIndex, "exact-arguments approval must precede M1 routing")
        for seam in [
            "SQLiteThreadMessagesReceiptStore.live()",
            "toolName: \"notion_page_read\"",
            "toolName: \"registry_get\"",
            "toolName: \"notion_blocks_append\""
        ] {
            guard let seamIndex = source.range(of: seam)?.lowerBound else {
                throw TestError.assertion("expected M1 seam missing: \(seam)")
            }
            try expect(guardIndex < seamIndex, "exact approval must precede \(seam)")
        }
    }

    await test("messages_send source exposes only the bounded M1 lane and internal journal context") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("TheBridge/Modules/MessagesModule.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        try expect(!source.contains("THREAD_MESSAGES_CONTAINED"), "stale blanket containment remains in the active handler")
        try expect(source.contains("Bounded THREAD M1"), "tool description must identify the narrow M1 lane")
        try expect(source.contains("context: .localDefault"), "internal receipt append must not demand an impossible nested route receipt")
    }

    final class InvocationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _services: [MessagesService] = []
        private var _verifyCount = 0
        var result = MessagesAppleScriptInvocationResult()

        var services: [MessagesService] { lock.withLock { _services } }
        var verifyCount: Int { lock.withLock { _verifyCount } }
        func invoke(_ service: MessagesService, _ recipient: String, _ body: String) -> MessagesAppleScriptInvocationResult {
            lock.withLock { _services.append(service) }
            return result
        }
        func verify(_ recipient: String, _ body: String, _ watermark: Int, _ preparedAt: Date) -> MessagesDeliveryVerification {
            lock.withLock { _verifyCount += 1 }
            return .init(status: .notFound)
        }
    }

    await test("ordinary one-to-one rejects missing, auto, RCS, and unknown service without invocation") {
        for service in [nil, "auto", "RCS", "sms", "bogus"] as [String?] {
            let probe = InvocationProbe()
            let attempt = MessagesModule.performOneToOneSend(
                recipient: "+15551234567", body: "test", confirm: "SEND",
                serviceOverride: service, afterId: 1, preparedAt: Date(),
                invoke: probe.invoke, verify: probe.verify
            )
            try expect(!attempt.invoked, "invalid service \(service ?? "<missing>") must not invoke")
            try expect(probe.services.isEmpty, "invalid service must have zero invocation calls")
            try expect(probe.verifyCount == 0, "invalid service must not correlate local records")
        }
    }

    await test("SMS rejects an email recipient before invocation") {
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "person@example.com", body: "test", confirm: "SEND",
            serviceOverride: "SMS", afterId: 1, preparedAt: Date(),
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(!attempt.invoked)
        try expect(probe.services.isEmpty)
        try expect(attempt.error?.contains("phone-number") == true)
    }

    await test("one ordinary request invokes exactly one explicit service and never falls back after error") {
        for service in [MessagesService.iMessage, .sms] {
            let probe = InvocationProbe()
            probe.result = .init(error: "forced failure", errorNumber: -1708)
            let attempt = MessagesModule.performOneToOneSend(
                recipient: "+15551234567", body: "test", confirm: "SEND",
                serviceOverride: service.rawValue, afterId: 1, preparedAt: Date(),
                invoke: probe.invoke, verify: probe.verify
            )
            try expect(attempt.invoked, "AppleScript attempt is consequence-possible even when it reports an error")
            try expect(probe.services == [service], "one request must invoke only the reviewed service")
            try expect(probe.verifyCount == 0, "synchronous AppleScript error must not trigger correlation retry")
        }
    }

    await test("successful invocation with no local match remains consequence-possible but not successful") {
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+15551234567", body: "test", confirm: "SEND",
            serviceOverride: "iMessage", afterId: 1, preparedAt: Date(),
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(attempt.invoked)
        try expect(probe.services == [.iMessage])
        try expect(probe.verifyCount == 1)
        try expect(!attempt.verification.verified, "missing local evidence must not be success")
        try expect(attempt.verification.status == .notFound)
    }

    await test("invoked send with NOT_FOUND still reports sent true") {
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+15551234567", body: "test", confirm: "SEND",
            serviceOverride: "iMessage", afterId: 1, preparedAt: Date(),
            invoke: probe.invoke, verify: probe.verify
        )
        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15551234567", body: "test", attempt: attempt
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let correlated) = fields["correlatedLocalRecord"],
              case .bool(let verified) = fields["verified"],
              case .bool(let invoked) = fields["deliveryInvoked"],
              case .string(let status) = fields["verificationStatus"],
              case .string(let semantics) = fields["compatibilityFieldSemantics"] else {
            throw TestError.assertion("expected dispatch vs correlation envelope")
        }
        try expect(sent, "dispatch success must not be false solely because chat.db missed")
        try expect(!correlated, "NOT_FOUND must not claim local correlation")
        try expect(!verified)
        try expect(invoked)
        try expect(status == MessagesDeliveryVerificationStatus.notFound.rawValue)
        try expect(semantics.contains("dispatch success"))
    }

    await test("AppleScript invoke error reports sent false with deliveryInvoked true") {
        let probe = InvocationProbe()
        probe.result = .init(error: "forced failure", errorNumber: -1708)
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+15551234567", body: "test", confirm: "SEND",
            serviceOverride: "iMessage", afterId: 1, preparedAt: Date(),
            invoke: probe.invoke, verify: probe.verify
        )
        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15551234567", body: "test", attempt: attempt
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let invoked) = fields["deliveryInvoked"] else {
            throw TestError.assertion("expected sent/deliveryInvoked on invoke error")
        }
        try expect(!sent)
        try expect(invoked)
        try expect(probe.verifyCount == 0)
    }

    await test("chatIdentifier success with NOT_FOUND still reports sent true") {
        let fields = MessagesModule.chatIdentifierSendMCPFields(
            chatIdentifier: "iMessage;-;+15551234567",
            body: "test",
            verification: .init(status: .notFound)
        )
        guard case .bool(let sent) = fields["sent"],
              case .bool(let correlated) = fields["correlatedLocalRecord"],
              case .bool(let verified) = fields["verified"],
              case .string(let status) = fields["verificationStatus"] else {
            throw TestError.assertion("expected chatIdentifier dispatch vs correlation envelope")
        }
        try expect(sent)
        try expect(!correlated)
        try expect(!verified)
        try expect(status == MessagesDeliveryVerificationStatus.notFound.rawValue)
    }

    await test("local correlation poll default is 20 attempts at 0.5s") {
        try expect(MessagesModule.localCorrelationPollAttempts == 20)
        try expect(MessagesModule.localCorrelationPollInterval == 0.5)
    }

    await test("messages_send rejects body+confirm without recipient or chatIdentifier") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_send",
                arguments: .object([
                    "body": .string("test"),
                    "confirm": .string("SEND")
                ])
            )
            throw TestError.assertion("Expected error for missing target")
        } catch is ToolRouterError {
            // Expected
        }
    }
}
