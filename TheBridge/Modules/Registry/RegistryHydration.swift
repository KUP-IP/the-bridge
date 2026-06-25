// RegistryHydration.swift — Data-Source Registry · Packet Runner (FR-1 / §8.3)
// TheBridge · Modules · Registry
//
// The `packet-registry-v1` hydration envelope (PRD FR-1, §8.3): a packet's
// primary (non-relation) properties + page body + curated ONE-HOP relation
// projections + provenance + unresolved-relation warnings.
//
// ADDITIVE to the flat `registry_get` path — a different, nested contract the
// Packet Runner controller and executor revalidation (§8.4 `registrySchemaVersion`)
// match on. Hydration stops after one relation hop and never loads a relation's
// BODY (deeper reads stay explicit via `registry_possess` — FR-1). A missing or
// inaccessible relation target is OMITTED and a warning appended, never guessed
// (FR-4, §8.3).

import Foundation
import MCP

/// The fixed PACKETS relation → §8.3 envelope-slot mapping plus the compact
/// per-target projection. This is the only packet-shaped knowledge in the
/// hydration path; kept small + data-driven so the generic-CRUD ethos holds
/// (CLAUDE.md: generic CRUD, not per-entity tools).
public enum PacketRelationProjection {
    /// The five §8.3 relation slots, in envelope order. Empty arrays are valid.
    public static let slots = ["project", "skills", "blockedBy", "blocking", "event"]

    /// Canonical entity-property key → envelope slot. The PACKETS entity's
    /// property map declares these canonical keys with `role:.relation`; a
    /// relation property whose key is absent here is simply not projected.
    public static let slotForKey: [String: String] = [
        "project": "project",
        "skills": "skills",
        "blockedBy": "blockedBy",
        "blocking": "blocking",
        "event": "event",
    ]

    /// Compact one-hop projection of a related target page (§8.3). Reads the
    /// title-typed cell (labelled `name` for the `skills` slot, else `title`),
    /// the status cell (by the fixed Notion name `Status`, else any status-typed
    /// cell), and — for `skills` only — a `Version` cell. Anything unresolved is
    /// OMITTED (never guessed). Never reads the target's own relations or body.
    public static func projectTarget(_ row: NotionRow, slot: String) -> Value {
        var out: [String: Value] = ["id": .string(row.id)]
        if let titleCell = row.cells.values.first(where: { $0.type == "title" }),
           case .string(let s) = titleCell.value, !s.isEmpty {
            out[slot == "skills" ? "name" : "title"] = .string(s)
        }
        if let statusCell = row.cells["Status"] ?? row.cells.values.first(where: { $0.type == "status" }),
           case .string(let s) = statusCell.value, !s.isEmpty {
            out["status"] = .string(s)
        }
        if slot == "skills", let vCell = row.cells["Version"] ?? row.cells["version"],
           case .string(let s) = vCell.value, !s.isEmpty {
            out["version"] = .string(s)
        }
        return .object(out)
    }
}

/// The typed `packet-registry-v1` envelope (§8.3). `asValue()` renders the exact
/// nested MCP shape the Packet Runner controller consumes.
public struct PacketRegistryEnvelope: Sendable {
    public static let schemaVersion = "packet-registry-v1"

    public struct Primary: Sendable {
        public let id: String
        public let title: String
        public let lastEditedTime: String
        public let properties: Value   // .object — non-relation projected props
        public init(id: String, title: String, lastEditedTime: String, properties: Value) {
            self.id = id; self.title = title; self.lastEditedTime = lastEditedTime; self.properties = properties
        }
    }

    public let primary: Primary
    public let body: String
    /// Keyed by §8.3 slot; absent slots render as empty arrays in `asValue()`.
    public let relations: [String: [Value]]
    public let fetchedAt: String
    public let warnings: [String]

    public init(primary: Primary, body: String, relations: [String: [Value]], fetchedAt: String, warnings: [String]) {
        self.primary = primary; self.body = body; self.relations = relations
        self.fetchedAt = fetchedAt; self.warnings = warnings
    }

    public func asValue() -> Value {
        var rel: [String: Value] = [:]
        for slot in PacketRelationProjection.slots { rel[slot] = .array(relations[slot] ?? []) }
        return .object([
            "schemaVersion": .string(Self.schemaVersion),
            "primary": .object([
                "id": .string(primary.id),
                "title": .string(primary.title),
                "lastEditedTime": .string(primary.lastEditedTime),
                "properties": primary.properties,
            ]),
            "body": .string(body),
            "relations": .object(rel),
            "provenance": .object(["fetchedAt": .string(fetchedAt), "source": .string("notion")]),
            "warnings": .array(warnings.map { .string($0) }),
        ])
    }

    /// Reformat a 32-hex dashless Notion id into canonical dashed UUID form
    /// (8-4-4-4-12) for `primary.id` (§8.4 `packetId` is the canonical page id).
    /// Non-32-hex input is returned unchanged.
    public static func dashedId(_ id: String) -> String {
        let h = id.replacingOccurrences(of: "-", with: "")
        guard h.count == 32, h.allSatisfy({ $0.isHexDigit }) else { return id }
        let c = Array(h)
        func s(_ a: Int, _ b: Int) -> String { String(c[a..<b]) }
        return "\(s(0,8))-\(s(8,12))-\(s(12,16))-\(s(16,20))-\(s(20,32))"
    }
}
