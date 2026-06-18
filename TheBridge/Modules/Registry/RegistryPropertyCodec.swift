// RegistryPropertyCodec.swift — Data-Source Registry · Notion property codec
// TheBridge · Modules/Registry
//
// A self-contained, pure (network-free, deterministic) bidirectional codec
// between Notion property JSON and the MCP `Value` type. This is the SSOT for
// "what a Notion property looks like as a flat Value" (DECODE) and "what an MCP
// Value must serialize to under properties[<id-or-name>] in a create/update
// body" (ENCODE).
//
// DECODE mirrors the conventions of SkillsModule.flattenProperty (title/
// rich_text → plain text, number → numeric, select/status → name, etc.) so the
// Registry surface stays consistent with the existing fetch_skill `properties`
// flatten. ENCODE is the inverse: it produces the Notion write payload object
// (NOT wrapped in the property name) for the writable subset, returning nil for
// read-only/derived types the caller must skip.
//
// Contract:
//   decode(type:property:)  — property is the value object UNDER properties[name]
//                             (i.e. { "type": "...", "rich_text": [...] }), NOT
//                             including the outer name key.
//   encode(type:value:)     — returns the payload dict to place UNDER
//                             properties[<id-or-name>], or nil for read-only/
//                             unsupported types (or a non-coercible value).
//   isWritable(type:)       — false for formula/rollup/created_time/
//                             last_edited_time/created_by/last_edited_by/
//                             unique_id/button/files (and unknown types).

import Foundation
import MCP

/// Bidirectional Notion-property ⇄ MCP `Value` codec for the Data-Source
/// Registry. All methods are pure, deterministic, and never throw.
public enum RegistryPropertyCodec {

    // MARK: - Writability

    /// Whether a Notion property `type` can be written via create/update.
    ///
    /// Read-only (derived/server-owned) types return false: `formula`,
    /// `rollup`, `created_time`, `last_edited_time`, `created_by`,
    /// `last_edited_by`, `unique_id`, `button`. `files` is treated as
    /// read-only here (upload requires a separate file-upload flow, not a
    /// plain property payload). Any unrecognised type is non-writable.
    public static func isWritable(type: String) -> Bool {
        switch type {
        case "title", "rich_text", "number", "select", "status",
             "multi_select", "date", "checkbox", "url", "email",
             "phone_number", "relation", "people":
            return true
        default:
            // formula, rollup, created_time, last_edited_time, created_by,
            // last_edited_by, unique_id, button, files, and anything unknown.
            return false
        }
    }

    // MARK: - Decode (Notion property JSON → MCP Value)

    /// Decode the value object under `properties[name]` into an MCP `Value`,
    /// given the Notion property `type`. Never throws; an absent/malformed
    /// inner payload decodes to `.null` rather than erroring, so a caller
    /// always gets a usable scalar/array/null.
    public static func decode(type: String, property: [String: Any]) -> Value {
        switch type {
        case "title", "rich_text":
            guard let arr = property[type] as? [[String: Any]] else { return .null }
            return .string(plainText(from: arr))

        case "number":
            return decodeNumber(property["number"])

        case "select", "status":
            guard let opt = property[type] as? [String: Any],
                  let name = opt["name"] as? String else { return .null }
            return .string(name)

        case "multi_select":
            guard let arr = property["multi_select"] as? [[String: Any]] else { return .null }
            return .array(arr.compactMap { ($0["name"] as? String).map(Value.string) })

        case "date":
            guard let d = property["date"] as? [String: Any],
                  let start = d["start"] as? String else { return .null }
            return .string(start)

        case "checkbox":
            guard let b = property["checkbox"] as? Bool else { return .null }
            return .bool(b)

        case "url", "email", "phone_number":
            guard let s = property[type] as? String else { return .null }
            return .string(s)

        case "relation":
            guard let arr = property["relation"] as? [[String: Any]] else { return .null }
            return .array(arr.compactMap { ($0["id"] as? String).map(Value.string) })

        case "people":
            guard let arr = property["people"] as? [[String: Any]] else { return .null }
            return .array(arr.compactMap { ($0["id"] as? String).map(Value.string) })

        case "files":
            guard let arr = property["files"] as? [[String: Any]] else { return .null }
            return .array(arr.compactMap { f -> Value? in
                if let n = f["name"] as? String, !n.isEmpty { return .string(n) }
                if let ext = f["external"] as? [String: Any],
                   let u = ext["url"] as? String { return .string(u) }
                if let file = f["file"] as? [String: Any],
                   let u = file["url"] as? String { return .string(u) }
                return nil
            })

        case "created_time", "last_edited_time":
            guard let s = property[type] as? String else { return .null }
            return .string(s)

        case "created_by", "last_edited_by":
            guard let person = property[type] as? [String: Any] else { return .null }
            return .string(personLabel(person))

        case "unique_id":
            guard let uid = property["unique_id"] as? [String: Any],
                  let raw = uid["number"] else { return .null }
            let numStr: String
            if let i = raw as? Int { numStr = String(i) }
            else if let d = raw as? Double { numStr = numberString(d) }
            else if let n = raw as? NSNumber { numStr = n.stringValue }
            else { return .null }
            if let prefix = uid["prefix"] as? String, !prefix.isEmpty {
                return .string("\(prefix)-\(numStr)")
            }
            return .string(numStr)

        case "formula":
            // Unwrap to the inner typed value: { "type": "string"|"number"|
            // "boolean"|"date", <inner> }.
            guard let f = property["formula"] as? [String: Any],
                  let inner = f["type"] as? String else { return .null }
            return decode(type: formulaInnerType(inner), property: f)

        case "boolean":
            // Formula "boolean" inner type (carries the bool under "boolean").
            guard let b = property["boolean"] as? Bool else { return .null }
            return .bool(b)

        case "string":
            // Formula "string" inner type (plain String under "string").
            guard let s = property["string"] as? String else { return .null }
            return .string(s)

        case "rollup":
            // Best-effort: array → flatten each element by its own type;
            // number/date/single → decode the inner typed value.
            guard let r = property["rollup"] as? [String: Any],
                  let inner = r["type"] as? String else { return .null }
            if inner == "array", let elems = r["array"] as? [[String: Any]] {
                return .array(elems.compactMap { e -> Value? in
                    guard let et = e["type"] as? String else { return nil }
                    let v = decode(type: et, property: e)
                    if case .null = v { return nil }
                    return v
                })
            }
            return decode(type: inner, property: r)

        default:
            // Unknown / unmodelled type: graceful `.null` (never garbage).
            return .null
        }
    }

