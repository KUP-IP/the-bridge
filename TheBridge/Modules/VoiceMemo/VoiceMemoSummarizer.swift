// VoiceMemoSummarizer.swift — LLM summary for memory_keep Relevant: field
// TheBridge · Modules · VoiceMemo

import Foundation

public enum VoiceMemoSummarizer {

    /// One-sentence summary for Notion Memory `summary` (Relevant:). Falls back to heuristic.
    public static func summarize(transcript: String, fallbackTitle: String) async -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackTitle }

        guard BridgeDefaults.voiceMemoOllamaRoutingEffective,
              VoiceMemoCuratorRouter.shouldUseLocalOllama(),
              let model = BridgeDefaults.ollamaSummarizationModelEffective else {
            return VoiceMemoParser.firstSentencePublic(in: trimmed, maxLen: 280)
        }

        let client = OllamaClient.fromDefaults()
        guard (try? await client.health()) == true else {
            return VoiceMemoParser.firstSentencePublic(in: trimmed, maxLen: 280)
        }

        let prompt = """
        Summarize this voice memo in one concise sentence (max 240 characters) for a personal knowledge base. \
        Reply with ONLY the summary sentence, no quotes or JSON.
        Transcript:
        \(trimmed.prefix(6000))
        """
        if let raw = try? await client.generate(model: model, prompt: prompt, options: .init(numPredict: 120, temperature: 0.3)) {
            let sentence = VoiceMemoParser.sanitizeTitle(raw, fallback: "")
            if !sentence.isEmpty {
                return String(sentence.prefix(280))
            }
        }
        return VoiceMemoParser.firstSentencePublic(in: trimmed, maxLen: 280)
    }
}
