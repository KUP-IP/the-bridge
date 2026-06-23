// NotesModuleTests.swift – v3.7·G  NotesModule tests
// TheBridge · Tests
//
// Exercises the full notes_* surface against the INJECTABLE AppleScript
// seam — zero contact with live Notes.app. Covers registration + tiers,
// CRUD (create/read/update/delete), search, the AppleScript-error path
// (incl. the -1743 Automation TCC guidance), id-vs-name addressing, and
// missing-parameter rejection, plus the pure script-builder / escaping /
// record-parsing helpers.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Mock runner

/// A deterministic, recording AppleScript seam. Captures every script it
/// was handed and returns a scripted response (default `.ok("")`). Tests
/// drive the entire module without touching Notes.app.
private final class MockNotesRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    private var _response: NotesScriptResult

    init(_ response: NotesScriptResult = .ok("")) {
        self._response = response
    }

    var scripts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _scripts
    }

    var lastScript: String { scripts.last ?? "" }

    func setResponse(_ r: NotesScriptResult) {
        lock.lock(); defer { lock.unlock() }
        _response = r
    }

    /// The `NotesScriptRunner` closure to inject.
    func runner() -> NotesScriptRunner {
        return { [self] source in
            lock.lock()
            _scripts.append(source)
            let r = _response
            lock.unlock()
            return r
        }
    }
}

private func makeRouter(_ runner: MockNotesRunner) async -> ToolRouter {
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await NotesModule.register(on: router, runner: runner.runner())
    return router
}

// Build a list/search record string with the module's framing.
private func makeRecords(_ rows: [(String, String, String, String)]) -> String {
    let fs = NotesModule.fieldSep
    let rs = NotesModule.recordSep
    return rows.map { "\($0.0)\(fs)\($0.1)\(fs)\($0.2)\(fs)\($0.3)" }.joined(separator: rs) + rs
}

