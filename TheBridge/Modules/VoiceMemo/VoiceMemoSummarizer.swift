// VoiceMemoSummarizer.swift — structured summary for memory_keep (W3 Phase C)
// TheBridge · Modules · VoiceMemo

import Foundation

/// Summary + action items for Notion Memory keeps (properties + optional body).
public struct VoiceMemoStructuredSummary: Sendable, Equatable {
    public let paragraph: String
    public let actions: [String]

    public init(paragraph: String, actions: [String]) {
        self.paragraph = paragraph
        self.actions = actions
    }

    /// Text for the registry `summary` / Relevant field (includes action bullets).
    public var relevantFieldText: String {
        VoiceMemoParser.memoryKeepFields(
            title: "",
            summary: paragraph,
            actions: actions
        )["summary"] ?? paragraph
    }
}

public enum VoiceMemoSummarizer {

    /// Structured summary for memory_keep: paragraph + action items. Falls back to heuristic.
    public static func structuredSummary(transcript: String, fallbackTitle: String) async -> VoiceMemoStructuredSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VoiceMemoStructuredSummary(paragraph: fallbackTitle, actions: [])
        }

        let heuristicActions = VoiceMemoParser.extractActionBulletsPublic(from: trimmed)
        let heuristicParagraph = VoiceMemoParser.firstSentencePublic(in: trimmed, maxLen: 280)

        guard BridgeDefaults.voiceMemoOllamaRoutingEffective,
              VoiceMemoCuratorRouter.shouldUseLocalOllama(),
              let model = BridgeDefaults.ollamaSummarizationModelEffective else {
            return VoiceMemoStructuredSummary(paragraph: heuristicParagraph, actions: heuristicActions)
        }

        let client = OllamaClient.fromDefaults()
        guard (try? await client.health()) == true else {
            return VoiceMemoStructuredSummary(paragraph: heuristicParagraph, actions: heuristicActions)
        }

        let prompt = """
        Summarize this voice memo for a personal knowledge base. Reply with ONLY valid JSON, no markdown:
        {"summary":"2-4 sentence paragraph","actions":["action item 1","action item 2"]}
        Use an empty actions array if none. Max 400 chars in summary.
        Transcript:
        \(trimmed.prefix(6000))
        """
        if let raw = try? await client.generate(model: model, prompt: prompt, options: .init(numPredict: 220, temperature: 0.3)),
           let parsed = parseStructuredJSON(raw, fallbackParagraph: heuristicParagraph, fallbackActions: heuristicActions) {
            return parsed
        }
        return VoiceMemoStructuredSummary(paragraph: heuristicParagraph, actions: heuristicActions)
    }

    /// One-sentence summary (legacy callers). Prefer `structuredSummary`.
    public static func summarize(transcript: String, fallbackTitle: String) async -> String {
        let structured = await structuredSummary(transcript: transcript, fallbackTitle: fallbackTitle)
        return structured.relevantFieldText
    }

    public static func parseStructuredJSON(
        _ raw: String,
        fallbackParagraph: String,
        fallbackActions: [String]
    ) -> VoiceMemoStructuredSummary? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonSlice = String(trimmed[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let summaryRaw = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let paragraph = VoiceMemoParser.sanitizeTitle(
            summaryRaw.isEmpty ? nil : summaryRaw,
            fallback: fallbackParagraph
        )
        var actions: [String] = []
        if let arr = obj["actions"] as? [String] {
            actions = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if let arr = obj["actions"] as? [Any] {
            actions = arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if actions.isEmpty { actions = fallbackActions }
        return VoiceMemoStructuredSummary(paragraph: String(paragraph.prefix(400)), actions: Array(actions.prefix(8)))
    }
}
