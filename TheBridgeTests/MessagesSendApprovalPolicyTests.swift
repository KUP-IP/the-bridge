// MessagesSendApprovalPolicyTests.swift — issue #126
// TheBridge · Tests
//
// Operator-selectable on-device approval for ordinary local one-to-one
// messages_send. Default Always ask. Group / THREAD / remote / jobs / raw
// chatNNN never inherit a skip. No live Messages.app send.

import Foundation
import MCP
import TheBridgeLib

func runMessagesSendApprovalPolicyTests() async {
    print("\n📬 Messages send approval policy (#126)")

    await test("missing stored mode defaults to alwaysAsk") {
        let suite = isolatedDefaults()
        defer { suite.tearDown() }
        try expect(MessagesSendApprovalPolicy.load(from: suite.defaults) == .alwaysAsk)
    }

    await test("invalid stored mode defaults to alwaysAsk") {
        let suite = isolatedDefaults()
        defer { suite.tearDown() }
        suite.defaults.set("not-a-mode", forKey: BridgeDefaults.messagesSendApprovalMode)
        try expect(MessagesSendApprovalPolicy.load(from: suite.defaults) == .alwaysAsk)
    }

    await test("save session round-trips and alwaysAsk clears the key") {
        let suite = isolatedDefaults()
        defer { suite.tearDown() }
        MessagesSendApprovalPolicy.save(.session, to: suite.defaults)
        try expect(MessagesSendApprovalPolicy.load(from: suite.defaults) == .session)
        try expect(suite.defaults.string(forKey: BridgeDefaults.messagesSendApprovalMode) == "session")
        MessagesSendApprovalPolicy.save(.alwaysAsk, to: suite.defaults)
        try expect(MessagesSendApprovalPolicy.load(from: suite.defaults) == .alwaysAsk)
        try expect(suite.defaults.object(forKey: BridgeDefaults.messagesSendApprovalMode) == nil,
                   "Always ask must remove the stored key")
        try expect(suite.defaults.integer(forKey: BridgeDefaults.messagesSendApprovalGeneration) >= 2,
                   "each save must bump the generation so session skips can be dropped")
    }

    await test("ordinary one-to-one iMessage/SMS with confirm SEND is eligible") {
        try expect(MessagesSendApprovalPolicy.isOrdinaryOneToOne(ordinarySend()))
        try expect(MessagesSendApprovalPolicy.isOrdinaryOneToOne(ordinarySend(service: "SMS")))
    }

    await test("chatIdentifier, THREAD, chatNNN, missing service, and missing SEND are not ordinary") {
        try expect(!MessagesSendApprovalPolicy.isOrdinaryOneToOne(ordinarySend(extra: [
            "chatIdentifier": .string("chat1234567890")
        ])))
        try expect(!MessagesSendApprovalPolicy.isOrdinaryOneToOne(ordinarySend(extra: [
            "threadPageId": .string("thread-page")
        ])))
        try expect(!MessagesSendApprovalPolicy.isOrdinaryOneToOne(ordinarySend(recipient: "chat42")))
        try expect(!MessagesSendApprovalPolicy.isOrdinaryOneToOne(ordinarySend(omitService: true)))
        try expect(!MessagesSendApprovalPolicy.isOrdinaryOneToOne(ordinarySend(confirm: "yes")))
        try expect(MessagesSendApprovalPolicy.isRawChatIdentifier("chat123"))
        try expect(!MessagesSendApprovalPolicy.isRawChatIdentifier("+15551234567"))
    }

    await test("policy: remote, jobs, and non-ordinary always require a prompt") {
        let local = localSession("s1")
        let remote = ToolDispatchContext(transportSessionId: "s1", origin: .remote)
        try expect(MessagesSendApprovalPolicy.requiresOnDevicePrompt(
            arguments: ordinarySend(), context: remote, mode: .trustedDirect, sessionAlreadyApproved: true
        ))
        try expect(MessagesSendApprovalPolicy.requiresOnDevicePrompt(
            arguments: ordinarySend(), context: .localDefault, mode: .trustedDirect, sessionAlreadyApproved: true
        ))
        try expect(MessagesSendApprovalPolicy.requiresOnDevicePrompt(
            arguments: ordinarySend(extra: ["chatIdentifier": .string("iMessage;-;+1555")]),
            context: local, mode: .trustedDirect, sessionAlreadyApproved: true
        ))
        try expect(MessagesSendApprovalPolicy.requiresOnDevicePrompt(
            arguments: ordinarySend(), context: local, mode: .alwaysAsk, sessionAlreadyApproved: true
        ))
        try expect(MessagesSendApprovalPolicy.requiresOnDevicePrompt(
            arguments: ordinarySend(), context: local, mode: .session, sessionAlreadyApproved: false
        ))
        try expect(!MessagesSendApprovalPolicy.requiresOnDevicePrompt(
            arguments: ordinarySend(), context: local, mode: .session, sessionAlreadyApproved: true
        ))
        try expect(!MessagesSendApprovalPolicy.requiresOnDevicePrompt(
            arguments: ordinarySend(), context: local, mode: .trustedDirect, sessionAlreadyApproved: false
        ))
    }

    await test("gate trustedDirect skips the modal for ordinary local session sends") {
        try await withStandardApprovalMode(.trustedDirect) {
            let provider = TestSecurityApprovalProvider()
            let gate = SecurityGate(approvalProvider: provider)
            let decision = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("live-1"))
            try expectAllow(decision, "trustedDirect ordinary local send")
            try expect(provider.approvalRequestCount == 0, "trustedDirect must not show the modal")
        }
    }

    await test("gate trustedDirect still prompts group, THREAD, remote, jobs, and chatNNN") {
        try await withStandardApprovalMode(.trustedDirect) {
            let cases: [(String, Value, ToolDispatchContext)] = [
                ("group", ordinarySend(extra: ["chatIdentifier": .string("chat1234567890")]), localSession("live-1")),
                ("THREAD", ordinarySend(extra: ["threadPageId": .string("thread-page")]), localSession("live-1")),
                ("chatNNN", ordinarySend(recipient: "chat99"), localSession("live-1")),
                ("remote", ordinarySend(), ToolDispatchContext(transportSessionId: "live-1", origin: .remote)),
                ("job", ordinarySend(), .localDefault),
            ]
            for (label, arguments, context) in cases {
                let provider = TestSecurityApprovalProvider()
                let gate = SecurityGate(approvalProvider: provider)
                let decision = await enforceMessages(gate: gate, arguments: arguments, context: context)
                try expectAllow(decision, "\(label) still executes after prompt")
                try expect(provider.approvalRequestCount == 1, "\(label) must prompt under trustedDirect")
            }
        }
    }

    await test("gate session: first ordinary send prompts, later same session skips, other session prompts") {
        try await withStandardApprovalMode(.session) {
            let provider = TestSecurityApprovalProvider()
            let gate = SecurityGate(approvalProvider: provider)
            let first = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            try expectAllow(first, "first session send")
            try expect(provider.approvalRequestCount == 1, "first session send must prompt")
            let second = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            try expectAllow(second, "second same-session send")
            try expect(provider.approvalRequestCount == 1, "same session must skip the second prompt")
            let other = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s2"))
            try expectAllow(other, "different session send")
            try expect(provider.approvalRequestCount == 2, "a new session must prompt")
        }
    }

    await test("gate session denial does not grant later skips") {
        try await withStandardApprovalMode(.session) {
            let provider = TestSecurityApprovalProvider(decision: .deny)
            let gate = SecurityGate(approvalProvider: provider)
            let first = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            guard case .reject = first else {
                throw TestError.assertion("denied first send must reject")
            }
            try expect(provider.approvalRequestCount == 1)
            let second = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            guard case .reject = second else {
                throw TestError.assertion("denied session must still prompt and reject")
            }
            try expect(provider.approvalRequestCount == 2, "denial must not record a session skip")
        }
    }

    await test("gate alwaysAsk never skips ordinary local session sends") {
        try await withStandardApprovalMode(.alwaysAsk) {
            let provider = TestSecurityApprovalProvider()
            let gate = SecurityGate(approvalProvider: provider)
            _ = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            _ = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            try expect(provider.approvalRequestCount == 2, "Always ask must prompt every send")
        }
    }

    await test("leaving session mode forgets prior session approvals") {
        try await withStandardApprovalMode(.session) {
            let provider = TestSecurityApprovalProvider()
            let gate = SecurityGate(approvalProvider: provider)
            _ = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            try expect(provider.approvalRequestCount == 1)
            MessagesSendApprovalPolicy.save(.trustedDirect)
            _ = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            try expect(provider.approvalRequestCount == 1, "trustedDirect skip after leaving session")
            MessagesSendApprovalPolicy.save(.session)
            _ = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            try expect(provider.approvalRequestCount == 2, "returning to session must prompt again")
        }
    }

    await test("reverting Always ask then returning to session forgets skips without an intervening send") {
        try await withStandardApprovalMode(.session) {
            let provider = TestSecurityApprovalProvider()
            let gate = SecurityGate(approvalProvider: provider)
            _ = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            try expect(provider.approvalRequestCount == 1)
            MessagesSendApprovalPolicy.save(.alwaysAsk)
            MessagesSendApprovalPolicy.save(.session)
            _ = await enforceMessages(gate: gate, arguments: ordinarySend(), context: localSession("s1"))
            try expect(provider.approvalRequestCount == 2, "mode revert must drop in-memory session skips")
        }
    }

    await test("messages_send result includes the active approvalMode") {
        try await withStandardApprovalMode(.session) {
            let router = ToolRouter(
                securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
                auditLog: AuditLog()
            )
            await MessagesModule.register(on: router)
            let result = try await router.dispatch(
                toolName: "messages_send",
                arguments: .object([
                    "recipient": .string("+15551234567"),
                    "body": .string("diagnostic-only invalid-service probe"),
                    "confirm": .string("SEND"),
                    "service": .string("auto")
                ])
            )
            guard case .object(let object) = result else {
                throw TestError.assertion("invalid-service result must be an object")
            }
            try expect(object["sent"] == .bool(false))
            try expect(object["approvalMode"] == .string("session"),
                       "diagnostics must surface the live approval mode")
        }
    }

    await test("messages_send stays neverAutoApprove and documents configurable approval") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await MessagesModule.register(on: router)
        let tool = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }!
        try expect(tool.neverAutoApprove, "Always Allow must not persist a downgrade")
        try expect(tool.tier == .request)
        try expect(tool.description.contains("Always ask"), "tool description must name the default mode")
        try expect(tool.description.contains("remote"), "tool description must name remote as always-prompt")
    }

    await test("Gates UI and AX lock the messages send approval control") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let ui = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("TheBridge/UI/Sections/PermissionsSection.swift"),
            encoding: .utf8
        )
        try expect(ui.contains("messagesApprovalCard"), "Gates tab must render the approval card")
        try expect(ui.contains("BridgeAXID.Security.messagesSendApproval"),
                   "Gates card must use the locked AX id")
        let id = await MainActor.run { BridgeAXID.Security.messagesSendApproval }
        try expect(id == "bridge.settings.security.messages.approval", "got \(id)")
    }
}

