// VoiceMemoParser.swift — heuristic intent extraction (Wave 1)
// TheBridge · Modules · VoiceMemo
//
// Wave 1 uses deterministic phrase matching so jobs/tests run without an LLM.
// A future wave can swap the parser body for an HTTP/Ollama classifier while
// keeping the same VoiceMemoPlan envelope.

import Foundation

public enum VoiceMemoParser {

    /// Extract a routing plan from transcript text (Wave 1 heuristics).
    public static func parse(
        transcript: String,
        fallbackTitle: String,
        recordingPath: String? = nil
    ) -> VoiceMemoPlan {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        let skipMemoryKeep =
            lower.contains("don't create a memory")
            || lower.contains("do not create a memory")
            || lower.contains("no memory")
            || lower.contains("don't save a memory")
            || lower.contains("just update")
            || lower.contains("just log")

        let summary = firstSentence(in: text, maxLen: 280)
        let actions = extractActionBullets(from: text)
        var intents: [VoiceMemoIntent] = []

        if matchesReminder(lower) {
            intents.append(VoiceMemoIntent(
                kind: .reminder,
                confidence: 0.92,
                title: reminderTitle(from: text) ?? fallbackTitle,
                body: summary,
                dueISO8601: nil
            ))
        }

        if matchesAgentMemory(lower) {
            intents.append(VoiceMemoIntent(
                kind: .agentMemory,
                confidence: 0.88,
                title: fallbackTitle,
                body: summary,
                fields: ["scope": "global"]
            ))
        }

        if !skipMemoryKeep && matchesMemoryKeep(lower) {
            intents.append(VoiceMemoIntent(
                kind: .memoryKeep,
                confidence: 0.9,
                entityKey: "memory",
                title: generatedTitle(from: text, fallback: fallbackTitle),
                body: summary,
                fields: memoryKeepFields(
                    title: generatedTitle(from: text, fallback: fallbackTitle),
                    summary: summary,
                    actions: actions,
                    recordingPath: recordingPath
                )
            ))
        }

        for hint in entityHints(from: text, kind: .registryUpdate, entityKey: "contact") {
            intents.append(hint)
        }

        if let packet = extractPacketID(from: text) {
            intents.append(VoiceMemoIntent(
                kind: .registryUpdate,
                confidence: 0.93,
                entityKey: "session",
                entityHint: packet,
                title: packet,
                body: summary,
                fields: ["objective": appendLog(summary, actions: actions)]
            ))
        }

        if let projectHint = extractProjectHint(from: lower) {
            intents.append(VoiceMemoIntent(
                kind: .registryUpdate,
                confidence: 0.82,
                entityKey: "project",
                entityHint: projectHint,
                title: projectHint,
                body: summary,
                fields: ["summary": appendLog(summary, actions: actions)]
            ))
        }

        if intents.isEmpty {
            intents.append(VoiceMemoIntent(
                kind: .review,
                confidence: 0.5,
                title: fallbackTitle,
                body: summary
            ))
        }

        return VoiceMemoPlan(
            generatedTitle: generatedTitle(from: text, fallback: fallbackTitle),
            skipMemoryKeep: skipMemoryKeep,
            summary: summary,
            actions: actions,
            intents: intents
        )
    }

