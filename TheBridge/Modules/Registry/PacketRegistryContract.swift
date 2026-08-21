// PacketRegistryContract.swift — canonical PACKETS identity + read-only schema preflight.

import Foundation
import MCP

/// The single identity and execution-schema contract for the PACKETS data source.
///
/// This first slice is deliberately read-only toward Notion. It recognizes the
/// historical `session` spelling, but all resolved PACKETS entities use key
/// `packet`, so readers and caches cannot fork by alias.
public enum PacketRegistryContract {
    public static let version = "packet-registry-preflight-v1"

    public enum Classification: String, Sendable, Equatable {
        case mission
        case executionControl
        case controllerState
        case controllerOutput
        case systemDerived
    }

    public struct Field: Sendable, Equatable {
        public let key: String
        public let notionName: String
        public let type: String
        public let classification: Classification
        public let registryBindingRequired: Bool
        public let expectedOptions: Set<String>
        /// Registry entity key whose data source must be the relation target.
        public let relationTargetEntity: String?

        public init(
            _ key: String,
            _ notionName: String,
            _ type: String,
            _ classification: Classification,
            registryBindingRequired: Bool = true,
            options: Set<String> = [],
            relationTargetEntity: String? = nil
        ) {
            self.key = key
            self.notionName = notionName
            self.type = type
            self.classification = classification
            self.registryBindingRequired = registryBindingRequired
            self.expectedOptions = options
            self.relationTargetEntity = relationTargetEntity
        }
    }

    /// Complete schema observed on the governed PACKETS data source. Every live
    /// column must be classified here; additions fail preflight as unclassified
    /// until their ownership and execution semantics are deliberately assigned.
    public static let fields: [Field] = [
        .init("name", "Packet Name", "title", .mission),
        .init("title", "Packet Title", "rich_text", .mission),
        .init("status", "Status", "status", .executionControl,
              options: ["Backlog", "QUEUE", "REVIEW", "BLOCKED", "FOCUS", "Done", "Decline"]),
        .init("objective", "Objective", "rich_text", .mission),
        .init("executionClass", "Execution Class", "select", .executionControl,
              options: ["AUTO", "REVIEW-FIRST", "MANUAL"]),
        .init("priority", "Priority", "number", .executionControl),
        .init("project", "PROJECT", "relation", .mission, relationTargetEntity: "project"),
        .init("skills", "SKILLS", "relation", .mission, relationTargetEntity: "skill"),
        .init("blockedBy", "Blocked by", "relation", .executionControl, relationTargetEntity: "packet"),

        .init("mirrorStatus", "Mirror Status", "status", .controllerState,
              options: ["Snapshot Pending", "Synced"]),
        .init("sourceOfTruth", "Source of Truth", "rich_text", .controllerState),
        .init("agentType", "Agent Type", "select", .controllerState,
              options: ["Notion AI", "Cursor", "Claude Code", "Hybrid", "bridge-keepr", "Orchestrator", "app-dev", "executor"]),
        .init("model", "Model", "select", .controllerState,
              options: ["Fable", "Sol", "Grok", "Opus", "Composer", "Terra", "Sonnet", "Gemini", "Luna", "Kimi"]),
        .init("complexity", "Complexity", "number", .controllerState),
        .init("contextSize", "Context Size", "number", .controllerState),
        .init("duration", "Duration", "number", .controllerOutput),
        .init("tokens", "Tokens", "number", .controllerOutput),
        .init("output", "Packet Output", "rich_text", .controllerOutput),
        .init("telemetry", "AI LOGS", "relation", .controllerOutput, relationTargetEntity: "telemetry"),
        .init("event", "EVENT", "relation", .controllerState, relationTargetEntity: "schedule"),
        .init("blocking", "Blocking", "relation", .systemDerived, relationTargetEntity: "packet"),
        .init("lifecycleCheckedAt", "Lifecycle Checked At", "date", .controllerState),
        .init("missionRevision", "Mission Revision", "number", .controllerState),
        .init("missionHash", "Mission Hash", "rich_text", .controllerState),

        .init("client", "CLIENT", "relation", .controllerState,
              registryBindingRequired: false, relationTargetEntity: "client"),
        .init("cleanupEligibleAt", "Cleanup Eligible At", "date", .controllerState,
              registryBindingRequired: false),
        .init("created", "Created", "created_time", .systemDerived,
              registryBindingRequired: false),
        .init("executeDate", "Execute Date", "date", .controllerState,
              registryBindingRequired: false),
        .init("filter", "Filter", "formula", .systemDerived,
              registryBindingRequired: false),
        .init("lastExecutedAt", "Last Executed At", "date", .controllerOutput,
              registryBindingRequired: false),
        .init("lastExecutionURL", "Last Execution URL", "url", .controllerOutput,
              registryBindingRequired: false),
        .init("lastSnapshotAt", "Last Snapshot At", "date", .controllerState,
              registryBindingRequired: false),
        .init("lastEditedTime", "Last edited time", "last_edited_time", .systemDerived,
              registryBindingRequired: false),
        .init("packetID", "PKT-ID", "unique_id", .systemDerived,
              registryBindingRequired: false),
    ]

