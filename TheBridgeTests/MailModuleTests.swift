// MailModuleTests.swift – MailModule Tests (PKT-961 + inbox management)
// TheBridge · Tests
//
// Exercises MailModule against an INJECTABLE mock AppleScript seam — no
// Mail.app, no real send/archive/trash. Guards must refuse before the seam runs.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Mock AppleScript Seam

/// Deterministic MailScriptRunner. Supports a single canned result or a
/// sequenced queue (mutate then verify). Records every script.
final class MockMailScriptRunner: MailScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    private var _results: [MailScriptResult]
    private let defaultResult: MailScriptResult

    init(result: MailScriptResult = .success("")) {
        self.defaultResult = result
        self._results = []
    }

    /// FIFO results; after exhaustion falls back to `defaultResult`.
    init(results: [MailScriptResult], defaultResult: MailScriptResult = .success("")) {
        self.defaultResult = defaultResult
        self._results = results
    }

    var scripts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _scripts
    }

    var runCount: Int { scripts.count }

    func run(_ script: String) -> MailScriptResult {
        lock.lock()
        _scripts.append(script)
        let next: MailScriptResult
        if !_results.isEmpty {
            next = _results.removeFirst()
        } else {
            next = defaultResult
        }
        lock.unlock()
        return next
    }
}

// MARK: - MailModule Tests

