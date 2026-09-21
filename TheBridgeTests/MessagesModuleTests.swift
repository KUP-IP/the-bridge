// MessagesModuleTests.swift – V1-05 MessagesModule Tests
// TheBridge · Tests

import Foundation
import MCP
import SQLite3
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

    await test("messages_send catalog default is notify") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_send" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
        try expect(tool.tier == MessagesSendCatalogTier.registeredToolTier)
    }

    await test("messages_send is raisable and lowerable on the ordinary 3-tier ladder") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_send" })!
        try expect(tool.tier == .notify, "catalog registration default is .notify (#298)")
        try expect(!tool.neverAutoApprove, "Settings must be able to raise or lower messages_send")
        let opened = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send",
            module: "messages",
            registeredTier: tool.tier,
            neverAutoApprove: tool.neverAutoApprove,
            toolOverrides: ["messages_send": SecurityTier.open.rawValue],
            moduleOverrides: [:]
        )
        try expect(opened == .open, "operator Open override must win: got \(opened.rawValue)")
        let raised = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send",
            module: "messages",
            registeredTier: tool.tier,
            neverAutoApprove: tool.neverAutoApprove,
            toolOverrides: ["messages_send": SecurityTier.request.rawValue],
            moduleOverrides: [:]
        )
        try expect(raised == .request, "operator Request override must win: got \(raised.rawValue)")
        let notified = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send",
            module: "messages",
            registeredTier: tool.tier,
            neverAutoApprove: tool.neverAutoApprove,
            toolOverrides: [:],
            moduleOverrides: ["messages": SecurityTier.notify.rawValue]
        )
        try expect(notified == .notify, "module Always-Allow must cover messages_send: got \(notified.rawValue)")
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

    await test("delivery verification coerces the bound timestamp to numeric affinity") {
        var database: OpaquePointer?
        try expect(sqlite3_open(":memory:", &database) == SQLITE_OK, "failed to open in-memory SQLite database")
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = "SELECT 1787334139.219 >= ?1, 1787334139.219 >= CAST(?1 AS REAL)"
        try expect(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, "failed to prepare affinity probe")
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "1787334130.4726059", -1, transient)
        try expect(sqlite3_step(statement) == SQLITE_ROW, "affinity probe returned no row")
        try expect(sqlite3_column_int(statement, 0) == 0, "the regression precondition no longer holds")
        try expect(sqlite3_column_int(statement, 1) == 1, "numeric coercion must preserve eligible rows")

        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("TheBridge/Modules/MessagesModule.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        try expect(
            source.contains(">= CAST(?2 AS REAL)"),
            "delivery verification timestamp parameter must be explicitly numeric"
        )
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

    await test("omit service inherits live inbound iMessage and never uses outbound SMS history") {
        try expect(
            MessagesModule.latestInboundService(from: [
                ["is_from_me": 1, "service": "SMS"],
                ["is_from_me": 0, "service": "iMessage"]
            ]) == "iMessage",
            "inbound iMessage must win over later-looking outbound SMS when inbound is first in date-desc order"
        )
        try expect(
            MessagesModule.latestInboundService(from: [
                ["is_from_me": 1, "service": "SMS"]
            ]) == nil,
            "outbound-only history must not inherit"
        )
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+16056013705", body: "test", confirm: "SEND",
            serviceOverride: nil, afterId: 1, preparedAt: Date(),
            liveInboundRaw: "iMessage",
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(attempt.invoked)
        try expect(probe.services == [.iMessage])
        try expect(attempt.service == "iMessage")
    }

    await test("explicit SMS on live iMessage inbound fails closed without invocation") {
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+16056013705", body: "test", confirm: "SEND",
            serviceOverride: "SMS", afterId: 1, preparedAt: Date(),
            liveInboundRaw: "iMessage",
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(!attempt.invoked)
        try expect(probe.services.isEmpty)
        try expect(attempt.error?.contains("does not match live inbound") == true)
    }

    await test("live RCS + service=SMS without flag refuses") {
        let probe = InvocationProbe()
        let explicitSMS = MessagesModule.performOneToOneSend(
            recipient: "+12537920959", body: "test", confirm: "SEND",
            serviceOverride: "SMS", afterId: 1, preparedAt: Date(),
            liveInboundRaw: "RCS",
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(!explicitSMS.invoked)
        try expect(probe.services.isEmpty)
        try expect(explicitSMS.error?.contains("allowSmsDespiteLiveService:true") == true,
                   "missing-flag error must name the operator override, got \(explicitSMS.error ?? "nil")")
        try expect(explicitSMS.error?.contains("service=SMS") == true)
    }

    await test("live RCS + service=SMS + allowSmsDespiteLiveService uses SMS") {
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+12537920959", body: "test", confirm: "SEND",
            serviceOverride: "SMS", afterId: 1, preparedAt: Date(),
            liveInboundRaw: "RCS",
            allowSmsDespiteLiveService: true,
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(attempt.invoked)
        try expect(probe.services == [.sms])
        try expect(attempt.service == "SMS")
        try expect(attempt.error == nil)
    }

    await test("live iMessage + service=SMS + flag still refuses mismatch") {
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+16056013705", body: "test", confirm: "SEND",
            serviceOverride: "SMS", afterId: 1, preparedAt: Date(),
            liveInboundRaw: "iMessage",
            allowSmsDespiteLiveService: true,
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(!attempt.invoked)
        try expect(probe.services.isEmpty)
        try expect(attempt.error?.contains("does not match live inbound") == true,
                   "flag must not unlock iMessage→SMS, got \(attempt.error ?? "nil")")
    }

    await test("omit service on RCS still refuses") {
        let probe = InvocationProbe()
        let omit = MessagesModule.performOneToOneSend(
            recipient: "+12537920959", body: "test", confirm: "SEND",
            serviceOverride: nil, afterId: 1, preparedAt: Date(),
            liveInboundRaw: "RCS",
            allowSmsDespiteLiveService: true,
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(!omit.invoked)
        try expect(probe.services.isEmpty)
        try expect(omit.error?.localizedCaseInsensitiveContains("inherit") == true
                   || omit.error?.contains("omit") == true,
                   "omit on RCS must stay inherit-only, got \(omit.error ?? "nil")")
    }

    await test("live unknown + service=SMS without flag refuses") {
        let probe = InvocationProbe()
        let explicitSMS = MessagesModule.performOneToOneSend(
            recipient: "+15550001111", body: "test", confirm: "SEND",
            serviceOverride: "SMS", afterId: 1, preparedAt: Date(),
            liveInboundRaw: "unknown",
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(!explicitSMS.invoked)
        try expect(probe.services.isEmpty)
        try expect(explicitSMS.error?.contains("allowSmsDespiteLiveService:true") == true,
                   "unknown missing-flag error must name the operator override, got \(explicitSMS.error ?? "nil")")
    }

    await test("live unknown + service=SMS + allowSmsDespiteLiveService uses SMS") {
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+15550001111", body: "test", confirm: "SEND",
            serviceOverride: "SMS", afterId: 1, preparedAt: Date(),
            liveInboundRaw: "unknown",
            allowSmsDespiteLiveService: true,
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(attempt.invoked)
        try expect(probe.services == [.sms])
        try expect(attempt.service == "SMS")
    }

    await test("omit service on unknown still refuses") {
        let probe = InvocationProbe()
        let omit = MessagesModule.performOneToOneSend(
            recipient: "+15550001111", body: "test", confirm: "SEND",
            serviceOverride: nil, afterId: 1, preparedAt: Date(),
            liveInboundRaw: "unknown",
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(!omit.invoked)
        try expect(probe.services.isEmpty)
    }

    await test("flag does not unlock iMessage send on RCS inbound") {
        let probe = InvocationProbe()
        let attempt = MessagesModule.performOneToOneSend(
            recipient: "+12537920959", body: "test", confirm: "SEND",
            serviceOverride: "iMessage", afterId: 1, preparedAt: Date(),
            liveInboundRaw: "RCS",
            allowSmsDespiteLiveService: true,
            invoke: probe.invoke, verify: probe.verify
        )
        try expect(!attempt.invoked)
        try expect(probe.services.isEmpty)
        try expect(attempt.error?.contains("silent fallback") == true
                   || attempt.error?.contains("RCS") == true)
    }

    await test("resolveSendService RCS/unknown override matrix") {
        switch MessagesModule.resolveSendService(requested: "SMS", liveInboundRaw: "RCS") {
        case .refuse(let reason):
            try expect(reason.contains("allowSmsDespiteLiveService:true"))
        case .use:
            throw TestError.assertion("RCS + SMS without flag must refuse")
        }
        switch MessagesModule.resolveSendService(
            requested: "SMS", liveInboundRaw: "RCS", allowSmsDespiteLiveService: true
        ) {
        case .use(let service):
            try expect(service == .sms)
        case .refuse(let reason):
            throw TestError.assertion("RCS + SMS + flag must use SMS, got \(reason)")
        }
        switch MessagesModule.resolveSendService(
            requested: "SMS", liveInboundRaw: "iMessage", allowSmsDespiteLiveService: true
        ) {
        case .refuse(let reason):
            try expect(reason.contains("does not match live inbound"))
        case .use:
            throw TestError.assertion("flag must not unlock iMessage↔SMS mismatch")
        }
        switch MessagesModule.resolveSendService(
            requested: nil, liveInboundRaw: "RCS", allowSmsDespiteLiveService: true
        ) {
        case .refuse:
            break
        case .use:
            throw TestError.assertion("omit on RCS must refuse even with the flag")
        }
        switch MessagesModule.resolveSendService(
            requested: "SMS", liveInboundRaw: "unknown", allowSmsDespiteLiveService: true
        ) {
        case .use(let service):
            try expect(service == .sms)
        case .refuse(let reason):
            throw TestError.assertion("unknown + SMS + flag must use SMS, got \(reason)")
        }
        switch MessagesModule.resolveSendService(requested: "RCS", liveInboundRaw: nil) {
        case .refuse(let reason):
            try expect(reason.contains("not a sendable"))
        case .use:
            throw TestError.assertion("RCS must stay out of the send enum")
        }
    }

    await test("messages_chat catalog mentions service for inherit binding") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await MessagesModule.register(on: router)
        let chat = await router.registrations(forModule: "messages").first { $0.name == "messages_chat" }!
        try expect(chat.description.localizedCaseInsensitiveContains("service"),
                   "messages_chat must advertise chat.db service so send can inherit")
        let send = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }!
        try expect(send.description.localizedCaseInsensitiveContains("inherit"),
                   "messages_send must document inherit-or-fail-closed")
        try expect(send.description.localizedCaseInsensitiveContains("fallback"),
                   "messages_send must still name the no-fallback rule")
        try expect(send.description.contains("allowSmsDespiteLiveService"),
                   "messages_send must name the RCS/unknown SMS operator override")
        guard case .object(let schema) = send.inputSchema,
              case .object(let props)? = schema["properties"] else {
            throw TestError.assertion("messages_send schema not inspectable")
        }
        try expect(props["allowSmsDespiteLiveService"] != nil,
                   "messages_send schema must advertise allowSmsDespiteLiveService")
        try expect(props["service"] != nil)
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

    await test("#215 chat selector is XOR exact contact or chatIdentifier") {
        do {
            _ = try MessagesQueryContracts.ChatSelector.parse(contact: nil, chatIdentifier: nil)
            throw TestError.assertion("expected XOR failure")
        } catch is ToolRouterError {}
        do {
            _ = try MessagesQueryContracts.ChatSelector.parse(contact: "+1555", chatIdentifier: "chat123")
            throw TestError.assertion("expected both-set XOR failure")
        } catch is ToolRouterError {}
        let handle = try MessagesQueryContracts.ChatSelector.parse(contact: "+15551212", chatIdentifier: nil)
        try expect(handle == .contact("+15551212"))
        try expect(handle.whereClause == "h.id = ?1")
        let group = try MessagesQueryContracts.ChatSelector.parse(contact: "  ", chatIdentifier: "chatABCDEF")
        try expect(group == .chatIdentifier("chatABCDEF"))
        try expect(group.whereClause == "c.chat_identifier = ?1")
    }

    await test("#216 default lists filter tapbacks via associated_message_type and item_type") {
        try expect(MessagesQueryContracts.normalRowPredicate.contains("associated_message_type"))
        try expect(MessagesQueryContracts.normalRowPredicate.contains("item_type"))
        try expect(MessagesQueryContracts.normalRowPredicateM2.contains("m2.associated_message_type"))
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsURL
            .deletingLastPathComponent()
            .appendingPathComponent("TheBridge/Modules/MessagesModule.swift"), encoding: .utf8)
        try expect(!source.contains("c.chat_identifier LIKE '%'"),
                   "messages_chat/participants must not LIKE chat_identifier")
        try expect(!source.contains("h.id LIKE '%'"),
                   "lookupLiveInboundService/messages_chat must not LIKE handle id")
        try expect(source.contains("MessagesQueryContracts.normalRowPredicate"),
                   "default search/chat SQL must apply the tapback filter")
        try expect(source.contains("MessagesQueryContracts.normalRowPredicateM2"),
                   "messages_recent last-message subquery must skip tapbacks")
    }

    await test("#217 date_read zero is null and is_read is bool") {
        try expect(MessagesQueryContracts.dateReadValue(0) == .null)
        try expect(MessagesQueryContracts.dateReadValue(0.0) == .null)
        try expect(MessagesQueryContracts.dateReadValue(NSNull()) == .null)
        try expect(MessagesQueryContracts.dateReadValue("2001-01-01 00:00:00") == .null)
        try expect(MessagesQueryContracts.dateReadValue("2026-09-02 12:00:00") == .string("2026-09-02 12:00:00"))
        try expect(MessagesQueryContracts.isReadValue(0) == .bool(false))
        try expect(MessagesQueryContracts.isReadValue(1) == .bool(true))
    }

    await test("#218 filePath XOR body and 1:1 iMessage-only policy") {
        try expect(MessagesQueryContracts.payloadXORError(body: "hi", filePath: "/tmp/x")?.contains("XOR") == true)
        try expect(MessagesQueryContracts.payloadXORError(body: nil, filePath: nil)?.contains("missing") == true)
        try expect(MessagesQueryContracts.payloadXORError(body: "hi", filePath: nil) == nil)
        try expect(MessagesQueryContracts.fileSendPolicyError(
            filePath: "/tmp/x.png",
            chatIdentifier: "chat123",
            resolvedService: "iMessage",
            checkFilesystem: false
        )?.contains("chatIdentifier") == true)
        try expect(MessagesQueryContracts.fileSendPolicyError(
            filePath: "/tmp/x.png",
            chatIdentifier: nil,
            resolvedService: "SMS",
            checkFilesystem: false
        )?.contains("SMS") == true)
        try expect(MessagesQueryContracts.fileSendPolicyError(
            filePath: "~/Library/Messages/chat.db",
            chatIdentifier: nil,
            resolvedService: "iMessage",
            checkFilesystem: true
        )?.contains("Library/Messages") == true)
        try expect(MessagesQueryContracts.fileSendPolicyError(
            filePath: "/no/such/file.png",
            chatIdentifier: nil,
            resolvedService: "iMessage",
            checkFilesystem: true
        )?.contains("not found") == true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-wave3-attach.txt")
        try Data("ok".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try expect(MessagesQueryContracts.fileSendPolicyError(
            filePath: tmp.path,
            chatIdentifier: nil,
            resolvedService: "iMessage",
            checkFilesystem: true
        ) == nil)
    }

    await test("#204 catalog refuses group create and documents existing chatIdentifier send") {
        let send = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }!
        try expect(send.description.localizedCaseInsensitiveContains("group create is not built"))
        try expect(send.description.localizedCaseInsensitiveContains("chatIdentifier"))
        try expect(send.metadata?.whenNotToUse.contains(where: { $0.localizedCaseInsensitiveContains("group create") }) == true)
        try expect(send.description.localizedCaseInsensitiveContains("providerDeliveryConfirmed")
                   || send.description.localizedCaseInsensitiveContains("not provider delivery"))
    }

    await test("#199 send envelopes never claim provider delivery from local correlation") {
        let fields = MessagesModule.oneToOneSendMCPFields(
            recipient: "+15551234567",
            body: "hi",
            attempt: .init(
                invoked: true,
                verification: .init(status: .verified, messageRowId: 9),
                service: "iMessage"
            )
        )
        guard case .bool(let claimed) = fields["providerDeliveryConfirmed"] else {
            throw TestError.assertion("providerDeliveryConfirmed missing")
        }
        try expect(!claimed)
        let group = MessagesModule.chatIdentifierSendMCPFields(
            chatIdentifier: "iMessage;-;+1555",
            body: "hi",
            verification: .init(status: .verified, messageRowId: 9)
        )
        guard case .bool(let groupClaimed) = group["providerDeliveryConfirmed"] else {
            throw TestError.assertion("group providerDeliveryConfirmed missing")
        }
        try expect(!groupClaimed)
    }
}
