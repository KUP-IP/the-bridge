// SkillNotionMetadata.swift — Notion property names + rich_text bridge fields for skills
// NotionBridge · Modules
//
// SSOT = Notion. The live SKILLS data source exposes these `rich_text` columns:
//   • "Description"        — the single agent-facing field (preferred).
//   • "Summary"            — LEGACY agent-facing field; kept only as a read
//                            fallback while the Notion Phase-0 unification (which
//                            rewrites Description on every row and deletes Summary)
//                            is still pending. Code must be gate-safe: prefer
//                            Description, fall back to Summary, never blank either.
//   • "Activation Examples" — trigger phrases (one per line).
//   • "Anti-Triggers"       — anti-trigger phrases (one per line).
//
// HISTORICAL BUG (fixed PKT-1003 / Skills Truth-Up): sync read+write previously
// targeted the phantom "Bridge Summary" / "Bridge Triggers" / "Bridge
// Anti-triggers" columns, which DO NOT EXIST in the live data source. A "pull"
// therefore read empty strings and BLANKED local metadata. The read now targets
// the real columns with an ordered fallback, and the pull is gate-safe (an empty
// Notion value never overwrites a non-empty local value — see SkillsModule's
// skill_sync_notion pull branch).

import Foundation

/// Real Notion column names on each skill page in the live SKILLS data source.
/// `description` is the preferred agent-facing field; `summaryLegacy` is read as
/// a fallback only (it is being retired by the Notion Phase-0 unification).
public enum SkillNotionColumns: Sendable {
    public static let description = "Description"
    public static let summaryLegacy = "Summary"
    public static let activationExamples = "Activation Examples"
    public static let antiTriggers = "Anti-Triggers"

    /// Ordered read fallback for the single agent-facing field: prefer the
    /// canonical "Description", fall back to the legacy "Summary" while it still
    /// exists in Notion (Phase-0 gate). First non-empty wins.
    public static let agentFacingReadKeys: [String] = [description, summaryLegacy]
}

/// DEPRECATED — retained for source compatibility. Previously held the phantom
/// "Bridge *" property names that never existed in the live data source. Now
/// re-pointed at the real columns so any lingering reference is harmless.
/// New code should use `SkillNotionColumns`.
@available(*, deprecated, message: "Use SkillNotionColumns; the 'Bridge *' columns never existed in the live data source.")
public enum SkillBridgeNotionPropertyNames: Sendable {
    public static let summary = SkillNotionColumns.description
    public static let triggers = SkillNotionColumns.activationExamples
    public static let antiTriggers = SkillNotionColumns.antiTriggers
}

/// Structured result of a Notion → local metadata pull. Empty strings/arrays
/// mean "Notion had nothing here" — the caller treats those as no-ops so a pull
/// can never blank a non-empty local field.
public struct SkillNotionPulledMetadata: Sendable, Equatable {
    public let summary: String
    public let triggerPhrases: [String]
    public let antiTriggerPhrases: [String]

    public init(summary: String, triggerPhrases: [String], antiTriggerPhrases: [String]) {
        self.summary = summary
        self.triggerPhrases = triggerPhrases
        self.antiTriggerPhrases = antiTriggerPhrases
    }
}

/// Encode/decode for PATCH page properties and GET page parse.
public enum SkillNotionMetadata: Sendable {

    /// Plain text from a top-level `rich_text` page property.
    public static func richTextPlain(propertyName: String, properties: [String: Any]) -> String {
        guard let prop = properties[propertyName] as? [String: Any],
              (prop["type"] as? String) == "rich_text",
              let rt = prop["rich_text"] as? [[String: Any]] else {
            return ""
        }
        return NotionJSON.extractPlainText(from: rt)
    }

    /// First non-empty `rich_text` plain text among `keys`, in order. Used for
    /// the agent-facing field's Description→Summary fallback so the read works
    /// whether or not the legacy "Summary" column still exists.
    public static func firstRichTextPlain(keys: [String], properties: [String: Any]) -> String {
        for key in keys {
            let text = richTextPlain(propertyName: key, properties: properties)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// One phrase per line when stored in Notion.
    public static func phrasesFromStoredText(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parse a fetched Notion page's `properties` into the agent-facing metadata
    /// fields, reading the REAL columns (Description→Summary fallback,
    /// Activation Examples, Anti-Triggers). Pure; never throws. Empty fields are
    /// surfaced as empty — the pull caller treats those as no-ops (gate-safe).
    public static func parsePulledMetadata(properties: [String: Any]) -> SkillNotionPulledMetadata {
        let summary = firstRichTextPlain(keys: SkillNotionColumns.agentFacingReadKeys, properties: properties)
        let trigText = richTextPlain(propertyName: SkillNotionColumns.activationExamples, properties: properties)
        let antiText = richTextPlain(propertyName: SkillNotionColumns.antiTriggers, properties: properties)
        return SkillNotionPulledMetadata(
            summary: summary,
            triggerPhrases: phrasesFromStoredText(trigText),
            antiTriggerPhrases: phrasesFromStoredText(antiText)
        )
    }

    /// JSON body for `PATCH /v1/pages/{id}` — `{ "properties": { ... } }`.
    /// Writes the single agent-facing field to "Description" (SSOT field) plus
    /// the trigger/anti-trigger columns. Does NOT write the legacy "Summary"
    /// column (it is being retired); the Notion Phase-0 unification owns that.
    public static func buildPagePropertiesPatchData(
        summary: String,
        triggerPhrases: [String],
        antiTriggerPhrases: [String]
    ) throws -> Data {
        let trigText = triggerPhrases.joined(separator: "\n")
        let antiText = antiTriggerPhrases.joined(separator: "\n")
        let props: [String: Any] = [
            SkillNotionColumns.description: richTextPropertyJSON(summary),
            SkillNotionColumns.activationExamples: richTextPropertyJSON(trigText),
            SkillNotionColumns.antiTriggers: richTextPropertyJSON(antiText)
        ]
        let body: [String: Any] = ["properties": props]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Private

    private static func richTextPropertyJSON(_ text: String) -> [String: Any] {
        if text.isEmpty {
            let empty: [[String: Any]] = []
            return ["rich_text": empty]
        }
        let chunks = chunkForNotionRichText(text)
        let arr: [[String: Any]] = chunks.map { chunk in
            ["type": "text", "text": ["content": chunk]]
        }
        return ["rich_text": arr]
    }

    /// Notion text content objects are limited to 2000 characters each.
    private static func chunkForNotionRichText(_ text: String, maxLen: Int = 2000) -> [String] {
        var out: [String] = []
        var rest = String(text)
        while !rest.isEmpty {
            let prefix = String(rest.prefix(maxLen))
            out.append(prefix)
            rest = String(rest.dropFirst(maxLen))
        }
        return out
    }
}
