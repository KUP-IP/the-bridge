// PacketRegistryContract.swift — canonical PACKETS contract and read-only validation.

import CryptoKit
import Foundation
import MCP

public enum PacketRegistryContract {
    public static let version = "packet-registry-v1"

    public struct Field: Sendable, Equatable {
        public let key: String
        public let notionName: String
        public let type: String
        public let requiredOptions: Set<String>
        /// Registry entity key whose data source must be the target of this relation.
        public let relationTargetEntity: String?

        public init(
            _ key: String,
            _ notionName: String,
            _ type: String,
            options: Set<String> = [],
            relationTargetEntity: String? = nil
        ) {
            self.key = key
            self.notionName = notionName
            self.type = type
            self.requiredOptions = options
            self.relationTargetEntity = relationTargetEntity
        }
    }

    /// One source of truth for the mission-bearing PACKETS surface. Controller-owned
    /// output/timestamp fields are deliberately not part of the mission contract.
    public static let fields: [Field] = [
        .init("name", "Packet Name", "title"),
        .init("title", "Packet Title", "rich_text"),
        .init("status", "Status", "status", options: ["Backlog", "QUEUE", "REVIEW", "BLOCKED", "FOCUS", "Done", "Decline"]),
        .init("objective", "Objective", "rich_text"),
        .init("sourceOfTruth", "Source of Truth", "rich_text"),
        .init("executionClass", "Execution Class", "select", options: ["AUTO", "REVIEW-FIRST", "MANUAL"]),
        .init("project", "PROJECT", "relation", relationTargetEntity: "project"),
        .init("skills", "SKILLS", "relation", relationTargetEntity: "skill"),
        .init("blockedBy", "Blocked by", "relation", relationTargetEntity: "packet"),
        .init("blocking", "Blocking", "relation", relationTargetEntity: "packet"),
        .init("missionRevision", "Mission Revision", "number"),
        .init("missionHash", "Mission Hash", "rich_text"),
    ]

    private static let legacySignature: Set<String> = [
        "packet name", "packet title", "objective", "source of truth",
        "packet output", "project", "skills",
    ]

    /// Recognize the historical PACKETS registration without relying on its human
    /// label. The live pre-A1 install uses key `session`, display name `Sessions`.
    /// A genuine Sessions entity is not aliased unless it carries the PACKETS
    /// property contract.
    public static func isPacketEntity(_ entity: RegistryEntity) -> Bool {
        if entity.key == "packet" { return true }
        guard entity.key == "session" else { return false }
        if entity.displayName.localizedCaseInsensitiveContains("packet") { return true }
        let names = Set(entity.properties.map { $0.notionName.lowercased() })
        return legacySignature.isSubset(of: names)
    }

    public static func canonicalized(_ entity: RegistryEntity) -> RegistryEntity {
        RegistryEntity(
            key: "packet",
            displayName: entity.displayName,
            dataSourceId: entity.dataSourceId,
            workspace: entity.workspace,
            properties: entity.properties,
            cacheTTLSeconds: entity.cacheTTLSeconds,
            hasBody: entity.hasBody)
    }

    /// Select the operative stored PACKETS binding deterministically. A fully
    /// bound candidate outranks an unbound compatibility remnant; otherwise the
    /// canonical key outranks legacy `session`. Duplicate candidates are still
    /// reported by preflight and are never silently treated as healthy.
    public static func preferredStoredEntity(in config: RegistryConfig) -> RegistryEntity? {
        let candidates = configuredPacketEntities(in: config)
        return candidates.first(where: { $0.key == "packet" && $0.isFullyBound })
            ?? candidates.first(where: { $0.isFullyBound })
            ?? candidates.first(where: { $0.key == "packet" })
            ?? candidates.last
    }

    public static func entity(from config: RegistryConfig) -> RegistryEntity? {
        preferredStoredEntity(in: config).map(canonicalized)
    }

    /// Resolve the actual persisted row addressed by a lifecycle operation.
    /// `session` is an alias only when the directly stored session row is itself
    /// PACKETS-shaped, or when no direct session row exists and packet is the
    /// only compatible identity. A genuine Sessions row always wins its own key.
    public static func storedEntity(
        forRequestedKey key: String,
        in config: RegistryConfig
    ) -> RegistryEntity? {
        if key == "packet" { return preferredStoredEntity(in: config) }
        if key == "session" {
            if let direct = config.entities.first(where: { $0.key == "session" }) {
                return direct
            }
            return preferredStoredEntity(in: config)
        }
        return config.entities.first(where: { $0.key == key })
    }

