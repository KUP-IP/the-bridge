// VoiceMemoNotifier.swift — operator alerts for voice memo curator outcomes
// TheBridge · Modules · VoiceMemo · PKT-MEM-104 + PKT-MEM-120

import Foundation
import MCP

public enum VoiceMemoNotifier {

    /// Per-batch counts for the operator-facing notification lanes.
    public struct NotifyCounts: Sendable, Equatable {
        public var review: Int
        public var noTranscript: Int
        public var routingFailed: Int
        /// Memos whose Understand step sent the transcript to a CLOUD provider (FRONTIER-FIRST W4).
        public var cloudSends: Int
        /// Execute deferred to connected MCP agent (PKT-MEM-120).
        public var agentDeferred: Int

        public init(
            review: Int = 0,
            noTranscript: Int = 0,
            routingFailed: Int = 0,
            cloudSends: Int = 0,
            agentDeferred: Int = 0
        ) {
            self.review = review
            self.noTranscript = noTranscript
            self.routingFailed = routingFailed
            self.cloudSends = cloudSends
            self.agentDeferred = agentDeferred
        }

        public var needsNotification: Bool {
            review > 0 || noTranscript > 0 || routingFailed > 0 || cloudSends > 0 || agentDeferred > 0
        }
    }

    /// Classify a batch of receipts into the operator notification lanes.
    public static func classify(receipts: [VoiceMemoReceipt]) -> NotifyCounts {
        let noTranscript = receipts.filter(isNoTranscriptSkip).count
        let routingFailed = receipts.flatMap(\.outcomes).filter { $0.status == .failed }.count
        let review = receipts.flatMap(\.outcomes).filter { $0.status == .review }.count
        let cloudSends = receipts.filter { $0.provenance == .cloud }.count
        let agentDeferred = receipts.filter(isAgentDeferredSkip).count
        return NotifyCounts(
            review: review,
            noTranscript: noTranscript,
            routingFailed: routingFailed,
            cloudSends: cloudSends,
            agentDeferred: agentDeferred
        )
    }

    private static func isNoTranscriptSkip(_ receipt: VoiceMemoReceipt) -> Bool {
        guard let reason = receipt.skippedReason?.lowercased() else { return false }
        return reason.contains("no transcript") || reason.contains("transcription failed")
    }

    private static func isAgentDeferredSkip(_ receipt: VoiceMemoReceipt) -> Bool {
        guard let reason = receipt.skippedReason?.lowercased() else { return false }
        return reason.contains("deferred to connected mcp agent")
    }

    /// Best-effort macOS notification via the `notify` tool when registered.
    public static func notify(
        title: String,
        body: String,
        settingsSection: String? = nil,
        settingsAnchor: String? = nil,
        router: ToolRouter
    ) async {
        var args: [String: Value] = [
            "title": .string(title),
            "body": .string(body),
        ]
        if let settingsSection, !settingsSection.isEmpty {
            args["openSettingsSection"] = .string(settingsSection)
        }
        if let settingsAnchor, !settingsAnchor.isEmpty {
            args["openSettingsAnchor"] = .string(settingsAnchor)
        }
        _ = try? await router.dispatch(toolName: "notify", arguments: .object(args))
    }

    public static func notifyIfNeeded(receipts: [VoiceMemoReceipt], reviewQueued: Int, router: ToolRouter) async {
        _ = reviewQueued
        let counts = classify(receipts: receipts)
        guard counts.needsNotification else { return }

        let suppress = await MainActor.run { MemoryHubUIState.shouldSuppressNotifications }

        if counts.agentDeferred > 0, !suppress {
            let n = counts.agentDeferred
            let body = n == 1
                ? "1 memo ready for agent commit"
                : "\(n) memos ready for agent commit"
            await notify(
                title: "Voice Memos awaiting agent",
                body: body,
                settingsSection: "Memory",
                settingsAnchor: "process",
                router: router
            )
        }

        if counts.review > 0, !suppress {
            let n = counts.review
            let body = n == 1
                ? "1 transcribed, needs disposition"
                : "\(n) transcribed, need disposition"
            await notify(
                title: "Voice Memos need triage",
                body: body,
                settingsSection: "Memory",
                settingsAnchor: "inbox",
                router: router
            )
        }
        if counts.noTranscript > 0, !suppress {
            let n = counts.noTranscript
            let body = n == 1 ? "1 missing transcript" : "\(n) missing transcript"
            await notify(
                title: "Voice Memos skipped",
                body: body,
                settingsSection: "Memory",
                settingsAnchor: "inbox",
                router: router
            )
        }
        if counts.routingFailed > 0, !suppress {
            let n = counts.routingFailed
            let body = n == 1
                ? "1 routing failure — open Memory Inbox to retry"
                : "\(n) routing failures — open Memory Inbox to retry"
            await notify(
                title: "Voice Memos routing failed",
                body: body,
                settingsSection: "Memory",
                settingsAnchor: "inbox",
                router: router
            )
        }
        if counts.cloudSends > 0, !suppress {
            let n = counts.cloudSends
            let body = n == 1
                ? "1 transcript sent to your cloud provider for parsing"
                : "\(n) transcripts sent to your cloud provider for parsing"
            await notify(
                title: "Voice Memos used cloud parsing",
                body: body,
                settingsSection: "Memory",
                settingsAnchor: "activity",
                router: router
            )
        }
    }
}