    // MARK: - Encode (MCP Value → Notion property payload object)

    /// Encode an MCP `Value` into the Notion property payload object suitable
    /// to place under `properties[<id-or-name>]` in a create/update body.
    ///
    /// Returns the payload dict (NOT wrapped in the property name), e.g. for
    /// `type: "title"` + `.string("Hi")` → `["title": [["text": ["content": "Hi"]]]]`.
    ///
    /// Returns nil for read-only/unsupported types (caller skips), or when the
    /// supplied value cannot be coerced into a sensible payload for that type.
    /// For an explicit `.null` on a writable type, returns Notion's "clear"
    /// payload where one exists (e.g. `rich_text → ["rich_text": []]`,
    /// `select → ["select": NSNull()]`).
    public static func encode(type: String, value: Value) -> [String: Any]? {
        guard isWritable(type: type) else { return nil }

        switch type {
        case "title":
            if case .null = value { return ["title": []] }
            guard let s = stringy(value) else { return nil }
            return ["title": textRuns(s)]

        case "rich_text":
            if case .null = value { return ["rich_text": []] }
            guard let s = stringy(value) else { return nil }
            return ["rich_text": textRuns(s)]

        case "number":
            if case .null = value { return ["number": NSNull()] }
            guard let n = numeric(value) else { return nil }
            return ["number": n]

        case "select":
            if case .null = value { return ["select": NSNull()] }
            guard let s = stringy(value), !s.isEmpty else { return ["select": NSNull()] }
            return ["select": ["name": s]]

        case "status":
            if case .null = value { return ["status": NSNull()] }
            guard let s = stringy(value), !s.isEmpty else { return ["status": NSNull()] }
            return ["status": ["name": s]]

        case "multi_select":
            guard let names = listOrNil(value) else { return nil }
            return ["multi_select": names.map { ["name": $0] }]

        case "date":
            if case .null = value { return ["date": NSNull()] }
            guard let s = stringy(value), !s.isEmpty else { return ["date": NSNull()] }
            return ["date": ["start": s]]

        case "checkbox":
            guard let b = boolean(value) else { return nil }
            return ["checkbox": b]

        case "url", "email", "phone_number":
            if case .null = value { return [type: NSNull()] }
            guard let s = stringy(value) else { return nil }
            return [type: s]

        case "relation":
            guard let ids = listOrNil(value) else { return nil }
            return ["relation": ids.map { ["id": $0] }]

        case "people":
            guard let ids = listOrNil(value) else { return nil }
            return ["people": ids.map { ["id": $0] }]

        default:
            return nil
        }
    }