    /// When Ollama routing is enabled and configured, attempt LLM classification; fall back to heuristics.
    public static func parseWithOptionalOllama(
        transcript: String,
        fallbackTitle: String,
        recordingPath: String? = nil
    ) async -> VoiceMemoPlan {
        guard BridgeDefaults.voiceMemoOllamaRoutingEffective,
              let model = BridgeDefaults.ollamaRoutingModelEffective else {
            return parse(transcript: transcript, fallbackTitle: fallbackTitle, recordingPath: recordingPath)
        }
        let client = OllamaClient.fromDefaults()
        guard (try? await client.health()) == true else {
            return parse(transcript: transcript, fallbackTitle: fallbackTitle, recordingPath: recordingPath)
        }
        let prompt = """
        Classify this voice memo transcript into routing lanes. Reply with ONLY JSON:
        {"lanes":["reminder"|"memory_keep"|"agent_memory"|"registry_update"|"review"], "title":"...", "confidence":0.0-1.0}
        Transcript:
        \(transcript.prefix(4000))
        """
        let genOptions = OllamaClient.GenerateOptions(numPredict: 512, temperature: 0.2, think: false)
        guard let raw = try? await client.generate(model: model, prompt: prompt, options: genOptions),
              let plan = parseOllamaJSON(raw, transcript: transcript, fallbackTitle: fallbackTitle, recordingPath: recordingPath) else {
            return parse(transcript: transcript, fallbackTitle: fallbackTitle, recordingPath: recordingPath)
        }
        return plan
    }

    // MARK: - Matchers

    private static func matchesReminder(_ lower: String) -> Bool {
        lower.contains("remind me")
            || lower.contains("add to my reminders")
            || lower.contains("add to reminders")
            || lower.contains("add this to reminders")
    }

    private static func matchesMemoryKeep(_ lower: String) -> Bool {
        lower.contains("memory keep")
            || lower.contains("keep this")
            || lower.contains("save this note")
            || lower.contains("save this")
            || (lower.contains("remember that") && !lower.contains("remind me"))
    }

    private static func matchesAgentMemory(_ lower: String) -> Bool {
        lower.contains("agents should know")
            || lower.contains("when bridge starts")
            || lower.contains("when agents connect")
            || lower.contains("agent memory")
    }

