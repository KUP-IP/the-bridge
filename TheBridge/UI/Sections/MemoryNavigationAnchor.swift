// MemoryNavigationAnchor.swift — compound Memory deep-link parsing (PKT-MEM sprint)
// TheBridge · UI · Sections

import Foundation

/// Parsed Memory section anchor for MCP navigation + Settings deep-links.
public struct MemoryNavigationResolution: Sendable, Equatable {
    public var tab: MemorySection.Tab?
    public var memoId: String?
    public var inboxFilter: MemorySection.InboxFilter?

    public init(tab: MemorySection.Tab? = nil, memoId: String? = nil, inboxFilter: MemorySection.InboxFilter? = nil) {
        self.tab = tab
        self.memoId = memoId
        self.inboxFilter = inboxFilter
    }
}

public enum MemoryNavigationAnchor {

    /// Resolve a compound anchor string (`process/<memoId>`, `inbox/awaitingAgent`, …).
    public static func resolve(_ anchor: String?) -> MemoryNavigationResolution {
        guard let raw = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return MemoryNavigationResolution() }

        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let head = parts.first?
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") ?? ""
        let tail = parts.count > 1 ? parts.dropFirst().joined(separator: "/") : nil

        switch head {
        case "process", "curator", "pipeline", "activity":
            var res = MemoryNavigationResolution(tab: .process)
            if let tail, !tail.isEmpty { res.memoId = tail }
            return res
        case "inbox", "review", "voicememos", "voicememo", "voice":
            var res = MemoryNavigationResolution(tab: .inbox)
            if let tail, !tail.isEmpty {
                let filterNorm = tail.lowercased().replacingOccurrences(of: "-", with: "")
                if let f = MemorySection.InboxFilter.allCases.first(where: {
                    $0.rawValue.lowercased() == filterNorm
                }) {
                    res.inboxFilter = f
                }
            }
            return res
        case "notion", "registry":
            return MemoryNavigationResolution(tab: .notion)
        case "agent", "sqlite", "remember":
            return MemoryNavigationResolution(tab: .agent)
        case "processing", "models", "routing":
            return MemoryNavigationResolution(tab: .processing)
        default:
            if let tab = MemorySection.tab(for: anchor) {
                return MemoryNavigationResolution(tab: tab)
            }
            return MemoryNavigationResolution()
        }
    }
}
