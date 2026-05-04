// NotionModels.swift – V1-05 → V1-12 → PKT-367 Notion API Type Definitions
// NotionBridge · Notion
//
// Models for Notion REST API integration.
// PKT-320: Updated error messages to reference NOTION_API_TOKEN
// PKT-367: Added models for comments, users, file uploads, connections.
//          Replaced `archived` references with `in_trash` (A2).

import Foundation

// MARK: - Notion API Error

/// Error type for Notion API operations.
public enum NotionClientError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case maxRetriesExceeded
    case httpError(Int, String)
    case decodingError(String)
    case connectionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Notion API token not found. Set NOTION_API_TOKEN environment variable or add token to ~/.config/notion-bridge/config.json"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .maxRetriesExceeded:
            return "Max retries exceeded"
        case .httpError(let code, let body):
            return "HTTP \(code): \(String(body.prefix(500)))"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        case .connectionNotFound(let name):
            return "Notion connection '\(name)' not found in registry. Run notion_connections_list or connections_list to see available workspace connection names, or omit workspace to use the primary connection. For data-source/page aliases, pass the canonical Notion ID from notion_search/notion_datasource_get."
        }
    }
}

// MARK: - Notion Page (Minimal)

/// Lightweight Notion page representation.
public struct NotionPage: Sendable {
    public let id: String
    public let url: String
    public let title: String
    public let inTrash: Bool  // PKT-367: A2 — renamed from `archived`
    public let properties: String // raw JSON string

    public init(id: String, url: String, title: String, inTrash: Bool = false, properties: String) {
        self.id = id
        self.url = url
        self.title = title
        self.inTrash = inTrash
        self.properties = properties
    }
}

// MARK: - Notion Block (Minimal)

/// Lightweight Notion block representation.
public struct NotionBlock: Sendable {
    public let id: String
    public let type: String
    public let hasChildren: Bool
    public let inTrash: Bool  // PKT-367: A2 — renamed from `archived`
    public let content: String // raw JSON string

    public init(id: String, type: String, hasChildren: Bool, inTrash: Bool = false, content: String) {
        self.id = id
        self.type = type
        self.hasChildren = hasChildren
        self.inTrash = inTrash
        self.content = content
    }
}

// MARK: - Notion Search Result

/// A search result from the Notion API.
public struct NotionSearchResult: Sendable {
    public let id: String
    public let objectType: String // "page" or "database"
    public let title: String
    public let url: String

    public init(id: String, objectType: String, title: String, url: String) {
        self.id = id
        self.objectType = objectType
        self.title = title
        self.url = url
    }
}

// MARK: - PKT-367: New Models

/// A Notion comment.
public struct NotionComment: Sendable {
    public let id: String
    public let parentId: String
    public let text: String
    public let createdTime: String
    public let createdBy: String // user ID

    public init(id: String, parentId: String, text: String, createdTime: String, createdBy: String) {
        self.id = id
        self.parentId = parentId
        self.text = text
        self.createdTime = createdTime
        self.createdBy = createdBy
    }
}

/// A Notion user.
public struct NotionUser: Sendable {
    public let id: String
    public let name: String
    public let email: String?
    public let type: String // "person" or "bot"
    public let avatarURL: String?

    public init(id: String, name: String, email: String?, type: String, avatarURL: String?) {
        self.id = id
        self.name = name
        self.email = email
        self.type = type
        self.avatarURL = avatarURL
    }
}

/// A Notion file upload result.
public struct NotionFileUpload: Sendable {
    public let id: String
    public let status: String
    public let url: String?

    public init(id: String, status: String, url: String?) {
        self.id = id
        self.status = status
        self.url = url
    }
}

/// A named workspace connection for the multi-token registry.
public struct NotionConnection: Sendable, Codable {
    public var name: String
    public var token: String
    public var primary: Bool

    public init(name: String, token: String, primary: Bool = false) {
        self.name = name
        self.token = token
        self.primary = primary
    }
}

/// Connection info returned by notion_connections_list (token masked).
public struct NotionConnectionInfo: Sendable {
    public let name: String
    public let isPrimary: Bool
    public let status: String // "connected" or "error: ..."
    public let maskedToken: String

    public init(name: String, isPrimary: Bool, status: String, maskedToken: String) {
        self.name = name
        self.isPrimary = isPrimary
        self.status = status
        self.maskedToken = maskedToken
    }
}

// MARK: - JSON Helpers

/// Utility to convert JSONSerialization output to a dictionary string.
public enum NotionJSON {

    /// Extract a title from Notion page properties JSON.
    public static func extractTitle(from properties: [String: Any]) -> String {
        for (_, value) in properties {
            guard let prop = value as? [String: Any],
                  let propType = prop["type"] as? String,
                  propType == "title",
                  let titleArr = prop["title"] as? [[String: Any]] else {
                continue
            }
            let parts = titleArr.compactMap { item -> String? in
                return item["plain_text"] as? String
            }
            if !parts.isEmpty {
                return parts.joined()
            }
        }
        return "Untitled"
    }

    /// Extract plain text from a rich_text array.
    public static func extractPlainText(from richText: [[String: Any]]) -> String {
        return richText.compactMap { $0["plain_text"] as? String }.joined()
    }

    /// Plain text from a Notion block object (`results[]` item), for common block types with `rich_text` / `caption`.
    public static func extractPlainTextFromBlock(_ block: [String: Any]) -> String {
        let type = block["type"] as? String ?? ""
        guard let typeData = block[type] as? [String: Any] else { return "" }
        if let richText = typeData["rich_text"] as? [[String: Any]], !richText.isEmpty {
            return extractPlainText(from: richText)
        }
        if let caption = typeData["caption"] as? [[String: Any]], !caption.isEmpty {
            return extractPlainText(from: caption)
        }
        // v1.7.0: meeting_notes block - surface title, status, child block IDs
        if type == "meeting_notes" {
            var parts: [String] = []
            if let title = typeData["title"] as? String, !title.isEmpty {
                parts.append("Meeting: " + title)
            }
            if let status = typeData["status"] as? String {
                parts.append("Status: " + status)
            }
            if let children = typeData["children"] as? [String: Any] {
                if let sid = children["summary_block_id"] as? String {
                    parts.append("summary_block_id: " + sid)
                }
                if let nid = children["notes_block_id"] as? String {
                    parts.append("notes_block_id: " + nid)
                }
                if let tid = children["transcript_block_id"] as? String {
                    parts.append("transcript_block_id: " + tid)
                }
            }
            if !parts.isEmpty { return parts.joined(separator: " | ") }
        }
        // v1.8.5: table_row — cells is [[rich_text_object]]
        if type == "table_row", let cells = typeData["cells"] as? [[[String: Any]]] {
            let cellTexts = cells.map { extractPlainText(from: $0) }
            let joined = cellTexts.joined(separator: " | ")
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { return joined }
        }
        return ""
    }

    /// Pretty-print a JSON object to string.
    public static func prettyPrint(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        ) else {
            return String(describing: obj)
        }
        return String(data: data, encoding: .utf8) ?? String(describing: obj)
    }

    /// Mask a token for display: ntn_•••••••1234
    public static func maskToken(_ token: String) -> String {
        guard token.count >= 8 else { return "••••••••" }
        let prefix = String(token.prefix(4))
        let suffix = String(token.suffix(4))
        return "\(prefix)•••••••\(suffix)"
    }
}
