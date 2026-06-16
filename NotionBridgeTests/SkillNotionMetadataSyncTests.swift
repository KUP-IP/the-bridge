// SkillNotionMetadataSyncTests.swift — PKT-1003 Skills Truth-Up · Wave A
// NotionBridge · Tests
//
// Locks the metadata-sync remediation: read + write now target the REAL live
// SKILLS columns (Description → Summary fallback, Activation Examples,
// Anti-Triggers) instead of the phantom "Bridge *" columns that never existed.
// Critically, asserts the historical pull-blanks-metadata bug is gone:
//   • the agent-facing field reads "Description", falling back to legacy
//     "Summary" only when Description is empty (Phase-0 gate-safe);
//   • parsing a page that has NONE of the real columns yields empty fields
//     (which the SkillsModule pull branch treats as a no-op — proven here by
//     SkillNotionPulledMetadata equality);
//   • the push patch body writes "Description"/"Activation Examples"/
//     "Anti-Triggers" and NOT the phantom "Bridge *" names.
//
// Pure parse/build assertions — no NotionClient, no network.

import Foundation
import NotionBridgeLib

// MARK: - Fixture helpers

/// A `rich_text` page-property value carrying a single plain-text run.
private func richTextProp(_ text: String) -> [String: Any] {
    return [
        "type": "rich_text",
        "rich_text": [
            ["type": "text", "plain_text": text, "text": ["content": text]]
        ]
    ]
}

/// Decode a built PATCH body back into `[String: Any]` for assertions.
private func decodePatch(_ data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let props = obj["properties"] as? [String: Any] else {
        throw TestError.assertion("patch body is not { properties: {...} }")
    }
    return props
}

/// Plain text of a `rich_text` property in a built patch body.
private func patchPlainText(_ props: [String: Any], _ key: String) -> String? {
    guard let prop = props[key] as? [String: Any],
          let arr = prop["rich_text"] as? [[String: Any]] else { return nil }
    return arr.compactMap { run -> String? in
        (run["text"] as? [String: Any])?["content"] as? String
    }.joined()
}

// MARK: - Runner

