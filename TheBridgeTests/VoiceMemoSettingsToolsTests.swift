// VoiceMemoSettingsToolsTests.swift — PKT-1120
// Hermetic coverage for the MCP settings pair and mode-aware UI copy.
// #284: local-model routing keys are gone; snapshot is four values.

import Foundation
import MCP
import TheBridgeLib

private final class VoiceMemoSettingsDefaultsFixture: @unchecked Sendable {
    let suiteName = "kup.solutions.the-bridge.tests.voice-settings.\(UUID().uuidString)"
    let defaults: UserDefaults

    init?() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
        reset()
    }

    func reset() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

func runVoiceMemoSettingsToolsTests() async {
    print("\n🎚️ Voice Memo Settings Tool Tests")

    guard let fixture = VoiceMemoSettingsDefaultsFixture() else {
        print("  ❌ FAIL: could not create hermetic UserDefaults suite")
        return
    }
    VoiceMemoModule.settingsDefaultsOverrideForTesting = fixture.defaults
    defer {
        VoiceMemoModule.settingsDefaultsOverrideForTesting = nil
        fixture.reset()
    }

    let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
    await VoiceMemoModule.register(on: router)

    await test("voice_memo_settings tools register with exact tiers, schemas, and annotations") {
        let tools = await router.registrations(forModule: VoiceMemoModule.moduleName)
        guard let get = tools.first(where: { $0.name == "voice_memo_settings_get" }),
              let set = tools.first(where: { $0.name == "voice_memo_settings_set" }) else {
            throw TestError.assertion("settings tools missing")
        }
        try expect(get.tier == .open, "settings_get must be open")
        try expect(set.tier == .notify, "settings_set must be notify")
        guard case .object(let schema) = set.inputSchema,
              case .object(let properties)? = schema["properties"] else {
            throw TestError.assertion("settings_set schema missing")
        }
        try expect(Set(properties.keys) == Set([
            "curatorMode", "appleTranscript", "speechAnalyzerTranscription",
            "parakeetTranscription",
        ]), "settings_set must expose four optional keys (no local-model routing)")
        try expect(!properties.keys.contains("ollamaRouting"), "#284: ollamaRouting must not be a settings key")
        let getAnnotation = ToolAnnotationCatalog.annotations(for: get.name)
        let setAnnotation = ToolAnnotationCatalog.annotations(for: set.name)
        try expect(getAnnotation?.readOnlyHint == true && getAnnotation?.idempotentHint == true,
                   "settings_get annotation")
        try expect(setAnnotation?.readOnlyHint == false && setAnnotation?.idempotentHint == true,
                   "settings_set annotation")
    }

    await test("voice_memo_settings_get returns all four effective defaults") {
        fixture.reset()
        let result = try await router.dispatch(
            toolName: "voice_memo_settings_get",
            arguments: .object([:]))
        guard case .object(let snapshot) = result else {
            throw TestError.assertion("expected settings snapshot")
        }
        try expect(snapshot["curatorMode"] == .string("auto"), "default curatorMode")
        try expect(snapshot["appleTranscript"] == .bool(true), "default appleTranscript")
        try expect(snapshot["speechAnalyzerTranscription"] == .bool(false), "default speechAnalyzer off")
        try expect(snapshot["parakeetTranscription"] == .bool(true), "default parakeetTranscription")
        try expect(snapshot["ollamaRouting"] == nil, "#284: snapshot must omit ollamaRouting")
        try expect(snapshot.count == 4, "snapshot must contain exactly four values")
    }

    await test("voice_memo_settings_set partially updates mode and preserves ladder toggles") {
        fixture.reset()
        fixture.defaults.set(false, forKey: BridgeDefaults.voiceMemoAppleTranscript)
        fixture.defaults.set(true, forKey: BridgeDefaults.voiceMemoParakeetTranscription)
        let result = try await router.dispatch(
            toolName: "voice_memo_settings_set",
            arguments: .object(["curatorMode": .string("heuristics")]))
        guard case .object(let snapshot) = result else {
            throw TestError.assertion("expected post-write snapshot")
        }
        try expect(snapshot["curatorMode"] == .string("heuristics"), "mode update")
        try expect(snapshot["appleTranscript"] == .bool(false), "apple unchanged")
        try expect(snapshot["parakeetTranscription"] == .bool(true), "parakeet unchanged")
    }

    await test("voice_memo_settings_set rejects unknown mode before writing any key") {
        fixture.reset()
        let result = try await router.dispatch(
            toolName: "voice_memo_settings_set",
            arguments: .object([
                "curatorMode": .string("bogus"),
                "appleTranscript": .bool(false),
            ]))
        guard case .object(let response) = result,
              case .string(let error)? = response["error"],
              case .array(let valid)? = response["validValues"] else {
            throw TestError.assertion("expected structured invalid mode response")
        }
        let expected = VoiceMemoCuratorMode.allCases.map { Value.string($0.rawValue) }
        try expect(valid == expected, "valid values must derive from allCases")
        for mode in VoiceMemoCuratorMode.allCases {
            try expect(error.contains(mode.rawValue), "error must list \(mode.rawValue)")
        }
        try expect(!VoiceMemoCuratorMode.allCases.map(\.rawValue).contains("local"),
                   "#284: local is not a valid curator mode")
        try expect(fixture.defaults.object(forKey: BridgeDefaults.voiceMemoCuratorMode) == nil,
                   "invalid mode must not write curatorMode")
        try expect(fixture.defaults.object(forKey: BridgeDefaults.voiceMemoAppleTranscript) == nil,
                   "validation must precede all writes")
    }

    await test("voice_memo_settings_set persists a toggle and subsequent get reflects it") {
        fixture.reset()
        let setResult = try await router.dispatch(
            toolName: "voice_memo_settings_set",
            arguments: .object(["appleTranscript": .bool(false)]))
        let getResult = try await router.dispatch(
            toolName: "voice_memo_settings_get",
            arguments: .object([:]))
        guard case .object(let setSnapshot) = setResult,
              case .object(let getSnapshot) = getResult else {
            throw TestError.assertion("expected settings snapshots")
        }
        try expect(fixture.defaults.object(forKey: BridgeDefaults.voiceMemoAppleTranscript) as? Bool == false,
                   "toggle persisted")
        try expect(setSnapshot == getSnapshot, "set returns the post-write get snapshot")
        try expect(getSnapshot["appleTranscript"] == .bool(false), "subsequent get reflects write")
    }

    await test("Memory Settings Auto and Cloud help point to Cloud enhancement") {
        try expect(MemorySettingsTab.curatorModeHelp(.auto).contains("Cloud enhancement below"),
                   "Auto cloud cross-reference")
        try expect(MemorySettingsTab.curatorModeHelp(.cloud).contains("Cloud enhancement below"),
                   "Cloud cross-reference")
    }
}
