// MCPClientPresence.swift — interactive MCP session presence for Auto Execute defer (PKT-MEM-120)
// TheBridge · Server
//
// Counts HTTP `/mcp` + legacy SSE sessions only — wired from the same connect/disconnect
// hooks as StatusBarController. Stdio is intentionally excluded (synthetic local session).

import Foundation

public actor MCPClientPresence {

    public static let shared = MCPClientPresence()

    /// Mirrors `StatusBarController.removalGracePeriod` (4s).
    public static let disconnectGraceNanoseconds: UInt64 = 4_000_000_000

    /// Hermetic test seam — when set, `hasConnectedClient` returns this value.
    nonisolated(unsafe) public static var testOverride: Bool?

    private var connectedNames: Set<String> = []
    private var pendingRemovals: [String: Task<Void, Never>] = [:]

    private init() {}

    public var hasConnectedClient: Bool {
        if let testOverride = Self.testOverride { return testOverride }
        return !connectedNames.isEmpty
    }

    /// First connected client name for operator-facing UI (sorted for stability).
    public var primaryClientName: String? {
        connectedNames.sorted().first
    }

    public func recordConnect(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingRemovals[trimmed]?.cancel()
        pendingRemovals.removeValue(forKey: trimmed)
        connectedNames.insert(trimmed)
    }

    public func recordDisconnect(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingRemovals[trimmed]?.cancel()
        pendingRemovals[trimmed] = Task {
            try? await Task.sleep(nanoseconds: Self.disconnectGraceNanoseconds)
            await self.removeAfterGrace(name: trimmed)
        }
    }

    private func removeAfterGrace(name: String) {
        pendingRemovals.removeValue(forKey: name)
        connectedNames.remove(name)
    }

    public func resetForTesting() {
        for (_, task) in pendingRemovals { task.cancel() }
        pendingRemovals.removeAll()
        connectedNames.removeAll()
    }
}