// MARK: - Helpers

private struct IsolatedDefaults {
    let name: String
    let defaults: UserDefaults
    func tearDown() { defaults.removePersistentDomain(forName: name) }
}

private func isolatedDefaults() -> IsolatedDefaults {
    let name = "bridge.test.messages-approval.\(UUID().uuidString)"
    return IsolatedDefaults(name: name, defaults: UserDefaults(suiteName: name)!)
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

private func withStandardApprovalMode(
    _ mode: MessagesSendApprovalMode,
    _ body: () async throws -> Void
) async throws {
    let key = BridgeDefaults.messagesSendApprovalMode
    let generationKey = BridgeDefaults.messagesSendApprovalGeneration
    let previous = UserDefaults.standard.object(forKey: key)
    let previousGeneration = UserDefaults.standard.object(forKey: generationKey)
    defer {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let previousGeneration {
            UserDefaults.standard.set(previousGeneration, forKey: generationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: generationKey)
        }
    }
    MessagesSendApprovalPolicy.save(mode)
    try await body()
}

private func enforceMessages(
    gate: SecurityGate,
    arguments: Value,
    context: ToolDispatchContext
) async -> GateDecision {
    await gate.enforce(
        toolName: "messages_send",
        tier: .request,
        neverAutoApprove: true,
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
