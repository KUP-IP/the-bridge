// MemoryHubTriageSessionBridge.swift — triage session UI/MCP seam (PKT-MEM-121 / 122)
// TheBridge · Modules · VoiceMemo

import Foundation

public enum MemoryHubTriageSessionBridge {

    /// Drop any active agent↔UI triage session for `memoId` (Re-run Understand, R10.3).
    public static func invalidateForMemo(memoId: String) {
        Task { await TriageSessionStore.shared.invalidateForMemo(memoId: memoId) }
    }

    /// Whether a triage session is active for the memo (UI banner).
    public static func isActive(memoId: String) async -> Bool {
        await TriageSessionStore.shared.activeSession(forMemoId: memoId) != nil
    }

    /// Operator ended triage from the UI banner.
    public static func endSession(memoId: String) {
        Task {
            if let sid = await TriageSessionStore.shared.activeSession(forMemoId: memoId) {
                await TriageSessionStore.shared.endSession(sessionId: sid, reason: "operator ended")
            }
        }
    }

    /// Process-tab commit succeeded — notify awaiting agent (no double-commit).
    public static func emitCommitted(memoId: String, receiptHash: String, detail: String) {
        Task {
            await TriageSessionStore.shared.emitCommitted(
                memoId: memoId, receiptHash: receiptHash, detail: detail)
        }
    }
}
