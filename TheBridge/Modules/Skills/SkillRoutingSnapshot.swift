// SkillRoutingSnapshot.swift — authoritative Runtime Exposure routing projection

import CryptoKit
import Foundation
import MCP

public enum SkillRoutingSnapshotStatus: String, Codable, Sendable, Equatable {
    case healthy
    case degraded
    case empty
    case missing
}

public enum SkillRoutingSnapshotSource: String, Codable, Sendable, Equatable {
    case runtimeExposureGeneration = "runtime_exposure_generation"
    case legacyProjection = "legacy_projection"
    case runtimeExposurePointer = "runtime_exposure_pointer"
}

public struct SkillRoutingSnapshotMetadata: Codable, Sendable, Equatable {
    public let status: SkillRoutingSnapshotStatus
    public let source: SkillRoutingSnapshotSource
    public let snapshotID: String
    public let count: Int
    public let reason: String

    public init(status: SkillRoutingSnapshotStatus, source: SkillRoutingSnapshotSource,
                snapshotID: String, count: Int, reason: String) {
        self.status = status
        self.source = source
        self.snapshotID = snapshotID
        self.count = count
        self.reason = reason
    }
}

public struct SkillRoutingSnapshot: Sendable {
    public let metadata: SkillRoutingSnapshotMetadata
    public let skills: [Value]

    public init(metadata: SkillRoutingSnapshotMetadata, skills: [Value]) {
        self.metadata = metadata
        self.skills = skills
    }

    public var value: Value {
        .object([
            "status": .string(metadata.status.rawValue),
            "source": .string(metadata.source.rawValue),
            "snapshot": .string(metadata.snapshotID),
            "count": .int(metadata.count),
            "reason": .string(metadata.reason),
            "skills": .array(skills),
        ])
    }
}

extension SkillsModule {
    /// The only production projection used by the routing tool, handshake
    /// instructions, resources, and bridge_initialize evidence.
    public static func routingSnapshot(now: Date = Date()) async -> SkillRoutingSnapshot {
        let authority = await SkillRuntimeGenerationStore.shared.routingAuthority()
        switch authority {
        case .active(let gate):
            let items = await mergedRoutingSkills(exposureGate: gate)
            return runtimeRoutingSnapshot(items: items, gate: gate, now: now)
        case .corrupt(let pointerID):
            return .init(
                metadata: .init(
                    status: .missing,
                    source: .runtimeExposurePointer,
                    snapshotID: pointerID,
                    count: 0,
                    reason: "active_runtime_exposure_generation_is_missing_or_corrupt"
                ),
                skills: []
            )
        case .legacy:
            return await legacyRoutingSnapshot()
        }
    }

    /// Synchronous compatibility projection for callers that cannot suspend.
    /// Production handshakes and resources use `routingSnapshot()` instead.
    public static func legacyRoutingSnapshotSync() -> SkillRoutingSnapshot {
        let items = legacyNotionRoutingRows()
        return legacySnapshot(items: items)
    }

    @_spi(Testing)
    public static func runtimeRoutingSnapshot(
        items: [Value],
        gate: SkillRuntimeExposureGate,
        now: Date
    ) -> SkillRoutingSnapshot {
        let degraded = gate.isDegraded(now: now)
        let status: SkillRoutingSnapshotStatus = degraded ? .degraded : (items.isEmpty ? .empty : .healthy)
        let reason: String
        if degraded {
            reason = "runtime_exposure_freshness_expired"
        } else if items.isEmpty {
            reason = "verified_runtime_exposure_contains_no_routing_skills"
        } else if let renewed = gate.freshnessRenewedAt, renewed > gate.generation.compiledAt {
            // A later unchanged shadow is the only path that moves the lease
            // past compiledAt. Publish writes a lease at compiledAt (#279)
            // and must keep the generation-verified reason so LIVE read-back
            // does not look like a shadow renew.
            reason = "verified_unchanged_shadow_renewed_freshness"
        } else {
            reason = "verified_active_runtime_exposure_generation"
        }
        return .init(
            metadata: .init(
                status: status,
                source: .runtimeExposureGeneration,
                snapshotID: gate.generation.generationID,
                count: degraded ? 0 : items.count,
                reason: reason
            ),
            skills: degraded ? [] : items
        )
    }

