// MessagesSendApprovalPolicyTests.swift
// TheBridge · Tests
//
// `messages_send` uses the ordinary SecurityGate ladder (open / notify /
// request). Catalog default is .notify for ordinary 1:1 plain text (#298);
// groups, attachments, and SMS-override (`allowSmsDespiteLiveService`)
// stay .request at dispatch. neverAutoApprove is false so Settings can
// raise or lower the per-tool tier, including for remote/tunnel sessions.
// confirm:SEND remains handler-required. Ordinary send inherits live inbound
// iMessage/SMS or fails closed (#198). Explicit SMS on RCS/unknown requires
// allowSmsDespiteLiveService (#249). This does not change host Auto-review
// (#294). No live Messages.app send.

import Foundation
import MCP
import TheBridgeLib

func runMessagesSendApprovalPolicyTests() async {
    print("\n📬 Messages send 3-tier SecurityGate ladder")

    await test("messages_send is catalog notify and Settings can raise or lower it") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await MessagesModule.register(on: router)
        let tool = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }!
        try expect(tool.tier == .notify, "catalog registration default is .notify for ordinary 1:1 text (#298)")
        try expect(!tool.neverAutoApprove, "Settings must be able to raise or lower messages_send")
        try expect(tool.description.localizedCaseInsensitiveContains("confirm"),
                   "tool description must name confirm:SEND")
        try expect(tool.description.localizedCaseInsensitiveContains("iMessage")
                   || tool.description.localizedCaseInsensitiveContains("SMS"),
                   "tool description must name the explicit service contract")
        try expect(tool.description.localizedCaseInsensitiveContains("Notify"),
                   "tool description must name the Notify catalog default")
        try expect(tool.description.localizedCaseInsensitiveContains("Auto-review"),
                   "tool description must name that host Auto-review (#294) is unchanged")
        try expect(!tool.description.contains("Always ask"),
                   "send-only Always ask copy must not remain on the tool")
    }

    await test("effective Open also skips the prompt for a local session") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate, tier: .open, arguments: ordinarySend(), context: localSession("s1")
        )
        try expectAllow(decision, "Open local ordinary send")
        try expect(provider.approvalRequestCount == 0)
    }

    await test("Always Allow on messages_send persists a Notify override") {
        let toolKey = BridgeDefaults.tierOverrides
        let moduleKey = BridgeDefaults.moduleTierOverrides
        let previousTool = UserDefaults.standard.object(forKey: toolKey)
        let previousModule = UserDefaults.standard.object(forKey: moduleKey)
        defer {
            if let previousTool {
                UserDefaults.standard.set(previousTool, forKey: toolKey)
            } else {
                UserDefaults.standard.removeObject(forKey: toolKey)
            }
            if let previousModule {
                UserDefaults.standard.set(previousModule, forKey: moduleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: moduleKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: toolKey)
        UserDefaults.standard.removeObject(forKey: moduleKey)
        let provider = TestSecurityApprovalProvider(decision: .alwaysAllow)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate, tier: .request, arguments: ordinarySend(), context: localSession("s1")
        )
        try expectAllow(decision, "Always Allow send")
        let stored = UserDefaults.standard.dictionary(forKey: toolKey) as? [String: String] ?? [:]
        try expect(stored["messages_send"] == SecurityTier.notify.rawValue,
                   "Always Allow must persist a notify override for messages_send, got \(stored)")
    }

    await test("SecurityGate no longer consults a send-only approval policy") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("TheBridge/Security/SecurityGate.swift"),
            encoding: .utf8
        )
        try expect(!source.contains("MessagesSendApprovalPolicy"),
                   "SecurityGate must use resolveEffectiveTier only for messages_send")
        try expect(!source.contains("messagesSendSessionApprovals"),
                   "send-only session skip state must be gone")
        try expect(!source.contains("forceModalReview: neverAutoApprove && toolName == \"messages_send\""),
                   "Request must not force a send-only NSAlert lock")
        try expect(!source.contains("neverAutoApprove || toolName == \"messages_send\""),
                   "Request body must not special-case messages_send vs mail_send")
        try expect(!source.contains("origin != .local"),
                   "do not add a named remote origin floor")
    }

    await test("effective Open + confirm SEND + explicit service skips the on-device prompt for a remote session") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate,
            tier: .open,
            arguments: ordinarySend(),
            context: ToolDispatchContext(transportSessionId: "cloud-agent-1", origin: .remote)
        )
        try expectAllow(decision, "Open remote ordinary send")
        try expect(provider.approvalRequestCount == 0,
                   "effective Open must not force a Mac modal for remote origin")
    }

    await test("effective Notify skips the prompt for remote, jobs, group, and THREAD") {
        let cases: [(String, Value, ToolDispatchContext)] = [
            ("remote", ordinarySend(), ToolDispatchContext(transportSessionId: "s1", origin: .remote)),
            ("job", ordinarySend(), .localDefault),
            ("group", ordinarySend(extra: ["chatIdentifier": .string("iMessage;-;+1555")]), localSession("s1")),
            ("THREAD", ordinarySend(extra: ["threadPageId": .string("thread-page")]), localSession("s1")),
        ]
        for (label, arguments, context) in cases {
            let provider = TestSecurityApprovalProvider()
            let gate = SecurityGate(approvalProvider: provider)
            let decision = await enforceMessages(
                gate: gate, tier: .notify, arguments: arguments, context: context
            )
            try expectAllow(decision, "\(label) at Notify")
            try expect(provider.approvalRequestCount == 0,
                       "\(label) must follow the tool's Notify tier, not a send-only remote/group lock")
        }
    }

    await test("effective Request still prompts, including remote") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate,
            tier: .request,
            arguments: ordinarySend(),
            context: ToolDispatchContext(transportSessionId: "cloud-agent-1", origin: .remote)
        )
        try expectAllow(decision, "Request remote send after prompt")
        try expect(provider.approvalRequestCount == 1,
                   "catalog/request effective tier must still show the on-device prompt")
        try expect(!provider.lastForceModalReview,
                   "Request messages_send must use the same prompt style as mail_send, not a forced NSAlert")
        try expect(provider.lastAllowAlwaysAllowAction,
                   "messages_send must offer Always Allow like other non-locked request tools")
    }

    await test("effective Request denial still rejects") {
        let provider = TestSecurityApprovalProvider(decision: .deny)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate,
            tier: .request,
            arguments: ordinarySend(),
            context: ToolDispatchContext(transportSessionId: "cloud-agent-1", origin: .remote)
        )
        guard case .reject = decision else {
            throw TestError.assertion("Request deny must reject, got \(String(describing: decision))")
        }
        try expect(provider.approvalRequestCount == 1)
    }

    await test("Request still prompts every send — no send-only session skip") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        _ = await enforceMessages(gate: gate, tier: .request, arguments: ordinarySend(), context: localSession("s1"))
        _ = await enforceMessages(gate: gate, tier: .request, arguments: ordinarySend(), context: localSession("s1"))
        try expect(provider.approvalRequestCount == 2,
                   "ordinary Request has no send-only session grant")
    }

    await test("router Open override reaches the handler without a prompt") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        try await withToolOverride("messages_send", SecurityTier.open) {
            let result = try await router.dispatch(
                toolName: "messages_send",
                arguments: ordinarySend(service: "auto")
            )
            guard case .object(let object) = result else {
                throw TestError.assertion("invalid-service result must be an object")
            }
            try expect(object["sent"] == .bool(false), "auto service must still fail closed")
            try expect(object["approvalMode"] == nil,
                       "retired send-only approvalMode must not appear on results")
            try expect(provider.approvalRequestCount == 0,
                       "Open override must skip the Mac modal")
        }
    }

    await test("handler still requires confirm SEND and explicit service under Open") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        try await withToolOverride("messages_send", SecurityTier.open) {
            let missingConfirm = try await router.dispatch(
                toolName: "messages_send",
                arguments: ordinarySend(confirm: "yes")
            )
            guard case .object(let denied) = missingConfirm else {
                throw TestError.assertion("missing SEND must return an object")
            }
            try expect(denied["sent"] == .bool(false), "confirm:SEND remains required at Open")
            try expect(provider.approvalRequestCount == 0)

            let missingService = try await router.dispatch(
                toolName: "messages_send",
                arguments: ordinarySend(recipient: "nobody-issue-198@example.invalid", omitService: true)
            )
            guard case .object(let noService) = missingService else {
                throw TestError.assertion("missing service must return an object")
            }
            try expect(noService["sent"] == .bool(false), "omit service without live inbound must fail closed")
            if case .string(let error) = noService["error"] {
                try expect(error.localizedCaseInsensitiveContains("inherit")
                           || error.localizedCaseInsensitiveContains("explicit"),
                           "omit-without-inbound error must name inherit or explicit, got \(error)")
            } else {
                throw TestError.assertion("omit-without-inbound must return an error string")
            }
        }
    }

    await test("raw chatNNN is still rejected at Open without an on-device prompt") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        try await withToolOverride("messages_send", SecurityTier.open) {
            let result = try await router.dispatch(
                toolName: "messages_send",
                arguments: ordinarySend(recipient: "chat99")
            )
            guard case .object(let object) = result else {
                throw TestError.assertion("raw chatNNN result must be an object")
            }
            try expect(object["sent"] == .bool(false), "raw chatNNN must stay rejected")
            try expect(provider.approvalRequestCount == 0)
        }
    }

    await test("live mail_trash and snippets_delete are Request without neverAutoApprove floor") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await MailModule.register(on: router)
        await SnippetsModule.register(on: router)
        await MessagesModule.register(on: router)
        let trash = await router.registrations(forModule: "mail").first { $0.name == "mail_trash" }
        let sendMail = await router.registrations(forModule: "mail").first { $0.name == "mail_send" }
        let snippets = await router.registrations(forModule: "snippets").first { $0.name == "snippets_delete" }
        let send = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }
        try expect(trash?.neverAutoApprove == false, "mail_trash Always Allow must be available")
        try expect(snippets?.neverAutoApprove == false, "snippets_delete Always Allow must be available")
        try expect(sendMail?.neverAutoApprove == false && sendMail?.tier == .request,
                   "mail_send is request without neverAutoApprove")
        try expect(send?.neverAutoApprove == false && send?.tier == .notify,
                   "messages_send catalog default is notify without neverAutoApprove (#298)")
        try expect(trash?.tier == .request)
        try expect(snippets?.tier == .request)
    }

    await test("mail_trash and snippets_delete honor overrides like messages_send") {
        let send = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send", module: "messages",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: ["messages_send": "open"], moduleOverrides: [:]
        )
        try expect(send == .open)

        let trash = ToolRouter.resolveEffectiveTier(
            toolName: "mail_trash", module: "mail",
            registeredTier: .request, neverAutoApprove: true,
            toolOverrides: ["mail_trash": "open"], moduleOverrides: ["mail": "open"]
        )
        try expect(trash == .open, "mail_trash must honor an Open override")

        let snippets = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_delete", module: "snippets",
            registeredTier: .request, neverAutoApprove: true,
            toolOverrides: ["snippets_delete": "notify"], moduleOverrides: ["snippets": "open"]
        )
        try expect(snippets == .notify, "snippets_delete must honor a Notify override")
    }

    await test("Gates UI no longer hosts a send-only approval card") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let ui = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("TheBridge/UI/Sections/PermissionsSection.swift"),
            encoding: .utf8
        )
        try expect(!ui.contains("messagesApprovalCard"),
                   "Gates tab must not render a send-only approval card")
        try expect(!ui.contains("MessagesSendApprovalMode"),
                   "Gates tab must not mention the retired send-only mode enum")
        try expect(ui.contains("alwaysAllowCard"),
                   "ordinary Always-Allow grants card must remain")
    }

    await test("Request pending maps to awaitingApproval and does not allow") {
        let provider = TestSecurityApprovalProvider(decision: .pending)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await enforceMessages(
            gate: gate,
            tier: .request,
            arguments: ordinarySend(),
            context: ToolDispatchContext(transportSessionId: "cloud-agent-1", origin: .remote)
        )
        guard case .awaitingApproval(let id) = decision else {
            throw TestError.assertion("Request pending must be awaitingApproval, got \(String(describing: decision))")
        }
        try expect(!id.isEmpty, "awaitingApproval id must be a stable digest")
        try expect(provider.approvalRequestCount == 1)
    }

    await test("router returns awaiting_approval without running messages_send") {
        let provider = TestSecurityApprovalProvider(decision: .pending)
        let gate = SecurityGate(approvalProvider: provider)
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await MessagesModule.register(on: router)
        let result = try await router.dispatch(
            toolName: "messages_send",
            arguments: groupSend()
        )
        guard case .object(let object) = result else {
            throw TestError.assertion("awaiting_approval must be an object, got \(result)")
        }
        try expect(object["approvalStatus"] == .string("awaiting_approval"))
        try expect(object["sent"] == .bool(false), "handler must not send")
        try expect(object["consequencePossible"] == .bool(false))
        try expect(object["resume"] != nil, "client must be told to retry after Allow")
        try expect(provider.approvalRequestCount == 1)
        let awaiting = await log.entries(withStatus: .awaiting)
        try expect(awaiting.count == 1, "audit must record awaiting_approval")
    }

    await test("retry after pending Allow reaches the handler without a second hang") {
        let provider = SequenceApprovalProvider([.pending, .allow])
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        let first = try await router.dispatch(
            toolName: "messages_send",
            arguments: groupSend(service: "auto")
        )
        guard case .object(let pendingObject) = first else {
            throw TestError.assertion("first call must be an object")
        }
        try expect(pendingObject["approvalStatus"] == .string("awaiting_approval"))
        try expect(pendingObject["sent"] == .bool(false))

        let second = try await router.dispatch(
            toolName: "messages_send",
            arguments: groupSend(service: "auto")
        )
        guard case .object(let allowedObject) = second else {
            throw TestError.assertion("retry after Allow must reach the handler")
        }
        try expect(allowedObject["approvalStatus"] == nil,
                   "handler result must not look like awaiting_approval")
        try expect(allowedObject["sent"] == .bool(false),
                   "auto service still fail-closes; proves handler ran")
        try expect(provider.requestCount == 2)
    }

    await test("#298 discriminator: 1:1 plain text is notify; group/attachment/SMS-override are request") {
        let cases: [(String, Value, SecurityTier)] = [
            ("1:1 phone + body", ordinarySend(), .notify),
            ("1:1 email + body", ordinarySend(recipient: "ada@example.com"), .notify),
            ("1:1 chatIdentifier phone", chatIdentifierSend("+15551234567"), .notify),
            ("1:1 chatIdentifier email", chatIdentifierSend("ada@example.com"), .notify),
            ("1:1 service-prefixed chat", chatIdentifierSend("iMessage;-;+15551234567"), .notify),
            ("1:1 SMS-prefixed chat", chatIdentifierSend("SMS;-;+15551234567"), .notify),
            ("omit-service 1:1 still notify", ordinarySend(omitService: true), .notify),
            ("group chatNNNN", groupSend(), .request),
            ("group UUID chat id", chatIdentifierSend("677927082d92462b9e1ddc5450b9ae10"), .request),
            ("attachment filePath", ordinarySend(extra: ["filePath": .string("/tmp/song.m4a"), "body": .string("")]), .request),
            ("SMS override flag", ordinarySend(extra: ["allowSmsDespiteLiveService": .bool(true)]), .request),
            ("dual recipient+chatIdentifier", ordinarySend(extra: ["chatIdentifier": .string("chat123456789")]), .request),
            ("raw chatNNNN recipient", ordinarySend(recipient: "chat123456789"), .request),
            ("empty body no file", ordinarySend(extra: ["body": .string("   ")]), .request),
        ]
        for (label, arguments, expected) in cases {
            let got = MessagesSendCatalogTier.registeredDefault(
                toolName: "messages_send", arguments: arguments
            )
            try expect(got == expected, "\(label): expected \(expected.rawValue), got \(got.rawValue)")
            let forces = MessagesSendCatalogTier.forcesRequestHumanApproval(
                toolName: "messages_send", arguments: arguments
            )
            try expect(forces == (expected == .request),
                       "\(label): forcesRequest=\(forces) expected \(expected == .request)")
        }
        try expect(
            !MessagesSendCatalogTier.forcesRequestHumanApproval(
                toolName: "mail_send", arguments: ordinarySend()
            ),
            "discriminator must not raise unrelated tools"
        )
    }

    await test("#298 router: ordinary 1:1 text is notify (no Confirm prompt)") {
        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        let result = try await router.dispatch(
            toolName: "messages_send",
            arguments: ordinarySend(service: "auto")
        )
        guard case .object(let object) = result else {
            throw TestError.assertion("1:1 notify path must reach the handler")
        }
        try expect(object["approvalStatus"] == nil, "1:1 plain text must not await Confirm")
        try expect(object["sent"] == .bool(false), "auto service still fail-closes; proves handler ran")
        try expect(provider.approvalRequestCount == 0,
                   "ordinary 1:1 text must use notify, not request")
    }

    await test("#298 router: group, attachment, and SMS-override still request") {
        let cases: [(String, Value)] = [
            ("group", groupSend()),
            ("attachment", ordinarySend(extra: ["filePath": .string("/tmp/clip.m4a"), "body": .string("")])),
            ("SMS override", ordinarySend(extra: ["allowSmsDespiteLiveService": .bool(true)])),
        ]
        for (label, arguments) in cases {
            let provider = TestSecurityApprovalProvider(decision: .pending)
            let gate = SecurityGate(approvalProvider: provider)
            let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
            await MessagesModule.register(on: router)
            let result = try await router.dispatch(
                toolName: "messages_send",
                arguments: arguments
            )
            guard case .object(let object) = result else {
                throw TestError.assertion("\(label) must return an object")
            }
            try expect(object["approvalStatus"] == .string("awaiting_approval"),
                       "\(label) must stay Request / Confirm")
            try expect(object["sent"] == .bool(false), "\(label) must not send while awaiting")
            try expect(provider.approvalRequestCount == 1,
                       "\(label) must prompt; count=\(provider.approvalRequestCount)")
        }
    }

    await test("#298 Settings override still wins over the discriminator") {
        let groupRegistered = MessagesSendCatalogTier.registeredDefault(
            toolName: "messages_send", arguments: groupSend()
        )
        try expect(groupRegistered == .request, "group catalog default is request")
        let lowered = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send",
            module: "messages",
            registeredTier: groupRegistered,
            neverAutoApprove: false,
            toolOverrides: ["messages_send": SecurityTier.open.rawValue],
            moduleOverrides: [:]
        )
        try expect(lowered == .open, "Settings Open must still lower a group send")

        let oneToOne = MessagesSendCatalogTier.registeredDefault(
            toolName: "messages_send", arguments: ordinarySend()
        )
        try expect(oneToOne == .notify, "1:1 catalog default is notify")
        let raised = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send",
            module: "messages",
            registeredTier: oneToOne,
            neverAutoApprove: false,
            toolOverrides: ["messages_send": SecurityTier.request.rawValue],
            moduleOverrides: [:]
        )
        try expect(raised == .request, "Settings Request must still raise a 1:1 send")

        let provider = TestSecurityApprovalProvider()
        let gate = SecurityGate(approvalProvider: provider)
        let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
        await MessagesModule.register(on: router)
        try await withToolOverride("messages_send", SecurityTier.open) {
            let result = try await router.dispatch(
                toolName: "messages_send",
                arguments: groupSend(service: "auto")
            )
            guard case .object(let object) = result else {
                throw TestError.assertion("Open override on group must reach handler")
            }
            try expect(object["approvalStatus"] == nil)
            try expect(provider.approvalRequestCount == 0,
                       "Settings Open must skip Confirm even for a group send")
        }
    }
}

