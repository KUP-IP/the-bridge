// MemoryRowFormatter.swift — shared markdown rows for memory surfaces (PKT-MEM-115)
// TheBridge · Modules

import Foundation

/// Pure formatter for agent-memory markdown rows. Used by handshake inject,
/// `bridge://memory`, and `fetch_skill` `scopedMemory` appendix.
public enum MemoryRowFormatter {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// One bullet row: type, text, optional entity, source, created date, use count.
    public static func rowLine(_ entry: MemoryEntry) -> String {
        var row = "- [\(entry.type.rawValue)] \(entry.text)"
        if let entity = entry.entity?.trimmingCharacters(in: .whitespacesAndNewlines),
           !entity.isEmpty {
            row += " · \(entity)"
        }
        let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            row += " · source: \(source)"
        }
        row += " · \(dayFormatter.string(from: entry.createdAt))"
        if entry.useCount > 0 {
            row += " · used \(entry.useCount)×"
        }
        return row
    }

    /// Grouped-by-scope markdown (pinned-first order preserved from input slice).
    public static func markdown(_ entries: [MemoryEntry]) -> String {
        guard !entries.isEmpty else { return "No memories stored yet." }

        var scopeOrder: [String] = []
        var byScope: [String: [MemoryEntry]] = [:]
        for entry in entries {
            if byScope[entry.scope] == nil { scopeOrder.append(entry.scope) }
            byScope[entry.scope, default: []].append(entry)
        }

        var sections: [String] = []
        for scope in scopeOrder {
            var lines = ["## \(scope)"]
            for entry in byScope[scope] ?? [] {
                lines.append(rowLine(entry))
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}
