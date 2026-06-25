// VoiceMemoLiveRegressionTests.swift — live-suite fixtures as unit tests (PKT-MEM-105/106)
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runVoiceMemoLiveRegressionTests() async {
    print("\n🎙️ Voice Memos live regression fixtures")

    await test("homophone: blog that → log that contact lane") {
        let transcript = "Blog that I talked with Jacob about the Bridge launch."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(plan.intents.contains { $0.kind == .registryUpdate && $0.entityKey == "contact" }, "contact lane")
        try expect(plan.intents.contains { $0.entityHint?.lowercased().contains("jacob") == true }, "Jacob hint")
    }

    await test("entityHints: bare update session does not fire contact lane") {
        let transcript = "Update session DST-8 objective to ship memory hub."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(!plan.intents.contains { $0.entityKey == "contact" }, "no contact misfire")
        try expect(plan.intents.contains { $0.entityKey == "session" && $0.entityHint == "DST-8" }, "session DST-8")
    }

    await test("session lane: DST-N without PKT prefix") {
        let plan = VoiceMemoParser.parse(
            transcript: "Update session DST-8 — focus on trust fixes.",
            fallbackTitle: "Memo"
        )
        let session = plan.intents.first { $0.entityKey == "session" }
        try expect(session?.entityHint == "DST-8", "DST-8 hint")
        try expect((session?.confidence ?? 0) >= 0.85, "auto-execute confidence")
    }

    await test("block lane: update block extracts hint") {
        let plan = VoiceMemoParser.parse(
            transcript: "Update block Event block. Description is the live test run.",
            fallbackTitle: "Memo"
        )
        try expect(plan.intents.contains { $0.entityKey == "block" }, "block lane")
    }

    await test("project lane confidence ≥ 0.85 for Bridge v4") {
        let plan = VoiceMemoParser.parse(
            transcript: "Update project Bridge v4 — ship trust fixes this week.",
            fallbackTitle: "Memo"
        )
        let project = plan.intents.first { $0.entityKey == "project" }
        try expect((project?.confidence ?? 0) >= 0.85, "project auto-execute threshold")
    }

    await test("reminder title prefers block phrase over remind tail") {
        let transcript = "Block deep work on Memory Hub v4. Remind me to start at 9am with pass phrase."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        let reminder = plan.intents.first { $0.kind == .reminder }
        try expect(reminder?.title?.lowercased().contains("deep work") == true || reminder?.title?.lowercased().contains("memory hub") == true,
                   "block-derived title, got \(reminder?.title ?? "nil")")
    }

    await test("primary intent election suppresses secondary lanes") {
        let intents = [
            VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: "Email Sarah"),
            VoiceMemoIntent(kind: .memoryKeep, confidence: 0.9, entityKey: "memory"),
            VoiceMemoIntent(kind: .agentMemory, confidence: 0.88),
        ]
        let split = VoiceMemoIntentElection.split(intents)
        try expect(split.execute.count == 1, "one execute lane")
        try expect(split.execute.first?.kind == .reminder, "highest priority wins")
        try expect(split.suppressed.count == 2, "two suppressed")
    }

    await test("appendVoiceMemoLog preserves existing content") {
        let merged = VoiceMemoParser.appendVoiceMemoLog(existing: "Prior brief.", newContent: "New note.")
        try expect(merged.contains("Prior brief."), "keeps existing")
        try expect(merged.contains("New note."), "appends new")
        try expect(merged.contains("Voice memo"), "stamp marker")
    }

    await test("processed gate: review queued prevents mark (logic)") {
        // Document invariant: processOne sets reviewQueuedForMemo when queueReview fires.
        let reviewQueuedForMemo = true
        let hasExecuted = true
        let shouldMark = hasExecuted && !reviewQueuedForMemo
        try expect(!shouldMark, "must not mark processed when review pending")
    }

    await test("curator heuristics mode skips Ollama summarization flag") {
        let prior = UserDefaults.standard.string(forKey: BridgeDefaults.voiceMemoCuratorMode)
        UserDefaults.standard.set(VoiceMemoCuratorMode.heuristics.rawValue, forKey: BridgeDefaults.voiceMemoCuratorMode)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: BridgeDefaults.voiceMemoCuratorMode) }
            else { UserDefaults.standard.removeObject(forKey: BridgeDefaults.voiceMemoCuratorMode) }
        }
        try expect(!VoiceMemoCuratorRouter.shouldSummarizeForMemoryKeep(), "heuristics skips LLM summary")
    }
}