func runNotesModuleTests() async {
    print("\n🗒️  NotesModule Tests (v3.7·G)")

    // ----------------------------------------------------------------
    // Registration + tiers
    // ----------------------------------------------------------------

    await test("NotesModule registers exactly 6 tools") {
        let router = await makeRouter(MockNotesRunner())
        let tools = await router.registrations(forModule: "notes")
        try expect(tools.count == 6, "Expected 6 notes tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        for n in ["notes_list", "notes_read", "notes_create", "notes_update", "notes_delete", "notes_search"] {
            try expect(names.contains(n), "Missing \(n)")
        }
    }

    await test("notes_* tiers: list/read/search=open, create/update=notify, delete=request") {
        let router = await makeRouter(MockNotesRunner())
        let tools = await router.registrations(forModule: "notes")
        func tier(_ name: String) -> SecurityTier? { tools.first { $0.name == name }?.tier }
        try expect(tier("notes_list") == .open, "list tier \(String(describing: tier("notes_list")))")
        try expect(tier("notes_read") == .open, "read tier")
        try expect(tier("notes_search") == .open, "search tier")
        try expect(tier("notes_create") == .notify, "create tier")
        try expect(tier("notes_update") == .notify, "update tier")
        try expect(tier("notes_delete") == .request, "delete tier")
    }

    await test("every notes tool inputSchema property key is camelCase") {
        let router = await makeRouter(MockNotesRunner())
        var violations: [String] = []
        for reg in await router.registrations(forModule: "notes") {
            guard case .object(let top) = reg.inputSchema,
                  case .object(let props)? = top["properties"] else { continue }
            for key in props.keys {
                let ok = key.first?.isLowercase == true && key.allSatisfy { $0.isLetter || $0.isNumber }
                if !ok { violations.append("\(reg.name).\(key)") }
            }
        }
        try expect(violations.isEmpty, "non-camelCase notes schema keys: \(violations.sorted())")
    }

    // ----------------------------------------------------------------
    // notes_list
    // ----------------------------------------------------------------

    await test("notes_list parses framed records into rows") {
        let runner = MockNotesRunner(.ok(makeRecords([
            ("id://a", "Groceries", "Shopping", "2026-06-01"),
            ("id://b", "Ideas", "Notes", "2026-05-30")
        ])))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(toolName: "notes_list", arguments: .object([:]))
        guard case .object(let dict) = result,
              case .int(let count)? = dict["count"],
              case .array(let rows)? = dict["notes"] else {
            throw TestError.assertion("expected notes/count, got \(result)")
        }
        try expect(count == 2, "expected 2 notes, got \(count)")
        guard case .object(let first) = rows[0], case .string(let name)? = first["name"] else {
            throw TestError.assertion("row 0 malformed")
        }
        try expect(name == "Groceries", "first name \(name)")
    }

    await test("notes_list scopes to a folder when provided") {
        let runner = MockNotesRunner(.ok(""))
        let router = await makeRouter(runner)
        _ = try await router.dispatch(toolName: "notes_list", arguments: .object(["folder": .string("Work")]))
        try expect(runner.lastScript.contains("notes of folder \"Work\""),
                   "folder not scoped in script: \(runner.lastScript)")
    }

    await test("notes_list respects limit") {
        let runner = MockNotesRunner(.ok(makeRecords([
            ("1", "a", "f", "d"), ("2", "b", "f", "d"), ("3", "c", "f", "d")
        ])))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_list", arguments: .object(["limit": .int(2)]))
        guard case .object(let dict) = result, case .int(let count)? = dict["count"] else {
            throw TestError.assertion("expected count")
        }
        try expect(count == 2, "limit not applied, got \(count)")
    }

    // ----------------------------------------------------------------
    // notes_read
    // ----------------------------------------------------------------

    await test("notes_read returns found note by id with body + html") {
        let fs = NotesModule.fieldSep
        let payload = "id://x\(fs)My Note\(fs)Notes\(fs)plain body text\(fs)<div>plain body text</div>"
        let runner = MockNotesRunner(.ok(payload))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_read", arguments: .object(["noteId": .string("id://x")]))
        guard case .object(let dict) = result,
              case .bool(let found)? = dict["found"],
              case .string(let body)? = dict["body"],
              case .string(let html)? = dict["html"] else {
            throw TestError.assertion("expected found/body/html, got \(result)")
        }
        try expect(found == true, "should be found")
        try expect(body == "plain body text", "body \(body)")
        try expect(html == "<div>plain body text</div>", "html \(html)")
        // Reading by id must emit a `note id "…"` resolve clause.
        try expect(runner.lastScript.contains("note id \"id://x\""),
                   "id resolve clause missing: \(runner.lastScript)")
    }

    await test("notes_read by name emits case-insensitive name resolve clause") {
        let runner = MockNotesRunner(.ok(""))
        let router = await makeRouter(runner)
        _ = try await router.dispatch(
            toolName: "notes_read", arguments: .object(["noteName": .string("Groceries")]))
        try expect(runner.lastScript.contains("ignoring case"), "no ignoring-case clause")
        try expect(runner.lastScript.contains("set wanted to \"Groceries\""), "name not bound")
    }

    await test("notes_read returns found=false on empty (no-match) output") {
        let runner = MockNotesRunner(.ok(""))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_read", arguments: .object(["noteId": .string("id://missing")]))
        guard case .object(let dict) = result, case .bool(let found)? = dict["found"] else {
            throw TestError.assertion("expected found flag")
        }
        try expect(found == false, "expected not found")
    }

    await test("notes_read rejects when neither noteId nor noteName given") {
        let router = await makeRouter(MockNotesRunner())
        do {
            _ = try await router.dispatch(toolName: "notes_read", arguments: .object([:]))
            throw TestError.assertion("expected rejection")
        } catch is ToolRouterError {
            // expected
        }
    }

    // ----------------------------------------------------------------
    // notes_create
    // ----------------------------------------------------------------

    await test("notes_create returns created id and embeds title/body in script") {
        let runner = MockNotesRunner(.ok("x-coredata://NEW-NOTE"))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_create",
            arguments: .object(["title": .string("Trip"), "body": .string("pack bags")]))
        guard case .object(let dict) = result,
              case .bool(let created)? = dict["created"],
              case .string(let id)? = dict["id"] else {
            throw TestError.assertion("expected created/id, got \(result)")
        }
        try expect(created == true, "not created")
        try expect(id == "x-coredata://NEW-NOTE", "id \(id)")
        try expect(runner.lastScript.contains("Trip") && runner.lastScript.contains("pack bags"),
                   "title/body not in create script")
        try expect(runner.lastScript.contains("make new note"), "no make-new-note verb")
    }

    await test("notes_create places note in folder when provided") {
        let runner = MockNotesRunner(.ok("id://1"))
        let router = await makeRouter(runner)
        _ = try await router.dispatch(
            toolName: "notes_create",
            arguments: .object(["title": .string("T"), "folder": .string("Work")]))
        try expect(runner.lastScript.contains("folder \"Work\""), "folder not targeted")
        try expect(runner.lastScript.contains("make new note at theFolder"), "not created at folder")
    }

    await test("notes_create rejects missing title") {
        let router = await makeRouter(MockNotesRunner())
        do {
            _ = try await router.dispatch(toolName: "notes_create", arguments: .object(["body": .string("x")]))
            throw TestError.assertion("expected rejection for missing title")
        } catch is ToolRouterError {
            // expected
        }
    }

    // ----------------------------------------------------------------
    // notes_update
    // ----------------------------------------------------------------

    await test("notes_update returns updated=true with note id") {
        let runner = MockNotesRunner(.ok("id://u1"))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_update",
            arguments: .object(["noteId": .string("id://u1"), "body": .string("new content")]))
        guard case .object(let dict) = result,
              case .bool(let updated)? = dict["updated"],
              case .string(let id)? = dict["id"] else {
            throw TestError.assertion("expected updated/id, got \(result)")
        }
        try expect(updated == true, "not updated")
        try expect(id == "id://u1", "id \(id)")
        try expect(runner.lastScript.contains("set body of theNote"), "no body-set verb")
        try expect(runner.lastScript.contains("new content"), "body content missing")
    }

    await test("notes_update returns updated=false when no note matched") {
        let runner = MockNotesRunner(.ok(""))   // empty id ⇒ no match
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_update",
            arguments: .object(["noteName": .string("Ghost"), "body": .string("x")]))
        guard case .object(let dict) = result, case .bool(let updated)? = dict["updated"] else {
            throw TestError.assertion("expected updated flag")
        }
        try expect(updated == false, "should not be updated")
    }

    await test("notes_update rejects missing body") {
        let router = await makeRouter(MockNotesRunner())
        do {
            _ = try await router.dispatch(
                toolName: "notes_update", arguments: .object(["noteId": .string("id://1")]))
            throw TestError.assertion("expected rejection for missing body")
        } catch is ToolRouterError {
            // expected
        }
    }

    // ----------------------------------------------------------------
    // notes_delete
    // ----------------------------------------------------------------

    await test("notes_delete requires confirm='DELETE'") {
        let runner = MockNotesRunner(.ok("id://d1"))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_delete",
            arguments: .object(["noteId": .string("id://d1"), "confirm": .string("nope")]))
        guard case .object(let dict) = result, case .bool(let deleted)? = dict["deleted"] else {
            throw TestError.assertion("expected deleted flag")
        }
        try expect(deleted == false, "must not delete without DELETE confirm")
        // The runner must not have been invoked (gated before scripting).
        try expect(runner.scripts.isEmpty, "delete script ran despite bad confirm")
    }

    await test("notes_delete with confirm='DELETE' deletes and returns id") {
        let runner = MockNotesRunner(.ok("id://d2"))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_delete",
            arguments: .object(["noteId": .string("id://d2"), "confirm": .string("DELETE")]))
        guard case .object(let dict) = result,
              case .bool(let deleted)? = dict["deleted"],
              case .string(let id)? = dict["id"] else {
            throw TestError.assertion("expected deleted/id, got \(result)")
        }
        try expect(deleted == true, "not deleted")
        try expect(id == "id://d2", "id \(id)")
        try expect(runner.lastScript.contains("delete theNote"), "no delete verb")
    }

    await test("notes_delete rejects missing confirm") {
        let router = await makeRouter(MockNotesRunner())
        do {
            _ = try await router.dispatch(
                toolName: "notes_delete", arguments: .object(["noteId": .string("id://1")]))
            throw TestError.assertion("expected rejection for missing confirm")
        } catch is ToolRouterError {
            // expected
        }
    }

    // ----------------------------------------------------------------
    // notes_search
    // ----------------------------------------------------------------

    await test("notes_search parses matches and embeds the query") {
        let runner = MockNotesRunner(.ok(makeRecords([
            ("id://s1", "Recipe", "Food", "2026-06-01")
        ])))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_search", arguments: .object(["query": .string("flour")]))
        guard case .object(let dict) = result,
              case .int(let count)? = dict["count"] else {
            throw TestError.assertion("expected count, got \(result)")
        }
        try expect(count == 1, "expected 1 match, got \(count)")
        try expect(runner.lastScript.contains("set q to \"flour\""), "query not embedded")
        try expect(runner.lastScript.contains("ignoring case"), "search not case-insensitive")
    }

    await test("notes_search rejects missing query") {
        let router = await makeRouter(MockNotesRunner())
        do {
            _ = try await router.dispatch(toolName: "notes_search", arguments: .object([:]))
            throw TestError.assertion("expected rejection for missing query")
        } catch is ToolRouterError {
            // expected
        }
    }

    // ----------------------------------------------------------------
    // AppleScript error path  (the seam's failure branch)
    // ----------------------------------------------------------------

    await test("AppleScript error surfaces as structured error on a read") {
        let runner = MockNotesRunner(.failure(message: "Notes got an error: boom", code: -2700))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_list", arguments: .object([:]))
        guard case .object(let dict) = result,
              case .string(let err)? = dict["error"],
              case .int(let code)? = dict["errorNumber"] else {
            throw TestError.assertion("expected error/errorNumber, got \(result)")
        }
        try expect(err.contains("boom"), "error message lost: \(err)")
        try expect(code == -2700, "code \(code)")
        try expect(dict["tccDenied"] == nil, "non-TCC error should not flag tccDenied")
    }

    await test("AppleScript -1743 (Automation denied) yields TCC guidance") {
        let runner = MockNotesRunner(.failure(message: "Not authorized to send Apple events to Notes.", code: -1743))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "notes_create",
            arguments: .object(["title": .string("X")]))
        guard case .object(let dict) = result,
              case .bool(let tcc)? = dict["tccDenied"],
              case .string(let guidance)? = dict["guidance"] else {
            throw TestError.assertion("expected tccDenied/guidance, got \(result)")
        }
        try expect(tcc == true, "tccDenied should be true")
        try expect(guidance.localizedCaseInsensitiveContains("Automation"), "guidance missing Automation hint")
    }

    // ----------------------------------------------------------------
    // Pure helpers: escaping / selector / record parsing / scripts
    // ----------------------------------------------------------------

    await test("escapeAS escapes backslash then quote (order-correct)") {
        try expect(NotesModule.escapeAS(#"a"b"#) == #"a\"b"#, "quote escape")
        try expect(NotesModule.escapeAS(#"a\b"#) == #"a\\b"#, "backslash escape")
        // A pre-escaped-looking input must not be mangled into a valid escape.
        try expect(NotesModule.escapeAS(#"\""#) == #"\\\""#, "combined escape")
    }

    await test("noteSelector prefers noteId over noteName") {
        let sel = NotesModule.noteSelector(["noteId": .string("ID"), "noteName": .string("NAME")])
        try expect(sel == .id("ID"), "id should win, got \(String(describing: sel))")
        let sel2 = NotesModule.noteSelector(["noteName": .string("NAME")])
        try expect(sel2 == .name("NAME"), "name fallback")
        let sel3 = NotesModule.noteSelector([:])
        try expect(sel3 == nil, "nil when neither present")
    }

    await test("parseNoteRecords skips short/blank records") {
        let fs = NotesModule.fieldSep
        let rs = NotesModule.recordSep
        let raw = "a\(fs)b\(fs)c\(fs)d\(rs)\(rs)tooShort\(rs)e\(fs)f\(fs)g\(fs)h\(rs)"
        let recs = NotesModule.parseNoteRecords(raw)
        try expect(recs.count == 2, "expected 2 valid records, got \(recs.count)")
        try expect(recs[0] == NotesModule.NoteRecord(id: "a", name: "b", folder: "c", modified: "d"),
                   "rec0 \(recs[0])")
    }

    await test("Scripts.list/search/create use the framing + Apple-events verbs") {
        let listScript = NotesModule.Scripts.list(folder: nil)
        try expect(listScript.contains("tell application \"Notes\""), "list not a Notes tell")
        try expect(listScript.contains("ASCII character 31") && listScript.contains("ASCII character 30"),
                   "list missing separator literals")
        let createScript = NotesModule.Scripts.create(title: "T", body: "B", folder: nil)
        try expect(createScript.contains("make new note"), "create verb missing")
        let delScript = NotesModule.Scripts.delete(selector: .id("z"))
        try expect(delScript.contains("delete theNote"), "delete verb missing")
    }
}
