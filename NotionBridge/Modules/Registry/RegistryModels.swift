// RegistryModels.swift — Data-Source Registry (vertical slice v0)
// NotionBridge · Modules · Registry
//
// The config-driven core of the Data-Source Registry: the typed model that
// maps `entity type → Notion data source + property map (bound by PROPERTY
// ID)`. This is the foundation the spec's "first vertical slice" is built on
// (Decision 7) — Skills is seeded as entity #1, the validating fold-in.
//
// Binding contract (Decision 1 + Decision 5): a property is addressed by its
// Notion PROPERTY ID (stable across renames); `notionName` is the human
// display name used ONLY for introspection matching + UI. `notionPropertyId`
// is intentionally `nil` in the shipped seed — a duplicated Notion template
// mints fresh property IDs, so the bundle CANNOT hardcode them; the schema
// binder resolves them by name against the live data source at setup.
//
// This file is pure value types — no Notion client, no disk, no I/O — so it
// is deterministic under test and safe to evolve.

import Foundation
import MCP

/// Semantic role of a property, so CRUD + domain verbs can reason about a
/// field (e.g. "the title", "the status") without hardcoding its
/// workspace-specific name. `generic` is the default — most fields need no
/// special handling.
public enum RegistryPropertyRole: String, Codable, Sendable, CaseIterable {
    case title
    case status
    case date
    case relation
    case generic
}

/// One field in an entity's property map. Bound by Notion PROPERTY ID; the
/// `notionName` is the display name (introspection match + UI label).
public struct RegistryProperty: Codable, Sendable, Equatable {
    /// Canonical, workspace-agnostic key the Bridge addresses this field by
    /// (e.g. `name`, `email`, `summary`). Stable regardless of Notion renames.
    public let key: String
    /// Notion property display name — the introspection match key (Decision 5)
    /// and the UI label. Mutable: a rename updates the name, never the binding.
    public var notionName: String
    /// The resolved Notion PROPERTY ID. `nil`/empty until the schema binder
    /// resolves it against the live data source (Decision 5 — never shipped).
    public var notionPropertyId: String?
    /// Notion property type (`title`, `rich_text`, `status`, `select`,
    /// `relation`, `date`, …) — validated against the live schema on every
    /// sync cycle so a silent type change is caught (Decision 9 drift watch).
    public var type: String
    /// Semantic role hint (default `generic`).
    public var role: RegistryPropertyRole

    public init(
        key: String,
        notionName: String,
        notionPropertyId: String? = nil,
        type: String,
        role: RegistryPropertyRole = .generic
    ) {
        self.key = key
        self.notionName = notionName
        self.notionPropertyId = notionPropertyId
        self.type = type
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case key, notionName, notionPropertyId, type, role
    }

    // Forwards-tolerant decode: unknown keys ignored, missing fields default —
    // older readers survive future writer revisions (mirrors CachedSkillBody).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.notionName = try c.decodeIfPresent(String.self, forKey: .notionName) ?? ""
        let pid = try c.decodeIfPresent(String.self, forKey: .notionPropertyId)
        self.notionPropertyId = (pid?.isEmpty == true) ? nil : pid
        self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.role = try c.decodeIfPresent(RegistryPropertyRole.self, forKey: .role) ?? .generic
    }

    /// Whether this property is bound to a concrete Notion property id and is
    /// therefore addressable for reads/writes.
    public var isBound: Bool { (notionPropertyId?.isEmpty == false) }

    /// Return a copy bound to `id` (the schema binder's output).
    public func bound(to id: String) -> RegistryProperty {
        var copy = self
        copy.notionPropertyId = id.isEmpty ? nil : id
        return copy
    }
}

/// A configured entity type: `entity → Notion data source + property map`,
/// plus its cache volatility and whether its page body is content (the
/// "properties-first + body" pattern Skills and BLOCKS share — Decision 1).
public struct RegistryEntity: Codable, Sendable, Equatable {
    /// Canonical entity key (`skill`, `project`, `contact`, …).
    public let key: String
    /// Human display name for the Settings pane.
    public var displayName: String
    /// Notion data source id this entity is backed by.
    public var dataSourceId: String
    /// Notion connection name; `nil` resolves to the primary connection
    /// (Decision 8 — entities are workspace-agnostic, resolved at the
    /// connection layer).
    public var workspace: String?
    /// The property map (Decision 1), bound by property id.
    public var properties: [RegistryProperty]
    /// Read-through cache TTL in seconds, by volatility (Decision 4).
    public var cacheTTLSeconds: Int
    /// True for "properties-first scheduling entity WITH a body" (Skills,
    /// BLOCKS): the page body is an authored spec loaded on demand, not
    /// eagerly cached (Decision 1 / Decision 4 — body on demand).
    public var hasBody: Bool

