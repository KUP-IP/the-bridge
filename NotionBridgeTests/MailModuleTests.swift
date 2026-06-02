// MailModuleTests.swift – v3.7·H (PKT-961) MailModule Tests
// NotionBridge · Tests
//
// Exercises the MailModule tools against an INJECTABLE mock AppleScript seam
// (`MockMailScriptRunner`) — no Mail.app is launched and NO mail is ever sent.
// The mock records every script it is handed so we can assert the send-guard
// REFUSED a no-confirm send WITHOUT ever invoking the seam.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - Mock AppleScript Seam

/// Deterministic, side-effect-free MailScriptRunner. Records each script and
/// returns a canned result (default success). A class (reference type) so the
/// recorded scripts are observable after dispatch despite the `Sendable` seam.
final class MockMailScriptRunner: MailScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    private let result: MailScriptResult

    init(result: MailScriptResult = .success("")) {
        self.result = result
    }

    var scripts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _scripts
    }

    var runCount: Int { scripts.count }

    func run(_ script: String) -> MailScriptResult {
        lock.lock(); _scripts.append(script); lock.unlock()
        return result
    }
}

// MARK: - MailModule Tests

func runMailModuleTests() async {
    print("\n\u{1F4E7} MailModule Tests (PKT-961 · v3.7·H)")

    // Each test installs a fresh mock seam; restore the production runner after.
    func withMock(_ mock: MockMailScriptRunner, _ body: () async throws -> Void) async rethrows {
        let prior = MailModule.scriptRunner
        MailModule.scriptRunner = mock
        defer { MailModule.scriptRunner = prior }
        try await body()
    }

    func makeRouter() async -> ToolRouter {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await MailModule.register(on: router)
        return router
    }

    // 1. Registration — exactly the 5 mail_* tools.
    await test("MailModule registers 5 tools") {
        let router = await makeRouter()
        let tools = await router.registrations(forModule: "mail")
        try expect(tools.count == 5, "Expected 5 mail tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        for n in ["mail_list", "mail_read", "mail_search", "mail_draft", "mail_send"] {
            try expect(names.contains(n), "Missing \(n)")
        }
    }

    // 2. Tiering — list/read/search .open, draft .notify, send .request.
    await test("mail tiers: list/read/search=.open, draft=.notify, send=.request") {
        let router = await makeRouter()
        let tools = await router.registrations(forModule: "mail")
        func tier(_ name: String) throws -> SecurityTier {
            guard let t = tools.first(where: { $0.name == name }) else {
                throw TestError.assertion("missing \(name)")
            }
            return t.tier
        }
        try expect(try tier("mail_list") == .open, "mail_list must be .open")
        try expect(try tier("mail_read") == .open, "mail_read must be .open")
        try expect(try tier("mail_search") == .open, "mail_search must be .open")
        try expect(try tier("mail_draft") == .notify, "mail_draft must be .notify")
        try expect(try tier("mail_send") == .request, "mail_send must be .request")
    }

    // 3. mail_list — parses tab/newline rows from the seam.
    await test("mail_list returns parsed rows from the seam") {
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
                  case .string(let subj0) = r0["subject"] else {
                throw TestError.assertion("row0 missing id/subject")
            }
            try expect(id0 == "101", "Expected id 101, got \(id0)")
            try expect(subj0 == "Hello", "Expected subject 'Hello', got \(subj0)")
        }
    }

    // 4. mail_read — parses header/body split from the seam.
    await test("mail_read returns subject/sender/date/body") {
        let fixture = "Project Update\nalice@example.com\nMon Jun 2\n---\nThe body line one.\nLine two."
        let mock = MockMailScriptRunner(result: .success(fixture))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_read", arguments: .object(["messageId": .string("101")]))
            guard case .object(let dict) = result,
                  case .string(let subject) = dict["subject"],
                  case .string(let body) = dict["body"] else {
                throw TestError.assertion("Expected subject/body, got \(result)")
            }
            try expect(subject == "Project Update", "Expected subject, got \(subject)")
            try expect(body.contains("body line one"), "Expected body content, got \(body)")
        }
    }

    // 5. mail_search — keyword query parses matching rows.
    await test("mail_search returns matching rows") {
        let fixture = "201\tfalse\tWed\tcarol@example.com\tInvoice March"
        let mock = MockMailScriptRunner(result: .success(fixture))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_search", arguments: .object(["query": .string("Invoice")]))
            guard case .object(let dict) = result, case .int(let count) = dict["count"] else {
                throw TestError.assertion("Expected count, got \(result)")
            }
            try expect(count == 1, "Expected 1 hit, got \(count)")
            // The query keyword must have been escaped into the script.
            try expect(mock.scripts.first?.contains("Invoice") == true, "search script should contain the query")
        }
    }

    // 6. mail_draft — creates an UNSENT draft; the script must NOT send.
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
            // The draft script must never contain a `send` command.
            let script = mock.scripts.first ?? ""
            try expect(!script.contains("send newMsg"), "draft script must NOT send")
            try expect(script.contains("save newMsg"), "draft script must save the message")
        }
    }

    // 7. SEND-GUARD — mail_send WITHOUT the confirm token is REFUSED and
    //    NEVER invokes the AppleScript seam (no mail sent).
    await test("SEND-GUARD: mail_send WITHOUT confirm='SEND' is refused (seam never runs)") {
        let mock = MockMailScriptRunner(result: .success("sent"))
        try await withMock(mock) {
            let router = await makeRouter()
            let result = try await router.dispatch(toolName: "mail_send", arguments: .object([
                "to": .string("alice@example.com"),
                "subject": .string("Should not send"),
                "body": .string("nope"),
                "confirm": .string("nope")   // wrong token
            ]))
            guard case .object(let dict) = result, case .bool(let sent) = dict["sent"] else {
                throw TestError.assertion("Expected sent flag, got \(result)")
            }
            try expect(sent == false, "Expected sent=false without confirm='SEND'")
            // The guard returns BEFORE building/running any script.
            try expect(mock.runCount == 0, "send-guard MUST short-circuit before the AppleScript seam runs (runCount=\(mock.runCount))")
        }
    }

    // 8. SEND-GUARD: a missing confirm token also refuses (still never sends).
    await test("SEND-GUARD: mail_send with NO confirm key is rejected before the seam") {
        let mock = MockMailScriptRunner(result: .success("sent"))
        try await withMock(mock) {
            let router = await makeRouter()
            do {
                _ = try await router.dispatch(toolName: "mail_send", arguments: .object([
                    "to": .string("alice@example.com"),
                    "subject": .string("x"),
                    "body": .string("y")
                    // confirm absent → invalidArguments
                ]))
                throw TestError.assertion("Expected error for missing confirm")
            } catch is ToolRouterError {
                // Expected — missing required param.
            }
            try expect(mock.runCount == 0, "no-confirm send must not touch the seam")
        }
    }

    // 9. mail_send WITH the exact confirm token sends through the (mock) seam.
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

    // 10. Error path — a seam failure (e.g. TCC denial -1743) surfaces as a
    //     structured error with guidance, not a crash.
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

    // 11. Argument validation — required params enforced for read/search/draft.
    await test("mail_read / mail_search / mail_draft reject missing required params") {
        let mock = MockMailScriptRunner()
        try await withMock(mock) {
            let router = await makeRouter()
            for (tool, args) in [
                ("mail_read", Value.object([:])),
                ("mail_search", Value.object([:])),
                ("mail_draft", Value.object(["to": .string("a@b.com")]))  // missing subject/body
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

    // 12. Annotation catalog mirror — mail_send confirms, reads don't.
    await test("mail annotations mirror the security model (send confirms, reads don't)") {
        let send = ToolAnnotationCatalog.annotations(for: "mail_send")
        try expect(send?.requiresConfirmation == true, "mail_send must require confirmation")
        try expect(send?.readOnlyHint == false, "mail_send is not read-only")
        let list = ToolAnnotationCatalog.annotations(for: "mail_list")
        try expect(list?.readOnlyHint == true && list?.requiresConfirmation == false,
                   "mail_list must be read-only, no confirm")
        let draft = ToolAnnotationCatalog.annotations(for: "mail_draft")
        try expect(draft?.requiresConfirmation == false, "mail_draft (.notify) must not require confirmation")
    }
}
