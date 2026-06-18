// NotionPageRef.swift — Shared Notion page ID validation for skills (Settings + MCP)
// Accepts 32 hex digits (dashes optional) or https URLs on notion.so / notion.site.

import Foundation

/// Validation failure for `NotionPageRef.normalizedPageId(from:)`.
public struct NotionPageRefParseError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Validates and normalizes Notion page identifiers for skill storage.
public enum NotionPageRef: Sendable {

    /// Normalizes to dashed UUID form (`8-4-4-4-12`) when valid.
    public static func normalizedPageId(from raw: String) -> Result<String, NotionPageRefParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(NotionPageRefParseError("Page ID or URL is empty."))
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: trimmed),
                  let host = url.host?.lowercased(),
                  host.contains("notion.so") || host.contains("notion.site") else {
                return .failure(NotionPageRefParseError("URL must use a Notion host (notion.so or notion.site)."))
            }
            // trimmed already contains the full URL including any fragment —
            // no need to re-append url.fragment (that was a double-append bug).
            guard let hex32 = extract32HexDigits(from: trimmed) else {
                return .failure(NotionPageRefParseError("Could not find a valid Notion page ID in that URL."))
            }
            return .success(formatDashedUUID(hex32))
        }

        let hex = trimmed.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32 else {
            return .failure(NotionPageRefParseError("Notion page ID must be 32 hexadecimal characters (dashes optional)."))
        }
        guard hex.allSatisfy(\.isHexDigit) else {
            return .failure(NotionPageRefParseError("Notion page ID must contain only hexadecimal digits."))
        }
        return .success(formatDashedUUID(hex))
    }

    /// True when the stored value is already a valid normalized id (legacy rows may fail).
    public static func isValidStoredPageId(_ raw: String) -> Bool {
        let hex = raw.replacingOccurrences(of: "-", with: "").lowercased()
        return hex.count == 32 && hex.allSatisfy(\.isHexDigit)
    }

    private static func extract32HexDigits(from s: String) -> String? {
        let uuidPattern = #"[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}"#
        if let regex = try? NSRegularExpression(pattern: uuidPattern),
           let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let range = Range(m.range, in: s) {
            let hex = String(s[range]).replacingOccurrences(of: "-", with: "").lowercased()
            if hex.count == 32 { return hex }
        }
        let plainPattern = #"[a-fA-F0-9]{32}"#
        if let regex = try? NSRegularExpression(pattern: plainPattern),
           let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let range = Range(m.range, in: s) {
            return String(s[range]).lowercased()
        }
        return nil
    }

    private static func formatDashedUUID(_ hex32: String) -> String {
        let s = hex32.lowercased()
        guard s.count == 32 else { return hex32 }
        let i8 = s.index(s.startIndex, offsetBy: 8)
        let i12 = s.index(s.startIndex, offsetBy: 12)
        let i16 = s.index(s.startIndex, offsetBy: 16)
        let i20 = s.index(s.startIndex, offsetBy: 20)
        return "\(s[..<i8])-\(s[i8..<i12])-\(s[i12..<i16])-\(s[i16..<i20])-\(s[i20...])"
    }
}
