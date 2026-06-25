// MemoryHubPreview.swift — progressive preview policy + notification gate (PKT-MEM-106 0c)
// TheBridge · Modules · VoiceMemo
//
// Pure policy for the progressive preview pipeline (heuristic → local-auto → cloud-manual)
// and the precise notification-suppression gate. Timing/UI live in the view; the decision
// rules + timeout/failure semantics + enhancement authority are testable here. Locked
// values are SPEC §0.1 / PKT-MEM-106 0c.

import Foundation

public enum PreviewProvenance: String, Codable, Sendable, CaseIterable {
    case heuristic   // fast, no provider — rendered first
    case local       // Ollama auto-enhancement
    case cloud       // operator-triggered cloud enhancement (manual only)
}

public enum MemoryHubPreview {
    /// Local enhancement soft timeout; manual cloud enhancement hard timeout.
    public static let localTimeoutSeconds: Double = 8
    public static let cloudTimeoutSeconds: Double = 20

    /// Local (Ollama) may AUTO-enhance after the heuristic render when enabled.
    public static func mayAutoEnhanceLocal(localEnabled: Bool) -> Bool { localEnabled }

    /// Cloud enhancement runs ONLY on explicit operator action — never auto.
    public static func mayCloudEnhance(operatorTriggered: Bool) -> Bool { operatorTriggered }

    /// On a local timeout or a cloud timeout/failure: keep the latest valid heuristic/local
    /// plan and record a status in activity. CLOUD FAILURE/timeout queues NO review item
    /// (cloud is optional quality polish, not a trust gate).
    public struct FallbackResult: Equatable, Sendable {
        public let kept: PreviewProvenance       // the provenance of the retained plan
        public let queuesReview: Bool            // always false for preview timeout/failure
        public let activityStatus: String        // "timeout" | "cloud_failure"
    }

    public static func onTimeoutOrFailure(latestValid: PreviewProvenance, isCloudFailure: Bool) -> FallbackResult {
        FallbackResult(kept: latestValid, queuesReview: false, activityStatus: isCloudFailure ? "cloud_failure" : "timeout")
    }

    /// If enhancement changed a lane the operator had already approved/committed in-session,
    /// that lane returns to uncommitted review state (commit only the displayed approved intent).
    public static func enhancementReturnsLaneToUncommitted(approvedIntentIds: Set<String>, changedIntentId: String) -> Bool {
        approvedIntentIds.contains(changedIntentId)
    }
}

public enum MemoryHubNotificationGate {
    /// Suppress notifications ONLY when the app is active AND Memory/Process is the selected
    /// surface. In every other cell (inactive app, or a non-Process surface) a queued-review /
    /// routing-or-transcript-error notification is DELIVERED and deep-links to the relevant
    /// Memory surface/filter.
    public static func shouldSuppress(appActive: Bool, processSelected: Bool) -> Bool {
        appActive && processSelected
    }
}
