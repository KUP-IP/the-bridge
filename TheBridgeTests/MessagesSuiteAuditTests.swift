// MessagesSuiteAuditTests.swift — Messages-suite every-angle-of-attack audit
// TheBridge · Tests
//
// Complements (does NOT duplicate) MessagesModuleTests.swift. That file
// owns: registration count, per-tool tier, missing-required-arg rejection,
// the env-gated chat.db smoke calls. This file owns the deeper audit:
//
//   • attributedBody decoder — the KNOWN defect: stray leading C0 control
//     byte ("\u{0001}Sup dude") + U+FFFC object-replacement glyphs in
//     previews. Deterministic typedstream-blob fixtures, no chat.db.
//   • per-tool argument hardening: wrong-type, empty-string, wrong-key.
//   • camelCase schema-key convention (BridgeToolAliases / lint contract).
//   • annotation coherence (every Messages tool has an explicit catalog
//     entry; requiresConfirmation mirrors tier/neverAutoApprove).
//   • messages_send confirm-gate + raw-chat-id reject + chat-id format
//     handling — all network- and Messages.app-free (argument/guard layer
//     only; NEVER a live send).
//   • ToolMetadata authored steers render into the MCP description.
//
// Pure, deterministic, no Full Disk Access required. The smoke calls that
// touch chat.db tolerate "authorization denied" exactly like
// MessagesModuleTests (CI/dev have no Full Disk Access).

import Foundation
import MCP
import TheBridgeLib

// MARK: - Typedstream fixture builder

/// Build a representative Apple `streamtyped` attributedBody blob:
///   0x04 0x0B "streamtyped" · class-hierarchy padding · NSString class-ref
///   marker 0x84 0x01 0x2B · length prefix · UTF-8 text · trailing attr bytes.
///
/// `framingPrefixByte`: when non-nil, simulates the live defect — the
/// typedstream length-prefix heuristic miscounts a framing/object-version
/// byte into the slice, so a stray control scalar (e.g. 0x01) leads the
/// decoded payload. This is exactly the artifact observed in production
/// previews ("\u{0001}Sup dude", "\u{0001}Hello Isaiah").
private func makeTypedStreamBlob(_ text: String, framingPrefixByte: UInt8? = nil) -> Data {
    var b: [UInt8] = [0x04, 0x0B]
    b += Array("streamtyped".utf8)
    // Class-hierarchy padding so the NSString marker lands past offset 60
    // (the decoder scans 60..<120 for the marker).
    b += [UInt8](repeating: 0x40, count: 50)
    b += [0x84, 0x01, 0x2B]              // NSString class-ref marker
    let t = Array(text.utf8)
    if let pfx = framingPrefixByte {
        // Defect path: length INCLUDES the stray framing byte (off-by-one).
        b += [UInt8(t.count + 1)]
        b += [pfx]
        b += t
    } else {
        // Clean path: 1-byte length, text immediately follows.
        b += [UInt8(t.count)]
        b += t
    }
    b += [0x86, 0x84, 0x02, 0x69, 0x49] // trailing NSDictionary attr bytes
    return Data(b)
}

private func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
private func hasLeadingOrTrailingControl(_ s: String) -> Bool {
    func ctl(_ v: UInt32) -> Bool {
        if v == 0x0A || v == 0x0D || v == 0x09 { return false }
        return v <= 0x1F || (v >= 0x7F && v <= 0x9F)
    }
    guard let f = s.unicodeScalars.first?.value, let l = s.unicodeScalars.last?.value else { return false }
    return ctl(f) || ctl(l)
}

