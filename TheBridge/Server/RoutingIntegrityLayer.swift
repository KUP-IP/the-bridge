// RoutingIntegrityLayer.swift - PKT-1094
// TheBridge / Server
//
// Server-side routing integrity primitives. This is intentionally code-owned:
// tool-to-skill bindings are no longer inferred from mutable skill-page prose.

import Foundation
import MCP

public struct RoutingGovernanceSkill: Sendable, Codable, Equatable, Hashable {
    public let slug: String
    public let role: String

    public init(slug: String, role: String) {
        self.slug = slug
        self.role = role
    }
}

public struct ToolSkillBinding: Sendable, Codable, Equatable, Hashable {
    public let toolName: String
    public let governingSkills: [RoutingGovernanceSkill]
    public let requiresManifestFetch: Bool
    public let reason: String

    public init(
        toolName: String,
        governingSkills: [RoutingGovernanceSkill],
        requiresManifestFetch: Bool = true,
        reason: String
    ) {
        self.toolName = toolName
        self.governingSkills = governingSkills
        self.requiresManifestFetch = requiresManifestFetch
        self.reason = reason
    }

    public var governanceSummary: String {
        governingSkills
            .map { "\($0.slug) (\($0.role))" }
            .joined(separator: ", ")
    }

    /// Exact acknowledgement scope. Scopes are intentionally tool-specific:
    /// acknowledging Messages reads never authorizes Notion or calendar work,
    /// and no process-wide/global marker exists.
    public var scopeID: String { "tool:\(toolName)" }
}

public struct RoutingIntegrityReceipt: Sendable, Codable, Equatable {
    public let registryVersion: Int
    public let boundToolCount: Int
    public let manifestMarkerTools: [String]
    public let descriptionCharBudget: Int
    public let warnings: [String]

    public init(
        registryVersion: Int,
        boundToolCount: Int,
        manifestMarkerTools: [String],
        descriptionCharBudget: Int,
        warnings: [String] = []
    ) {
        self.registryVersion = registryVersion
        self.boundToolCount = boundToolCount
        self.manifestMarkerTools = manifestMarkerTools
        self.descriptionCharBudget = descriptionCharBudget
        self.warnings = warnings
    }
}

public enum ToolSkillBindingRegistry {
    public static let registryVersion = 1

    public static let manifestMarkerTools: Set<String> = [
        BridgeInitializeModule.toolName,
        "fetch_skill",
        "skills_routing_list",
    ]

