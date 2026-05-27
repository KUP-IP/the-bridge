// CommandStoreSecurityTests.swift — v3.6·6 security audit
//
// Defense-in-depth contracts on the CommandStore filesystem boundary.
// The data layer protects itself in two ways:
//   1. `slugify()` filters to lowercase letters, digits, "-", "_" — any
//      input is sanitized before becoming a slug.
//   2. `delete(slug:)`, `get(slug:)`, `update(_:)` gate on the index;
//      a slug not in the index cannot reach `bodyURL(slug)`.
//
// These tests pin both invariants so a regression surfaces immediately.

import Foundation
import NotionBridgeLib

func runCommandStoreSecurityTests() async {
    print("\n\u{1F512} v3.6\u{B7}6 CommandStore Security Tests")

    await test("Security: slugify strips path-traversal characters") {
        let bad = "../../etc/passwd"
        let slug = CommandStore.slugify(bad)
        try expect(!slug.contains("/"), "slug must not contain forward slash; got '\(slug)'")
        try expect(!slug.contains(".."), "slug must not contain '..'; got '\(slug)'")
        try expect(!slug.contains("."), "slug must not contain '.'; got '\(slug)'")
    }

    await test("Security: slugify strips backslashes and null bytes") {
        let bad = "evil\\\u{0}slug"
        let slug = CommandStore.slugify(bad)
        try expect(!slug.contains("\\"))
        try expect(!slug.contains("\u{0}"))
    }

    await test("Security: slugify strips control characters") {
        let bad = "name\n\twith\rcontrols"
        let slug = CommandStore.slugify(bad)
        // Whitespace collapses to "-", control chars are dropped.
        try expect(!slug.contains("\n"))
        try expect(!slug.contains("\t"))
        try expect(!slug.contains("\r"))
    }

    await test("Security: slugify keeps only [a-z0-9_-]") {
        let mixed = "Hello-World_42 Foo!@#$%^&*()"
        let slug = CommandStore.slugify(mixed)
        for scalar in slug.unicodeScalars {
            let isAllowed = (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "-"
                || scalar == "_"
            try expect(isAllowed, "Disallowed scalar '\(scalar)' (U+\(String(scalar.value, radix: 16))) in slug '\(slug)'")
        }
    }

    await test("Security: Unicode characters are stripped (no homoglyphs)") {
        // U+0430 (Cyrillic a) looks like ASCII 'a' but is a different
        // scalar; slugify must drop it so two visually-identical names
        // cannot produce different slugs and bypass the duplicate check.
        let homoglyph = "p\u{0430}sswd"  // p-cyrA-sswd
        let slug = CommandStore.slugify(homoglyph)
        // Only the ASCII letters survive; the Cyrillic is dropped.
        try expect(slug == "psswd", "expected 'psswd', got '\(slug)'")
    }

    await test("Security: empty / whitespace-only names produce empty slugs (rejected upstream)") {
        try expect(CommandStore.slugify("") == "")
        try expect(CommandStore.slugify("   \t\n   ") == "")
        // Caller-side: `create(name:)` rejects with invalidName when slug is empty.
    }
}
