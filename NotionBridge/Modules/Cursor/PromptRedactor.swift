// PromptRedactor.swift — PKT-3.4.3 (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Gitleaks-style prompt redaction. Scrubs known credential shapes (AWS keys,
// GitHub tokens, Slack tokens, OpenAI / Anthropic / Stripe / Google keys,
// PEM private keys, JWTs, generic high-entropy strings) from prompts before
// dispatch to the cursor-sidecar. The scrubbed prompt is what flows downstream;
// the redacted values are NEVER persisted.
//
// Audit metadata returned with every redaction:
//   - count       — total number of matches across all rules
//   - ruleIds     — unique rule ids that matched at least once (insertion order)
//   - promptHash  — sha256(originalPrompt) hex; used for AI LOGS audit so a
//                   redaction event can be cross-referenced to a run without
//                   retaining the unredacted prompt
//
// Rules are inline (no external `gitleaks` binary required). User-extensible
// via UserDefaults key `com.notionbridge.cursor.extraRedactionRules` (dict
// of `ruleId: regexPattern`).
//
// Wave 1 of PKT-3.4.3 (this packet): pure redactor + UserDefaults storage.
// Modal surfacing of matched rule IDs in the new-run modal is PKT-3.4.2
// territory; this module just returns the audit payload.

import Foundation
import CryptoKit

public enum PromptRedactor {

    // MARK: - Types

    public struct Rule: @unchecked Sendable {
        public let id: String
        public let label: String
        public let regex: NSRegularExpression

        public init(id: String, label: String, regex: NSRegularExpression) {
            self.id = id
            self.label = label
            self.regex = regex
        }
    }

    public struct Result: Sendable, Equatable {
        public let scrubbed: String
        public let count: Int
        public let ruleIds: [String]
        public let promptHash: String

        public init(scrubbed: String, count: Int, ruleIds: [String], promptHash: String) {
            self.scrubbed = scrubbed
            self.count = count
            self.ruleIds = ruleIds
            self.promptHash = promptHash
        }
    }

    // MARK: - UserDefaults

    public static let userDefaultsKey = "com.notionbridge.cursor.extraRedactionRules"

    // MARK: - Built-in ruleset (gitleaks.toml equivalent, inline)

    public static let builtInRulePatterns: [(id: String, label: String, pattern: String)] = [
        ("aws-access-key-id",     "AWS Access Key ID",            "AKIA[0-9A-Z]{16}"),
        ("aws-session-token",     "AWS Session Token",            "(?:ASIA|FQoG)[A-Za-z0-9/+=]{100,}"),
        ("github-pat",            "GitHub Personal Access Token", "ghp_[A-Za-z0-9]{36,}"),
        ("github-oauth",          "GitHub OAuth Token",           "gho_[A-Za-z0-9]{36,}"),
        ("github-app-token",      "GitHub App Token",             "(?:ghu_|ghs_)[A-Za-z0-9]{36,}"),
        ("github-fine-grained",   "GitHub Fine-Grained PAT",      "github_pat_[A-Za-z0-9_]{82,}"),
        ("slack-bot-token",       "Slack Bot Token",              "xoxb-[0-9]{10,}-[0-9]{10,}-[A-Za-z0-9]{20,}"),
        ("slack-user-token",      "Slack User Token",             "xoxp-[0-9]{10,}-[0-9]{10,}-[0-9]{10,}-[A-Za-z0-9]{20,}"),
        ("slack-webhook",         "Slack Webhook URL",            "https://hooks\\.slack\\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]{16,}"),
        ("openai-key",            "OpenAI API Key",               "sk-(?:proj-)?[A-Za-z0-9_-]{32,}"),
        ("anthropic-key",         "Anthropic API Key",            "sk-ant-[A-Za-z0-9_-]{32,}"),
        ("stripe-secret-key",     "Stripe Secret Key",            "(?:sk|rk)_(?:test|live)_[A-Za-z0-9]{24,}"),
        ("google-api-key",        "Google API Key",               "AIza[0-9A-Za-z_-]{35}"),
        ("private-key-block",     "PEM-encoded private key",      "-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"),
        ("jwt",                   "JWT (RFC 7519)",               "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"),
        ("generic-high-entropy",  "Generic high-entropy ≥40",     "(?<![A-Za-z0-9])[A-Za-z0-9+/=_-]{40,}(?![A-Za-z0-9+/=_-])")
    ]

    public static let builtInRules: [Rule] = builtInRulePatterns.compactMap { triple in
        guard let rx = try? NSRegularExpression(pattern: triple.pattern, options: []) else {
            return nil
        }
        return Rule(id: triple.id, label: triple.label, regex: rx)
    }

    // MARK: - Public API

    public static func redact(
        _ prompt: String,
        defaults: UserDefaults = .standard
    ) -> Result {
        let rules = effectiveRules(defaults: defaults)
        var working = prompt
        var totalCount = 0
        var ruleIdsHit: [String] = []
        for rule in rules {
            let nsRange = NSRange(working.startIndex..<working.endIndex, in: working)
            let matches = rule.regex.matches(in: working, options: [], range: nsRange)
            if matches.isEmpty { continue }
            totalCount += matches.count
            if !ruleIdsHit.contains(rule.id) { ruleIdsHit.append(rule.id) }
            // Replace from end to preserve earlier ranges.
            for match in matches.reversed() {
                guard let r = Range(match.range, in: working) else { continue }
                let placeholder = "[REDACTED:\(rule.id)]"
                working.replaceSubrange(r, with: placeholder)
            }
        }
        return Result(
            scrubbed: working,
            count: totalCount,
            ruleIds: ruleIdsHit,
            promptHash: sha256Hex(prompt)
        )
    }

    public static func effectiveRules(defaults: UserDefaults = .standard) -> [Rule] {
        var all = builtInRules
        if let extra = defaults.dictionary(forKey: userDefaultsKey) as? [String: String] {
            for (id, pattern) in extra {
                if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
                    all.append(Rule(id: id, label: id, regex: rx))
                }
            }
        }
        return all
    }

    public static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
