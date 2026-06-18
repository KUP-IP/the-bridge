// RegistryWriter.swift — Data-Source Registry (Wave 2)
// NotionBridge · Modules · Registry
//
// The write path. Resolves canonical-key input (`[key: Value]`) against the
// entity's BOUND property map into `[BoundField]` (id + type + value), then:
//   • create — create-then-update (Decision/spec note: never set the full
//     property set via create-on-data-source; create with the TITLE only, then
//     PATCH the rest), so a Notion automation that fires on create sees a valid
//     titled row first.
//   • update — PATCH changed properties by id.
//   • delete — soft archive (Decision 8) + cache evict.
// Each successful write refreshes the read-through cache from the returned row
// so a subsequent read is a warm hit.

import Foundation
import MCP

public struct RegistryWriter: Sendable {
    public let gateway: RegistryNotionGateway
    public let cache: RegistryRowCache

    public init(gateway: RegistryNotionGateway, cache: RegistryRowCache = .shared) {
        self.gateway = gateway
        self.cache = cache
    }

    public enum RegistryWriteError: Error, LocalizedError, Equatable {
        case notFullyBound(entity: String, unbound: [String])
        case unknownFields(entity: String, keys: [String])
        case noWritableFields(entity: String)
        public var errorDescription: String? {
            switch self {
            case .notFullyBound(let e, let u):
                return "entity ‘\(e)’ has unbound properties \(u) — run introspection first"
            case .unknownFields(let e, let k):
                return "entity ‘\(e)’ has no properties \(k)"
            case .noWritableFields(let e):
                return "no writable fields supplied for ‘\(e)’"
            }
        }
    }

    /// Resolve canonical-key input into bound fields. Unknown keys (not in the
    /// property map) and unbound keys (no resolved property id) are reported.
    public static func resolve(
        _ input: [String: Value], entity: RegistryEntity
    ) -> (fields: [BoundField], unknown: [String], unbound: [String]) {
        var fields: [BoundField] = []
        var unknown: [String] = []
        var unbound: [String] = []
        for (key, value) in input {
            guard let prop = entity.property(key) else { unknown.append(key); continue }
            guard let pid = prop.notionPropertyId, !pid.isEmpty else { unbound.append(key); continue }
            fields.append(BoundField(
                propertyId: pid, notionName: prop.notionName, type: prop.type,
                value: value, isTitle: prop.role == .title))
        }
        return (fields.sorted { $0.notionName < $1.notionName }, unknown.sorted(), unbound.sorted())
    }

    /// At least one field must actually encode to a Notion payload — guards
    /// against a write whose entire envelope would be empty (e.g. only
    /// read-only types, or all values non-coercible for their type), which
    /// would otherwise no-op an update or create an empty untitled page.
    static func hasEncodable(_ fields: [BoundField]) -> Bool {
        fields.contains { RegistryPropertyCodec.encode(type: $0.type, value: $0.value) != nil }
    }

    // MARK: - Create (create-then-update)

    @discardableResult
    public func create(entity: RegistryEntity, fields input: [String: Value]) async throws -> CachedRow {
        let r = Self.resolve(input, entity: entity)
        if !r.unknown.isEmpty { throw RegistryWriteError.unknownFields(entity: entity.key, keys: r.unknown) }
        if !r.unbound.isEmpty { throw RegistryWriteError.notFullyBound(entity: entity.key, unbound: r.unbound) }
        if r.fields.isEmpty || !Self.hasEncodable(r.fields) { throw RegistryWriteError.noWritableFields(entity: entity.key) }

        let titleFields = r.fields.filter { $0.isTitle }
        let rest = r.fields.filter { !$0.isTitle }

        // Create-then-update: seed the page with the title, then PATCH the rest.
        let created = try await gateway.create(
            dataSourceId: entity.dataSourceId, workspace: entity.workspace,
            fields: titleFields.isEmpty ? r.fields : titleFields)
        // Cache the titled row immediately, so if the follow-up PATCH throws the
        // created page isn't an invisible orphan — a retry/read still sees it.
        // (Notion has no multi-call transaction; this is the best-effort guard.)
        _ = await RegistryReader.store(created, entity: entity, into: cache)
        var row = created
        if !titleFields.isEmpty, !rest.isEmpty {
            row = try await gateway.update(pageId: created.id, workspace: entity.workspace, fields: rest)
        }
        return await RegistryReader.store(row, entity: entity, into: cache)
    }

    // MARK: - Update

    @discardableResult
    public func update(entity: RegistryEntity, pageId: String, fields input: [String: Value]) async throws -> CachedRow {
        let r = Self.resolve(input, entity: entity)
        if !r.unknown.isEmpty { throw RegistryWriteError.unknownFields(entity: entity.key, keys: r.unknown) }
        if !r.unbound.isEmpty { throw RegistryWriteError.notFullyBound(entity: entity.key, unbound: r.unbound) }
        if r.fields.isEmpty || !Self.hasEncodable(r.fields) { throw RegistryWriteError.noWritableFields(entity: entity.key) }
        let row = try await gateway.update(pageId: pageId, workspace: entity.workspace, fields: r.fields)
        return await RegistryReader.store(row, entity: entity, into: cache)
    }

    // MARK: - Delete (soft archive + cache evict)

    public func delete(entity: RegistryEntity, pageId: String) async throws {
        try await gateway.archive(pageId: pageId, workspace: entity.workspace)
        await cache.evict(entity: entity.key, pageId: pageId)
    }
}