    public static let bindings: [ToolSkillBinding] = [
        ToolSkillBinding(
            toolName: "messages_send",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "relationship intent and draft/review boundary"),
                RoutingGovernanceSkill(slug: "mac-message", role: "approved delivery mechanics"),
            ],
            reason: "Outbound Messages delivery must be routed through relationship intent and explicit delivery approval."
        ),
        ToolSkillBinding(
            toolName: "messages_chat",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "conversation identity resolution"),
                RoutingGovernanceSkill(slug: "mac-message", role: "Messages data access"),
            ],
            reason: "Chat lookup feeds message delivery and must preserve contact/context routing."
        ),
        ToolSkillBinding(
            toolName: "messages_recent",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "recent-contact disambiguation"),
                RoutingGovernanceSkill(slug: "mac-message", role: "Messages data access"),
            ],
            reason: "Recent-message lookup is frequently used for recipient resolution before delivery."
        ),
        ToolSkillBinding(
            toolName: "messages_search",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "relationship context"),
                RoutingGovernanceSkill(slug: "mac-message", role: "Messages data search"),
            ],
            reason: "Message search carries relationship context and can drive outbound follow-up."
        ),
        ToolSkillBinding(
            toolName: "messages_content",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "relationship context"),
                RoutingGovernanceSkill(slug: "mac-message", role: "Messages thread read"),
            ],
            reason: "Thread reads shape relationship actions and must follow the messaging route."
        ),
        ToolSkillBinding(
            toolName: "messages_participants",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "identity disambiguation"),
                RoutingGovernanceSkill(slug: "mac-message", role: "Messages participant read"),
            ],
            reason: "Participant reads are identity-critical before any delivery action."
        ),
        ToolSkillBinding(
            toolName: "mail_send",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "recipient/context approval"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Mail delivery mechanics"),
            ],
            reason: "Outbound email requires relationship context and explicit send approval."
        ),
        ToolSkillBinding(
            toolName: "mail_draft",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "relationship drafting"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Mail draft mechanics"),
            ],
            reason: "Email drafting belongs to relationship routing even though it is unsent."
        ),
        ToolSkillBinding(
            toolName: "mail_move",
            governingSkills: [
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Mail mailbox relocate mechanics"),
            ],
            reason: "Mailbox moves are local Mail organize actions under Mac tooling."
        ),
        ToolSkillBinding(
            toolName: "mail_archive",
            governingSkills: [
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Mail archive mechanics"),
            ],
            reason: "Archive is the preferred reversible Mail cleanup path."
        ),
        ToolSkillBinding(
            toolName: "mail_mark",
            governingSkills: [
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Mail status flag mechanics"),
            ],
            reason: "Read/flag toggles are reversible Mail state under Mac tooling."
        ),
        ToolSkillBinding(
            toolName: "mail_trash",
            governingSkills: [
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Mail trash mechanics"),
            ],
            reason: "Trash is a guarded Mail remove path; prefer archive for reversible cleanup."
        ),
        ToolSkillBinding(
            toolName: "calendar_create",
            governingSkills: [
                RoutingGovernanceSkill(slug: "time-keepr", role: "scheduling intent and availability"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Calendar write mechanics"),
            ],
            reason: "Calendar writes require time-domain routing before native EventKit mutation."
        ),
        ToolSkillBinding(
            toolName: "calendar_update",
            governingSkills: [
                RoutingGovernanceSkill(slug: "time-keepr", role: "reschedule/change intent"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Calendar write mechanics"),
            ],
            reason: "Calendar updates must be routed through time intent before mutation."
        ),
        ToolSkillBinding(
            toolName: "calendar_delete",
            governingSkills: [
                RoutingGovernanceSkill(slug: "time-keepr", role: "calendar consequence review"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Calendar delete mechanics"),
            ],
            reason: "Calendar deletion is destructive and must preserve time-domain review."
        ),
        ToolSkillBinding(
            toolName: "reminders_create",
            governingSkills: [
                RoutingGovernanceSkill(slug: "time-keepr", role: "do-this-later capture"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Reminders write mechanics"),
            ],
            reason: "Reminder creation is a time/action commitment and must be routed as such."
        ),
        ToolSkillBinding(
            toolName: "reminders_update",
            governingSkills: [
                RoutingGovernanceSkill(slug: "time-keepr", role: "deadline/action adjustment"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Reminders write mechanics"),
            ],
            reason: "Reminder updates alter commitments and need time-domain routing."
        ),
        ToolSkillBinding(
            toolName: "reminders_delete",
            governingSkills: [
                RoutingGovernanceSkill(slug: "time-keepr", role: "reminder consequence review"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Reminders delete mechanics"),
            ],
            reason: "Reminder deletion is destructive and must preserve time-domain review."
        ),
        ToolSkillBinding(
            toolName: "contacts_search",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "identity resolution"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Contacts read mechanics"),
            ],
            reason: "Contact lookup anchors relationship routing and recent-contact safeguards."
        ),
        ToolSkillBinding(
            toolName: "contacts_resolve_handle",
            governingSkills: [
                RoutingGovernanceSkill(slug: "people-keepr", role: "recipient identity verification"),
                RoutingGovernanceSkill(slug: "mac-keepr", role: "Contacts read mechanics"),
            ],
            reason: "Handle resolution is identity-critical before messaging or relationship actions."
        ),
        ToolSkillBinding(
            toolName: "notion_page_create",
            governingSkills: [
                RoutingGovernanceSkill(slug: "notion-keepr", role: "workspace structure/content writes"),
            ],
            reason: "Notion page creation mutates workspace content and must follow Notion routing."
        ),
        ToolSkillBinding(
            toolName: "notion_page_update",
            governingSkills: [
                RoutingGovernanceSkill(slug: "notion-keepr", role: "page property mutation"),
            ],
            reason: "Notion page updates mutate workspace records and must follow Notion routing."
        ),
        ToolSkillBinding(
            toolName: "notion_page_edit",
            governingSkills: [
                RoutingGovernanceSkill(slug: "notion-keepr", role: "page body mutation"),
            ],
            reason: "Notion body edits mutate workspace content and must follow Notion routing."
        ),
        ToolSkillBinding(
            toolName: "notion_blocks_append",
            governingSkills: [
                RoutingGovernanceSkill(slug: "notion-keepr", role: "block-level content mutation"),
            ],
            reason: "Notion block appends mutate workspace content and must follow Notion routing."
        ),
        ToolSkillBinding(
            toolName: "manage_skill",
            governingSkills: [
                RoutingGovernanceSkill(slug: "skill-keepr", role: "skill registry governance"),
            ],
            reason: "Skill registry writes require SKILLS Keepr ownership."
        ),
    ]

    private static let byTool: [String: ToolSkillBinding] = Dictionary(
        uniqueKeysWithValues: bindings.map { ($0.toolName, $0) }
    )

    public static func binding(for toolName: String) -> ToolSkillBinding? {
        byTool[toolName]
    }

    public static func requiresManifestFetch(_ toolName: String) -> Bool {
        binding(for: toolName)?.requiresManifestFetch == true
    }

    public static func isManifestMarkerTool(_ toolName: String) -> Bool {
        manifestMarkerTools.contains(toolName)
    }

    public static var allScopeIDs: Set<String> {
        Set(bindings.map(\.scopeID))
    }

    public static func scopeID(for toolName: String) -> String? {
        binding(for: toolName)?.scopeID
    }

    public static func scopeIDs(governedBy authoritySlug: String) -> Set<String> {
        let normalized = normalizeAuthoritySlug(authoritySlug)
        return Set(bindings.compactMap { binding in
            binding.governingSkills.contains { normalizeAuthoritySlug($0.slug) == normalized }
                ? binding.scopeID
                : nil
        })
    }

    public static func normalizeAuthoritySlug(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let words = lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.joined(separator: "-")
    }

    public static func callSatisfiesManifestMarker(toolName: String, result: Value) -> Bool {
        guard isManifestMarkerTool(toolName) else { return false }
        if toolName == BridgeInitializeModule.toolName,
           case .object(let dict) = result,
           case .string(let finalState)? = dict["finalState"] {
            return finalState != StandingOrdersStore.InitializationState.incomplete.rawValue
        }
        if toolName == "skills_routing_list",
           case .object(let dict) = result,
           case .string(SkillRoutingSnapshotStatus.healthy.rawValue)? = dict["status"],
           case .int(let count)? = dict["count"] {
            return count > 0
        }
        if toolName == "fetch_skill", case .object(let dict) = result {
            return dict["error"] == nil && (dict["title"] != nil || dict["slug"] != nil || dict["content"] != nil)
        }
        return true
    }

    public static func governanceDescription(for toolName: String) -> String? {
        guard let binding = binding(for: toolName) else { return nil }
        return "Governance: governed by \(binding.governanceSummary). Manifest fetch required before dispatch."
    }

    public static func receipt() -> RoutingIntegrityReceipt {
        RoutingIntegrityReceipt(
            registryVersion: registryVersion,
            boundToolCount: bindings.count,
            manifestMarkerTools: manifestMarkerTools.sorted(),
            descriptionCharBudget: BridgeToolDescriptionRenderer.charBudget,
            warnings: bindings.isEmpty ? ["No server-side tool-skill bindings registered."] : []
        )
    }
}

public struct AmendmentMarker: Sendable, Equatable {
    public let identifier: String
    public let status: String
    public let effectiveDate: Date
    public let ageDays: Int
    public let sourceLine: Int

    public var isDueForCollapse: Bool {
        status.uppercased() == "ACTIVE" && ageDays >= AmendmentLifecycle.dueForCollapseDays
    }
}

public enum AmendmentLifecycle {
    public static let dueForCollapseDays = 30

    public static func scan(markdown: String, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> [AmendmentMarker] {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { idx, rawLine in
                parseLine(String(rawLine), sourceLine: idx + 1, now: now, calendar: calendar)
            }
    }

    public static func dueForCollapse(markdown: String, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> [AmendmentMarker] {
        scan(markdown: markdown, now: now, calendar: calendar)
            .filter(\.isDueForCollapse)
    }

    public static func jobTemplate() -> [String: Value] {
        [
            "id": .string("weekly-amendment-collapse-scan"),
            "name": .string("Weekly amendment collapse scan"),
            "schedule": .string("0 9 * * 1"),
            "description": .string("Scan standing-order and skill-page amendment markers for ACTIVE entries older than 30 days and flag them DUE_FOR_COLLAPSE."),
            "actions": .array([
                .object([
                    "tool": .string("standing_orders_list"),
                    "arguments": .object(["includeArchived": .bool(false)])
                ])
            ])
        ]
    }

    private static func parseLine(
        _ line: String,
        sourceLine: Int,
        now: Date,
        calendar: Calendar
    ) -> AmendmentMarker? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.localizedCaseInsensitiveContains("amendment") else { return nil }
        guard let date = firstDate(in: trimmed) else { return nil }

        let upper = trimmed.uppercased()
        let status: String
        if upper.contains("DUE_FOR_COLLAPSE") {
            status = "DUE_FOR_COLLAPSE"
        } else if upper.contains("SUPERSEDED") {
            status = "SUPERSEDED"
        } else if upper.contains("ACTIVE") {
            status = "ACTIVE"
        } else {
            status = "UNKNOWN"
        }

        let id = firstIdentifier(in: trimmed) ?? "line-\(sourceLine)"
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return AmendmentMarker(
            identifier: id,
            status: status,
            effectiveDate: date,
            ageDays: days,
            sourceLine: sourceLine
        )
    }

    private static func firstDate(in line: String) -> Date? {
        guard let range = line.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(line[range]))
    }

    private static func firstIdentifier(in line: String) -> String? {
        guard let range = line.range(of: #"\b[A-Z]{2,}-[A-Z0-9.-]+\b"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range])
    }
}

public struct IdentityPropagationScanResult: Sendable, Equatable {
    public let renameId: String
    public let unresolvedHits: Int
    public let completedScanCycles: Int

    public init(renameId: String, unresolvedHits: Int, completedScanCycles: Int) {
        self.renameId = renameId
        self.unresolvedHits = unresolvedHits
        self.completedScanCycles = completedScanCycles
    }
}

public enum IdentityPropagationContract {
    public enum CloseDecision: String, Sendable, Equatable {
        case canClose = "CAN_CLOSE"
        case blockedByImpactHits = "BLOCKED_BY_IMPACT_HITS"
        case escalateAfterRepeatedHits = "ESCALATE_AFTER_REPEATED_HITS"
    }

    public static let escalationScanCycleCount = 3

    public static func closeDecision(for result: IdentityPropagationScanResult) -> CloseDecision {
        guard result.unresolvedHits > 0 else { return .canClose }
        if result.completedScanCycles >= escalationScanCycleCount {
            return .escalateAfterRepeatedHits
        }
        return .blockedByImpactHits
    }
}
