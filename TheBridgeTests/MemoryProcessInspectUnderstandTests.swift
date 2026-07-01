// MemoryProcessInspectUnderstandTests.swift — W1 opt-in Understand + W2/W3 preview/keep
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runMemoryProcessInspectUnderstandTests() async {
    print("\n🔍 Memory Process inspect / understand (W1–W3)")

    await test("inspectTranscript_usesSidecarWithoutLadder") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-inspect-\(UUID().uuidString)", isDirectory: true)
        let recordings = fakeHome
            .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(fakeHome)
        defer { BridgePaths.overrideHomeForTesting(nil) }

        let audio = recordings.appendingPathComponent("inspect.m4a")
        try Data([0x00]).write(to: audio)
        let sidecar = recordings.appendingPathComponent("inspect.txt")
        try "Keep this insight about inspect-only selection.".data(using: .utf8)?.write(to: sidecar)

        let list = VoiceMemoDiscovery.listRecordings(roots: [recordings])
        try expect(list.count == 1, "one memo")
        let resolution = VoiceMemoProcessor.inspectTranscript(for: list[0])
        try expect(resolution.text?.contains("inspect-only") == true, "sidecar text")
        try expect(resolution.source == .sidecar, "sidecar source")
    }

    await test("voiceMemoGet_understandFalse_skipsPlan") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-get-\(UUID().uuidString)", isDirectory: true)
        let recordings = fakeHome
            .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(fakeHome)
        defer { BridgePaths.overrideHomeForTesting(nil) }

        let audio = recordings.appendingPathComponent("get.m4a")
        try Data([0x00]).write(to: audio)
        let sidecar = recordings.appendingPathComponent("get.txt")
        try "Remind me to test understand false.".data(using: .utf8)?.write(to: sidecar)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)
        let list = VoiceMemoDiscovery.listRecordings(roots: [recordings])
        let result = try await VoiceMemoProcessor.get(args: .object([
            "memoId": .string(list[0].id),
            "understand": .bool(false),
        ]), router: router)
        guard case .object(let env) = result else {
            try expect(false, "expected object envelope")
            return
        }
        try expect(env["plan"] == nil, "no plan on inspect")
        if case .bool(let u)? = env["understood"] { try expect(u == false, "understood false") }
    }

    await test("intentWritePreview_memoryKeep_listsAllFields") {
        let plan = VoiceMemoPlan(
            generatedTitle: "Demo",
            skipMemoryKeep: false,
            summary: "Summary paragraph.",
            actions: ["Follow up tomorrow"],
            intents: [
                VoiceMemoIntent(kind: .memoryKeep, confidence: 0.9, entityKey: "memory", title: "Demo",
                                fields: VoiceMemoParser.memoryKeepFields(title: "Demo", summary: "Summary paragraph.", actions: ["Follow up tomorrow"])),
            ]
        )
        let rows = MemoryProcessCockpit.intentRows(memoId: "m1", plan: plan)
        let keep = rows.first { $0.kind == .memoryKeep }!
        let lines = MemoryProcessCockpit.intentWritePreview(for: keep, plan: plan)
        try expect(lines.contains(where: { $0.label == "title" }), "title field")
        try expect(lines.contains(where: { $0.label == "summary" }), "summary field")
        try expect(lines.contains(where: { $0.value.contains("Follow up") }), "actions in summary field")
    }

    await test("structuredSummary_heuristicFallback") {
        let s = await VoiceMemoSummarizer.structuredSummary(
            transcript: "Remember to call Alex about the proposal tomorrow.",
            fallbackTitle: "Memo"
        )
        try expect(!s.paragraph.isEmpty, "paragraph")
        try expect(s.relevantFieldText.contains("Alex") || s.paragraph.contains("Alex"), "content preserved")
    }

    await test("summarizer_parseStructuredJSON_extractsActions") {
        let parsed = VoiceMemoSummarizer.parseStructuredJSON(
            "{\"summary\":\"Met with Alex about the proposal.\",\"actions\":[\"Email Alex Friday\"]}",
            fallbackParagraph: "fallback",
            fallbackActions: []
        )
        try expect(parsed?.paragraph.contains("Alex") == true, "summary parsed")
        try expect(parsed?.actions.first == "Email Alex Friday", "action parsed")
    }
}