    /// Keys removed for a lifecycle delete. Removing packet semantics clears
    /// both canonical and legacy packet-shaped bindings so a stale alias cannot
    /// survive. A genuine Sessions row is never included.
    public static func removalKeys(
        forRequestedKey key: String,
        in config: RegistryConfig
    ) -> [String] {
        if key == "packet" {
            return Array(Set(configuredPacketEntities(in: config).map(\.key))).sorted()
        }
        if key == "session" {
            if let direct = config.entities.first(where: { $0.key == "session" }) {
                if isPacketEntity(direct) {
                    return Array(Set(configuredPacketEntities(in: config).map(\.key))).sorted()
                }
                return ["session"]
            }
            if preferredStoredEntity(in: config) != nil {
                return Array(Set(configuredPacketEntities(in: config).map(\.key))).sorted()
            }
        }
        return [key]
    }

    public static func configuredPacketEntities(in config: RegistryConfig) -> [RegistryEntity] {
        config.entities.filter(isPacketEntity)
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

    /// Pure evaluator. It performs no config persistence, binding, repair, cache
    /// eviction, or Notion mutation.
    public static func evaluate(config: RegistryConfig, schema: DataSourceSchema) -> [Defect] {
        let candidates = PacketRegistryContract.configuredPacketEntities(in: config)
        guard let entity = PacketRegistryContract.preferredStoredEntity(in: config).map(PacketRegistryContract.canonicalized) else {
            return [.init(code: "BINDING_MISMATCH", field: "packet", expected: "one bound PACKETS entity", actual: "unconfigured")]
        }

        var defects: [Defect] = []
        if candidates.count != 1 {
            defects.append(.init(code: "DUPLICATE_BINDING", field: "packet", expected: "one PACKETS binding", actual: String(candidates.count)))
        }
        if entity.dataSourceId.isEmpty {
            defects.append(.init(code: "BINDING_MISMATCH", field: "packet", expected: "bound data source", actual: "unbound"))
        }

        for required in PacketRegistryContract.fields {
            let configured = entity.properties.filter { $0.key == required.key }
            if configured.count > 1 {
                defects.append(.init(
                    code: "DUPLICATE_FIELD_BINDING", field: required.key,
                    expected: "one canonical property", actual: String(configured.count)))
                continue
            }
            guard let property = configured.first, property.isBound,
                  let propertyID = property.notionPropertyId else {
                defects.append(.init(code: "UNBOUND_FIELD", field: required.key, expected: required.notionName, actual: "unbound"))
                continue
            }

            guard let matched = schema.column(withID: propertyID) else {
                if let byExpectedName = schema.column(named: required.notionName) {
                    defects.append(.init(code: "BINDING_MISMATCH", field: required.key, expected: byExpectedName.id, actual: propertyID))
                } else {
                    defects.append(.init(code: "MISSING_FIELD", field: required.key, expected: required.notionName, actual: "missing"))
                }
                continue
            }

            if matched.name != required.notionName {
                defects.append(.init(code: "RENAMED_FIELD", field: required.key, expected: required.notionName, actual: matched.name))
            }
            if property.notionName != matched.name {
                defects.append(.init(code: "BINDING_MISMATCH", field: required.key, expected: matched.name, actual: property.notionName))
            }
            if matched.column.type != required.type || property.type != required.type {
                defects.append(.init(
                    code: "TYPE_MISMATCH", field: required.key, expected: required.type,
                    actual: "config=\(property.type), schema=\(matched.column.type)"))
            }
            if !required.requiredOptions.isSubset(of: Set(matched.column.options)) {
                defects.append(.init(
                    code: "REQUIRED_OPTION_MISMATCH", field: required.key,
                    expected: required.requiredOptions.sorted().joined(separator: ","),
                    actual: matched.column.options.sorted().joined(separator: ",")))
            }
            if let targetKey = required.relationTargetEntity {
                let expectedTarget: String?
                if targetKey == "packet" {
                    expectedTarget = entity.dataSourceId
                } else {
                    expectedTarget = config.entity(targetKey)?.dataSourceId
                }
                guard let expectedTarget, !expectedTarget.isEmpty else {
                    defects.append(.init(code: "RELATION_TARGET_UNRESOLVED", field: required.key, expected: targetKey, actual: "unconfigured"))
                    continue
                }
                if matched.column.relationDataSourceId != expectedTarget {
                    defects.append(.init(
                        code: "RELATION_TARGET_MISMATCH", field: required.key,
                        expected: expectedTarget, actual: matched.column.relationDataSourceId ?? "missing"))
                }
            }
        }
        return defects
    }

    public static func value(contractVersion: String?, config: RegistryConfig, schema: DataSourceSchema) -> Value {
        guard contractVersion == nil || contractVersion == PacketRegistryContract.version else {
            return .object([
                "result": .string("DRIFT"),
                "contractVersion": .string(contractVersion ?? ""),
                "defectCount": .int(1),
                "defects": .array([.object([
                    "code": .string("UNSUPPORTED_CONTRACT_VERSION"),
                    "field": .string("contractVersion"),
                    "expected": .string(PacketRegistryContract.version),
                    "actual": .string(contractVersion ?? ""),
                ])]),
            ])
        }
        let defects = evaluate(config: config, schema: schema)
        return .object([
            "result": .string(defects.isEmpty ? "PASS" : "DRIFT"),
            "contractVersion": .string(PacketRegistryContract.version),
            "canonicalEntity": .string("packet"),
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

public enum PacketMissionIntegrity {
    public enum Consistency: String, Sendable {
        case CONSISTENT
        case PROPERTY_BODY_CONFLICT
        case HASH_MISMATCH
        case MISSING_REVISION
    }

    public struct Preparation: Sendable, Equatable {
        public let revision: Int
        public let hash: String
        public let changed: Bool
    }

    public enum PreparationError: Error, LocalizedError, Equatable {
        case incompleteStoredMissionState

        public var errorDescription: String? {
            "stored mission revision and hash must both be present or both be absent"
        }
    }

    private struct Fence: Equatable {
        let marker: Character
        let length: Int
    }

    private static func fenceOpening(_ line: String) -> Fence? {
        let prefix = line.prefix { $0 == " " }
        guard prefix.count <= 3 else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let run = rest.prefix { $0 == marker }.count
        guard run >= 3 else { return nil }
        return Fence(marker: marker, length: run)
    }

    private static func isFenceClosing(_ line: String, fence: Fence) -> Bool {
        let prefix = line.prefix { $0 == " " }
        guard prefix.count <= 3 else { return false }
        let rest = line.dropFirst(prefix.count)
        let run = rest.prefix { $0 == fence.marker }.count
        guard run >= fence.length else { return false }
        return rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(count) else { return nil }
        let remainder = trimmed.dropFirst(count)
        guard remainder.first?.isWhitespace == true else { return nil }
        return (count, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func withoutTrailingWhitespace(_ line: String) -> String {
        line.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
    }

    public static func authoredBody(_ body: String) -> String {
        let normalizedNewlines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var output: [String] = []
        var activeFence: Fence?
        for raw in normalizedNewlines.components(separatedBy: "\n") {
            if let fence = activeFence {
                output.append(raw)
                if isFenceClosing(raw, fence: fence) { activeFence = nil }
                continue
            }
            if let opening = fenceOpening(raw) {
                activeFence = opening
                output.append(raw)
                continue
            }
            if let h = heading(raw), h.level == 2,
               h.title.compare("Packet Runner Output", options: .caseInsensitive) == .orderedSame {
                break
            }
            var line = withoutTrailingWhitespace(raw)
            if let h = heading(line) {
                line = String(repeating: "#", count: h.level) + " " + h.title
            }
            line = line.replacingOccurrences(
                of: "^(\\s*[-*+]\\s+)\\[[Xx]\\]", with: "$1[x]",
                options: .regularExpression)
            if line.isEmpty, output.last == "" { continue }
            output.append(line)
        }
        while output.first == "" { output.removeFirst() }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n")
    }

    public static func normalizeScalar(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func canonical(
        title packetName: String,
        properties: [String: String],
        relations: [String: [String]],
        body: String
    ) -> String {
        let missionProperties: [String: String] = [
            "packetTitle": normalizeScalar(properties["title"] ?? ""),
            "objective": normalizeScalar(properties["objective"] ?? ""),
            "sourceOfTruth": normalizeScalar(properties["sourceOfTruth"] ?? ""),
            "executionClass": normalizeScalar(properties["executionClass"] ?? "").uppercased(),
        ]
        let missionRelations = ["project", "skills", "blockedBy", "blocking"].reduce(into: [String: [String]]()) { result, key in
            result[key] = Array(Set((relations[key] ?? []).map(normalizedIdentifier))).sorted()
        }
        let object: [String: Any] = [
            "packetName": normalizeScalar(packetName),
            "properties": missionProperties,
            "relations": missionRelations,
            "body": authoredBody(body),
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    public static func hash(canonical: String) -> String {
        SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func prepare(
        storedRevision: Int?, storedHash: String?, canonical: String
    ) throws -> Preparation {
        let nextHash = hash(canonical: canonical)
        if storedRevision == nil, storedHash == nil || storedHash?.isEmpty == true {
            return .init(revision: 1, hash: nextHash, changed: true)
        }
        guard let revision = storedRevision, revision > 0,
              let storedHash, !storedHash.isEmpty else {
            throw PreparationError.incompleteStoredMissionState
        }
        let changed = storedHash.lowercased() != nextHash
        return .init(revision: changed ? revision + 1 : revision, hash: nextHash, changed: changed)
    }

    /// Only explicitly duplicated body fields participate in contradiction
    /// detection. General Outcome/Scope prose is authored mission content, not a
    /// duplicate of a property and therefore cannot create a false conflict.
    public static func bodyMissionFields(_ body: String) -> [String: String] {
        let lines = authoredBody(body).components(separatedBy: "\n")
        let recognized: [String: String] = [
            "packet title": "title",
            "objective": "objective",
            "source of truth": "sourceOfTruth",
            "execution class": "executionClass",
        ]
        var result: [String: String] = [:]
        var currentKey: String?
        var currentLevel = 0
        var buffer: [String] = []
        var activeFence: Fence?

        func flush() {
            guard let currentKey else { return }
            result[currentKey] = normalizeScalar(buffer.joined(separator: "\n"))
        }

        for line in lines {
            if let fence = activeFence {
                if currentKey != nil { buffer.append(line) }
                if isFenceClosing(line, fence: fence) { activeFence = nil }
                continue
            }
            if let opening = fenceOpening(line) {
                activeFence = opening
                if currentKey != nil { buffer.append(line) }
                continue
            }
            if let h = heading(line) {
                if currentKey != nil, h.level <= currentLevel {
                    flush()
                    currentKey = nil
                    buffer = []
                }
                if h.level == 2, let key = recognized[h.title.lowercased()] {
                    flush()
                    currentKey = key
                    currentLevel = h.level
                    buffer = []
                }
                continue
            }
            if currentKey != nil { buffer.append(line) }
        }
        flush()
        return result
    }

    private static func executionClassToken(_ value: String) -> String {
        let normalized = normalizeScalar(value).uppercased()
        return normalized.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.description
    }

    public static func conflictFields(properties: [String: String], body: String) -> [String] {
        let bodyFields = bodyMissionFields(body)
        return ["title", "objective", "sourceOfTruth", "executionClass"].filter { key in
            guard let bodyValue = bodyFields[key], !bodyValue.isEmpty,
                  let propertyValue = properties[key], !propertyValue.isEmpty else { return false }
            if key == "executionClass" {
                return executionClassToken(propertyValue) != executionClassToken(bodyValue)
            }
            return normalizeScalar(propertyValue) != normalizeScalar(bodyValue)
        }
    }

    public static func classify(
        storedRevision: Int?,
        storedHash: String?,
        canonical: String,
        properties: [String: String],
        body: String,
        evidenceComplete: Bool = true
    ) -> Consistency {
        guard let revision = storedRevision, revision > 0 else { return .MISSING_REVISION }
        if !conflictFields(properties: properties, body: body).isEmpty { return .PROPERTY_BODY_CONFLICT }
        guard evidenceComplete,
              storedHash?.lowercased() == hash(canonical: canonical) else { return .HASH_MISMATCH }
        return .CONSISTENT
    }
}