    private static let legacySignature: Set<String> = [
        "packet name", "packet title", "objective", "packet output", "project", "skills",
    ]

    public static func isPacketEntity(_ entity: RegistryEntity) -> Bool {
        if entity.key == "packet" { return true }
        guard entity.key == "session" else { return false }
        if entity.displayName.localizedCaseInsensitiveContains("packet") { return true }
        let names = Set(entity.properties.map { $0.notionName.lowercased() })
        return legacySignature.isSubset(of: names)
    }

    public static func configuredEntities(in config: RegistryConfig) -> [RegistryEntity] {
        config.entities.filter(isPacketEntity)
    }

    public static func canonicalized(_ entity: RegistryEntity) -> RegistryEntity {
        RegistryEntity(
            key: "packet",
            displayName: entity.displayName,
            dataSourceId: entity.dataSourceId,
            workspace: entity.workspace,
            properties: entity.properties,
            cacheTTLSeconds: entity.cacheTTLSeconds,
            hasBody: entity.hasBody
        )
    }

    /// Deterministic transition read: canonical storage wins; a legacy PACKETS
    /// row is accepted only when no canonical row exists. Preflight still marks
    /// every multiple-candidate state as `DUPLICATE_BINDING`.
    public static func preferredStoredEntity(in config: RegistryConfig) -> RegistryEntity? {
        let candidates = configuredEntities(in: config)
        return candidates.first(where: { $0.key == "packet" }) ?? candidates.first
    }

    /// Persisted keys addressed by a removal request. A genuine Sessions entity
    /// remains independent; a PACKETS alias clears every PACKETS-shaped remnant.
    public static func removalKeys(forRequestedKey key: String, in config: RegistryConfig) -> Set<String> {
        if key == "packet" {
            return Set(configuredEntities(in: config).map(\.key))
        }
        if key == "session" {
            if let direct = config.entities.first(where: { $0.key == "session" }),
               !isPacketEntity(direct) {
                return ["session"]
            }
            if preferredStoredEntity(in: config) != nil {
                return Set(configuredEntities(in: config).map(\.key))
            }
        }
        return [key]
    }
}

public enum PacketRegistryPreflight {
    public struct Defect: Sendable, Equatable {
        public let code: String
        public let field: String
        public let expected: String
        public let actual: String

        public init(code: String, field: String, expected: String, actual: String) {
            self.code = code
            self.field = field
            self.expected = expected
            self.actual = actual
        }
    }

    public struct Report: Sendable, Equatable {
        public let contractVersion: String
        public let canonicalEntity: String
        public let bindingCandidates: [String]
        public let classifiedColumnCount: Int
        public let liveColumnCount: Int
        public let defects: [Defect]

        public var passes: Bool { defects.isEmpty }

        public var value: Value {
            .object([
                "result": .string(passes ? "PASS" : "DRIFT"),
                "contractVersion": .string(contractVersion),
                "canonicalEntity": .string(canonicalEntity),
                "bindingCandidates": .array(bindingCandidates.map(Value.string)),
                "classifiedColumnCount": .int(classifiedColumnCount),
                "liveColumnCount": .int(liveColumnCount),
                "defectCount": .int(defects.count),
                "defects": .array(defects.map { defect in
                    .object([
                        "code": .string(defect.code),
                        "field": .string(defect.field),
                        "expected": .string(defect.expected),
                        "actual": .string(defect.actual),
                    ])
                }),
            ])
        }
    }