    public init(
        key: String,
        displayName: String,
        dataSourceId: String,
        workspace: String? = nil,
        properties: [RegistryProperty],
        cacheTTLSeconds: Int,
        hasBody: Bool = false
    ) {
        self.key = key
        self.displayName = displayName
        self.dataSourceId = dataSourceId
        self.workspace = workspace
        self.properties = properties
        self.cacheTTLSeconds = cacheTTLSeconds
        self.hasBody = hasBody
    }

    enum CodingKeys: String, CodingKey {
        case key, displayName, dataSourceId, workspace, properties
        case cacheTTLSeconds, hasBody
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.dataSourceId = try c.decodeIfPresent(String.self, forKey: .dataSourceId) ?? ""
        self.workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        self.properties = try c.decodeIfPresent([RegistryProperty].self, forKey: .properties) ?? []
        self.cacheTTLSeconds = try c.decodeIfPresent(Int.self, forKey: .cacheTTLSeconds) ?? 3600
        self.hasBody = try c.decodeIfPresent(Bool.self, forKey: .hasBody) ?? false
    }

    /// Property lookup by canonical key.
    public func property(_ key: String) -> RegistryProperty? {
        properties.first { $0.key == key }
    }

    /// The title property, if one is declared.
    public var titleProperty: RegistryProperty? {
        properties.first { $0.role == .title }
    }

    /// Whether every declared property is bound to a Notion property id —
    /// i.e. the entity is ready for cache-backed reads/writes.
    public var isFullyBound: Bool {
        !properties.isEmpty && properties.allSatisfy { $0.isBound }
    }

    /// Return a copy with `properties` replaced by their bound forms (binder
    /// output). Properties absent from `bindings` keep their prior state.
    public func applying(bindings: [String: String]) -> RegistryEntity {
        var copy = self
        copy.properties = properties.map { prop in
            if let id = bindings[prop.key] { return prop.bound(to: id) }
            return prop
        }
        return copy
    }
}

/// The full, exportable registry config — one portable unit (Decision 8:
/// data source ids + property maps + per-entity settings). Persisted by
/// `RegistryConfigStore`.
public struct RegistryConfig: Codable, Sendable, Equatable {
    /// On-disk schema version, for forward migrations.
    public var schemaVersion: Int
    /// The configured entities.
    public var entities: [RegistryEntity]

    public init(schemaVersion: Int = 1, entities: [RegistryEntity] = []) {
        self.schemaVersion = schemaVersion
        self.entities = entities
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, entities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.entities = try c.decodeIfPresent([RegistryEntity].self, forKey: .entities) ?? []
    }

    /// Entity lookup by key.
    public func entity(_ key: String) -> RegistryEntity? {
        entities.first { $0.key == key }
    }

    /// Upsert an entity by key (replace-in-place or append).
    public mutating func upsert(_ entity: RegistryEntity) {
        if let i = entities.firstIndex(where: { $0.key == entity.key }) {
            entities[i] = entity
        } else {
            entities.append(entity)
        }
    }
}

// MARK: - Default seed (Skills as entity #1 — Decision 7)

public extension RegistryConfig {
    /// The first-run seed. Skills is entity #1 — the validating fold-in: if
    /// Skills cannot be expressed as a registry entity, the abstraction is
    /// wrong (Decision 7). Property IDs are intentionally absent (bound at
    /// setup via introspection — Decision 5).
    static func defaultSeed() -> RegistryConfig {
        RegistryConfig(schemaVersion: 1, entities: [.skillsSeed()])
    }
}

public extension RegistryEntity {
    /// Skills as a registry entity. The data source id is the operator's
    /// verified Keepr/Skills source (a portable install rebinds it at setup);
    /// property IDs are unbound (resolved by name against the live schema).
    /// `hasBody == true`: a skill is property-queryable AND body-possessable
    /// (the `fetch_skill`/`possess` pattern — Decision 1 / Decision 2).
    static func skillsSeed() -> RegistryEntity {
        RegistryEntity(
            key: "skill",
            displayName: "Skills",
            dataSourceId: "b6ff6ea5-3917-4af7-9c36-278dc8bfb21f",
            workspace: nil,
            properties: [
                RegistryProperty(key: "name", notionName: "Skill Name", type: "title", role: .title),
                RegistryProperty(key: "slug", notionName: "Slug", type: "rich_text"),
                RegistryProperty(key: "summary", notionName: "Description", type: "rich_text"),
                RegistryProperty(key: "triggers", notionName: "Activation Examples", type: "rich_text"),
                RegistryProperty(key: "antiTriggers", notionName: "Anti-Triggers", type: "rich_text"),
                RegistryProperty(key: "status", notionName: "Status", type: "status", role: .status),
                RegistryProperty(key: "domain", notionName: "Domain", type: "select"),
                RegistryProperty(key: "specialist", notionName: "Specialist", type: "relation", role: .relation),
            ],
            // Skills are stable, body-heavy reference content → 6h, matching
            // the Memory volatility tier (Decision 4 left Skills' TTL open).
            cacheTTLSeconds: 6 * 3600,
            hasBody: true
        )
    }
}