func runSkillNotionMetadataSyncTests() async {
    print("\n\u{1F517} PKT-1003 SkillNotionMetadata sync (real columns · gate-safe pull)")

    // -----------------------------------------------------------------
    // 1. Pull prefers the canonical "Description" over legacy "Summary".
    // -----------------------------------------------------------------
    await test("pull: Description is the agent-facing field, preferred over Summary") {
        let props: [String: Any] = [
            "Description": richTextProp("canonical agent-facing description"),
            "Summary": richTextProp("legacy summary should be ignored"),
            "Activation Examples": richTextProp("do the thing\nstart the flow"),
            "Anti-Triggers": richTextProp("never this\nnor that")
        ]
        let pulled = SkillNotionMetadata.parsePulledMetadata(properties: props)
        try expect(pulled.summary == "canonical agent-facing description", "got: \(pulled.summary)")
        try expect(pulled.triggerPhrases == ["do the thing", "start the flow"], "triggers: \(pulled.triggerPhrases)")
        try expect(pulled.antiTriggerPhrases == ["never this", "nor that"], "anti: \(pulled.antiTriggerPhrases)")
    }

    // -----------------------------------------------------------------
    // 2. Phase-0 gate: when Description is empty/absent, fall back to the
    //    legacy "Summary" column so the read works pre-unification.
    // -----------------------------------------------------------------
    await test("pull: falls back to legacy Summary when Description is absent (Phase-0 gate)") {
        let props: [String: Any] = [
            "Summary": richTextProp("legacy still present"),
            "Activation Examples": richTextProp("trigger one")
        ]
        let pulled = SkillNotionMetadata.parsePulledMetadata(properties: props)
        try expect(pulled.summary == "legacy still present", "expected Summary fallback, got: \(pulled.summary)")
        try expect(pulled.triggerPhrases == ["trigger one"], "triggers: \(pulled.triggerPhrases)")
    }

    // -----------------------------------------------------------------
    // 3. THE BUG: the phantom "Bridge *" columns are NOT read. A page that
    //    only has those yields empty fields — which the pull branch treats
    //    as a no-op (preserving local metadata) rather than blanking it.
    // -----------------------------------------------------------------
    await test("pull: phantom 'Bridge *' columns are ignored → empty (no blanking)") {
        let props: [String: Any] = [
            "Bridge Summary": richTextProp("phantom — must not be read"),
            "Bridge Triggers": richTextProp("phantom trigger"),
            "Bridge Anti-triggers": richTextProp("phantom anti")
        ]
        let pulled = SkillNotionMetadata.parsePulledMetadata(properties: props)
        // All empty ⇒ the SkillsModule pull branch keeps the existing local
        // value for each field (gate-safe). Equality proves "nothing to apply".
        try expect(pulled == SkillNotionPulledMetadata(summary: "", triggerPhrases: [], antiTriggerPhrases: []),
                   "phantom columns leaked into the pull: \(pulled)")
    }

    // -----------------------------------------------------------------
    // 4. firstRichTextPlain honours key order (Description wins; else Summary).
    // -----------------------------------------------------------------
    await test("firstRichTextPlain: ordered fallback, first non-empty wins") {
        let bothEmpty: [String: Any] = [
            "Description": richTextProp(""),
            "Summary": richTextProp("summary value")
        ]
        let got = SkillNotionMetadata.firstRichTextPlain(
            keys: SkillNotionColumns.agentFacingReadKeys, properties: bothEmpty)
        try expect(got == "summary value", "empty Description should fall through to Summary, got: \(got)")

        let noneMatch = SkillNotionMetadata.firstRichTextPlain(
            keys: SkillNotionColumns.agentFacingReadKeys, properties: [:])
        try expect(noneMatch == "", "absent columns should yield empty, got: \(noneMatch)")
    }

    // -----------------------------------------------------------------
    // 5. Push writes the REAL columns (Description / Activation Examples /
    //    Anti-Triggers) and never the phantom "Bridge *" names.
    // -----------------------------------------------------------------
    await test("push: patch body targets Description / Activation Examples / Anti-Triggers") {
        let data = try SkillNotionMetadata.buildPagePropertiesPatchData(
            summary: "agent-facing one-liner",
            triggerPhrases: ["fire a", "fire b"],
            antiTriggerPhrases: ["avoid x"]
        )
        let props = try decodePatch(data)

        try expect(props["Description"] != nil, "missing 'Description' in patch")
        try expect(props["Activation Examples"] != nil, "missing 'Activation Examples' in patch")
        try expect(props["Anti-Triggers"] != nil, "missing 'Anti-Triggers' in patch")

        // The phantom columns must be absent.
        try expect(props["Bridge Summary"] == nil, "phantom 'Bridge Summary' written")
        try expect(props["Bridge Triggers"] == nil, "phantom 'Bridge Triggers' written")
        try expect(props["Bridge Anti-triggers"] == nil, "phantom 'Bridge Anti-triggers' written")

        try expect(patchPlainText(props, "Description") == "agent-facing one-liner",
                   "Description text mismatch")
        try expect(patchPlainText(props, "Activation Examples") == "fire a\nfire b",
                   "Activation Examples text mismatch")
        try expect(patchPlainText(props, "Anti-Triggers") == "avoid x",
                   "Anti-Triggers text mismatch")
    }

    // -----------------------------------------------------------------
    // 6. Push leaves empty fields as an empty rich_text array (not a
    //    spurious value) — round-trips back to empty on a later pull.
    // -----------------------------------------------------------------
    await test("push: empty fields encode to empty rich_text arrays") {
        let data = try SkillNotionMetadata.buildPagePropertiesPatchData(
            summary: "", triggerPhrases: [], antiTriggerPhrases: [])
        let props = try decodePatch(data)
        for key in ["Description", "Activation Examples", "Anti-Triggers"] {
            guard let prop = props[key] as? [String: Any],
                  let arr = prop["rich_text"] as? [[String: Any]] else {
                throw TestError.assertion("\(key) is not a rich_text property")
            }
            try expect(arr.isEmpty, "\(key) should be empty rich_text, got \(arr.count) runs")
        }
    }

    // -----------------------------------------------------------------
    // 7. Multi-line trigger parsing trims blanks + whitespace-only lines.
    // -----------------------------------------------------------------
    await test("pull: trigger parsing drops blank + whitespace-only lines") {
        let props: [String: Any] = [
            "Description": richTextProp("d"),
            "Activation Examples": richTextProp("  alpha  \n\n   \nbeta\n")
        ]
        let pulled = SkillNotionMetadata.parsePulledMetadata(properties: props)
        try expect(pulled.triggerPhrases == ["alpha", "beta"], "parsed: \(pulled.triggerPhrases)")
    }
}
