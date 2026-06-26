// MemoryHubCockpitLabelsTests.swift — Voice Curator FRONTIER-FIRST W3
// TheBridge · Tests
//
// Pure-helper coverage for the Process cockpit UX remediation: kind→human label,
// election status→human (incl. "Held for review"), transcript source→human,
// provenance→inspector badge (incl. degraded), the no-transcript select-status
// selection, and the commit-value preview (so the operator commits with sight).
// All deterministic, UI-free — no network / Ollama / audio.

import Foundation
import MCP
import TheBridgeLib

/// Build cockpit rows the real way (the public election path) so commit-value preview
/// is asserted against rows shaped exactly as the view renders them.
private func cockpitRows(_ intents: [VoiceMemoIntent], memoId: String = "m1") -> [CockpitIntentRow] {
    MemoryProcessCockpit.intentRows(
        memoId: memoId,
        plan: VoiceMemoPlan(generatedTitle: "t", skipMemoryKeep: false, summary: "", actions: [], intents: intents)
    )
}

func runMemoryHubCockpitLabelsTests() async {
    print("\n🏷️ Memory Hub W3 — cockpit human labels + provenance + commit-value preview")

    // MARK: intentKind → human noun (kill the rawValue jargon)

    await test("label_intentKind_allCasesHumanized") {
        try expect(MemoryHubCockpitLabels.intentKind(.reminder) == "Reminder", "reminder")
        try expect(MemoryHubCockpitLabels.intentKind(.memoryKeep) == "Memory", "memory_keep → Memory")
        try expect(MemoryHubCockpitLabels.intentKind(.agentMemory) == "Agent note", "agent_memory → Agent note")
        try expect(MemoryHubCockpitLabels.intentKind(.registryUpdate) == "Update record", "registry_update → Update record")
        try expect(MemoryHubCockpitLabels.intentKind(.review) == "Needs review", "review → Needs review")
    }

    await test("label_intentKind_neverEqualsRawValue_forJargonCases") {
        // The whole point of W3: the cockpit must not show `memory_keep` / `agent_memory` /
        // `registry_update` verbatim.
        for kind in [VoiceMemoIntentKind.memoryKeep, .agentMemory, .registryUpdate] {
            try expect(MemoryHubCockpitLabels.intentKind(kind) != kind.rawValue,
                       "\(kind.rawValue) must be humanized, not raw")
            try expect(!MemoryHubCockpitLabels.intentKind(kind).contains("_"),
                       "humanized \(kind.rawValue) must not contain an underscore")
        }
    }

    // MARK: election status → human (the "suppressed" → "Held for review" requirement)

    await test("label_intentStatus_suppressedBecomesHeldForReview") {
        try expect(MemoryHubCockpitLabels.intentStatus("suppressed") == "Held for review",
                   "suppressed → Held for review")
    }

    await test("label_intentStatus_primaryAndReview") {
        try expect(MemoryHubCockpitLabels.intentStatus("primary") == "Primary", "primary → Primary")
        try expect(MemoryHubCockpitLabels.intentStatus("review") == "Needs review", "review → Needs review")
    }

    await test("label_intentStatus_unknownPassesThrough") {
        try expect(MemoryHubCockpitLabels.intentStatus("weird") == "weird", "unknown token passes through unchanged")
    }

    // MARK: transcript source → human (memoRow subtitle)

    await test("label_transcriptSource_mappings") {
        try expect(MemoryHubCockpitLabels.transcriptSource(.apple, hasTranscript: true) == "Apple", "apple")
        try expect(MemoryHubCockpitLabels.transcriptSource(.parakeet, hasTranscript: true) == "On-device", "parakeet → On-device")
        try expect(MemoryHubCockpitLabels.transcriptSource(.sidecar, hasTranscript: true) == "Cached", "sidecar → Cached")
        try expect(MemoryHubCockpitLabels.transcriptSource(.none, hasTranscript: true) == "No transcript", "none → No transcript")
    }

    await test("label_transcriptSource_noTranscriptOverridesSource") {
        // A real source but no resolved transcript still reads "No transcript".
        try expect(MemoryHubCockpitLabels.transcriptSource(.parakeet, hasTranscript: false) == "No transcript",
                   "hasTranscript=false → No transcript regardless of source")
    }

    // MARK: provenance → inspector badge (incl. degraded)

    await test("label_provenanceBadge_perArm") {
        try expect(MemoryHubCockpitLabels.provenanceBadge(.agent, degraded: false) == "Parsed by Claude (agent)", "agent")
        try expect(MemoryHubCockpitLabels.provenanceBadge(.cloud, degraded: false) == "Parsed by cloud", "cloud")
        try expect(MemoryHubCockpitLabels.provenanceBadge(.local, degraded: false) == "Parsed locally", "local")
        try expect(MemoryHubCockpitLabels.provenanceBadge(.heuristic, degraded: false) == "Parsed locally", "heuristic")
    }

    await test("label_provenanceBadge_degradedOverridesAllArms") {
        // Degraded is the operator-actionable signal — it must win over the arm label.
        for arm in [ParseProvenance.agent, .cloud, .local, .heuristic] {
            let badge = MemoryHubCockpitLabels.provenanceBadge(arm, degraded: true)
            try expect(badge.contains("degraded"), "degraded badge must say 'degraded' (arm=\(arm))")
            try expect(badge.contains("reconnect") || badge.contains("credits"),
                       "degraded badge must give the actionable next step (arm=\(arm))")
        }
    }

    // MARK: no-transcript select-status selection (the hang → legible "transcribing")

    await test("label_selectStatus_distinctForNoTranscript") {
        let withT = MemoryHubCockpitLabels.selectStatus(hasTranscript: true)
        let withoutT = MemoryHubCockpitLabels.selectStatus(hasTranscript: false)
        try expect(withT == "Loading preview…", "has transcript → generic loading line")
        try expect(withoutT.contains("Transcribing"), "no transcript → a 'Transcribing' line")
        try expect(withoutT.lowercased().contains("download"), "must warn the first run may download the model")
        try expect(withT != withoutT, "the two states must be visibly distinct")
    }

    await test("label_unresolvedTranscriptMessage_isActionable") {
        let msg = MemoryHubCockpitLabels.unresolvedTranscriptMessage()
        try expect(msg.contains("voice_memo_transcript_refresh"), "names the refresh tool")
        try expect(msg.lowercased().contains("processing"), "points at the Processing pane toggle")
    }

    // MARK: commit-value preview (commit with sight, not blind)

    await test("commitValuePreview_registryUsesDestinationField") {
        // registry_update writes fields[first-sorted-key]; preview that value.
        let intent = VoiceMemoIntent(
            kind: .registryUpdate, confidence: 0.9, entityKey: "project", entityHint: "Bridge",
            fields: ["status": "Shipped", "note": "ship it"])
        let rows = cockpitRows([intent])
        guard let row = rows.first else { try expect(false, "expected a row"); return }
        // destinationLabel sorts keys → "note" is first; preview must match that field's value.
        try expect(MemoryProcessCockpit.commitValuePreview(for: row) == "ship it",
                   "registry preview must show fields[first-sorted-key] value, got \(String(describing: MemoryProcessCockpit.commitValuePreview(for: row)))")
    }

    await test("commitValuePreview_reminderUsesTitle") {
        let intent = VoiceMemoIntent(kind: .reminder, confidence: 0.9, title: "Call the bank at 3pm")
        let rows = cockpitRows([intent])
        guard let row = rows.first else { try expect(false, "expected a row"); return }
        try expect(MemoryProcessCockpit.commitValuePreview(for: row) == "Call the bank at 3pm",
                   "reminder preview must show the proposed title")
    }

    await test("commitValuePreview_nilWhenNothingConcrete") {
        // A registry lane with no fields and no title → nothing concrete to preview yet.
        let intent = VoiceMemoIntent(kind: .registryUpdate, confidence: 0.9, entityKey: "project", entityHint: "Bridge")
        let rows = cockpitRows([intent])
        guard let row = rows.first else { try expect(false, "expected a row"); return }
        try expect(MemoryProcessCockpit.commitValuePreview(for: row) == nil,
                   "no fields + no title → nil preview")
    }
}
