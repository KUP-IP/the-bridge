// SkillRoutingGovernance.swift — skill-system ownership enforcement
// TheBridge · Skills

import Foundation
import MCP

/// Validates the SKILLS Keepr route receipt required before an MCP caller may
/// mutate the skill registry. The Settings UI does not pass through this
/// surface, so operator-managed local configuration remains unaffected.
public enum SkillRouteReceiptValidator {
    public static let schema: Value = .object([
        "type": .string("object"),
        "description": .string("Current SKILLS Keepr route receipt. Required for every skill-system mutation."),
        "properties": .object([
            "domainOwner": .object([
                "type": .string("string"),
                "description": .string("Must identify SKILLS Keepr, normally 'skill-keepr'.")
            ]),
            "routeId": .object([
                "type": .string("string"),
                "description": .string("SKILLS Keepr route identifier, such as R2, R4, R6, R6B, or R8.")
            ]),
            "targetSkills": stringArraySchema("Skill names covered by this receipt."),
            "changeManifest": stringArraySchema("Approved changes the worker may implement."),
            "acceptanceTests": stringArraySchema("Tests or checks that must pass."),
            "writeScope": stringArraySchema("Allowed write targets or property/body scopes.")
        ]),
        "required": .array([
            .string("domainOwner"), .string("routeId"), .string("targetSkills"),
            .string("changeManifest"), .string("acceptanceTests"), .string("writeScope")
        ])
    ])

    /// Returns nil when the receipt is valid, otherwise a user-actionable error.
    public static func validationError(
        receipt: Value?,
        expectedTargets: [String]
    ) -> String? {
        guard case .object(let fields)? = receipt else {
            return missingReceiptMessage
        }

        guard case .string(let rawOwner)? = fields["domainOwner"],
              ownerIsSkillKeepr(rawOwner) else {
            return "routeReceipt.domainOwner must be 'skill-keepr' or 'skills-keepr'."
        }

        guard case .string(let rawRoute)? = fields["routeId"],
              routeIsValid(rawRoute) else {
            return "routeReceipt.routeId must be a SKILLS Keepr route such as R2, R4, R6, R6B, or R8."
        }

        let targets = stringArray(fields["targetSkills"])
        guard !targets.isEmpty else {
            return "routeReceipt.targetSkills must contain at least one governed skill."
        }
        guard !stringArray(fields["changeManifest"]).isEmpty else {
            return "routeReceipt.changeManifest must contain at least one approved change."
        }
        guard !stringArray(fields["acceptanceTests"]).isEmpty else {
            return "routeReceipt.acceptanceTests must contain at least one verification check."
        }
        guard !stringArray(fields["writeScope"]).isEmpty else {
            return "routeReceipt.writeScope must contain at least one allowed write target."
        }

        let normalizedTargets = Set(targets.map(normalizeSkillName))
        let missing = expectedTargets
            .filter { !normalizedTargets.contains(normalizeSkillName($0)) }
        if !missing.isEmpty {
            return "routeReceipt.targetSkills does not cover: \(missing.joined(separator: ", ")). Re-route through SKILLS Keepr for the current target set."
        }
        return nil
    }

    public static let missingReceiptMessage =
        "A current SKILLS Keepr routeReceipt is required before skill-system mutations. Re-route for the current sub-task and include domainOwner, routeId, targetSkills, changeManifest, acceptanceTests, and writeScope."

    private static func stringArraySchema(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")]),
            "minItems": .int(1)
        ])
    }

    private static func stringArray(_ value: Value?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { item in
            guard case .string(let text) = item else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func ownerIsSkillKeepr(_ raw: String) -> Bool {
        let normalized = normalizeSkillName(raw)
        return normalized == "skill-keepr" || normalized == "skills-keepr"
    }

    private static func routeIsValid(_ raw: String) -> Bool {
        let route = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard route.first == "R", route.count >= 2 else { return false }
        let suffix = route.dropFirst()
        if suffix == "6B" { return true }
        guard let number = Int(suffix) else { return false }
        return (0...10).contains(number)
    }

    private static func normalizeSkillName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
    }
}

/// Pure routing-metadata checks surfaced by `skills_routing_list`.
public enum SkillRoutingConsistencyLinter {
    public static func warnings(
        parentName: String,
        summary: String,
        triggerPhrases: [String],
        antiTriggerPhrases: [String],
        specialists: [SpecialistSummary]
    ) -> [String] {
        var warnings: [String] = []
        let summaryText = summary.lowercased()
        let triggers = triggerPhrases.joined(separator: " ").lowercased()
        let antiTriggers = antiTriggerPhrases.joined(separator: " ").lowercased()
        let specialistText = specialists
            .map { "\($0.title) \($0.summary)" }
            .joined(separator: " ")
            .lowercased()

        let claimsFrontDoor = summaryText.contains("mandatory front door")
            || summaryText.contains("single point of entry")
            || summaryText.contains("single entry point")
        let hasBuilder = specialistText.contains("skill-builder")
            || specialistText.contains("construction")
            || specialistText.contains("scaffold")
        let antiRoutesConstruction = antiTriggers.contains("create a new skill")
            || antiTriggers.contains("create new skill")
            || antiTriggers.contains("build new skill")
            || antiTriggers.contains("skill construction")
        let triggersConstruction = triggers.contains("create")
            || triggers.contains("build")
            || triggers.contains("scaffold")
            || triggers.contains("restructure")
            || triggers.contains("consolidate")

        if claimsFrontDoor && hasBuilder && antiRoutesConstruction {
            warnings.append("\(parentName) claims front-door ownership but anti-routes construction despite having a construction specialist.")
        }
        if hasBuilder && !triggersConstruction {
            warnings.append("\(parentName) has a construction specialist but no construction or refactor trigger phrase.")
        }
        if !specialists.isEmpty && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("\(parentName) has specialists but no routing summary.")
        }
        for specialist in specialists where specialist.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("Specialist '\(specialist.title)' has an empty routing summary.")
        }
        return warnings
    }
}