func runMailModuleTests() async {
    print("\n\u{1F4E7} MailModule Tests (PKT-961 · inbox management)")

    func withMock(_ mock: MockMailScriptRunner, _ body: () async throws -> Void) async rethrows {
        let prior = MailModule.scriptRunner
        MailModule.scriptRunner = mock
        defer { MailModule.scriptRunner = prior }
        try await body()
    }

    func makeRouter() async -> ToolRouter {
        let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await MailModule.register(on: router)
        return router
    }

    // 1. Registration — 11 mail_* tools.
    await test("MailModule registers 11 tools") {
        let router = await makeRouter()
        let tools = await router.registrations(forModule: "mail")
        try expect(tools.count == 11, "Expected 11 mail tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        for n in [
            "mail_list", "mail_read", "mail_search", "mail_mailboxes", "mail_triage",
            "mail_draft", "mail_move", "mail_archive", "mail_mark", "mail_trash", "mail_send"
        ] {
            try expect(names.contains(n), "Missing \(n)")
        }
    }

    // 2. Tiering
    await test("mail tiers: reads=.open, organize=.notify, trash/send=.request") {
        let router = await makeRouter()
        let tools = await router.registrations(forModule: "mail")
        func tier(_ name: String) throws -> SecurityTier {
            guard let t = tools.first(where: { $0.name == name }) else {
                throw TestError.assertion("missing \(name)")
            }
            return t.tier
        }
        func neverAuto(_ name: String) throws -> Bool {
            guard let t = tools.first(where: { $0.name == name }) else {
                throw TestError.assertion("missing \(name)")
            }
            return t.neverAutoApprove
        }
        try expect(try tier("mail_list") == .open, "mail_list must be .open")
        try expect(try tier("mail_read") == .open, "mail_read must be .open")
        try expect(try tier("mail_search") == .open, "mail_search must be .open")
        try expect(try tier("mail_mailboxes") == .open, "mail_mailboxes must be .open")
        try expect(try tier("mail_triage") == .open, "mail_triage must be .open")
        try expect(try tier("mail_draft") == .notify, "mail_draft must be .notify")
        try expect(try tier("mail_move") == .notify, "mail_move must be .notify")
        try expect(try tier("mail_archive") == .notify, "mail_archive must be .notify")
        try expect(try tier("mail_mark") == .notify, "mail_mark must be .notify")
        try expect(try tier("mail_trash") == .request, "mail_trash must be .request")
        try expect(try neverAuto("mail_trash") == true, "mail_trash must neverAutoApprove")
        try expect(try tier("mail_send") == .request, "mail_send must be .request")
    }

    // 3. mail_list — parses rows + mailbox echo
    await test("mail_list returns parsed rows with mailbox echo") {
        let fixture = "101\ttrue\tMon\talice@example.com\tHello\n102\tfalse\tTue\tbob@example.com\tRe: Hello"
        let mock = MockMailScriptRunner(result: .success(fixture))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_list", arguments: .object(["limit": .int(10)]))
            guard case .object(let dict) = result,
                  case .int(let count) = dict["count"],
                  case .array(let rows) = dict["rows"] else {
                throw TestError.assertion("Expected {count, rows} object, got \(result)")
            }
            try expect(count == 2, "Expected 2 rows, got \(count)")
            guard case .object(let r0) = rows[0], case .string(let id0) = r0["id"],
                  case .string(let subj0) = r0["subject"],
                  case .string(let mb) = r0["mailbox"] else {
                throw TestError.assertion("row0 missing id/subject/mailbox")
            }
            try expect(id0 == "101", "Expected id 101, got \(id0)")
            try expect(subj0 == "Hello", "Expected subject 'Hello', got \(subj0)")
            try expect(mb == "Inbox", "Expected mailbox Inbox echo, got \(mb)")
        }
    }

    // 4. mail_read — header/body + optional mailbox locator in script
    await test("mail_read returns subject/sender/date/body and scopes mailbox") {
        let fixture = "Project Update\nalice@example.com\nMon Jun 2\nArchive\n---\nThe body line one.\nLine two."
        let mock = MockMailScriptRunner(result: .success(fixture))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_read", arguments: .object([
                "messageId": .string("101"),
                "mailbox": .string("Archive")
            ]))
            guard case .object(let dict) = result,
                  case .string(let subject) = dict["subject"],
                  case .string(let body) = dict["body"],
                  case .string(let mailbox) = dict["mailbox"] else {
                throw TestError.assertion("Expected subject/body/mailbox, got \(result)")
            }
            try expect(subject == "Project Update", "Expected subject, got \(subject)")
            try expect(body.contains("body line one"), "Expected body content, got \(body)")
            try expect(mailbox == "Archive", "Expected mailbox Archive, got \(mailbox)")
            try expect(mock.scripts.first?.contains("mailbox \"Archive\"") == true,
                       "read script should scope to Archive mailbox")
        }
    }

    // 5. mail_search — subject or sender
    await test("mail_search returns matching rows and matches sender") {
        let fixture = "201\tfalse\tWed\tcarol@example.com\tInvoice March"
        let mock = MockMailScriptRunner(result: .success(fixture))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_search", arguments: .object(["query": .string("Invoice")]))
            guard case .object(let dict) = result, case .int(let count) = dict["count"] else {
                throw TestError.assertion("Expected count, got \(result)")
            }
            try expect(count == 1, "Expected 1 hit, got \(count)")
            let script = mock.scripts.first ?? ""
            try expect(script.contains("Invoice") == true, "search script should contain the query")
            try expect(script.contains("sender contains") == true, "search should match sender")
        }
    }

    // 6. mail_mailboxes
    await test("mail_mailboxes parses account/mailbox rows") {
        let fixture = "iCloud\tInbox\niCloud\tArchive\nGmail\tTrash"
        let mock = MockMailScriptRunner(result: .success(fixture))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_mailboxes", arguments: .object([:]))
            guard case .object(let dict) = result,
                  case .int(let count) = dict["count"],
                  case .array(let accounts) = dict["accounts"] else {
                throw TestError.assertion("Expected accounts/count, got \(result)")
            }
            try expect(count == 3, "Expected 3 mailboxes, got \(count)")
            try expect(accounts.count == 2, "Expected 2 accounts, got \(accounts.count)")
        }
    }

    // 7. mail_triage — advisory buckets via signals
    await test("mail_triage buckets preserve vs candidateArchive") {
        let fixture = """
            101\ttrue\tMon\talerts@chase.com\tSecurity alert on your card
            102\ttrue\tTue\tnews@shop.com\tWeekly digest — unsubscribe
            """
        let mock = MockMailScriptRunner(result: .success(fixture))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_triage", arguments: .object(["limit": .int(10)]))
            guard case .object(let dict) = result,
                  case .bool(let advisory) = dict["advisory"],
                  case .array(let preserve) = dict["preserve"],
                  case .array(let candidate) = dict["candidateArchive"] else {
                throw TestError.assertion("Expected triage buckets, got \(result)")
            }
            try expect(advisory == true, "triage must be advisory")
            try expect(preserve.count >= 1, "expected at least one preserve row")
            try expect(candidate.count >= 1, "expected at least one candidateArchive row")
        }
    }

    // 8. MailTriageSignals pure unit checks
    await test("MailTriageSignals classifies legal/finance as preserve") {
        let row = MailTriageSignals.classify(
            messageId: "1",
            subject: "Court summons — action required",
            sender: "clerk@courts.gov",
            date: "Mon",
            read: "false"
        )
        try expect(row.recommendation == .preserve, "court summons should preserve")
        try expect(!row.reasons.isEmpty, "preserve should carry reasons")
    }

    await test("MailTriageSignals classifies read newsletter as candidateArchive") {
        let row = MailTriageSignals.classify(
            messageId: "2",
            subject: "Weekly digest of deals",
            sender: "noreply@shop.com",
            date: "Tue",
            read: "true"
        )
        try expect(row.recommendation == .candidateArchive, "read newsletter → candidateArchive")
    }

    await test("MailTriageSignals never archives from silence (read + no signals → needsReview)") {
        let row = MailTriageSignals.classify(
            messageId: "3",
            subject: "Lunch tomorrow?",
            sender: "friend@example.com",
            date: "Wed",
            read: "true"
        )
        try expect(row.recommendation == .needsReview, "unknown read mail must not be candidateArchive")
    }

    await test("MailTriageSignals noreply transactional mail → needsReview (not candidateArchive)") {
        let shipped = MailTriageSignals.classify(
            messageId: "4",
            subject: "Your order has shipped",
            sender: "Amazon <noreply@amazon.com>",
            date: "Thu",
            read: "true"
        )
        try expect(shipped.recommendation == .needsReview, "noreply shipping must not be candidateArchive")
        let receipt = MailTriageSignals.classify(
            messageId: "5",
            subject: "Your receipt from Acme",
            sender: "noreply@acme.com",
            date: "Thu",
            read: "true"
        )
        try expect(receipt.recommendation == .needsReview, "noreply receipt must not be candidateArchive")
    }

    await test("MailTriageSignals newsletter+unsubscribe still candidateArchive when read") {
        let row = MailTriageSignals.classify(
            messageId: "6",
            subject: "Weekly digest — unsubscribe anytime",
            sender: "news@shop.com",
            date: "Fri",
            read: "true"
        )
        try expect(row.recommendation == .candidateArchive, "explicit newsletter hints still archive")
    }

    await test("destinationMatches accepts Archive↔All Mail aliases") {
        try expect(MailModule.destinationMatches(foundIn: "All Mail", requested: "Archive"), "All Mail aliases Archive")
        try expect(MailModule.destinationMatches(foundIn: "[Gmail]/All Mail", requested: "Archive"), "Gmail All Mail aliases Archive")
        try expect(MailModule.destinationMatches(foundIn: "Archive", requested: "Archive"), "exact Archive")
        try expect(!MailModule.destinationMatches(foundIn: "Trash", requested: "Archive"), "Trash is not Archive")
    }

    await test("forcesBatchHumanApproval true only for archive/move with >1 unique id") {
        let batch = Value.object([
            "messageIds": .array([.string("1"), .string("2")]),
            "account": .string("iCloud")
        ])
        let single = Value.object([
            "messageIds": .array([.string("1")]),
            "account": .string("iCloud")
        ])
        try expect(MailModule.forcesBatchHumanApproval(toolName: "mail_archive", arguments: batch), "batch archive forces")
        try expect(MailModule.forcesBatchHumanApproval(toolName: "mail_move", arguments: batch), "batch move forces")
        try expect(!MailModule.forcesBatchHumanApproval(toolName: "mail_archive", arguments: single), "single archive does not force")
        try expect(!MailModule.forcesBatchHumanApproval(toolName: "mail_mark", arguments: batch), "mark never forces")
        let duped = Value.object(["messageIds": .array([.string("1"), .string("1")])])
        try expect(!MailModule.forcesBatchHumanApproval(toolName: "mail_archive", arguments: duped), "dup ids count as one")
    }

    // 9. mail_draft
    await test("mail_draft creates an unsent draft (no send command)") {
        let mock = MockMailScriptRunner(result: .success("draft-42"))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_draft", arguments: .object([
                "to": .string("alice@example.com"),
                "subject": .string("Hi"),
                "body": .string("Body text")
            ]))
            guard case .object(let dict) = result,
                  case .bool(let drafted) = dict["drafted"],
                  case .bool(let sent) = dict["sent"] else {
                throw TestError.assertion("Expected drafted/sent flags, got \(result)")
            }
            try expect(drafted == true, "Expected drafted=true")
            try expect(sent == false, "Expected sent=false for a draft")
            let script = mock.scripts.first ?? ""
            try expect(!script.contains("send newMsg"), "draft script must NOT send")
            try expect(script.contains("save newMsg"), "draft script must save the message")
        }
    }

    // 10. Identity — refuse empty/oversized/missing account; seam never runs
    await test("organize tools refuse empty/oversized ids or missing account before seam") {
        let mock = MockMailScriptRunner(result: .success("OK"))
        try await withMock(mock) {
            let router = await makeRouter()
            do {
                _ = try await router.dispatch(toolName: "mail_archive", arguments: .object([
                    "messageIds": .array([]),
                    "account": .string("iCloud")
                ]))
                throw TestError.assertion("Expected error for empty messageIds")
            } catch is ToolRouterError {
                // expected
            }
            do {
                _ = try await router.dispatch(toolName: "mail_archive", arguments: .object([
                    "messageIds": .array([.string("101")])
                ]))
                throw TestError.assertion("Expected error for missing account")
            } catch is ToolRouterError {
                // expected
            }
            let tooMany = (1...26).map { Value.string(String($0)) }
            do {
                _ = try await router.dispatch(toolName: "mail_move", arguments: .object([
                    "messageIds": .array(tooMany),
                    "account": .string("iCloud"),
                    "destinationMailbox": .string("Archive"),
                    "confirm": .string("MOVE")
                ]))
                throw TestError.assertion("Expected error for >25 messageIds")
            } catch is ToolRouterError {
                // expected
            }
            try expect(mock.runCount == 0, "invalid organize args must not touch the seam")
        }
    }

    // 11. planOnly — zero seam invocations
    await test("mail_archive planOnly plans without invoking the seam") {
        let mock = MockMailScriptRunner(result: .success("should-not-run"))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_archive", arguments: .object([
                "messageIds": .array([.string("101"), .string("102")]),
                "account": .string("iCloud"),
                "confirm": .string("ARCHIVE"),
                "planOnly": .bool(true)
            ]))
            guard case .object(let dict) = result,
                  case .bool(let plan) = dict["planOnly"],
                  case .array(let planned) = dict["planned"],
                  case .array(let mutated) = dict["mutated"],
                  case .array(let succeeded) = dict["succeeded"] else {
                throw TestError.assertion("Expected planOnly receipt, got \(result)")
            }
            try expect(plan == true, "planOnly flag")
            try expect(planned.count == 2, "planned should list both ids")
            try expect(mutated.isEmpty && succeeded.isEmpty, "planOnly must not mutate")
            try expect(mock.runCount == 0, "planOnly must not invoke AppleScript seam")
        }
    }

    // 12. Batch archive without confirm refuses (after human approval path)
    await test("BATCH-GUARD: mail_archive >1 id without confirm='ARCHIVE' refuses") {
        let mock = MockMailScriptRunner(result: .success("OK"))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_archive", arguments: .object([
                "messageIds": .array([.string("101"), .string("102")]),
                "account": .string("iCloud")
            ]))
            guard case .object(let dict) = result,
                  case .bool(let refused) = dict["refused"] else {
                throw TestError.assertion("Expected refused, got \(result)")
            }
            try expect(refused == true, "batch archive needs confirm ARCHIVE")
            try expect(mock.runCount == 0, "batch refuse must not touch seam")
        }
    }

    await test("BATCH-GATE: mail_archive >1 id denied at SecurityGate never touches seam") {
        let mock = MockMailScriptRunner(result: .success("OK"))
        try await withMock(mock) {
            let provider = TestSecurityApprovalProvider(decision: .deny)
            let gate = SecurityGate(approvalProvider: provider)
            let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
            await MailModule.register(on: router)
            do {
                _ = try await router.dispatch(toolName: "mail_archive", arguments: .object([
                    "messageIds": .array([.string("101"), .string("102")]),
                    "account": .string("iCloud"),
                    "confirm": .string("ARCHIVE")
                ]))
                throw TestError.assertion("Expected security rejection for denied batch archive")
            } catch is ToolRouterError {
                // expected
            }
            try expect(provider.approvalRequestCount >= 1, "batch must prompt Request-tier approval")
            try expect(mock.runCount == 0, "denied batch must not touch seam")
        }
    }

    await test("BATCH-GATE: single-id mail_archive stays Notify (no approval prompt)") {
        let mock = MockMailScriptRunner(results: [
            .success("OK\t101\tInbox\tArchive"),
            .success("101\tArchive\ttrue\tfalse")
        ])
        try await withMock(mock) {
            let provider = TestSecurityApprovalProvider(decision: .allow)
            let gate = SecurityGate(approvalProvider: provider)
            let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
            await MailModule.register(on: router)
            _ = try await router.dispatch(toolName: "mail_archive", arguments: .object([
                "messageIds": .array([.string("101")]),
                "account": .string("iCloud")
            ]))
            try expect(provider.approvalRequestCount == 0, "single-id archive must not Request-prompt")
        }
    }

    await test("batch force-request resolves effective tier to .request via neverAutoApprove") {
        let forced = ToolRouter.resolveEffectiveTier(
            toolName: "mail_archive",
            module: "mail",
            registeredTier: .notify,
            neverAutoApprove: true,
            toolOverrides: [:],
            moduleOverrides: [:]
        )
        try expect(forced == .request, "forced neverAutoApprove → request")
        let single = ToolRouter.resolveEffectiveTier(
            toolName: "mail_archive",
            module: "mail",
            registeredTier: .notify,
            neverAutoApprove: false,
            toolOverrides: [:],
            moduleOverrides: [:]
        )
        try expect(single == .notify, "single-id path stays notify")
    }

    // 13. mail_archive apply + verify receipt (account-scoped)
    await test("mail_archive apply returns mutated+verified receipt") {
        let mock = MockMailScriptRunner(results: [
            .success("OK\t101\tInbox\tArchive"),
            .success("101\tArchive\ttrue\tfalse")
        ])
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_archive", arguments: .object([
                "messageIds": .array([.string("101")]),
                "account": .string("iCloud")
            ]))
            guard case .object(let dict) = result,
                  case .bool(let ok) = dict["ok"],
                  case .array(let mutated) = dict["mutated"],
                  case .array(let succeeded) = dict["succeeded"],
                  case .array(let verified) = dict["verified"] else {
                throw TestError.assertion("Expected archive receipt, got \(result)")
            }
            try expect(ok == true, "archive should ok when verified")
            try expect(mutated.count == 1 && succeeded.count == 1, "one mutated")
            try expect(verified.count == 1, "one verified")
            try expect(mock.runCount == 2, "mutate + verify = 2 seam calls")
            try expect(mock.scripts[0].contains("move theMsg") == true, "archive script moves")
            try expect(mock.scripts[0].contains("of account \"iCloud\"") == true, "must scope account")
        }
    }

    await test("mail_archive verify accepts All Mail when destination is Archive") {
        let mock = MockMailScriptRunner(results: [
            .success("OK\t101\tINBOX\tArchive"),
            .success("101\tAll Mail\ttrue\tfalse")
        ])
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_archive", arguments: .object([
                "messageIds": .array([.string("101")]),
                "account": .string("Personal")
            ]))
            guard case .object(let dict) = result,
                  case .bool(let ok) = dict["ok"],
                  case .array(let succeeded) = dict["succeeded"],
                  case .array(let unverified) = dict["unverified"] else {
                throw TestError.assertion("Expected archive receipt, got \(result)")
            }
            try expect(ok == true, "All Mail alias must verify as archive success")
            try expect(succeeded.count == 1, "succeeded after alias verify")
            try expect(unverified.isEmpty, "no unverified on alias match")
        }
    }

    // 14. mutate-ok / verify-fail keeps mutated and warns against retry
    await test("mail_move mutate-ok verify-fail exposes mutated independently") {
        let mock = MockMailScriptRunner(results: [
            .success("OK\t101\tInbox\tProjects"),
            .failure(message: "Can't get message", number: -1728)
        ])
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_move", arguments: .object([
                "messageIds": .array([.string("101")]),
                "account": .string("iCloud"),
                "destinationMailbox": .string("Projects")
            ]))
            guard case .object(let dict) = result,
                  case .bool(let ok) = dict["ok"],
                  case .array(let mutated) = dict["mutated"],
                  case .array(let succeeded) = dict["succeeded"],
                  case .array(let unverified) = dict["unverified"],
                  case .string(let note) = dict["note"] else {
                throw TestError.assertion("Expected partial receipt, got \(result)")
            }
            try expect(ok == false, "overall ok false when verify misses")
            try expect(mutated.count == 1, "side effect recorded")
            try expect(succeeded.isEmpty, "succeeded must exclude unverified mutated")
            try expect(unverified.count == 1, "verify miss recorded")
            try expect(note.contains("do not retry"), "must warn against retry mutate")
        }
    }

    // 15. mail_trash DELETE-guard
    await test("DELETE-GUARD: mail_trash WITHOUT confirm='DELETE' is refused (seam never runs)") {
        let mock = MockMailScriptRunner(result: .success("OK"))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_trash", arguments: .object([
                "messageIds": .array([.string("101")]),
                "account": .string("iCloud"),
                "confirm": .string("nope")
            ]))
            guard case .object(let dict) = result,
                  case .bool(let refused) = dict["refused"] else {
                throw TestError.assertion("Expected refused, got \(result)")
            }
            try expect(refused == true, "wrong confirm must refuse")
            try expect(mock.runCount == 0, "DELETE-guard must short-circuit before seam")
        }
    }

    await test("mail_trash planOnly with confirm='DELETE' still skips seam") {
        let mock = MockMailScriptRunner(result: .success("OK"))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_trash", arguments: .object([
                "messageIds": .array([.string("101")]),
                "account": .string("iCloud"),
                "confirm": .string("DELETE"),
                "planOnly": .bool(true)
            ]))
            guard case .object(let dict) = result,
                  case .bool(let plan) = dict["planOnly"],
                  case .string(let action) = dict["action"] else {
                throw TestError.assertion("Expected planOnly trash receipt, got \(result)")
            }
            try expect(plan == true && action == "trash", "planOnly trash plan")
            try expect(mock.runCount == 0, "planOnly trash must not touch seam")
        }
    }

    // 14. SEND-GUARD
    await test("SEND-GUARD: mail_send WITHOUT confirm='SEND' is refused (seam never runs)") {
        let mock = MockMailScriptRunner(result: .success("sent"))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_send", arguments: .object([
                "to": .string("alice@example.com"),
                "subject": .string("Should not send"),
                "body": .string("nope"),
                "confirm": .string("nope")
            ]))
            guard case .object(let dict) = result, case .bool(let sent) = dict["sent"] else {
                throw TestError.assertion("Expected sent flag, got \(result)")
            }
            try expect(sent == false, "Expected sent=false without confirm='SEND'")
            try expect(mock.runCount == 0, "send-guard MUST short-circuit before the AppleScript seam runs")
        }
    }

    await test("SEND-GUARD: mail_send with NO confirm key is rejected before the seam") {
        let mock = MockMailScriptRunner(result: .success("sent"))
        try await withMock(mock) {
            let router = await makeRouter()
            do {
                _ = try await router.dispatch(toolName: "mail_send", arguments: .object([
                    "to": .string("alice@example.com"),
                    "subject": .string("x"),
                    "body": .string("y")
                ]))
                throw TestError.assertion("Expected error for missing confirm")
            } catch is ToolRouterError {
                // Expected
            }
            try expect(mock.runCount == 0, "no-confirm send must not touch the seam")
        }
    }

    await test("mail_send WITH confirm='SEND' sends through the seam") {
        let mock = MockMailScriptRunner(result: .success("sent"))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_send", arguments: .object([
                "to": .string("alice@example.com"),
                "subject": .string("Approved"),
                "body": .string("Go ahead"),
                "confirm": .string("SEND")
            ]))
            guard case .object(let dict) = result, case .bool(let sent) = dict["sent"] else {
                throw TestError.assertion("Expected sent flag, got \(result)")
            }
            try expect(sent == true, "Expected sent=true with confirm='SEND'")
            try expect(mock.runCount == 1, "send should invoke the seam exactly once")
            try expect(mock.scripts.first?.contains("send newMsg") == true, "send script must contain the send command")
        }
    }

    // 15. TCC error path
    await test("mail_list surfaces a seam failure as a structured error (TCC -1743)") {
        let mock = MockMailScriptRunner(result: .failure(message: "Not authorized to send Apple events to Mail.", number: -1743))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_list", arguments: .object([:]))
            guard case .object(let dict) = result,
                  case .string = dict["error"],
                  case .int(let num) = dict["errorNumber"] else {
                throw TestError.assertion("Expected structured error, got \(result)")
            }
            try expect(num == -1743, "Expected errorNumber -1743, got \(num)")
            try expect(dict["tccDenied"] != nil, "Expected tccDenied guidance on -1743")
        }
    }

    // 16. Argument validation
    await test("mail_read / mail_search / mail_draft reject missing required params") {
        let mock = MockMailScriptRunner()
        try await withMock(mock) {
            let router = await makeRouter()
            for (tool, args) in [
                ("mail_read", Value.object([:])),
                ("mail_search", Value.object([:])),
                ("mail_draft", Value.object(["to": .string("a@b.com")]))
            ] {
                do {
                    _ = try await router.dispatch(toolName: tool, arguments: args)
                    throw TestError.assertion("Expected error for \(tool) with missing params")
                } catch is ToolRouterError {
                    // Expected
                }
            }
        }
    }

    // 17. Annotations
    await test("mail annotations mirror the security model") {
        let send = ToolAnnotationCatalog.annotations(for: "mail_send")
        try expect(send?.requiresConfirmation == true, "mail_send must require confirmation")
        let trash = ToolAnnotationCatalog.annotations(for: "mail_trash")
        try expect(trash?.requiresConfirmation == true, "mail_trash must require confirmation")
        try expect(trash?.destructiveHint == true, "mail_trash is destructive")
        let list = ToolAnnotationCatalog.annotations(for: "mail_list")
        try expect(list?.readOnlyHint == true && list?.requiresConfirmation == false,
                   "mail_list must be read-only, no confirm")
        let triage = ToolAnnotationCatalog.annotations(for: "mail_triage")
        try expect(triage?.readOnlyHint == true, "mail_triage is read-only")
        let archive = ToolAnnotationCatalog.annotations(for: "mail_archive")
        try expect(archive?.requiresConfirmation == false, "mail_archive (.notify) must not require confirmation")
        try expect(archive?.destructiveHint == true, "mail_archive relocates (destructiveHint)")
        let draft = ToolAnnotationCatalog.annotations(for: "mail_draft")
        try expect(draft?.requiresConfirmation == false, "mail_draft (.notify) must not require confirmation")
    }
}