    /// Pure evaluator: no config persistence, binding, cache mutation, or
    /// Notion write. The caller supplies one already-read live schema snapshot.
    public static func evaluate(config: RegistryConfig, schema: DataSourceSchema) -> Report {
        let candidates = PacketRegistryContract.configuredEntities(in: config)
        var defects: [Defect] = []

        guard let stored = PacketRegistryContract.preferredStoredEntity(in: config) else {
            return Report(
                contractVersion: PacketRegistryContract.version,
                canonicalEntity: "packet",
                bindingCandidates: [],
                classifiedColumnCount: PacketRegistryContract.fields.count,
                liveColumnCount: schema.columnsByName.count,
                defects: [.init(code: "BINDING_MISSING", field: "packet", expected: "one canonical PACKETS binding", actual: "none")]
            )
        }
        let entity = PacketRegistryContract.canonicalized(stored)

        if candidates.count != 1 {
            let identities = candidates.map { "\($0.key):\($0.dataSourceId)" }.sorted()
            defects.append(.init(
                code: "DUPLICATE_BINDING", field: "packet",
                expected: "one persisted packet binding", actual: identities.joined(separator: ",")
            ))
        } else if stored.key != "packet" {
            defects.append(.init(
                code: "LEGACY_BINDING_ALIAS", field: "packet",
                expected: "persisted key packet", actual: stored.key
            ))
        }
        if entity.dataSourceId.isEmpty {
            defects.append(.init(code: "BINDING_MISSING", field: "packet", expected: "nonempty data source id", actual: "empty"))
        }

        let contractNames = Set(PacketRegistryContract.fields.map(\.notionName))
        for liveName in schema.names where !contractNames.contains(liveName) {
            defects.append(.init(
                code: "UNCLASSIFIED_COLUMN", field: liveName,
                expected: "classified PACKETS property", actual: schema.column(named: liveName)?.type ?? "unknown"
            ))
        }

        let contractKeys = Set(PacketRegistryContract.fields.map(\.key))
        for property in entity.properties where !contractKeys.contains(property.key) {
            defects.append(.init(
                code: "UNCLASSIFIED_BINDING", field: property.key,
                expected: "classified PACKETS binding", actual: property.notionName
            ))
        }

        for field in PacketRegistryContract.fields {
            let configuredForField = entity.properties.filter { $0.key == field.key }
            guard let live = schema.column(named: field.notionName) else {
                if let boundID = configuredForField.first?.notionPropertyId,
                   let renamed = schema.column(withID: boundID) {
                    defects.append(.init(
                        code: "RENAMED_COLUMN", field: field.key,
                        expected: field.notionName, actual: renamed.name
                    ))
                    continue
                }
                defects.append(.init(
                    code: "MISSING_COLUMN", field: field.key,
                    expected: "\(field.notionName):\(field.type)", actual: "missing"
                ))
                continue
            }
            if live.type != field.type {
                defects.append(.init(
                    code: "TYPE_MISMATCH", field: field.key,
                    expected: field.type, actual: live.type
                ))
            }
            if !field.expectedOptions.isEmpty, Set(live.options) != field.expectedOptions {
                defects.append(.init(
                    code: "OPTION_MISMATCH", field: field.key,
                    expected: field.expectedOptions.sorted().joined(separator: ","),
                    actual: live.options.sorted().joined(separator: ",")
                ))
            }
            if let targetKey = field.relationTargetEntity {
                let expectedTarget = targetKey == "packet"
                    ? entity.dataSourceId
                    : config.entity(targetKey)?.dataSourceId
                guard let expectedTarget, !expectedTarget.isEmpty else {
                    defects.append(.init(
                        code: "RELATION_TARGET_UNRESOLVED", field: field.key,
                        expected: targetKey, actual: "unconfigured"
                    ))
                    continue
                }
                if !identifiersEqual(live.relationDataSourceId, expectedTarget) {
                    defects.append(.init(
                        code: "RELATION_TARGET_MISMATCH", field: field.key,
                        expected: expectedTarget, actual: live.relationDataSourceId ?? "missing"
                    ))
                }
            }

            guard field.registryBindingRequired else { continue }
            let configured = configuredForField
            if configured.count > 1 {
                defects.append(.init(
                    code: "DUPLICATE_FIELD_BINDING", field: field.key,
                    expected: "one registry property", actual: String(configured.count)
                ))
                continue
            }
            guard let property = configured.first else {
                defects.append(.init(
                    code: "UNBOUND_FIELD", field: field.key,
                    expected: field.notionName, actual: "not configured"
                ))
                continue
            }
            if property.notionName != field.notionName || property.type != field.type {
                defects.append(.init(
                    code: "BINDING_CONTRACT_MISMATCH", field: field.key,
                    expected: "\(field.notionName):\(field.type)",
                    actual: "\(property.notionName):\(property.type)"
                ))
            }
            guard let propertyID = property.notionPropertyId, !propertyID.isEmpty else {
                defects.append(.init(
                    code: "UNBOUND_FIELD", field: field.key,
                    expected: live.id, actual: "unbound"
                ))
                continue
            }
            if propertyID != live.id {
                defects.append(.init(
                    code: "BINDING_ID_MISMATCH", field: field.key,
                    expected: live.id, actual: propertyID
                ))
            }
        }

        return Report(
            contractVersion: PacketRegistryContract.version,
            canonicalEntity: "packet",
            bindingCandidates: candidates.map(\.key).sorted(),
            classifiedColumnCount: PacketRegistryContract.fields.count,
            liveColumnCount: schema.columnsByName.count,
            defects: defects.sorted {
                ($0.code, $0.field, $0.actual) < ($1.code, $1.field, $1.actual)
            }
        )
    }

    private static func identifiersEqual(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let left = lhs.lowercased().replacingOccurrences(of: "-", with: "")
        let right = rhs.lowercased().replacingOccurrences(of: "-", with: "")
        return left == right
    }
}