// MARK: - Helpers

private func groupSend(
    chatIdentifier: String = "chat123456789",
    service: String = "iMessage",
    confirm: String = "SEND"
) -> Value {
    chatIdentifierSend(chatIdentifier, service: service, confirm: confirm)
}

private func chatIdentifierSend(
    _ chatIdentifier: String,
    service: String = "iMessage",
    confirm: String = "SEND"
) -> Value {
    .object([
        "chatIdentifier": .string(chatIdentifier),
        "body": .string("policy probe"),
        "confirm": .string(confirm),
        "service": .string(service)
    ])
}

private func ordinarySend(
    recipient: String = "+15551234567",
    service: String = "iMessage",
    confirm: String = "SEND",
    omitService: Bool = false,
    extra: [String: Value] = [:]
) -> Value {
    var args: [String: Value] = [
        "recipient": .string(recipient),
        "body": .string("policy probe"),
        "confirm": .string(confirm)
    ]
    if !omitService {
        args["service"] = .string(service)
    }
    for (key, value) in extra {
        args[key] = value
    }
    return .object(args)
}

private func localSession(_ id: String) -> ToolDispatchContext {
    ToolDispatchContext(transportSessionId: id, origin: .local)
}

private func enforceMessages(
    gate: SecurityGate,
    tier: SecurityTier,
    arguments: Value,
    context: ToolDispatchContext
) async -> GateDecision {
    await gate.enforce(
        toolName: "messages_send",
        tier: tier,
        neverAutoApprove: false,
        arguments: arguments,
        module: "messages",
        context: context
    )
}