    private static func entityHints(from text: String, kind: VoiceMemoIntentKind, entityKey: String) -> [VoiceMemoIntent] {
        let lower = text.lowercased()
        guard lower.contains("log that") || lower.contains("update ") || lower.contains("talked to") || lower.contains("called ") else {
            return []
        }
        var names: [String] = []
        let patterns = [
            #"log that i (?:talked|spoke|called) with ([a-z][a-z'\- ]{1,40})"#,
            #"update ([a-z][a-z'\- ]{1,30})'?s"#,
            #"called ([a-z][a-z'\- ]{1,30})"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { names.append(name.capitalized) }
            }
        }
        return names.map { name in
            VoiceMemoIntent(
                kind: kind,
                confidence: 0.86,
                entityKey: entityKey,
                entityHint: name,
                title: name,
                body: firstSentence(in: text, maxLen: 400),
                fields: ["brief": text.prefix(2000).description]
            )
        }
    }

    private static func extractPacketID(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"PKT-\d+"#, options: .caseInsensitive) else { return nil }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).uppercased()
    }

    private static func extractProjectHint(from lower: String) -> String? {
        if lower.contains("bridge v4") { return "Bridge v4" }
        if lower.contains("the bridge") { return "The Bridge" }
        if let regex = try? NSRegularExpression(pattern: #"project ([a-z0-9][a-z0-9 \-]{2,40})"#),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let range = Range(match.range(at: 1), in: lower) {
            return String(lower[range]).capitalized
        }
        return nil
    }

    private static func reminderTitle(from text: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: #"remind me (?:to |that )?(.{5,80})"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return firstSentence(in: text, maxLen: 80)
    }

    private static func generatedTitle(from text: String, fallback: String) -> String {
        let sentence = firstSentence(in: text, maxLen: 72)
        if sentence.count >= 8 { return sentence }
        return fallback
    }

    /// Canonical Memory registry field keys (bound entity `memory`).
    public static func memoryKeepFields(
        title: String,
        summary: String,
        actions: [String],
        recordingPath: String? = nil
    ) -> [String: String] {
        var relevant = summary
        if !actions.isEmpty {
            relevant += "\n\nActions:\n" + actions.map { "- \($0)" }.joined(separator: "\n")
        }
        var fields: [String: String] = [
            "title": title,
            "summary": relevant,
            "alias": "voice-memo",
            "status": "Inbox",
            "type": "Memory",
        ]
        if let recordingPath, !recordingPath.isEmpty {
            fields["url"] = "file://\(recordingPath)"
        }
        return fields
    }

    private static func parseOllamaJSON(
        _ raw: String,
        transcript: String,
        fallbackTitle: String,
        recordingPath: String?
    ) -> VoiceMemoPlan? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonSlice = String(trimmed[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lanes = obj["lanes"] as? [String] else { return nil }

        let confidence = (obj["confidence"] as? Double) ?? (obj["confidence"] as? Int).map(Double.init) ?? 0.75
        let summary = firstSentence(in: transcript, maxLen: 280)
        let actions = extractActionBullets(from: transcript)
        let generated = sanitizeTitle(obj["title"] as? String, fallback: generatedTitle(from: transcript, fallback: fallbackTitle))

        var intents: [VoiceMemoIntent] = []
        for lane in lanes {
            switch lane {
            case "reminder":
                intents.append(VoiceMemoIntent(kind: .reminder, confidence: confidence, title: generated, body: summary))
            case "memory_keep":
                intents.append(VoiceMemoIntent(
                    kind: .memoryKeep,
                    confidence: confidence,
                    entityKey: "memory",
                    title: generated,
                    body: summary,
                    fields: memoryKeepFields(title: generated, summary: summary, actions: actions, recordingPath: recordingPath)
                ))
            case "agent_memory":
                intents.append(VoiceMemoIntent(kind: .agentMemory, confidence: confidence, title: generated, body: summary, fields: ["scope": "global"]))
            case "registry_update":
                intents.append(VoiceMemoIntent(kind: .registryUpdate, confidence: confidence * 0.9, entityKey: "session", title: generated, body: summary))
            case "review":
                intents.append(VoiceMemoIntent(kind: .review, confidence: confidence, title: generated, body: summary))
            default:
                continue
            }
        }
        guard !intents.isEmpty else { return nil }
        return VoiceMemoPlan(
            generatedTitle: generated,
            skipMemoryKeep: !lanes.contains("memory_keep"),
            summary: summary,
            actions: actions,
            intents: intents
        )
    }

    private static func appendLog(_ summary: String, actions: [String]) -> String {
        if actions.isEmpty { return summary }
        return summary + "\n\nActions:\n" + actions.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Public wrapper for summarizer + tests.
    public static func firstSentencePublic(in text: String, maxLen: Int) -> String {
        firstSentence(in: text, maxLen: maxLen)
    }

    /// Reject placeholder LLM titles (`"..."`, `unknown`, etc.) in favor of heuristic fallback.
    public static func sanitizeTitle(_ raw: String?, fallback: String) -> String {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return fallback }
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lower = t.lowercased()
        let placeholders: Set<String> = ["...", "…", "—", "-", "unknown", "untitled", "n/a", "title", "memo"]
        if placeholders.contains(lower) || t == "..." || t == "…" { return fallback }
        if t.count < 3 { return fallback }
        return String(t.prefix(120))
    }

    private static func firstSentence(in text: String, maxLen: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let terminators = CharacterSet(charactersIn: ".!?\n")
        if let charRange = trimmed.rangeOfCharacter(from: terminators) {
            let sentence = String(trimmed[..<charRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { return String(sentence.prefix(maxLen)) }
        }
        return String(trimmed.prefix(maxLen))
    }

    private static func extractActionBullets(from text: String) -> [String] {
        var actions: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("• ") {
                actions.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if t.lowercased().hasPrefix("action:") {
                actions.append(String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            }
        }
        if actions.isEmpty {
            let lower = text.lowercased()
            if lower.contains("follow up") || lower.contains("follow-up") {
                actions.append("Follow up")
            }
        }
        return actions
    }
}