func runMessagesSuiteAuditTests() async {
    print("\n\u{1F50E} Messages Suite Audit (every-angle-of-attack)")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await MessagesModule.register(on: router)

    // ============================================================
    // MARK: A. attributedBody decoder — the KNOWN defect
    // ============================================================

    await test("decoder: clean typedstream blob round-trips unchanged") {
        let d = makeTypedStreamBlob("Sup dude")
        let r = MessagesModule.decodeAttributedBodyForTesting(d)
        try expect(r == "Sup dude", "expected 'Sup dude', got \(String(describing: r))")
    }

    await test("decoder: stray leading control byte is STRIPPED (the KNOWN defect)") {
        // Pre-fix this returned "\u{0001}Sup dude" (U+0001 lead).
        let d = makeTypedStreamBlob("Sup dude", framingPrefixByte: 0x01)
        let r = MessagesModule.decodeAttributedBodyForTesting(d)
        try expect(r == "Sup dude",
                   "stray control prefix not stripped, got scalars \(r.map { scalars($0) } ?? [])")
        try expect(r != nil && !hasLeadingOrTrailingControl(r!),
                   "decoded string still has a leading/trailing control scalar")
    }

    await test("decoder: 'Hello Isaiah' with framing prefix decodes clean") {
        let d = makeTypedStreamBlob("Hello Isaiah", framingPrefixByte: 0x01)
        let r = MessagesModule.decodeAttributedBodyForTesting(d)
        try expect(r == "Hello Isaiah", "got \(String(describing: r))")
    }

    await test("decoder: U+FFFC object-replacement glyph is removed from preview") {
        let d = makeTypedStreamBlob("Photo \u{FFFC} sent", framingPrefixByte: 0x01)
        let r = MessagesModule.decodeAttributedBodyForTesting(d)
        try expect(r != nil && !r!.unicodeScalars.contains(where: { $0.value == 0xFFFC }),
                   "U+FFFC not removed, got \(String(describing: r))")
        try expect(r == "Photo  sent", "got \(String(describing: r))")
    }

    await test("decoder: multi-byte UTF-8 (emoji) payload survives sanitize") {
        let d = makeTypedStreamBlob("hey 👋 there", framingPrefixByte: 0x01)
        let r = MessagesModule.decodeAttributedBodyForTesting(d)
        try expect(r == "hey 👋 there", "emoji corrupted, got \(String(describing: r))")
    }

    await test("decoder: interior tab/newline preserved (only framing stripped)") {
        let s = MessagesModule.sanitizeDecodedText("\u{0001}line1\nline2\tend\u{0002}")
        try expect(s == "line1\nline2\tend", "interior whitespace lost, got \(String(describing: s))")
    }

    await test("sanitize: all-control input → nil (no empty noise rows)") {
        try expect(MessagesModule.sanitizeDecodedText("\u{0001}\u{0002}\u{007F}") == nil,
                   "all-control should sanitize to nil")
        try expect(MessagesModule.sanitizeDecodedText("\u{FFFC}\u{FFFC}") == nil,
                   "all-U+FFFC should sanitize to nil")
    }

    await test("sanitize: clean ASCII unchanged (behaviour-preserving)") {
        try expect(MessagesModule.sanitizeDecodedText("perfectly normal text") == "perfectly normal text")
    }

    await test("decoder: non-typedstream garbage → nil (no crash, no leak)") {
        try expect(MessagesModule.decodeAttributedBodyForTesting(Data([0x00, 0x01, 0x02])) == nil,
                   "tiny garbage should be nil")
        try expect(MessagesModule.decodeAttributedBodyForTesting(Data()) == nil,
                   "empty data should be nil")
    }

    // ============================================================
    // MARK: B. Per-tool argument hardening (wrong-type / empty / wrong-key)
    // ============================================================

    await test("messages_search: wrong-type query (int) is rejected, not crashed") {
        do {
            _ = try await router.dispatch(toolName: "messages_search",
                                          arguments: .object(["query": .int(42)]))
            throw TestError.assertion("expected rejection for int query")
        } catch is ToolRouterError { /* expected */ }
    }

    await test("messages_search: wrong param key surfaces did-you-mean via dispatchFormatted") {
        // `query` is required; sending `q` must fail. dispatchFormatted is the
        // central did-you-mean path. `q` is not a known alias, so we just
        // assert a clean structured error (no crash, isError true).
        let (text, isErr) = await router.dispatchFormatted(
            toolName: "messages_search", arguments: .object(["q": .string("hi")]))
        try expect(isErr, "expected isError for missing 'query'")
        try expect(text.localizedCaseInsensitiveContains("query")
                   || text.localizedCaseInsensitiveContains("missing"),
                   "error envelope should name the missing param, got: \(text)")
    }

    await test("messages_chat: empty-string contact still dispatches to a structured result/err") {
        do {
            let r = try await router.dispatch(toolName: "messages_chat",
                                              arguments: .object(["contact": .string("")]))
            if case .object(let d) = r {
                try expect(d["rows"] != nil || d["error"] != nil, "expected rows/error key")
            } else { throw TestError.assertion("expected object result") }
        } catch {
            try expect(error.localizedDescription.localizedCaseInsensitiveContains("authorization denied"),
                       "unexpected error: \(error.localizedDescription)")
        }
    }

    await test("messages_content: wrong-type messageId (string) is rejected") {
        do {
            _ = try await router.dispatch(toolName: "messages_content",
                                          arguments: .object(["messageId": .string("not-an-int")]))
            throw TestError.assertion("expected rejection for string messageId")
        } catch is ToolRouterError { /* expected */ }
    }

    await test("messages_participants: wrong-type chatIdentifier is rejected") {
        do {
            _ = try await router.dispatch(toolName: "messages_participants",
                                          arguments: .object(["chatIdentifier": .bool(true)]))
            throw TestError.assertion("expected rejection for bool chatIdentifier")
        } catch is ToolRouterError { /* expected */ }
    }

    await test("messages_recent: non-int limit falls back to default (no crash)") {
        do {
            let r = try await router.dispatch(toolName: "messages_recent",
                                              arguments: .object(["limit": .string("oops")]))
            if case .object(let d) = r {
                try expect(d["rows"] != nil || d["error"] != nil, "expected rows/error key")
            } else { throw TestError.assertion("expected object result") }
        } catch {
            try expect(error.localizedDescription.localizedCaseInsensitiveContains("authorization denied"),
                       "unexpected error: \(error.localizedDescription)")
        }
    }

    // ============================================================
    // MARK: C. Schema-key convention (camelCase / alias contract)
    // ============================================================

    await test("every Messages tool inputSchema property key is camelCase") {
        func camelOK(_ k: String) -> Bool {
            guard let f = k.first, f.isLowercase else { return false }
            return k.allSatisfy { $0.isLetter || $0.isNumber }
        }
        var violations: [String] = []
        for reg in await router.registrations(forModule: "messages") {
            guard case .object(let top) = reg.inputSchema,
                  case .object(let props)? = top["properties"] else { continue }
            for key in props.keys where !camelOK(key) { violations.append("\(reg.name).\(key)") }
        }
        try expect(violations.isEmpty, "non-camelCase Messages schema keys: \(violations.sorted())")
    }

    await test("clean Messages param keys produce no false-positive did-you-mean") {
        try expect(BridgeToolAliases.didYouMean(
            providedKeys: ["query", "limit", "contact", "messageId",
                           "chatIdentifier", "recipient", "body", "confirm", "service"]) == nil,
            "Messages canonical keys must not collide with the alias map")
    }

    await test("messages_send schema accepts recipient or chatIdentifier target") {
        let regs = await router.registrations(forModule: "messages")
        guard let send = regs.first(where: { $0.name == "messages_send" }),
              case .object(let schema) = send.inputSchema,
              case .object(let props)? = schema["properties"],
              case .array(let required)? = schema["required"] else {
            throw TestError.assertion("messages_send schema not inspectable")
        }
        try expect(props["recipient"] != nil, "messages_send schema missing recipient")
        try expect(props["chatIdentifier"] != nil, "messages_send schema missing chatIdentifier")
        let requiredStrings = Set(required.compactMap { value -> String? in
            if case .string(let string) = value { return string }
            return nil
        })
        try expect(requiredStrings == Set(["body", "confirm"]),
                   "messages_send should require body+confirm globally; target is recipient OR chatIdentifier")
    }

    // ============================================================
    // MARK: D. Annotation + tier coherence
    // ============================================================

    await test("every Messages tool has an EXPLICIT annotation entry") {
        for reg in await router.registrations(forModule: "messages") {
            try expect(ToolAnnotationCatalog.annotations(for: reg.name) != nil,
                       "\(reg.name) missing explicit annotation entry")
        }
    }

    await test("read tools are readOnly+non-destructive; messages_send is the lone confirm-gate") {
        let names = ["messages_search", "messages_recent", "messages_chat",
                     "messages_content", "messages_participants"]
        for n in names {
            let a = ToolAnnotationCatalog.annotations(for: n)
            try expect(a?.readOnlyHint == true && a?.destructiveHint == false
                       && a?.requiresConfirmation == false,
                       "\(n) annotation should be read-only/non-destructive/no-confirm, got \(String(describing: a))")
        }
        let send = ToolAnnotationCatalog.annotations(for: "messages_send")
        try expect(send?.readOnlyHint == false && send?.requiresConfirmation == true,
                   "messages_send must be write + confirm-gated, got \(String(describing: send))")
    }

    await test("annotation.requiresConfirmation mirrors registered tier (request==confirm)") {
        for reg in await router.registrations(forModule: "messages") {
            guard let a = ToolAnnotationCatalog.annotations(for: reg.name) else {
                throw TestError.assertion("\(reg.name) has no annotation")
            }
            let should = reg.tier == .request || reg.neverAutoApprove
            try expect(a.requiresConfirmation == should,
                       "\(reg.name): confirm=\(a.requiresConfirmation) tier=\(reg.tier.rawValue)")
        }
    }

    // ============================================================
    // MARK: E. messages_send — guard layer (network/Messages.app-free)
    // ============================================================

    await test("messages_send: confirm != 'SEND' returns sent=false (no AppleScript)") {
        let r = try await router.dispatch(toolName: "messages_send", arguments: .object([
            "recipient": .string("+15551234567"), "body": .string("hi"), "confirm": .string("send")]))
        if case .object(let d) = r, case .bool(let sent) = d["sent"] {
            try expect(sent == false, "lowercase 'send' must NOT pass the confirm gate")
        } else { throw TestError.assertion("expected object with sent=false") }
    }

    await test("messages_send: chatIdentifier confirm guard returns sent=false before AppleScript") {
        let r = try await router.dispatch(toolName: "messages_send", arguments: .object([
            "chatIdentifier": .string("677927082d92462b9e1ddc5450b9ae10"),
            "body": .string("hi"),
            "confirm": .string("send")
        ]))
        if case .object(let d) = r, case .bool(let sent) = d["sent"] {
            try expect(sent == false, "lowercase 'send' must NOT pass the chatIdentifier confirm gate")
        } else { throw TestError.assertion("expected object with sent=false") }
    }

    await test("messages_send: raw chat identifier recipient is rejected (ghost-thread guard)") {
        let r = try await router.dispatch(toolName: "messages_send", arguments: .object([
            "recipient": .string("chat123456789"),
            "body": .string("hi"), "confirm": .string("SEND")]))
        if case .object(let d) = r {
            try expect({ if case .bool(let s) = d["sent"] { return s == false }; return false }(),
                       "raw chatNNN recipient must be rejected with sent=false")
            try expect({ if case .string(let e) = d["error"] { return e.localizedCaseInsensitiveContains("chat") }; return false }(),
                       "rejection error should mention chat-identifier resolution")
        } else { throw TestError.assertion("expected object result") }
    }

    await test("messages_send: uppercase CHAT raw id also rejected (case-insensitive guard)") {
        let r = try await router.dispatch(toolName: "messages_send", arguments: .object([
            "recipient": .string("CHAT99"), "body": .string("x"), "confirm": .string("SEND")]))
        if case .object(let d) = r, case .bool(let s) = d["sent"] {
            try expect(s == false, "CHAT99 must be rejected (regex is .caseInsensitive)")
        } else { throw TestError.assertion("expected object result") }
    }

    await test("raw-chat-id guard regex: matches chatNNN, not phones/emails (no send path)") {
        // Mirror the exact guard regex from messages_send (line ~700).
        // Deterministic + AppleScript-free: we test the discriminator itself
        // so we never reach the NSAppleScript send path with a valid number.
        let re = try! NSRegularExpression(pattern: "^chat[0-9]+$", options: .caseInsensitive)
        func isRawChat(_ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        try expect(isRawChat("chat123456789"), "chat123456789 must match")
        try expect(isRawChat("CHAT99"), "case-insensitive: CHAT99 must match")
        try expect(!isRawChat("+15550009999"), "phone must NOT match the chatNNN guard")
        try expect(!isRawChat("a@b.com"), "email must NOT match the chatNNN guard")
        try expect(!isRawChat("chat 12"), "chat with space must NOT match (anchored)")
    }

    // ============================================================
    // MARK: F. ToolMetadata authored steers render into MCP description
    // ============================================================

    await test("Messages tool descriptions render with authored When-to-use steers") {
        for reg in await router.registrations(forModule: "messages") {
            let rendered = BridgeToolDescriptionRenderer.render(reg)
            try expect(!rendered.trimmingCharacters(in: .whitespaces).isEmpty,
                       "\(reg.name) rendered description is empty")
            try expect(rendered.count <= BridgeToolDescriptionRenderer.charBudget,
                       "\(reg.name) description exceeds char budget")
        }
    }

    await test("messages_recent metadata steers away from per-message reads") {
        let regs = await router.registrations(forModule: "messages")
        guard let r = regs.first(where: { $0.name == "messages_recent" }) else {
            throw TestError.assertion("messages_recent not registered")
        }
        let d = BridgeToolDescriptionRenderer.render(r)
        try expect(d.contains("When to use:") || d.contains("Not for:"),
                   "messages_recent should carry authored steers, got: \(d)")
        try expect(d.contains("messages_chat") || d.contains("messages_content"),
                   "messages_recent should cross-reference sibling read tools, got: \(d)")
    }

    await test("messages_send metadata names the confirm contract + contacts steer") {
        let regs = await router.registrations(forModule: "messages")
        guard let r = regs.first(where: { $0.name == "messages_send" }) else {
            throw TestError.assertion("messages_send not registered")
        }
        let d = BridgeToolDescriptionRenderer.render(r)
        try expect(d.contains("SEND"), "send description must surface the confirm token, got: \(d)")
        try expect(d.localizedCaseInsensitiveContains("contacts_resolve_handle")
                   || d.localizedCaseInsensitiveContains("messages_participants"),
                   "send should steer to handle/participant resolution, got: \(d)")
    }
}