private func expectAllow(_ decision: GateDecision, _ msg: String) throws {
    switch decision {
    case .allow:
        break
    default:
        throw TestError.assertion("\(msg): expected .allow, got \(String(describing: decision))")
    }
}

private func withToolOverride(
    _ toolName: String,
    _ tier: SecurityTier,
    _ body: () async throws -> Void
) async throws {
    let key = BridgeDefaults.tierOverrides
    let previous = UserDefaults.standard.object(forKey: key)
    defer {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    UserDefaults.standard.set([toolName: tier.rawValue], forKey: key)
    try await body()
}

/// Deterministic multi-call approval provider for pending → Allow retry tests.
final class SequenceApprovalProvider: @unchecked Sendable, SecurityApprovalProviding {
    private let lock = NSLock()
    private var remaining: [SecurityApprovalDecision]
    private(set) var requestCount = 0

    init(_ decisions: [SecurityApprovalDecision]) {
        remaining = decisions
    }

    func requestPermission() async {}

    func requestApproval(
        title: String,
        body: String,
        allowAlwaysAllowAction: Bool,
        forceModalReview: Bool
    ) async -> SecurityApprovalDecision {
        lock.withLock {
            requestCount += 1
            if remaining.isEmpty { return .deny }
            return remaining.removeFirst()
        }
    }

    func sendFireAndForget(context: ExecutionNotificationContext) async {}
}