    /// Notion rejects a single rich-text/title run whose `content` exceeds 2000
    /// UTF-16 code units (its length unit — NOT grapheme/Character count). Split
    /// `s` into consecutive ≤2000-unit runs WITHOUT splitting a grapheme, so an
    /// arbitrarily long value (incl. emoji / combining marks, which are >1 unit
    /// each) writes successfully and reads back concatenated. Empty string still
    /// yields one empty run (a valid, non-clearing write of "").
    static func textRuns(_ s: String) -> [[String: Any]] {
        let limit = 2000
        if s.utf16.count <= limit { return [["text": ["content": s]]] }
        var runs: [[String: Any]] = []
        var current = ""
        var count = 0
        for ch in s {
            let u = ch.utf16.count
            if count + u > limit, !current.isEmpty {
                runs.append(["text": ["content": current]])
                current = ""; count = 0
            }
            current.append(ch)
            count += u
        }
        if !current.isEmpty { runs.append(["text": ["content": current]]) }
        return runs.isEmpty ? [["text": ["content": s]]] : runs
    }

    // MARK: - Coercion helpers

    /// Coerce a `Value` to a String for text/select/url payloads.
    /// `.string` passes through; `.int`/`.double`/`.bool` stringify; other
    /// kinds (array/object/null) are non-coercible → nil.
    private static func stringy(_ value: Value) -> String? {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return numberString(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Coerce a `Value` to a JSON number (Double) for a `number` payload.
    /// Accepts `.int`, `.double`, and a numeric `.string`.
    private static func numeric(_ value: Value) -> Double? {
        switch value {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            return Double(t)
        default: return nil
        }
    }

    /// Coerce a `Value` to a Bool for a `checkbox` payload. Accepts `.bool`
    /// and a truthy/falsey `.string` ("true"/"false"/"yes"/"no"/"1"/"0").
    private static func boolean(_ value: Value) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1", "on", "checked": return true
            case "false", "no", "0", "off", "unchecked", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Flatten a `Value` to a list of non-empty strings for multi_select /
    /// relation / people payloads, OR `nil` when the value is NON-COERCIBLE.
    /// Distinguishing the two matters: an empty list is a DELIBERATE clear, but
    /// a `.bool`/`.object`/`.data` value is a caller MISTAKE that must be
    /// SKIPPED (`nil`), not silently turned into a clearing write that wipes the
    /// existing list. `.null` and an explicitly-empty list/string clear; a
    /// coercible scalar/array yields its items.
    private static func listOrNil(_ value: Value) -> [String]? {
        switch value {
        case .null:
            return []                                   // deliberate clear
        case .array(let arr):
            return arr.compactMap { stringy($0) }.filter { !$0.isEmpty }
        case .string(let s):
            if s.contains(",") {
                return s.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? [] : [t]
        case .int(let i):
            return [String(i)]
        case .double(let d):
            return [numberString(d)]
        default:
            return nil                                  // .bool/.object/.data — non-coercible, skip
        }
    }

    // MARK: - Decode helpers

    /// Normalise a Notion JSON number to `.double` (per Registry contract),
    /// or `.null` when absent. Accepts Int / Double / NSNumber wire shapes.
    private static func decodeNumber(_ raw: Any?) -> Value {
        switch raw {
        case let i as Int: return .double(Double(i))
        case let d as Double: return .double(d)
        case let n as NSNumber: return .double(n.doubleValue)
        default: return .null
        }
    }

    /// Map a Notion formula inner `type` to the decode case that reads its
    /// payload. "number" reads under "number" (handled by the number case);
    /// "string"/"boolean"/"date" read under their own keys.
    private static func formulaInnerType(_ inner: String) -> String {
        // The formula object carries its value under a key named after the
        // inner type ("string"/"number"/"boolean"/"date"); decode() has a
        // matching case for each, so the inner type name IS the decode type.
        return inner
    }

    /// Extract concatenated plain text from a Notion rich-text array,
    /// preferring `plain_text`, falling back to `text.content`. Mirrors
    /// NotionJSON.extractPlainText semantics so decode is consistent with the
    /// existing flatten path.
    private static func plainText(from runs: [[String: Any]]) -> String {
        var out = ""
        for run in runs {
            if let pt = run["plain_text"] as? String {
                out += pt
            } else if let text = run["text"] as? [String: Any],
                      let content = text["content"] as? String {
                out += content
            }
        }
        return out
    }

    /// Best human label for a Notion person/user object: `name`, else a
    /// person email, else the opaque `id`, else empty string (never nil so a
    /// people/by array stays positional).
    private static func personLabel(_ person: [String: Any]) -> String {
        if let name = person["name"] as? String, !name.isEmpty { return name }
        if let p = person["person"] as? [String: Any],
           let email = p["email"] as? String, !email.isEmpty { return email }
        if let id = person["id"] as? String { return id }
        return ""
    }

    /// Render a Double without a trailing ".0" when it is integral, so a
    /// round-tripped integer-valued number stringifies as "42", not "42.0".
    private static func numberString(_ d: Double) -> String {
        if d.rounded() == d && abs(d) < 9.007199254740992e15 {
            return String(Int(d))
        }
        return String(d)
    }
}
