// RegistryPropertyCodecTests.swift — Data-Source Registry · property codec
// NotionBridge · Tests (custom harness — NOT XCTest)
//
// ZERO network / ZERO live Notion: every input is a hand-built Notion property
// value object (the dict UNDER properties[name]) or an MCP `Value`, driven
// straight through RegistryPropertyCodec.decode / .encode / .isWritable.
//
// Coverage:
//   (a) decode of each supported type from representative Notion JSON;
//   (b) encode of each writable type producing the exact expected payload dict
//       (compared by JSON-canonical form via JSONSerialization .sortedKeys,
//       since [String: Any] is not Equatable);
//   (c) round-trip (encode → re-decode-equivalent) for the scalar/array types;
//   (d) isWritable true/false table;
//   (e) read-only types encode → nil; unknown type → graceful decode/encode;
//   (f) empty / null clearing payloads.
//
// Run via: swift run NotionBridgeTests (this file is wired into TestRunner by
// the operator — runRegistryPropertyCodecTests() is the entry point).

import Foundation
import MCP
import NotionBridgeLib

func runRegistryPropertyCodecTests() async {
    print("\n\u{1F4DF} RegistryPropertyCodec Tests (Data-Source Registry · Notion ⇄ Value)")

    // ── canonicalization: [String: Any] → stable sorted-keys JSON string ──
    // [String: Any] / payload dicts are not Equatable; compare by serializing
    // both sides to JSON with .sortedKeys so key order never matters and
    // NSNull / nested arrays / numbers all compare structurally.
    func canon(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj) || obj is [Any] || obj is [String: Any] else {
            return String(describing: obj)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]
        ) else {
            return String(describing: obj)
        }
        return String(data: data, encoding: .utf8) ?? String(describing: obj)
    }

    // Assert an encode payload equals an expected dict, field-by-field, via
    // canonical JSON. Returns the canonical strings in the message on failure.
    func samePayload(_ got: [String: Any]?, _ want: [String: Any]) throws {
        guard let got = got else {
            throw TestError.assertion("expected payload \(canon(want)) but got nil")
        }
        let g = canon(got), w = canon(want)
        try expect(g == w, "payload mismatch — got \(g) want \(w)")
    }

    // ───────────────────────── DECODE ─────────────────────────

    await test("decode title → plain string") {
        let prop: [String: Any] = ["type": "title",
            "title": [["plain_text": "Hello", "text": ["content": "Hello"]]]]
        try expect(RegistryPropertyCodec.decode(type: "title", property: prop) == .string("Hello"),
                   "title decode")
    }

    await test("decode rich_text → concatenated plain string") {
        let prop: [String: Any] = ["type": "rich_text",
            "rich_text": [["plain_text": "foo "], ["plain_text": "bar"]]]
        try expect(RegistryPropertyCodec.decode(type: "rich_text", property: prop) == .string("foo bar"),
                   "rich_text decode")
    }

    await test("decode number → .double (integral and fractional)") {
        let intP: [String: Any] = ["type": "number", "number": 42]
        let dblP: [String: Any] = ["type": "number", "number": 3.5]
        try expect(RegistryPropertyCodec.decode(type: "number", property: intP) == .double(42.0),
                   "number(int) decode")
        try expect(RegistryPropertyCodec.decode(type: "number", property: dblP) == .double(3.5),
                   "number(double) decode")
        let unset: [String: Any] = ["type": "number", "number": NSNull()]
        try expect(RegistryPropertyCodec.decode(type: "number", property: unset) == .null,
                   "number(null) → .null")
    }

    await test("decode select / status → name (or .null when unset)") {
        let sel: [String: Any] = ["type": "select", "select": ["name": "Active"]]
        let st: [String: Any] = ["type": "status", "status": ["name": "Done"]]
        try expect(RegistryPropertyCodec.decode(type: "select", property: sel) == .string("Active"),
                   "select decode")
        try expect(RegistryPropertyCodec.decode(type: "status", property: st) == .string("Done"),
                   "status decode")
        let unset: [String: Any] = ["type": "select", "select": NSNull()]
        try expect(RegistryPropertyCodec.decode(type: "select", property: unset) == .null,
                   "select(unset) → .null")
    }

    await test("decode multi_select → array of names") {
        let prop: [String: Any] = ["type": "multi_select",
            "multi_select": [["name": "red"], ["name": "green"]]]
        try expect(RegistryPropertyCodec.decode(type: "multi_select", property: prop)
                   == .array([.string("red"), .string("green")]),
                   "multi_select decode")
    }

    await test("decode date → start only (or .null when unset)") {
        let prop: [String: Any] = ["type": "date",
            "date": ["start": "2026-06-17", "end": "2026-06-18"]]
        try expect(RegistryPropertyCodec.decode(type: "date", property: prop) == .string("2026-06-17"),
                   "date decode (start only)")
        let unset: [String: Any] = ["type": "date", "date": NSNull()]
        try expect(RegistryPropertyCodec.decode(type: "date", property: unset) == .null,
                   "date(unset) → .null")
    }

    await test("decode checkbox → bool") {
        let t: [String: Any] = ["type": "checkbox", "checkbox": true]
        let f: [String: Any] = ["type": "checkbox", "checkbox": false]
        try expect(RegistryPropertyCodec.decode(type: "checkbox", property: t) == .bool(true), "checkbox true")
        try expect(RegistryPropertyCodec.decode(type: "checkbox", property: f) == .bool(false), "checkbox false")
    }

    await test("decode url / email / phone_number → string") {
        let url: [String: Any] = ["type": "url", "url": "https://x.com"]
        let email: [String: Any] = ["type": "email", "email": "a@b.com"]
        let phone: [String: Any] = ["type": "phone_number", "phone_number": "+1 555"]
        try expect(RegistryPropertyCodec.decode(type: "url", property: url) == .string("https://x.com"), "url")
        try expect(RegistryPropertyCodec.decode(type: "email", property: email) == .string("a@b.com"), "email")
        try expect(RegistryPropertyCodec.decode(type: "phone_number", property: phone) == .string("+1 555"), "phone")
    }

    await test("decode relation → array of ids") {
        let prop: [String: Any] = ["type": "relation",
            "relation": [["id": "page-1"], ["id": "page-2"]]]
        try expect(RegistryPropertyCodec.decode(type: "relation", property: prop)
                   == .array([.string("page-1"), .string("page-2")]),
                   "relation decode")
    }

    await test("decode people → array of ids") {
        let prop: [String: Any] = ["type": "people",
            "people": [["id": "user-1", "name": "Iz"], ["id": "user-2"]]]
        try expect(RegistryPropertyCodec.decode(type: "people", property: prop)
                   == .array([.string("user-1"), .string("user-2")]),
                   "people decode (ids)")
    }

    await test("decode formula → unwraps inner typed value") {
        let strF: [String: Any] = ["type": "formula",
            "formula": ["type": "string", "string": "computed"]]
        let numF: [String: Any] = ["type": "formula",
            "formula": ["type": "number", "number": 7]]
        let boolF: [String: Any] = ["type": "formula",
            "formula": ["type": "boolean", "boolean": true]]
        try expect(RegistryPropertyCodec.decode(type: "formula", property: strF) == .string("computed"),
                   "formula(string)")
        try expect(RegistryPropertyCodec.decode(type: "formula", property: numF) == .double(7.0),
                   "formula(number)")
        try expect(RegistryPropertyCodec.decode(type: "formula", property: boolF) == .bool(true),
                   "formula(boolean)")
    }

    await test("decode rollup → best-effort array / number") {
        let arrR: [String: Any] = ["type": "rollup",
            "rollup": ["type": "array", "array": [
                ["type": "number", "number": 1],
                ["type": "number", "number": 2]]]]
        try expect(RegistryPropertyCodec.decode(type: "rollup", property: arrR)
                   == .array([.double(1.0), .double(2.0)]),
                   "rollup(array)")
        let numR: [String: Any] = ["type": "rollup",
            "rollup": ["type": "number", "number": 9]]
        try expect(RegistryPropertyCodec.decode(type: "rollup", property: numR) == .double(9.0),
                   "rollup(number)")
    }

    await test("decode created_time / last_edited_time → string") {
        let ct: [String: Any] = ["type": "created_time", "created_time": "2026-01-01T00:00:00Z"]
        try expect(RegistryPropertyCodec.decode(type: "created_time", property: ct)
                   == .string("2026-01-01T00:00:00Z"),
                   "created_time decode")
    }

    await test("decode unique_id → PREFIX-123 / bare number") {
        let withPrefix: [String: Any] = ["type": "unique_id",
            "unique_id": ["prefix": "PKT", "number": 1005]]
        let noPrefix: [String: Any] = ["type": "unique_id",
            "unique_id": ["prefix": NSNull(), "number": 42]]
        try expect(RegistryPropertyCodec.decode(type: "unique_id", property: withPrefix) == .string("PKT-1005"),
                   "unique_id with prefix")
        try expect(RegistryPropertyCodec.decode(type: "unique_id", property: noPrefix) == .string("42"),
                   "unique_id no prefix")
    }

    await test("decode unknown type → graceful .null") {
        let prop: [String: Any] = ["type": "verification", "verification": ["state": "verified"]]
        try expect(RegistryPropertyCodec.decode(type: "verification", property: prop) == .null,
                   "unknown type → .null")
    }

    // ───────────────────────── ENCODE ─────────────────────────

    await test("encode title → text run payload") {
        try samePayload(RegistryPropertyCodec.encode(type: "title", value: .string("Hi")),
                        ["title": [["text": ["content": "Hi"]]]])
    }

    await test("encode rich_text → text run payload") {
        try samePayload(RegistryPropertyCodec.encode(type: "rich_text", value: .string("body")),
                        ["rich_text": [["text": ["content": "body"]]]])
    }

    await test("encode number → accepts .double / .int / numeric string") {
        try samePayload(RegistryPropertyCodec.encode(type: "number", value: .double(3.5)),
                        ["number": 3.5])
        try samePayload(RegistryPropertyCodec.encode(type: "number", value: .int(42)),
                        ["number": 42.0])
        try samePayload(RegistryPropertyCodec.encode(type: "number", value: .string("7.25")),
                        ["number": 7.25])
        // Non-numeric string → nil (not coercible).
        try expect(RegistryPropertyCodec.encode(type: "number", value: .string("abc")) == nil,
                   "number(non-numeric string) → nil")
    }

    await test("encode select / status → name object") {
        try samePayload(RegistryPropertyCodec.encode(type: "select", value: .string("Active")),
                        ["select": ["name": "Active"]])
        try samePayload(RegistryPropertyCodec.encode(type: "status", value: .string("Done")),
                        ["status": ["name": "Done"]])
    }

    await test("encode multi_select → accepts array OR comma string") {
        try samePayload(
            RegistryPropertyCodec.encode(type: "multi_select",
                                         value: .array([.string("a"), .string("b")])),
            ["multi_select": [["name": "a"], ["name": "b"]]])
        try samePayload(
            RegistryPropertyCodec.encode(type: "multi_select", value: .string("x, y ,z")),
            ["multi_select": [["name": "x"], ["name": "y"], ["name": "z"]]])
    }

    await test("encode date → start object") {
        try samePayload(RegistryPropertyCodec.encode(type: "date", value: .string("2026-06-17")),
                        ["date": ["start": "2026-06-17"]])
    }

    await test("encode checkbox → bool (accepts .bool and truthy string)") {
        try samePayload(RegistryPropertyCodec.encode(type: "checkbox", value: .bool(true)),
                        ["checkbox": true])
        try samePayload(RegistryPropertyCodec.encode(type: "checkbox", value: .string("yes")),
                        ["checkbox": true])
        try expect(RegistryPropertyCodec.encode(type: "checkbox", value: .string("maybe")) == nil,
                   "checkbox(non-bool string) → nil")
    }

    await test("encode url / email / phone_number → raw string") {
        try samePayload(RegistryPropertyCodec.encode(type: "url", value: .string("https://x.com")),
                        ["url": "https://x.com"])
        try samePayload(RegistryPropertyCodec.encode(type: "email", value: .string("a@b.com")),
                        ["email": "a@b.com"])
        try samePayload(RegistryPropertyCodec.encode(type: "phone_number", value: .string("+1 555")),
                        ["phone_number": "+1 555"])
    }

    await test("encode relation → id objects (accepts array of id strings)") {
        try samePayload(
            RegistryPropertyCodec.encode(type: "relation",
                                         value: .array([.string("p1"), .string("p2")])),
            ["relation": [["id": "p1"], ["id": "p2"]]])
    }

    await test("encode people → id objects") {
        try samePayload(
            RegistryPropertyCodec.encode(type: "people",
                                         value: .array([.string("u1"), .string("u2")])),
            ["people": [["id": "u1"], ["id": "u2"]]])
    }

    // ──────────────── CLEARING / NULL PAYLOADS ────────────────

    await test("encode null/empty → Notion clear payloads") {
        try samePayload(RegistryPropertyCodec.encode(type: "rich_text", value: .null),
                        ["rich_text": []])
        try samePayload(RegistryPropertyCodec.encode(type: "title", value: .null),
                        ["title": []])
        try samePayload(RegistryPropertyCodec.encode(type: "select", value: .null),
                        ["select": NSNull()])
        try samePayload(RegistryPropertyCodec.encode(type: "select", value: .string("")),
                        ["select": NSNull()])
        try samePayload(RegistryPropertyCodec.encode(type: "number", value: .null),
                        ["number": NSNull()])
        try samePayload(RegistryPropertyCodec.encode(type: "date", value: .null),
                        ["date": NSNull()])
        try samePayload(RegistryPropertyCodec.encode(type: "url", value: .null),
                        ["url": NSNull()])
    }

    // ──────────────── READ-ONLY TYPES → nil ────────────────

    await test("encode read-only types → nil") {
        let readOnly = ["formula", "rollup", "created_time", "last_edited_time",
                        "created_by", "last_edited_by", "unique_id", "button", "files"]
        for t in readOnly {
            try expect(RegistryPropertyCodec.encode(type: t, value: .string("x")) == nil,
                       "\(t) must encode to nil")
        }
    }

    await test("encode unknown type → nil") {
        try expect(RegistryPropertyCodec.encode(type: "verification", value: .string("x")) == nil,
                   "unknown type encode → nil")
    }

    // ──────────────── isWritable TABLE ────────────────

    await test("isWritable true for the writable set") {
        let writable = ["title", "rich_text", "number", "select", "status",
                        "multi_select", "date", "checkbox", "url", "email",
                        "phone_number", "relation", "people"]
        for t in writable {
            try expect(RegistryPropertyCodec.isWritable(type: t), "\(t) should be writable")
        }
    }

    await test("isWritable false for read-only / unknown") {
        let notWritable = ["formula", "rollup", "created_time", "last_edited_time",
                           "created_by", "last_edited_by", "unique_id", "button",
                           "files", "totally_made_up"]
        for t in notWritable {
            try expect(!RegistryPropertyCodec.isWritable(type: t), "\(t) should NOT be writable")
        }
    }

    // ──────────────── ROUND-TRIP (encode → decode-equivalent) ────────────────

    await test("round-trip title / rich_text") {
        // encode a Value → build a properties[name] value object → decode back.
        for t in ["title", "rich_text"] {
            let payload = RegistryPropertyCodec.encode(type: t, value: .string("RT"))!
            var prop = payload; prop["type"] = t
            try expect(RegistryPropertyCodec.decode(type: t, property: prop) == .string("RT"),
                       "round-trip \(t)")
        }
    }

    await test("round-trip number / checkbox / url") {
        let numPayload = RegistryPropertyCodec.encode(type: "number", value: .double(12.5))!
        var numProp = numPayload; numProp["type"] = "number"
        try expect(RegistryPropertyCodec.decode(type: "number", property: numProp) == .double(12.5),
                   "round-trip number")

        let cbPayload = RegistryPropertyCodec.encode(type: "checkbox", value: .bool(true))!
        var cbProp = cbPayload; cbProp["type"] = "checkbox"
        try expect(RegistryPropertyCodec.decode(type: "checkbox", property: cbProp) == .bool(true),
                   "round-trip checkbox")

        let urlPayload = RegistryPropertyCodec.encode(type: "url", value: .string("https://k.up"))!
        var urlProp = urlPayload; urlProp["type"] = "url"
        try expect(RegistryPropertyCodec.decode(type: "url", property: urlProp) == .string("https://k.up"),
                   "round-trip url")
    }

    await test("round-trip select / status / date") {
        let selPayload = RegistryPropertyCodec.encode(type: "select", value: .string("Open"))!
        var selProp = selPayload; selProp["type"] = "select"
        try expect(RegistryPropertyCodec.decode(type: "select", property: selProp) == .string("Open"),
                   "round-trip select")

        let stPayload = RegistryPropertyCodec.encode(type: "status", value: .string("Live"))!
        var stProp = stPayload; stProp["type"] = "status"
        try expect(RegistryPropertyCodec.decode(type: "status", property: stProp) == .string("Live"),
                   "round-trip status")

        let dPayload = RegistryPropertyCodec.encode(type: "date", value: .string("2026-06-17"))!
        var dProp = dPayload; dProp["type"] = "date"
        try expect(RegistryPropertyCodec.decode(type: "date", property: dProp) == .string("2026-06-17"),
                   "round-trip date")
    }

    await test("round-trip multi_select / relation") {
        let msPayload = RegistryPropertyCodec.encode(type: "multi_select",
                                                     value: .array([.string("a"), .string("b")]))!
        var msProp = msPayload; msProp["type"] = "multi_select"
        try expect(RegistryPropertyCodec.decode(type: "multi_select", property: msProp)
                   == .array([.string("a"), .string("b")]),
                   "round-trip multi_select")

        let relPayload = RegistryPropertyCodec.encode(type: "relation",
                                                      value: .array([.string("p1"), .string("p2")]))!
        var relProp = relPayload; relProp["type"] = "relation"
        try expect(RegistryPropertyCodec.decode(type: "relation", property: relProp)
                   == .array([.string("p1"), .string("p2")]),
                   "round-trip relation")
    }

    print("  (RegistryPropertyCodec: decode/encode/isWritable + round-trip matrix complete)")
}
