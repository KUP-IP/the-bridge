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
        let text = normalizeTranscript(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
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

        if let sessionHint = extractSessionHint(from: text, lower: lower) {
            intents.append(VoiceMemoIntent(
                kind: .registryUpdate,
                confidence: sessionHint.uppercased().hasPrefix("PKT") ? 0.93 : 0.88,
                entityKey: "session",
                entityHint: sessionHint,
                title: sessionHint,
                body: summary,
                fields: ["objective": appendLog(summary, actions: actions)]
            ))
        }

        if let blockHint = extractBlockHint(from: text, lower: lower) {
            intents.append(VoiceMemoIntent(
                kind: .registryUpdate,
                confidence: 0.87,
                entityKey: "block",
                entityHint: blockHint,
                title: blockHint,
                body: summary,
                fields: ["description": appendLog(summary, actions: actions)]
            ))
        }

        if let projectHint = extractProjectHint(from: lower) {
            intents.append(VoiceMemoIntent(
                kind: .registryUpdate,
                confidence: 0.86,
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

    /// FRONTIER-FIRST shim: delegate the Understand step to `VoiceMemoParseRouter`
    /// (cloud → heuristic for `.auto`). Name retained so existing callers compile.
    public static func parseWithOptionalOllama(
        transcript: String,
        fallbackTitle: String,
        recordingPath: String? = nil
    ) async -> VoiceMemoPlan {
        await VoiceMemoParseRouter.parse(
            transcript: transcript,
            fallbackTitle: fallbackTitle,
            recordingPath: recordingPath
        )
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
        guard lower.contains("log that")
            || lower.contains("talked to")
            || lower.contains("called ")
            || (lower.contains("update ") && (lower.contains("'s") || lower.contains(" contact")))
            || lower.contains("client")
        else {
            return []
        }
        var names: [String] = []
        let patterns = [
            #"log that i (?:talked|spoke|called) with ([a-z][a-z'\- ]{1,40})"#,
            #"update ([a-z][a-z'\- ]{1,30})'?s"#,
            #"called ([a-z][a-z'\- ]{1,30})"#,
            // PKT-MEM-127: voice-router `client` alias — the registry entity is
            // `contact` (entityKey above is already correctly "contact"), but no
            // prior pattern recognized the word "client" at all.
            //
            // Fixed 2026-07-03 (real transcript, not a paraphrase): the actual
            // GH #73 memo says "Greg, Flachek, my client, and..." — name FIRST,
            // "client" as an appositive AFTER the name (dictation commas as
            // pause artifacts). An earlier version of this pattern only looked
            // FORWARD from a bare "client <Name>", which on this exact real
            // transcript matched "client, and..." and captured "and" as the
            // "name" — a live-verified false positive, caught only by testing
            // against the real transcript instead of a secondhand paraphrase of
            // it. Split into two narrower, higher-precision forms instead of one
            // greedy bidirectional guess. Both require: (1) `\bclient\b` — a
            // real word boundary, so "clients" (plural, no named person) never
            // matches as a substring of "client" the way a bare "client" literal
            // would; (2) `(?-i:[A-Z])` — a TRUE capitalized first letter on the
            // captured name, overriding the pattern-wide .caseInsensitive compile
            // option just for that one check, so a lowercase filler word
            // immediately before/after the anchor (e.g. "of" in "some of my
            // clients") can never be captured as if it were a proper name — a
            // second live-caught false positive from the first revision of this
            // fix, found by a dedicated plural-noise regression test.
            #"((?-i:[A-Z])[a-zA-Z'\-]+(?:,\s*(?-i:[A-Z])[a-zA-Z'\-]+){0,2}),?\s+my \bclient\b"#,
            // backward: "<Name>[, <Name>], my client" — matches the real evidence.
            #"\bclient\b\s+named\s+((?-i:[A-Z])[a-zA-Z'\- ]{1,40})"#,
            // forward: "client named <Name>" / "a client named <Name>" — "named"
            // is an unambiguous anchor, unlike a bare "client <anything>" which
            // is exactly what caused the first false-positive above.
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                // Dictation transcripts often insert a comma for a pause between
                // first/last name ("Greg, Flachek, my client") — collapse any
                // internal comma-separated capture into a clean space-joined name.
                let name = String(text[range])
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
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

    private static func extractSessionHint(from text: String, lower: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: #"\b(DST|DS)-(\d+)\b"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r1 = Range(match.range(at: 1), in: text),
           let r2 = Range(match.range(at: 2), in: text) {
            return "\(text[r1].uppercased())-\(text[r2])"
        }
        if let packet = extractPacketID(from: text) { return packet }
        if lower.contains("update session") || lower.contains("session update") {
            if let regex = try? NSRegularExpression(pattern: #"session\s+(DST|DS)-(\d+)"#, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r1 = Range(match.range(at: 1), in: text),
               let r2 = Range(match.range(at: 2), in: text) {
                return "\(text[r1].uppercased())-\(text[r2])"
            }
        }
        return nil
    }

    private static func extractBlockHint(from text: String, lower: String) -> String? {
        guard lower.contains("update block") || lower.contains("block ") else { return nil }
        let patterns = [
            #"update block\s+(.{3,60}?)(?:\.\s|\.\s*remind|\.\s*with|\.$)"#,
            #"block\s+(.{8,60}?)(?:\.\s|\.\s*remind|\.\s*with pass phrase|\.$)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                let hint = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if hint.count >= 3 { return hint }
            }
        }
        return nil
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
        if let regex = try? NSRegularExpression(
            pattern: #"block\s+(.{8,80}?)(?:\.\s|\.\s*remind|\.\s*with pass phrase|\.$)"#,
            options: .caseInsensitive
        ),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let title = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        if let regex = try? NSRegularExpression(
            pattern: #"remind me (?:to |that )?(.{5,80}?)(?:\.\s|\.\s*with pass phrase|\.\s*pass phrase|$)"#,
            options: .caseInsensitive
        ),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return firstSentence(in: text, maxLen: 80)
    }

    /// ASR homophone normalization before phrase matching.
    public static func normalizeTranscript(_ text: String) -> String {
        var t = text
        let pairs: [(String, String)] = [
            ("blog that", "log that"),
            ("blog this", "log this"),
            ("blog my", "log my"),
        ]
        for (from, to) in pairs {
            t = t.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        return t
    }

    /// Append voice-memo content to an existing registry text field (never overwrite).
    public static func appendVoiceMemoLog(existing: String?, newContent: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let block = "— Voice memo \(stamp):\n\(newContent.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty else {
            return block
        }
        return existing + "\n\n" + block
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

    private static func appendLog(_ summary: String, actions: [String]) -> String {
        if actions.isEmpty { return summary }
        return summary + "\n\nActions:\n" + actions.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Public wrapper for summarizer + tests.
    public static func extractActionBulletsPublic(from text: String) -> [String] {
        extractActionBullets(from: text)
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
