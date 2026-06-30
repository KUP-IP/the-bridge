// VoiceMemoReviewTag.swift — structured inbox filter tags (PKT-MEM-120)
// TheBridge · Modules · VoiceMemo

import Foundation

public enum VoiceMemoReviewTag: String, Codable, Sendable, CaseIterable {
    case awaitingAgent
    case lowConfidence
    case noTranscript
    case routingFailed
    case suppressed
    case unclassified

    public var inboxLabel: String {
        switch self {
        case .awaitingAgent: return "Awaiting agent"
        case .lowConfidence: return "Low confidence"
        case .noTranscript: return "No transcript"
        case .routingFailed: return "Routing failed"
        case .suppressed: return "Suppressed"
        case .unclassified: return "Other"
        }
    }

    /// Legacy derive-on-read when `reviewTag` is absent on disk.
    public static func derive(from entry: VoiceMemoReviewEntry) -> VoiceMemoReviewTag {
        if let raw = entry.reviewTag, let tag = VoiceMemoReviewTag(rawValue: raw) {
            return tag
        }
        let reason = entry.reason.lowercased()
        if reason.contains("awaiting") && (reason.contains("agent") || reason.contains("mcp")) {
            return .awaitingAgent
        }
        if reason.contains("curator mode agent") {
            return .awaitingAgent
        }
        if reason.contains("deferred to connected mcp agent") {
            return .awaitingAgent
        }
        if reason.contains("no transcript") || reason.contains("missing transcript") {
            return .noTranscript
        }
        if reason.contains("routing") || reason.contains("classify") || reason.contains("transcription failed") {
            return .routingFailed
        }
        if reason.contains("secondary intent suppressed") {
            return .suppressed
        }
        if entry.confidence < 0.65 {
            return .lowConfidence
        }
        return .unclassified
    }
}

extension VoiceMemoReviewEntry {
    public var effectiveReviewTag: VoiceMemoReviewTag {
        VoiceMemoReviewTag.derive(from: self)
    }
}
