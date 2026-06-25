// VoiceMemoProcessedGate.swift — the single processed-gate predicate (PKT-MEM-106 0a)
// TheBridge · Modules · VoiceMemo
//
// Trust invariant (PKT-MEM-105 / SPEC §2): a memo is marked processed ONLY when
// no pending review entry remains for it. Before 0a, ~10 `markProcessed` callsites
// each decided independently (the processor's in-run flag, the resolver's
// unconditional marks, the commit's unconditional mark). 0a routes EVERY callsite
// through this one predicate so a memo can never be marked processed while a
// sibling lane is still pending review.

import Foundation

public enum VoiceMemoProcessedGate {

    /// The single processed-gate predicate: true when NO pending review entry
    /// remains for `memoId`. Pass an already-loaded manifest to avoid re-reading.
    public static func noPendingReview(
        memoId: String,
        manifest: VoiceMemoReviewManifest = VoiceMemoReviewStore.load()
    ) -> Bool {
        !manifest.entries.contains { $0.memoId == memoId && $0.status == .pending }
    }

    /// Mark the memo processed only when the gate is open. Returns whether it marked.
    /// This is the ONLY way Phase-0 code should mark a memo processed.
    @discardableResult
    public static func markProcessedIfClear(memoId: String, at date: Date = Date()) throws -> Bool {
        guard noPendingReview(memoId: memoId) else { return false }
        try VoiceMemoProcessedStore.markProcessed(id: memoId, at: date)
        return true
    }
}
