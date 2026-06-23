// SkillURLParser.swift — Platform-agnostic URL → UUID + Platform extraction
// TheBridge · Modules
// V2-SKILLS: Shared utility for SkillsView (UI) and SkillsModule (MCP).
// Detects platform from URL, extracts canonical UUID.

import Foundation

// MARK: - SkillPlatform

/// Platform a skill document is hosted on.
/// Auto-detected from URL; stored per-skill for fetch routing.
public enum SkillPlatform: String, Codable, Sendable, CaseIterable, Equatable {
    case notion
    case googleDocs
    case manual // Fallback when no URL provided or platform unrecognized

    public var displayName: String {
        switch self {
        case .notion:     return "Notion"
        case .googleDocs: return "Google Docs"
        case .manual:     return "Manual"
        }
    }

    public var systemImage: String {
        switch self {
        case .notion:     return "doc.text"
        case .googleDocs: return "doc.richtext"
        case .manual:     return "square.and.pencil"
        }
    }

    /// Reconstruct a canonical URL from a UUID for this platform.
    public func canonicalURL(uuid: String) -> String? {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        switch self {
        case .notion:
            guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
            return "https://www.notion.so/\(hex)"
        case .googleDocs:
            guard !uuid.isEmpty else { return nil }
            return "https://docs.google.com/document/d/\(uuid)/edit"
        case .manual:
            return nil
        }
    }
}

// MARK: - SkillURLParser

/// Parses a URL string to extract a document UUID and detect the hosting platform.
/// Used by both SkillsView (UI) and SkillsModule (MCP tool) to ensure consistent behavior.
public enum SkillURLParser {

    /// Result of a successful URL parse.
    public struct ParseResult: Sendable, Equatable {
        public let uuid: String
        public let platform: SkillPlatform
        /// The original URL (preserved for click-to-open).
        public let originalURL: String
    }

    /// Parse error with user-facing message.
    public struct ParseError: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Attempt to extract UUID and platform from a URL string.
    /// Returns nil for empty strings. Returns ParseError for unrecognized URLs.
    public static func parse(url: String) -> Result<ParseResult, ParseError> {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ParseError("URL is empty."))
        }

        let lower = trimmed.lowercased()

        // Notion: notion.so or notion.site
        if lower.contains("notion.so") || lower.contains("notion.site") {
            switch NotionPageRef.normalizedPageId(from: trimmed) {
            case .success(let normalized):
                return .success(ParseResult(
                    uuid: normalized,
                    platform: .notion,
                    originalURL: trimmed
                ))
            case .failure(let err):
                return .failure(ParseError(err.message))
            }
        }

        // Google Docs: docs.google.com/document/d/{ID}
        if lower.contains("docs.google.com/document/d/") {
            if let docId = extractGoogleDocId(from: trimmed) {
                return .success(ParseResult(
                    uuid: docId,
                    platform: .googleDocs,
                    originalURL: trimmed
                ))
            } else {
                return .failure(ParseError("Could not extract Google Doc ID from URL."))
            }
        }

        // Google Docs: drive.google.com with /d/{ID}
        if lower.contains("drive.google.com") {
            if let docId = extractGoogleDriveId(from: trimmed) {
                return .success(ParseResult(
                    uuid: docId,
                    platform: .googleDocs,
                    originalURL: trimmed
                ))
            }
        }

        // Unrecognized URL
        return .failure(ParseError("Unrecognized platform URL. Enter the UUID manually and select the platform."))
    }

    /// Detect platform from a URL without full parsing. Returns .manual if unrecognized.
    public static func detectPlatform(from url: String) -> SkillPlatform {
        let lower = url.lowercased()
        if lower.contains("notion.so") || lower.contains("notion.site") { return .notion }
        if lower.contains("docs.google.com") || lower.contains("drive.google.com") { return .googleDocs }
        return .manual
    }

    // MARK: - Private Extractors

    private static func extractGoogleDocId(from url: String) -> String? {
        // Pattern: docs.google.com/document/d/{ID}/...
        guard let range = url.range(of: "document/d/") else { return nil }
        let afterD = url[range.upperBound...]
        let idPortion: Substring
        if let slashRange = afterD.range(of: "/") {
            idPortion = afterD[..<slashRange.lowerBound]
        } else if let queryRange = afterD.range(of: "?") {
            idPortion = afterD[..<queryRange.lowerBound]
        } else {
            idPortion = afterD
        }
        let id = String(idPortion).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private static func extractGoogleDriveId(from url: String) -> String? {
        // Pattern: drive.google.com/.../d/{ID}/...
        guard let range = url.range(of: "/d/") else { return nil }
        let afterD = url[range.upperBound...]
        let idPortion: Substring
        if let slashRange = afterD.range(of: "/") {
            idPortion = afterD[..<slashRange.lowerBound]
        } else if let queryRange = afterD.range(of: "?") {
            idPortion = afterD[..<queryRange.lowerBound]
        } else {
            idPortion = afterD
        }
        let id = String(idPortion).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
