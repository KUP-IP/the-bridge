// RegistrySchema.swift — Data-Source Registry (Wave 2)
// TheBridge · Modules · Registry
//
// Sendable intermediate models that sit between the raw Notion JSON and the
// registry's typed layer. The gateway decodes a page's raw `[String: Any]`
// properties into `NotionRow.cells` (each a decoded, Sendable `NotionCell`)
// at the boundary, so nothing downstream touches `Any` — reader, writer, and
// cache all operate on `Value`.

import Foundation
import MCP

/// A data source's column schema: property NAME → (id, type). Read via the
/// gateway's `schema(...)` (Notion `getDataSource`). The binder matches an
/// entity's declared property names against this to resolve PROPERTY IDs and
/// detect type drift (Decision 5 + Decision 9).
public struct DataSourceSchema: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public let id: String
        public let type: String
        public init(id: String, type: String) { self.id = id; self.type = type }
    }

    /// Keyed by Notion property display name.
    public let columnsByName: [String: Column]

    public init(columnsByName: [String: Column]) {
        self.columnsByName = columnsByName
    }

    public func column(named name: String) -> Column? { columnsByName[name] }
    public var names: [String] { Array(columnsByName.keys).sorted() }
}

/// One decoded property cell of a row: the Notion property id + type + the
/// decoded MCP `Value`. Sendable (unlike the raw `[String: Any]`).
public struct NotionCell: Sendable, Equatable {
    public let id: String
    public let type: String
    public let value: Value
    public init(id: String, type: String, value: Value) {
        self.id = id; self.type = type; self.value = value
    }
}

/// A Notion page/row in Sendable form: identity + freshness anchor + its cells
/// keyed by property NAME (each cell also carries the property id for
/// rename-safe projection).
public struct NotionRow: Sendable, Equatable {
    public let id: String
    public let url: String
    public let lastEditedTime: String
    public let cells: [String: NotionCell]
    /// True when Notion reports the page as trashed (`in_trash`/`archived`). A
    /// deleted (soft-archived) page is still returned by `getPage`, so the
    /// reader uses this to treat it as not-found rather than serving it as live.
    public let archived: Bool

    public init(id: String, url: String, lastEditedTime: String, cells: [String: NotionCell], archived: Bool = false) {
        self.id = id; self.url = url; self.lastEditedTime = lastEditedTime; self.cells = cells; self.archived = archived
    }

    /// The cell for a property, matched by bound id first (rename-safe), then
    /// by display name.
    public func cell(for property: RegistryProperty) -> NotionCell? {
        if let id = property.notionPropertyId, !id.isEmpty,
           let byId = cells.values.first(where: { $0.id == id }) {
            return byId
        }
        return cells[property.notionName]
    }
}

/// A resolved field ready to write: the bound property id, its Notion type,
/// and the typed value. The writer produces these from canonical-key input;
/// the live gateway encodes each via `RegistryPropertyCodec` keyed by id.
public struct BoundField: Sendable, Equatable {
    public let propertyId: String
    public let notionName: String
    public let type: String
    public let value: Value
    public let isTitle: Bool
    public init(propertyId: String, notionName: String, type: String, value: Value, isTitle: Bool) {
        self.propertyId = propertyId
        self.notionName = notionName
        self.type = type
        self.value = value
        self.isTitle = isTitle
    }
}

// MARK: - Decode helper (raw Notion properties → cells)

public enum RegistryRowDecoder {
    /// Build a `NotionRow` from a raw Notion page JSON object (the dict from
    /// `getPage` / a query result row). Decodes every property cell via
    /// `RegistryPropertyCodec`.
    public static func row(from page: [String: Any]) -> NotionRow {
        let id = (page["id"] as? String) ?? ""
        let url = (page["url"] as? String) ?? ""
        let lastEdited = (page["last_edited_time"] as? String) ?? ""
        let archived = (page["in_trash"] as? Bool) ?? (page["archived"] as? Bool) ?? false
        let props = (page["properties"] as? [String: Any]) ?? [:]
        var cells: [String: NotionCell] = [:]
        for (name, raw) in props {
            guard let obj = raw as? [String: Any] else { continue }
            let type = (obj["type"] as? String) ?? ""
            let pid = (obj["id"] as? String) ?? ""
            let value = RegistryPropertyCodec.decode(type: type, property: obj)
            cells[name] = NotionCell(id: pid, type: type, value: value)
        }
        return NotionRow(id: id, url: url, lastEditedTime: lastEdited, cells: cells, archived: archived)
    }

    /// Build a `DataSourceSchema` from a raw `getDataSource` JSON object.
    public static func schema(from dataSource: [String: Any]) -> DataSourceSchema {
        let props = (dataSource["properties"] as? [String: Any]) ?? [:]
        var cols: [String: DataSourceSchema.Column] = [:]
        for (name, raw) in props {
            guard let obj = raw as? [String: Any] else { continue }
            let id = (obj["id"] as? String) ?? ""
            let type = (obj["type"] as? String) ?? ""
            cols[name] = DataSourceSchema.Column(id: id, type: type)
        }
        return DataSourceSchema(columnsByName: cols)
    }
}