    public static func renderRoutingInstructions(snapshot: SkillRoutingSnapshot) -> String {
        let m = snapshot.metadata
        let evidence = "Routing snapshot: status=\(m.status.rawValue) source=\(m.source.rawValue) snapshot=\(m.snapshotID) count=\(m.count) reason=\(m.reason)"
        guard !snapshot.skills.isEmpty else {
            return """
            The Bridge MCP server. No routing skills are currently available.
            \(evidence)
            Call skills_routing_list to refresh the same authoritative snapshot.

            \(dispatchContract)
            """
        }
        let lines = snapshot.skills.compactMap(routingInstructionLine)
        return """
        The Bridge MCP server. \(snapshot.skills.count) routing skill(s) available:
        \(lines.joined(separator: "\n"))
        \(evidence)
        Use fetch_skill to load full skill content by name. Call skills_routing_list to refresh this same snapshot.

        \(dispatchContract)
        """
    }

    private static func legacyRoutingSnapshot() async -> SkillRoutingSnapshot {
        let items = await mergedRoutingSkills(exposureGate: nil)
        return legacySnapshot(items: items)
    }

    private static func legacySnapshot(items: [Value]) -> SkillRoutingSnapshot {
        let count = items.count
        return .init(
            metadata: .init(
                status: count == 0 ? .empty : .healthy,
                source: .legacyProjection,
                snapshotID: legacySnapshotID(items),
                count: count,
                reason: count == 0
                    ? "legacy_projection_contains_no_routing_skills"
                    : "runtime_exposure_not_activated_legacy_projection_in_use"
            ),
            skills: items
        )
    }

    private static func legacyNotionRoutingRows() -> [Value] {
        readAllSkills().filter { skill in
            guard skill.enabled, skill.routingDiscoverable else { return false }
            switch skill.source {
            case .notion(let pageID):
                return NotionPageRef.isValidStoredPageId(pageID.trimmingCharacters(in: .whitespacesAndNewlines))
            case .file:
                return true
            }
        }.map { .object(skillRowFields($0).merging(["source": .string($0.source.isFile ? "file" : "notion")]) { old, _ in old }) }
            .sorted { routingName($0).localizedCaseInsensitiveCompare(routingName($1)) == .orderedAscending }
    }

    private static func routingInstructionLine(_ value: Value) -> String? {
        guard case .object(let row) = value,
              case .string(let name)? = row["name"] else { return nil }
        var line = name
        if case .string(let summary)? = row["summary"], !summary.isEmpty { line += " — \(summary)" }
        if case .array(let triggers)? = row["triggerPhrases"] {
            let values = triggers.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
            if !values.isEmpty { line += " [triggers: \(values.joined(separator: ", "))]" }
        }
        if case .array(let antiTriggers)? = row["antiTriggerPhrases"] {
            let values = antiTriggers.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
            if !values.isEmpty { line += " [avoid: \(values.joined(separator: ", "))]" }
        }
        return line
    }

    private static func routingName(_ value: Value) -> String {
        guard case .object(let row) = value, case .string(let name)? = row["name"] else { return "" }
        return name
    }

    private static func legacySnapshotID(_ items: [Value]) -> String {
        let identity = items.map { value -> String in
            guard case .object(let row) = value else { return "" }
            let name = row["name"].flatMap { if case .string(let v) = $0 { return v } else { return nil } } ?? ""
            let source = row["source"].flatMap { if case .string(let v) = $0 { return v } else { return nil } } ?? ""
            return "\(name.lowercased())|\(source)"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "legacy-\(String(digest.prefix(16)))"
    }
}
