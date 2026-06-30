// MemoryProcessPreviewSession.swift — in-memory Process preview session cache (PKT-MEM-121)
// TheBridge · Modules · VoiceMemo
//
// LRU-capped (12) in-memory cache of the full Process preview UI bundle per memo.
// Survives Memory sub-tab switches and Settings section leave/return within one app
// session; cleared on app quit. Transcript SHA-256 fingerprint guards stale hits.

import Foundation

/// Full Process-tab preview state for one memo (transcript + plan + UI selection).
public struct MemoryProcessPreviewBundle: Sendable, Equatable {
    public let memoId: String
    public let transcript: String
    public let transcriptFingerprint: String
    public let plan: VoiceMemoPlan
    public let selectedIntentId: String?
    public let overrideIntentId: String?
    public let intentDiffBadges: [String: String]
    public let picker: CockpitPickerState?
    public let selectedRowId: String?
    public let titleDraft: String?
    /// V1 — multi-select intent tags for batch Confirm.
    public let checkedIntentIds: [String]
    /// V1 — transcript expand/collapse in center pane.
    public let transcriptExpanded: Bool
    /// V1 — per-intent registry row picks.
    public let selectedRowIdByIntentId: [String: String]
    /// V1 — per-intent registry picker state.
    public let pickerByIntentId: [String: CockpitPickerState]

    public init(
        memoId: String,
        transcript: String,
        transcriptFingerprint: String,
        plan: VoiceMemoPlan,
        selectedIntentId: String?,
        overrideIntentId: String?,
        intentDiffBadges: [String: String],
        picker: CockpitPickerState?,
        selectedRowId: String?,
        titleDraft: String?,
        checkedIntentIds: [String] = [],
        transcriptExpanded: Bool = false,
        selectedRowIdByIntentId: [String: String] = [:],
        pickerByIntentId: [String: CockpitPickerState] = [:]
    ) {
        self.memoId = memoId
        self.transcript = transcript
        self.transcriptFingerprint = transcriptFingerprint
        self.plan = plan
        self.selectedIntentId = selectedIntentId
        self.overrideIntentId = overrideIntentId
        self.intentDiffBadges = intentDiffBadges
        self.picker = picker
        self.selectedRowId = selectedRowId
        self.titleDraft = titleDraft
        self.checkedIntentIds = checkedIntentIds
        self.transcriptExpanded = transcriptExpanded
        self.selectedRowIdByIntentId = selectedRowIdByIntentId
        self.pickerByIntentId = pickerByIntentId
    }
}

/// In-memory LRU session store for Process preview bundles.
public actor MemoryProcessPreviewSession {
    public static let shared = MemoryProcessPreviewSession()
    public static let lruCapacity = 12

    private var cache: [String: MemoryProcessPreviewBundle] = [:]
    private var accessOrder: [String] = []
    public private(set) var lastSelectedMemoId: String?

    public init() {}

    /// SHA-256 hex digest of a transcript (trimmed). Shared with title-cache freshness.
    public static func transcriptFingerprint(_ transcript: String) -> String {
        MemoryHubActivityLog.sha256Hex(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Lookup a cached bundle when the memo's current transcript fingerprint matches.
    public func get(memoId: String, transcriptFingerprint current: String) -> MemoryProcessPreviewBundle? {
        guard let bundle = cache[memoId], bundle.transcriptFingerprint == current else { return nil }
        touch(memoId)
        return bundle
    }

    /// MemoId-only lookup (used when the memo list has not yet populated `transcript`).
    public func getIfPresent(memoId: String) -> MemoryProcessPreviewBundle? {
        guard let bundle = cache[memoId] else { return nil }
        touch(memoId)
        return bundle
    }

    /// Store or refresh a bundle; evicts the LRU entry when over capacity.
    public func put(_ bundle: MemoryProcessPreviewBundle) {
        cache[bundle.memoId] = bundle
        touch(bundle.memoId)
        evictIfNeeded()
    }

    public func remove(memoId: String) {
        cache.removeValue(forKey: memoId)
        accessOrder.removeAll { $0 == memoId }
        if lastSelectedMemoId == memoId { lastSelectedMemoId = nil }
    }

    /// Explicit invalidation (Re-run Understand) — same as `remove`.
    public func invalidate(memoId: String) {
        remove(memoId: memoId)
    }

    public func setLastSelectedMemoId(_ memoId: String?) {
        lastSelectedMemoId = memoId
    }

    /// Hermetic tests — wipe all entries.
    public func resetForTesting() {
        cache.removeAll()
        accessOrder.removeAll()
        lastSelectedMemoId = nil
    }

    private func touch(_ memoId: String) {
        accessOrder.removeAll { $0 == memoId }
        accessOrder.append(memoId)
    }

    private func evictIfNeeded() {
        while accessOrder.count > Self.lruCapacity {
            let evicted = accessOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}
