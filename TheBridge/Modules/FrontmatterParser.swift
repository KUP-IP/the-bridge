// FrontmatterParser.swift — W2 D8: SKILL.md YAML frontmatter parser
// TheBridge · Modules
//
// Pure, dependency-free YAML-subset parser tailored for SKILL.md frontmatter.
// Supports the shape `anthropics/skills` SKILL.md files use in practice:
//
//   ---
//   name: my-skill
//   description: A short description
//   triggers: [foo, bar, baz]      # inline array
//   anti_triggers:                  # block-style array
//     - never
//     - "do not use here"
//   active: true                    # boolean
//   # this is a comment
//   ---
//
// Out-of-scope (NOT handled — by design, kept minimal):
//   - nested objects / maps
//   - multi-line scalars (`|`, `>`)
//   - anchors / aliases
//   - explicit type tags
//
// Defensive contract: NEVER throws. Malformed input → `(frontmatter: [:],
// body: <whole file>)`. Empty input → `(frontmatter: [:], body: "")`.
//
// Result type: `[String: FrontmatterValue]` where `FrontmatterValue` is a
// small tagged enum (string / bool / array). The conversion to the
// public-API `[String: MCP.Value]` for `fetch_skill` `properties` happens
// at the boundary in `SkillsModule` — this file has zero MCP dependencies
// so it stays cheap to unit-test.

import Foundation

/// A frontmatter scalar value. Arrays carry their elements as strings —
/// nested types are NOT supported by the minimal parser; a sub-array or
/// sub-object would be parsed as a string for forward-compatibility.
public enum FrontmatterValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case array([String])
}

public enum FrontmatterParser {

    /// Parse a SKILL.md file's text. Returns the decoded frontmatter map
    /// plus the markdown body (everything after the closing `---`).
    ///
    /// - Returns: `(frontmatter, body)`. Empty map + entire text as body
    ///   when there is no leading `---` block or the block is malformed
    ///   (unclosed). Never throws.
    public static func parse(_ text: String) -> (frontmatter: [String: FrontmatterValue], body: String) {
        // Empty fast-path
        if text.isEmpty { return ([:], "") }

        // Normalise line endings: split on \n, trim trailing \r per line.
        let rawLines = text.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }

