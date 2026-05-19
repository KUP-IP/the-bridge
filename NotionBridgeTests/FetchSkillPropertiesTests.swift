// FetchSkillPropertiesTests.swift — cu-sa (fetch_skill simplified `properties` map)
// NotionBridge · Tests
//
// Synthetic-fixture matrix for the cu-sa additive change: the
// `fetch_skill` return envelope now carries a NEW `properties` key — a
// simplified `{ propertyName: human-readable scalar/array }` flatten of
// the page `properties` JSON that `getPage` ALREADY returns (and which
// was previously parsed only for the title and then discarded).
//
// ZERO network / ZERO live Notion: every input is a hand-built Notion
// `properties` dictionary in the exact wire shape, driven through the
// production envelope builder via `buildSkillResultForTesting`.
//
// Coverage:
//   (a) every modelled property type flattens to the right Value;
//   (b) a multi-property page flattens all keys together;
//   (c) empty / non-DB page → `"properties": {}` (never an error);
//   (d) ENVELOPE STABILITY — every pre-cu-sa key + its value type is
//       byte-for-byte identical to a baseline built with no properties;
//       the ONLY delta is the added `properties` key;
//   (e) content / markdown body is unchanged by the new path.

import Foundation
import MCP
import NotionBridgeLib

func runFetchSkillPropertiesTests() async {
    print("\n\u{1F4DF} FetchSkillProperties Tests (cu-sa · simplified properties map)")

    // ── synthetic /markdown JSON envelope helper ─────────────────────
    func mdJSON(_ markdown: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["markdown": markdown], options: []
        )
        return String(data: data, encoding: .utf8)!
    }

    // Build the envelope with the given properties blob; mention lookup
    // is a no-op (mentions are out of scope for these tests).
    func build(props: [String: Any],
               body: String = "hello body",
               name: String = "demo",
               title: String = "Demo",
               url: String = "https://www.notion.so/p1",
               summary: String = "",
               trig: [String] = [],
               anti: [String] = []) async -> Value {
        await SkillsModule.buildSkillResultForTesting(
            name: name, title: title, url: url,
            markdownJSONOrText: mdJSON(body),
            summary: summary, triggerPhrases: trig, antiTriggerPhrases: anti,
            pageProperties: props
        ) { _ in nil }
    }

    func propsMap(_ v: Value) throws -> [String: Value] {
        guard case .object(let o) = v else {
            throw TestError.assertion("result must be an object")
        }
        guard case .object(let p)? = o["properties"] else {
            throw TestError.assertion("missing/invalid `properties` object key")
        }
        return p
    }

    // Notion property wire-shape builders (each is `{ type, <type>: … }`).
    func richText(_ s: String) -> [String: Any] {
        ["type": "rich_text",
         "rich_text": [["plain_text": s, "type": "text"]]]
    }
    func titleProp(_ s: String) -> [String: Any] {
        ["type": "title", "title": [["plain_text": s, "type": "text"]]]
    }
    func selectProp(_ name: String) -> [String: Any] {
        ["type": "select", "select": ["name": name, "id": "opt1"]]
    }
    func statusProp(_ name: String) -> [String: Any] {
        ["type": "status", "status": ["name": name, "id": "st1"]]
    }
    func multiSelect(_ names: [String]) -> [String: Any] {
        ["type": "multi_select",
         "multi_select": names.map { ["name": $0, "id": $0] }]
    }
    func numberProp(_ n: Any) -> [String: Any] {
        ["type": "number", "number": n]
    }
    func checkbox(_ b: Bool) -> [String: Any] {
        ["type": "checkbox", "checkbox": b]
    }
    func dateProp(_ start: String, end: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["start": start]
        if let e = end { d["end"] = e }
        return ["type": "date", "date": d]
    }
    func urlProp(_ s: String) -> [String: Any] { ["type": "url", "url": s] }
    func emailProp(_ s: String) -> [String: Any] { ["type": "email", "email": s] }
    func phoneProp(_ s: String) -> [String: Any] {
        ["type": "phone_number", "phone_number": s]
    }
    func people(_ specs: [[String: Any]]) -> [String: Any] {
        ["type": "people", "people": specs]
    }
    func relation(_ ids: [String]) -> [String: Any] {
        ["type": "relation", "relation": ids.map { ["id": $0] }]
    }

    // ============================================================
    // MARK: (a) per-type flatten correctness
    // ============================================================

    await test("cu-sa (a): title → plain text string") {
        let p = try propsMap(await build(props: ["Name": titleProp("Skill One")]))
        guard case .string(let s)? = p["Name"] else {
            throw TestError.assertion("title must flatten to a string")
        }
        try expect(s == "Skill One", "got: \(s)")
    }

    await test("cu-sa (a): rich_text → joined plain text") {
        let rt: [String: Any] = ["type": "rich_text", "rich_text": [
            ["plain_text": "Hello ", "type": "text"],
            ["plain_text": "World", "type": "text"]
        ]]
        let p = try propsMap(await build(props: ["Notes": rt]))
        guard case .string(let s)? = p["Notes"] else {
            throw TestError.assertion("rich_text must be a string")
        }
        try expect(s == "Hello World", "got: \(s)")
    }

    await test("cu-sa (a): select → option name") {
        let p = try propsMap(await build(props: ["Stage": selectProp("Active")]))
        guard case .string(let s)? = p["Stage"] else {
            throw TestError.assertion("select must be a string")
        }
        try expect(s == "Active", "got: \(s)")
    }

    await test("cu-sa (a): status → option name") {
        let p = try propsMap(await build(props: ["State": statusProp("In Progress")]))
        guard case .string(let s)? = p["State"] else {
            throw TestError.assertion("status must be a string")
        }
        try expect(s == "In Progress", "got: \(s)")
    }

    await test("cu-sa (a): multi_select → [names]") {
        let p = try propsMap(await build(props: ["Tags": multiSelect(["a", "b", "c"])]))
        guard case .array(let arr)? = p["Tags"] else {
            throw TestError.assertion("multi_select must be an array")
        }
        let names = arr.compactMap { v -> String? in
            if case .string(let s) = v { return s } else { return nil }
        }
        try expect(names == ["a", "b", "c"], "got: \(names)")
    }

    await test("cu-sa (a): number (integral) → int") {
        let p = try propsMap(await build(props: ["Count": numberProp(42)]))
        guard case .int(let i)? = p["Count"] else {
            throw TestError.assertion("integral number must be .int; got \(String(describing: p["Count"]))")
        }
        try expect(i == 42, "got: \(i)")
    }

    await test("cu-sa (a): number (fractional) → double") {
        let p = try propsMap(await build(props: ["Ratio": numberProp(3.5)]))
        guard case .double(let d)? = p["Ratio"] else {
            throw TestError.assertion("fractional number must be .double; got \(String(describing: p["Ratio"]))")
        }
        try expect(d == 3.5, "got: \(d)")
    }

    await test("cu-sa (a): checkbox → bool") {
        let p = try propsMap(await build(props: ["Done": checkbox(true)]))
        guard case .bool(let b)? = p["Done"] else {
            throw TestError.assertion("checkbox must be a bool")
        }
        try expect(b == true, "got: \(b)")
    }

    await test("cu-sa (a): date → start string (range end dropped)") {
        let p = try propsMap(await build(
            props: ["Due": dateProp("2026-05-18", end: "2026-06-01")]))
        guard case .string(let s)? = p["Due"] else {
            throw TestError.assertion("date must be the start string")
        }
        try expect(s == "2026-05-18", "got: \(s)")
    }

    await test("cu-sa (a): url / email / phone_number → string") {
        let p = try propsMap(await build(props: [
            "Site": urlProp("https://example.com"),
            "Mail": emailProp("a@b.co"),
            "Tel": phoneProp("+15551234")
        ]))
        guard case .string(let u)? = p["Site"],
              case .string(let e)? = p["Mail"],
              case .string(let t)? = p["Tel"] else {
            throw TestError.assertion("url/email/phone must all be strings")
        }
        try expect(u == "https://example.com" && e == "a@b.co" && t == "+15551234",
                   "got: \(u) | \(e) | \(t)")
    }

    await test("cu-sa (a): people → [name, fallback email, fallback id]") {
        let specs: [[String: Any]] = [
            ["id": "u1", "name": "Alice", "person": ["email": "alice@x.co"]],
            ["id": "u2", "person": ["email": "bob@x.co"]],   // no name → email
            ["id": "u3"]                                      // no name/email → id
        ]
        let p = try propsMap(await build(props: ["Owners": people(specs)]))
        guard case .array(let arr)? = p["Owners"] else {
            throw TestError.assertion("people must be an array")
        }
        let labels = arr.compactMap { v -> String? in
            if case .string(let s) = v { return s } else { return nil }
        }
        try expect(labels == ["Alice", "bob@x.co", "u3"], "got: \(labels)")
    }

    await test("cu-sa (a): relation → [ids]") {
        let p = try propsMap(await build(props: ["Linked": relation(["pgA", "pgB"])]))
        guard case .array(let arr)? = p["Linked"] else {
            throw TestError.assertion("relation must be an array")
        }
        let ids = arr.compactMap { v -> String? in
            if case .string(let s) = v { return s } else { return nil }
        }
        try expect(ids == ["pgA", "pgB"], "got: \(ids)")
    }

    await test("cu-sa (a): files → [names / urls]") {
        let files: [String: Any] = ["type": "files", "files": [
            ["name": "doc.pdf", "type": "file",
             "file": ["url": "https://s3/doc.pdf"]],
            ["name": "", "type": "external",
             "external": ["url": "https://ext/x"]]   // empty name → url
        ]]
        let p = try propsMap(await build(props: ["Attach": files]))
        guard case .array(let arr)? = p["Attach"] else {
            throw TestError.assertion("files must be an array")
        }
        let vals = arr.compactMap { v -> String? in
            if case .string(let s) = v { return s } else { return nil }
        }
        try expect(vals == ["doc.pdf", "https://ext/x"], "got: \(vals)")
    }

    await test("cu-sa (a): created/last_edited time → string") {
        let p = try propsMap(await build(props: [
            "Created": ["type": "created_time", "created_time": "2026-01-01T00:00:00Z"],
            "Edited":  ["type": "last_edited_time", "last_edited_time": "2026-02-02T00:00:00Z"]
        ]))
        guard case .string(let c)? = p["Created"],
              case .string(let e)? = p["Edited"] else {
            throw TestError.assertion("time props must be strings")
        }
        try expect(c == "2026-01-01T00:00:00Z" && e == "2026-02-02T00:00:00Z",
                   "got: \(c) | \(e)")
    }

    await test("cu-sa (a): created_by / last_edited_by → person label") {
        let p = try propsMap(await build(props: [
            "By": ["type": "created_by",
                   "created_by": ["id": "u9", "name": "Carol"]]
        ]))
        guard case .string(let s)? = p["By"] else {
            throw TestError.assertion("created_by must be a string label")
        }
        try expect(s == "Carol", "got: \(s)")
    }

    await test("cu-sa (a): unique_id with prefix → 'PRE-123'") {
        let p = try propsMap(await build(props: [
            "ID": ["type": "unique_id",
                   "unique_id": ["prefix": "TASK", "number": 123]]
        ]))
        guard case .string(let s)? = p["ID"] else {
            throw TestError.assertion("unique_id must be a string")
        }
        try expect(s == "TASK-123", "got: \(s)")
    }

    await test("cu-sa (a): unique_id without prefix → '123'") {
        let p = try propsMap(await build(props: [
            "ID": ["type": "unique_id",
                   "unique_id": ["prefix": NSNull(), "number": 7]]
        ]))
        guard case .string(let s)? = p["ID"] else {
            throw TestError.assertion("unique_id must be a string")
        }
        try expect(s == "7", "got: \(s)")
    }

    await test("cu-sa (a): formula → resolved inner value") {
        let p = try propsMap(await build(props: [
            "Calc": ["type": "formula",
                     "formula": ["type": "number", "number": 99]],
            "Flag": ["type": "formula",
                     "formula": ["type": "checkbox", "checkbox": true]],
            "Label": ["type": "formula",
                      "formula": ["type": "string", "string": "computed"]]
        ]))
        guard case .int(let n)? = p["Calc"],
              case .bool(let b)? = p["Flag"] else {
            throw TestError.assertion("formula must resolve inner type")
        }
        try expect(n == 99 && b == true, "got: \(n) | \(b)")
        // formula→string has no `rich_text`/`string`-array shape → the
        // inner `string` is a bare String, not a Notion rich_text array,
        // so it is safely skipped (never throws, never garbage).
        try expect(p["Label"] == nil,
                   "bare formula string has no rich_text shape → skipped")
    }

    await test("cu-sa (a): rollup array → flattened element array") {
        let rollup: [String: Any] = ["type": "rollup", "rollup": [
            "type": "array",
            "array": [
                ["type": "title", "title": [["plain_text": "X", "type": "text"]]],
                ["type": "title", "title": [["plain_text": "Y", "type": "text"]]]
            ]
        ]]
        let p = try propsMap(await build(props: ["Roll": rollup]))
        guard case .array(let arr)? = p["Roll"] else {
            throw TestError.assertion("rollup array must be an array")
        }
        let vals = arr.compactMap { v -> String? in
            if case .string(let s) = v { return s } else { return nil }
        }
        try expect(vals == ["X", "Y"], "got: \(vals)")
    }

    await test("cu-sa (a): rollup number → resolved number") {
        let rollup: [String: Any] = ["type": "rollup",
                                      "rollup": ["type": "number", "number": 5]]
        let p = try propsMap(await build(props: ["Sum": rollup]))
        guard case .int(let n)? = p["Sum"] else {
            throw TestError.assertion("rollup number must resolve to int")
        }
        try expect(n == 5, "got: \(n)")
    }

    await test("cu-sa (a): unknown property type is SKIPPED (never throws)") {
        let p = try propsMap(await build(props: [
            "Weird": ["type": "verification", "verification": ["state": "verified"]],
            "Keep":  titleProp("kept")
        ]))
        try expect(p["Weird"] == nil, "unknown type must be skipped")
        guard case .string(let s)? = p["Keep"] else {
            throw TestError.assertion("known sibling must survive")
        }
        try expect(s == "kept", "got: \(s)")
    }

    await test("cu-sa (a): structurally-absent value is skipped, not crashed") {
        // `select: null` (cleared) and a malformed entry (missing `type`).
        let p = try propsMap(await build(props: [
            "Empty": ["type": "select", "select": NSNull()],
            "Bad":   ["select": ["name": "x"]],          // no `type`
            "Good":  numberProp(1)
        ]))
        try expect(p["Empty"] == nil, "cleared select skipped")
        try expect(p["Bad"] == nil, "no-type property skipped")
        try expect(p["Good"] != nil, "valid sibling survives")
    }

    // ============================================================
    // MARK: (b) multi-property page
    // ============================================================

    await test("cu-sa (b): multi-property page flattens all keys together") {
        let props: [String: Any] = [
            "Name":  titleProp("Daily Standup"),
            "Stage": selectProp("Active"),
            "Tags":  multiSelect(["ops", "team"]),
            "Count": numberProp(3),
            "Done":  checkbox(false),
            "Due":   dateProp("2026-05-20")
        ]
        let p = try propsMap(await build(props: props))
        try expect(p.count == 6, "expected 6 flattened keys; got \(p.count): \(p.keys.sorted())")
        guard case .string(let n)? = p["Name"],
              case .string(let st)? = p["Stage"],
              case .array(let tg)? = p["Tags"],
              case .int(let c)? = p["Count"],
              case .bool(let d)? = p["Done"],
              case .string(let du)? = p["Due"] else {
            throw TestError.assertion("a multi-prop key flattened to the wrong type")
        }
        try expect(n == "Daily Standup" && st == "Active" && c == 3
                   && d == false && du == "2026-05-20" && tg.count == 2,
                   "multi-prop values wrong")
    }

    // ============================================================
    // MARK: (c) empty / non-DB page → {}
    // ============================================================

    await test("cu-sa (c): no properties → \"properties\": {} (not an error)") {
        let p = try propsMap(await build(props: [:]))
        try expect(p.isEmpty, "empty page must yield an empty map; got \(p)")
    }

    await test("cu-sa (c): default (omitted) pageProperties → {} ") {
        // The pre-cu-sa wrapper signature path: no pageProperties arg.
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "T", url: "u",
            markdownJSONOrText: mdJSON("body")
        ) { _ in nil }
        let p = try propsMap(r)
        try expect(p.isEmpty, "omitted properties must default to {}; got \(p)")
    }

    await test("cu-sa (c): all-unknown-type page → {} (no error, no partial)") {
        let p = try propsMap(await build(props: [
            "A": ["type": "verification", "verification": [:]],
            "B": ["type": "button", "button": [:]]
        ]))
        try expect(p.isEmpty, "all-unknown page flattens to {}; got \(p)")
    }

    // ============================================================
    // MARK: (d) ENVELOPE STABILITY — only `properties` is added
    // ============================================================

    // The literal pre-cu-sa envelope key set (cmd-w4 era): name, title,
    // url, blockCount, truncated, content + the merged skill metadata
    // (summary / triggerPhrases / antiTriggerPhrases). cu-sa adds EXACTLY
    // one key — `properties` — and it is additive on EVERY path (the
    // default no-properties path now also emits `"properties": {}`), so
    // the true stability contract is: (i) the legacy 9 keys + their
    // value types are byte-identical whether properties are empty or
    // populated, and (ii) the only key beyond the legacy set is
    // `properties`. (The earlier draft of this test wrongly assumed a
    // runtime "baseline" that does NOT carry `properties`; since the key
    // is unconditionally additive, no such baseline exists — corrected
    // here to assert the real, stronger invariant rather than weaken it.)
    let legacyEnvelopeKeys: Set<String> = [
        "name", "title", "url", "blockCount", "truncated", "content",
        "summary", "triggerPhrases", "antiTriggerPhrases"
    ]

    await test("cu-sa (d): legacy keys byte-identical empty↔populated; only `properties` added") {
        // Same inputs, differing ONLY in the new properties blob.
        let empty = await build(
            props: [:],
            body: "hello body", name: "skillName", title: "Page Title",
            url: "https://www.notion.so/p9",
            summary: "sum", trig: ["t1"], anti: ["a1"]
        )
        let populated = await build(
            props: ["Name": titleProp("Page Title"), "N": numberProp(1)],
            body: "hello body", name: "skillName", title: "Page Title",
            url: "https://www.notion.so/p9",
            summary: "sum", trig: ["t1"], anti: ["a1"]
        )
        guard case .object(let e) = empty,
              case .object(let p) = populated else {
            throw TestError.assertion("both results must be objects")
        }

        // 1. The full key set is EXACTLY the legacy keys ∪ {properties}
        //    — no key removed, no key added beyond `properties`, on both.
        let expectedKeys = legacyEnvelopeKeys.union(["properties"])
        try expect(Set(e.keys) == expectedKeys,
                   "empty-props envelope keys must be legacy ∪ {properties}; got \(Set(e.keys))")
        try expect(Set(p.keys) == expectedKeys,
                   "populated-props envelope keys must be legacy ∪ {properties}; got \(Set(p.keys))")

        // 2. EVERY legacy key's value is byte-for-byte identical between
        //    the empty and populated envelopes (Value is Equatable —
        //    exact structural compare). Properties presence must not
        //    perturb a single pre-cu-sa key.
        for k in legacyEnvelopeKeys {
            try expect(e[k] != nil, "missing legacy key: \(k)")
            try expect(e[k] == p[k],
                       "legacy key `\(k)` changed with properties: \(String(describing: e[k])) → \(String(describing: p[k]))")
        }

        // 3. The canonical legacy value TYPES are unchanged.
        guard case .int? = p["blockCount"] else {
            throw TestError.assertion("blockCount must still be .int")
        }
        guard case .bool? = p["truncated"] else {
            throw TestError.assertion("truncated must still be .bool")
        }
        guard case .string? = p["content"] else {
            throw TestError.assertion("content must still be .string")
        }
        guard case .array? = p["triggerPhrases"] else {
            throw TestError.assertion("triggerPhrases must still be .array")
        }
        // 4. The single new key is itself an object on both paths.
        guard case .object? = e["properties"], case .object? = p["properties"] else {
            throw TestError.assertion("`properties` must be an object on every path")
        }
    }

    await test("cu-sa (d): default (no-arg) path emits exactly `properties:{}` and nothing else new") {
        // The pre-cu-sa wrapper call shape (no pageProperties arg) and
        // the explicit empty-properties call must produce byte-identical
        // envelopes, and that envelope's ONLY non-legacy key is an empty
        // `properties` object. This pins the additive default path.
        let viaDefault = await SkillsModule.buildSkillResultForTesting(
            name: "x", title: "Y", url: "z",
            markdownJSONOrText: mdJSON("body")
        ) { _ in nil }
        let viaExplicitEmpty = await build(props: [:], body: "body",
                                           name: "x", title: "Y", url: "z")
        guard case .object(let d) = viaDefault,
              case .object(let x) = viaExplicitEmpty else {
            throw TestError.assertion("objects expected")
        }
        // Identical envelopes (the default arg IS `[:]`).
        try expect(Value.object(d) == Value.object(x),
                   "default no-arg path must equal explicit empty-props path")
        // The only key beyond the legacy set is `properties`, == {}.
        try expect(Set(d.keys).subtracting(legacyEnvelopeKeys) == ["properties"],
                   "only `properties` may extend the legacy set; got \(Set(d.keys).subtracting(legacyEnvelopeKeys))")
        guard case .object(let pm)? = d["properties"] else {
            throw TestError.assertion("`properties` must be an object")
        }
        try expect(pm.isEmpty, "default path `properties` must be {}; got \(pm)")
    }

    // ============================================================
    // MARK: (e) content / markdown body unchanged by the new path
    // ============================================================

    await test("cu-sa (e): content body is unaffected by populated properties") {
        let body = "# Heading\n\n- bullet one\n- bullet two"
        let noProps = await build(props: [:], body: body)
        let withProps = await build(props: ["Name": titleProp("T")], body: body)
        func content(_ v: Value) throws -> String {
            guard case .object(let o) = v, case .string(let s)? = o["content"] else {
                throw TestError.assertion("missing content")
            }
            return s
        }
        let a = try content(noProps)
        let b = try content(withProps)
        try expect(a == b, "content must not change with properties; \(a) vs \(b)")
        try expect(a.contains("# Heading") && a.contains("- bullet one"),
                   "markdown structure must be preserved; got: \(a)")
    }

    await test("cu-sa (e): blockCount unaffected by properties presence") {
        let body = "line a\nline b\nline c"
        let noProps = await build(props: [:], body: body)
        let withProps = await build(props: ["N": numberProp(1)], body: body)
        func bc(_ v: Value) throws -> Int {
            guard case .object(let o) = v, case .int(let n)? = o["blockCount"] else {
                throw TestError.assertion("missing blockCount")
            }
            return n
        }
        try expect(try bc(noProps) == bc(withProps),
                   "blockCount must be properties-independent")
    }

    // ============================================================
    // MARK: (f) REAL live-Notion FOCUS-DB-row fixture
    // ============================================================
    //
    // Closes the cu-sa honest residual recorded in v3-hub Decision Log
    // row 26 ("Notion property wire-shapes are modelled-from-spec, not
    // live-verified"). The blob below is the VERBATIM `properties` object
    // returned by the live Notion REST API for FOCUS-DB row PKT-798
    // (WS-C, page 85d9aa02515f40e1b44e7540373f2fe4), captured 2026-05-19
    // via `notion_page_read includeBlocks:false`. It carries the genuine
    // wire noise the synthetic builders above omit: percent-encoded
    // property `id`s, `has_more` on relations, `annotations`/`href`/
    // `text` on rich_text/title runs, `color`/`id` on select/status/
    // multi_select options, `formula` with inner `boolean`/`string`
    // types, and `number: null`. Driving it through the EXACT production
    // flatten proves the modelled mapping matches reality AND locks the
    // real safe-skip behavior on shapes the model does not surface.
    let realPKT798Properties = #"""
    {
      "AI LOGS": { "has_more": false, "id": "f%40av", "type": "relation",
        "relation": [ { "id": "361cbb58-889e-814e-bd95-f3c4a494272f" } ] },
      "Blocked by": { "has_more": false, "id": "%3FS%3F%3F", "type": "relation",
        "relation": [] },
      "Blocking": { "has_more": false, "id": "qjgT", "type": "relation",
        "relation": [ { "id": "d3887c51-83f9-44b1-987d-46fa41d943b0" } ] },
      "cascadeSource": { "id": "%3C%3FHP", "type": "rich_text",
        "rich_text": [] },
      "Complexity": { "id": "ySOP", "number": 5, "type": "number" },
      "Context Size": { "id": "DMV%40", "number": null, "type": "number" },
      "Created": { "created_time": "2026-05-15T15:37:00.000Z",
        "id": "W%7Cn%3C", "type": "created_time" },
      "Duration": { "id": "BRDz", "number": 150, "type": "number" },
      "EVENT": { "has_more": false, "id": "K%3EAT", "type": "relation",
        "relation": [ { "id": "361cbb58-889e-81d7-b59c-f374cbbfa832" } ] },
      "Filter": { "formula": { "boolean": true, "type": "boolean" },
        "id": "Tb%5D_", "type": "formula" },
      "fromStatus": { "id": "s~%5E%3C", "type": "status",
        "status": { "color": "green", "id": "jvqx", "name": "Done" } },
      "Model": { "id": "u%7B%3CR", "type": "select",
        "select": { "color": "purple",
          "id": "4d5462d6-c291-4075-9e43-1d246c02e03b", "name": "Opus 4.7" } },
      "Objective": { "id": "jr~M", "type": "rich_text",
        "rich_text": [ { "annotations": { "bold": false, "code": false,
          "color": "default", "italic": false, "strikethrough": false,
          "underline": false }, "href": null,
          "plain_text": "Pre-marketplace cleanup: run a privacy audit.",
          "text": { "content": "Pre-marketplace cleanup: run a privacy audit.",
            "link": null }, "type": "text" } ] },
      "Packet Name": { "id": "title", "type": "title",
        "title": [ { "annotations": { "bold": false, "code": false,
          "color": "default", "italic": false, "strikethrough": false,
          "underline": false }, "href": null,
          "plain_text": "Bridge v2.3 prep · 0.3 — Remediate test floor + PermissionView + privacy audit",
          "text": { "content": "Bridge v2.3 prep · 0.3 — Remediate test floor + PermissionView + privacy audit",
            "link": null }, "type": "text" } ] },
      "Packet Output": { "id": "VyF%7C", "type": "rich_text", "rich_text": [] },
      "PKT-ID": { "id": "FDqm", "type": "unique_id",
        "unique_id": { "number": 798, "prefix": "PKT" } },
      "PROJECT": { "has_more": false, "id": "NkiO", "type": "relation",
        "relation": [ { "id": "268b2a2a-77cb-4a11-b902-2af150ea698b" } ] },
      "SKILLS": { "has_more": false, "id": "%5C%5Coj", "type": "relation",
        "relation": [ { "id": "318cbb58-889e-801a-90c7-d424baba3639" },
          { "id": "b2eb533e-3be1-465b-86d4-1af6937db638" } ] },
      "Sort": { "formula": { "string": null, "type": "string" },
        "id": "fT~c", "type": "formula" },
      "Status": { "id": "y%3Cxv", "type": "status",
        "status": { "color": "green", "id": "_qF`", "name": "Done" } },
      "Tokens": { "id": "K%3C%3BC", "number": null, "type": "number" },
      "Trigger": { "id": "%5E%60aE", "type": "multi_select",
        "multi_select": [ { "color": "purple", "id": "Fgf_", "name": "📦" } ] }
    }
    """#

    await test("cu-sa (f): real live-Notion FOCUS row PKT-798 flattens to the modelled values") {
        guard let data = realPKT798Properties.data(using: .utf8),
              let realProps = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw TestError.assertion("real fixture must parse as a JSON object")
        }
        let p = try propsMap(await build(props: realProps))

        // Modelled scalar shapes resolve to the right human values.
        try expect(p["Complexity"] == .int(5), "Complexity → 5; got \(String(describing: p["Complexity"]))")
        try expect(p["Duration"] == .int(150), "Duration → 150; got \(String(describing: p["Duration"]))")
        try expect(p["Model"] == .string("Opus 4.7"), "select → option name; got \(String(describing: p["Model"]))")
        try expect(p["Status"] == .string("Done"), "status → name; got \(String(describing: p["Status"]))")
        try expect(p["fromStatus"] == .string("Done"), "status → name; got \(String(describing: p["fromStatus"]))")
        try expect(p["PKT-ID"] == .string("PKT-798"), "unique_id → prefix-number; got \(String(describing: p["PKT-ID"]))")
        try expect(p["Trigger"] == .array([.string("\u{1F4E6}")]), "multi_select → [names]; got \(String(describing: p["Trigger"]))")
        try expect(p["PROJECT"] == .array([.string("268b2a2a-77cb-4a11-b902-2af150ea698b")]),
                   "relation → [ids]; got \(String(describing: p["PROJECT"]))")
        try expect(p["SKILLS"] == .array([.string("318cbb58-889e-801a-90c7-d424baba3639"),
                                          .string("b2eb533e-3be1-465b-86d4-1af6937db638")]),
                   "relation → [ids] order-preserving; got \(String(describing: p["SKILLS"]))")
        try expect(p["Blocked by"] == .array([]), "empty relation → []; got \(String(describing: p["Blocked by"]))")
        try expect(p["cascadeSource"] == .string(""), "empty rich_text → \"\"; got \(String(describing: p["cascadeSource"]))")
        try expect(p["Created"] == .string("2026-05-15T15:37:00.000Z"),
                   "created_time → ISO string; got \(String(describing: p["Created"]))")
        guard case .string(let pn)? = p["Packet Name"], pn.contains("Remediate test floor") else {
            throw TestError.assertion("title → plain text; got \(String(describing: p["Packet Name"]))")
        }

        // Safe-skip contract holds on REAL data (NOT just synthetic):
        // number:null and formula(inner string/boolean) are unmodelled
        // and MUST be omitted entirely — never crash, never garbage,
        // never a partial. This is the documented behavior surfaced for
        // the operator in Decision row 26; this test pins it to reality.
        for skipped in ["Context Size", "Tokens", "Filter", "Sort"] {
            try expect(p[skipped] == nil,
                       "real unmodelled shape `\(skipped)` must be skipped, not surfaced; got \(String(describing: p[skipped]))")
        }

        // The flatten injects NO key absent from the live input, and
        // emits ONLY modelled Value kinds (string/int/double/bool/array
        // /object) — no opaque/raw passthrough leaks from real noise.
        let inputKeys = Set(realProps.keys)
        for (k, v) in p {
            try expect(inputKeys.contains(k), "flatten introduced a non-input key `\(k)`")
            switch v {
            case .string, .int, .double, .bool, .array, .object: break
            default: throw TestError.assertion("real fixture produced a non-modelled Value for `\(k)`: \(v)")
            }
        }
    }
}
