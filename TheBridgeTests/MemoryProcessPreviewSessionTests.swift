// MemoryProcessPreviewSessionTests.swift — PKT-MEM-121 Process preview session cache
// TheBridge · Tests

import Foundation
import TheBridgeLib

private func makePlan(title: String = "Standup") -> VoiceMemoPlan {
    VoiceMemoPlan(
        generatedTitle: title,
        skipMemoryKeep: false,
        summary: "morning standup",
        actions: [],
        intents: [
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.9, entityKey: "session", entityHint: "DST-8", title: "T")
        ]
    )
}

private func makeBundle(
    memoId: String,
    transcript: String,
    selectedIntentId: String? = "intent_a",
    overrideIntentId: String? = nil,
    picker: CockpitPickerState? = nil,
    selectedRowId: String? = nil,
    titleDraft: String? = "Draft title"
) -> MemoryProcessPreviewBundle {
    let fp = MemoryProcessPreviewSession.transcriptFingerprint(transcript)
    return MemoryProcessPreviewBundle(
        memoId: memoId,
        transcript: transcript,
        transcriptFingerprint: fp,
        plan: makePlan(),
        selectedIntentId: selectedIntentId,
        overrideIntentId: overrideIntentId,
        intentDiffBadges: ["intent_a": "fields"],
        picker: picker,
        selectedRowId: selectedRowId,
        titleDraft: titleDraft
    )
}

func runMemoryProcessPreviewSessionTests() async {
    print("\n🧠 Memory Process preview session cache (PKT-MEM-121)")

    await test("previewSession_putGet_roundTrip") {
        await MemoryProcessPreviewSession.shared.resetForTesting()
        let bundle = makeBundle(memoId: "m1", transcript: "hello world")
        await MemoryProcessPreviewSession.shared.put(bundle)
        let fp = MemoryProcessPreviewSession.transcriptFingerprint("hello world")
        let hit = await MemoryProcessPreviewSession.shared.get(memoId: "m1", transcriptFingerprint: fp)
        try expect(hit == bundle, "cache hit returns identical bundle")
        try expect(await MemoryProcessPreviewSession.shared.lastSelectedMemoId == nil, "put does not set lastSelected")
    }

    await test("previewSession_fingerprintMismatch_miss") {
        await MemoryProcessPreviewSession.shared.resetForTesting()
        await MemoryProcessPreviewSession.shared.put(makeBundle(memoId: "m1", transcript: "original"))
        let miss = await MemoryProcessPreviewSession.shared.get(
            memoId: "m1",
            transcriptFingerprint: MemoryProcessPreviewSession.transcriptFingerprint("changed transcript")
        )
        try expect(miss == nil, "stale fingerprint must miss")
    }

    await test("previewSession_invalidate_evictsEntry") {
        await MemoryProcessPreviewSession.shared.resetForTesting()
        await MemoryProcessPreviewSession.shared.put(makeBundle(memoId: "m1", transcript: "x"))
        await MemoryProcessPreviewSession.shared.invalidate(memoId: "m1")
        let fp = MemoryProcessPreviewSession.transcriptFingerprint("x")
        let hit = await MemoryProcessPreviewSession.shared.get(memoId: "m1", transcriptFingerprint: fp)
        try expect(hit == nil, "invalidate removes cached bundle")
    }

    await test("previewSession_remove_evictsEntry") {
        await MemoryProcessPreviewSession.shared.resetForTesting()
        let bundle = makeBundle(memoId: "m1", transcript: "x")
        await MemoryProcessPreviewSession.shared.put(bundle)
        await MemoryProcessPreviewSession.shared.remove(memoId: "m1")
        let fp = MemoryProcessPreviewSession.transcriptFingerprint("x")
        let hit = await MemoryProcessPreviewSession.shared.get(memoId: "m1", transcriptFingerprint: fp)
        try expect(hit == nil, "removed memo absent from cache")
    }

    await test("previewSession_lru_evictsOldestBeyondCapacity") {
        await MemoryProcessPreviewSession.shared.resetForTesting()
        for i in 0..<(MemoryProcessPreviewSession.lruCapacity + 2) {
            await MemoryProcessPreviewSession.shared.put(makeBundle(memoId: "m\(i)", transcript: "t\(i)"))
        }
        let oldestFp = MemoryProcessPreviewSession.transcriptFingerprint("t0")
        let oldest = await MemoryProcessPreviewSession.shared.get(memoId: "m0", transcriptFingerprint: oldestFp)
        try expect(oldest == nil, "LRU evicts oldest entry")
        let newestFp = MemoryProcessPreviewSession.transcriptFingerprint("t\(MemoryProcessPreviewSession.lruCapacity + 1)")
        let newest = await MemoryProcessPreviewSession.shared.get(
            memoId: "m\(MemoryProcessPreviewSession.lruCapacity + 1)",
            transcriptFingerprint: newestFp
        )
        try expect(newest != nil, "newest entry retained")
    }

    await test("previewSession_lastSelectedMemoId_tracksSelection") {
        await MemoryProcessPreviewSession.shared.resetForTesting()
        await MemoryProcessPreviewSession.shared.setLastSelectedMemoId("memo-42")
        try expect(await MemoryProcessPreviewSession.shared.lastSelectedMemoId == "memo-42", "tracks last selected")
        await MemoryProcessPreviewSession.shared.remove(memoId: "memo-42")
        try expect(await MemoryProcessPreviewSession.shared.lastSelectedMemoId == nil, "remove clears lastSelected when matching")
    }

    await test("previewSession_pickerState_roundTripsInBundle") {
        await MemoryProcessPreviewSession.shared.resetForTesting()
        let picker = CockpitPickerState(
            entity: "session",
            rows: [MemoryHubRegistryRow(id: "r1", title: "DST-8")],
            stale: false,
            sourceError: nil
        )
        let bundle = makeBundle(
            memoId: "m1",
            transcript: "picker test",
            picker: picker,
            selectedRowId: "r1"
        )
        await MemoryProcessPreviewSession.shared.put(bundle)
        let fp = MemoryProcessPreviewSession.transcriptFingerprint("picker test")
        let hit = await MemoryProcessPreviewSession.shared.get(memoId: "m1", transcriptFingerprint: fp)
        try expect(hit?.picker == picker, "picker state preserved")
        try expect(hit?.selectedRowId == "r1", "selectedRowId preserved")
    }

    await test("previewSession_getIfPresent_whenListTranscriptEmpty") {
        await MemoryProcessPreviewSession.shared.resetForTesting()
        let bundle = makeBundle(memoId: "m1", transcript: "post-transcription body")
        await MemoryProcessPreviewSession.shared.put(bundle)
        let hit = await MemoryProcessPreviewSession.shared.getIfPresent(memoId: "m1")
        try expect(hit?.transcript == "post-transcription body", "memoId-only lookup when list transcript lagging")
    }

    await test("previewSession_refreshPreview_invalidatesTriageSession_stub") {
        // SC-7 — hook exists and is callable; PKT-MEM-122 wires real triage state.
        MemoryHubTriageSessionBridge.invalidateForMemo(memoId: "m-triage")
        try expect(true, "triage invalidation hook callable without crash")
    }

    await test("previewSession_refreshPreview_axId_wellFormed") {
        let id = BridgeAXID.Memory.Process.refreshPreview
        try expect(id == "bridge.settings.memory.process.refreshPreview", "refreshPreview AX id well-formed")
    }
}