        // Find the opening `---` (must be the FIRST non-empty line) and
        // the closing `---` somewhere after it.
        var idx = 0
        // Allow a BOM-stripped or leading-blank file: skip purely empty
        // leading lines. (Not strict YAML; defensive.)
        while idx < rawLines.count, rawLines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            idx += 1
        }
        guard idx < rawLines.count, rawLines[idx].trimmingCharacters(in: .whitespaces) == "---" else {
            // No leading delimiter: no frontmatter, whole file is body.
            return ([:], text)
        }
        let openIdx = idx
        idx += 1

        // Scan for closing `---`.
        var closeIdx: Int? = nil
        while idx < rawLines.count {
            if rawLines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                closeIdx = idx
                break
            }
            idx += 1
        }
        guard let closing = closeIdx else {
            // Unclosed frontmatter: treat the whole file as body, no
            // frontmatter (defensive — never throws, never half-parsed).
            return ([:], text)
        }

        // Body is everything after the closing `---`. Preserve the
        // newline boundary so the body reads naturally.
        let bodyLines = Array(rawLines[(closing + 1)...])
        // Drop a single leading empty line after the delimiter for a
        // cleaner body (the common SKILL.md convention).
        let body: String
        if let first = bodyLines.first, first.isEmpty {
            body = bodyLines.dropFirst().joined(separator: "\n")
        } else {
            body = bodyLines.joined(separator: "\n")
        }

        let fm = parseBody(Array(rawLines[(openIdx + 1)..<closing]))
        return (fm, body)
    }

    // MARK: - Internals

    /// Parse the body of the frontmatter block (between the two `---`
    /// delimiters). Lines are processed top-down with a tiny state
    /// machine for block-style arrays (a key followed by lines beginning
    /// with `- `).
    private static func parseBody(_ lines: [String]) -> [String: FrontmatterValue] {
        var out: [String: FrontmatterValue] = [:]

        // State for block-style array: which key we are appending to and
        // its accumulated elements.
        var pendingArrayKey: String? = nil
        var pendingArrayElements: [String] = []

        func flushPendingArray() {
            if let key = pendingArrayKey {
                out[key] = .array(pendingArrayElements)
                pendingArrayKey = nil
                pendingArrayElements = []
            }
        }

        for raw in lines {
            // Strip a trailing comment but ONLY when the `#` is preceded
            // by a space (so a `#` inside a quoted string is preserved).
            let line = stripTrailingComment(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip pure comments / blank lines.
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }

            // Block-style array continuation: `- value` (or `  - value`).
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                guard pendingArrayKey != nil else {
                    // Stray `-` with no key context: skip (defensive).
                    continue
                }
                let elt = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                pendingArrayElements.append(unquote(elt))
                continue
            }

            // A `key:` or `key: value` line ends any pending block array.
            flushPendingArray()

            guard let colonIdx = line.firstIndex(of: ":") else {
                // Lines without a `:` are silently ignored — defensive.
                continue
            }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let after = line[line.index(after: colonIdx)...]
            let rawValue = String(after).trimmingCharacters(in: .whitespaces)

            if rawValue.isEmpty {
                // `key:` with nothing after — opens a block-style array
                // (the next non-empty line should be `- ...`).
                pendingArrayKey = key
                pendingArrayElements = []
                continue
            }

            out[key] = scalarValue(from: rawValue)
        }

        flushPendingArray()
        return out
    }

    /// Decode a single scalar value (RHS of `key: <value>`).
    /// Supports: inline arrays `[a, b, "c"]`, booleans `true/false`,
    /// quoted strings, and unquoted strings.
    private static func scalarValue(from raw: String) -> FrontmatterValue {
        // Inline array
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            let elts = splitTopLevelCommas(inner).map {
                unquote($0.trimmingCharacters(in: .whitespaces))
            }
            return .array(elts)
        }
        // Boolean
        switch raw.lowercased() {
        case "true":  return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        // String (quoted or bare)
        return .string(unquote(raw))
    }

    /// Strip a YAML-style trailing comment: ` # comment` (the `#` must
    /// be preceded by whitespace AND not inside a quoted string).
    private static func stripTrailingComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var prev: Character = " "
        for (i, ch) in line.enumerated() {
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble && prev.isWhitespace {
                let cutoff = line.index(line.startIndex, offsetBy: i)
                return String(line[..<cutoff]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            }
            prev = ch
        }
        return line
    }

    /// Remove matching surrounding quotes (single or double). Handles
    /// trivial `\"` and `\\` escapes inside a double-quoted string;
    /// single-quoted strings take the contents verbatim (YAML semantics).
    /// Unclosed quotes return the raw input minus the leading quote —
    /// defensive, never throws.
    private static func unquote(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let first = s.first!
        if first == "\"" || first == "'" {
            // Find the matching closing quote.
            if s.count >= 2, s.last == first {
                let inner = String(s.dropFirst().dropLast())
                if first == "\"" {
                    return inner
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                }
                return inner
            }
            // Unclosed — strip leading quote, return rest (defensive).
            return String(s.dropFirst())
        }
        return s
    }

    /// Split a string on top-level commas (i.e. not inside a quoted
    /// region). Used for inline-array elements.
    private static func splitTopLevelCommas(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var inSingle = false
        var inDouble = false
        for ch in s {
            if ch == "'" && !inDouble { inSingle.toggle(); cur.append(ch) }
            else if ch == "\"" && !inSingle { inDouble.toggle(); cur.append(ch) }
            else if ch == "," && !inSingle && !inDouble {
                parts.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty || !parts.isEmpty {
            parts.append(cur)
        }
        return parts
    }
}
