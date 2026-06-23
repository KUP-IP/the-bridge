// RoutingIndex.swift — auto-generated digest of routing skills emitted
// in the MCP initialize handshake. PKT-9.
//
// Goal: the agent learns "what's routable" without having to fetch
// every skill body. One-line description + triggers + anti-triggers
// per skill, in deterministic order, formatted as compact markdown.
//
// The index is regenerated from the skills cache; cache population is
// owned by the existing skills-sync pipeline (out of scope here).

import Foundation

public struct RoutingSkillSummary: Equatable, Sendable {
    public let slug: String
    public let name: String
    public let domain: String?     // e.g. FOCUS, SYSTEM, CRM
    public let maturity: String?   // Stable / Testing / Genesis
    public let description: String
    public let triggers: [String]
    public let antiTriggers: [String]

    public init(
        slug: String,
        name: String,
        domain: String?,
        maturity: String?,
        description: String,
        triggers: [String],
        antiTriggers: [String]
    ) {
        self.slug = slug
        self.name = name
        self.domain = domain
        self.maturity = maturity
        self.description = description
        self.triggers = triggers
        self.antiTriggers = antiTriggers
    }
}

public enum RoutingIndex {

    /// Render a compact markdown digest of every routing skill in `skills`.
    /// Stable ordering (alpha by slug) so the output is reproducible.
    public static func render(_ skills: [RoutingSkillSummary]) -> String {
        guard !skills.isEmpty else {
            return "## Routing skills available\n\n_None registered yet._"
        }
        var out = "## Routing skills available\n"
        for skill in skills.sorted(by: { $0.slug < $1.slug }) {
            let badge = [skill.domain, skill.maturity]
                .compactMap { $0 }
                .joined(separator: ", ")
            let header = badge.isEmpty
                ? "- **\(skill.name)** (`\(skill.slug)`)"
                : "- **\(skill.name)** (`\(skill.slug)`, \(badge))"
            out += "\n\(header)\n  \(oneLine(skill.description))"
            if !skill.triggers.isEmpty {
                out += "\n  triggers: \(skill.triggers.joined(separator: ", "))"
            }
            if !skill.antiTriggers.isEmpty {
                out += "\n  anti: \(skill.antiTriggers.joined(separator: ", "))"
            }
        }
        return out
    }

    /// Collapse any embedded newlines so each skill stays on one logical row.
    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }
}
