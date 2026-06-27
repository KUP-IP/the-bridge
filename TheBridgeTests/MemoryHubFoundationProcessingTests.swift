// MemoryHubFoundationProcessingTests.swift — PROCESSING provider capability profile contracts
// TheBridgeTests · PKT-MEM-115 Memory Hub UX Reconstruction (D6/D17/D23/D36/D42)

import Foundation
import TheBridgeLib

public func runProcessingProviderTests() async {
    print("\n⚙️ PROCESSING Provider Capability Profile Contracts (D6/D17/D23/D36/D42)")

    // MARK: ProviderFamily cases accessible

    await test("ProviderFamily cases are accessible") {
        let families: [ProviderFamily] = [
            .anthropic, .openai, .cursor, .google, .elevenLabs, .custom(id: "my-llm")
        ]
        try expect(families.count == 6, "Expected 6 ProviderFamily values")
        if case .custom(let id) = families.last {
            try expect(id == "my-llm", "custom id should carry through")
        } else {
            throw TestError.assertion("Last family should be .custom(id:)")
        }
    }

    // MARK: ProviderFamily Equatable + Hashable

    await test("ProviderFamily Equatable and Hashable") {
        try expect(ProviderFamily.anthropic == ProviderFamily.anthropic, "anthropic == anthropic")
        try expect(ProviderFamily.openai != ProviderFamily.anthropic, "openai != anthropic")
        try expect(ProviderFamily.custom(id: "a") == ProviderFamily.custom(id: "a"), "custom(a) == custom(a)")
        try expect(ProviderFamily.custom(id: "a") != ProviderFamily.custom(id: "b"), "custom(a) != custom(b)")
        var set = Set<ProviderFamily>()
        set.insert(.anthropic)
        set.insert(.openai)
        set.insert(.anthropic)
        try expect(set.count == 2, "Set deduplication: anthropic + openai = 2 unique entries")
    }

    // MARK: ProviderCapability cases accessible and CaseIterable

    await test("ProviderCapability.transcription and .quizGeneration accessible") {
        let t = ProviderCapability.transcription
        let q = ProviderCapability.quizGeneration
        try expect(t != q, "transcription != quizGeneration")
        try expect(t.rawValue == "transcription", "rawValue: transcription")
        try expect(q.rawValue == "quizGeneration", "rawValue: quizGeneration")
    }

    await test("ProviderCapability is CaseIterable with all 6 cases") {
        let all = ProviderCapability.allCases
        try expect(all.count == 6, "Expected 6 ProviderCapability cases, got \(all.count)")
        try expect(all.contains(.transcription), "missing transcription")
        try expect(all.contains(.summarization), "missing summarization")
        try expect(all.contains(.titleGeneration), "missing titleGeneration")
        try expect(all.contains(.quizGeneration), "missing quizGeneration")
        try expect(all.contains(.routing), "missing routing")
        try expect(all.contains(.general), "missing general")
    }

    // MARK: CredentialReference uses credentialKey field name (D23)

    await test("CredentialReference field is credentialKey, not apiKey or secret") {
        let ref = CredentialReference(credentialKey: "memory-hub.provider.openai.apiKey", label: "OpenAI Key")
        try expect(ref.credentialKey == "memory-hub.provider.openai.apiKey", "credentialKey value roundtrip")
        try expect(ref.label == "OpenAI Key", "label roundtrip")

        // Ensure Codable round-trip preserves field name as credentialKey
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(ref)
        let json = String(decoding: data, as: UTF8.self)
        try expect(json.contains("credentialKey"), "JSON must contain 'credentialKey' key")
        try expect(!json.contains("\"apiKey\""), "JSON must NOT contain 'apiKey' key")
        try expect(!json.contains("\"secret\""), "JSON must NOT contain 'secret' key")

        let decoded = try JSONDecoder().decode(CredentialReference.self, from: data)
        try expect(decoded == ref, "CredentialReference round-trip equality")
    }

    // MARK: ProviderCapabilityProfile constructible

    await test("ProviderCapabilityProfile is constructible with defaults") {
        let profile = ProviderCapabilityProfile(
            capability: .transcription,
            family: .openai,
            credentialRef: CredentialReference(credentialKey: "memory-hub.provider.openai.apiKey"),
            modelId: "gpt-4o-transcribe",
            isEnabled: true
        )
        try expect(profile.capability == .transcription, "capability")
        try expect(profile.family == .openai, "family")
        try expect(profile.modelId == "gpt-4o-transcribe", "modelId")
        try expect(profile.isEnabled == true, "isEnabled default")
        try expect(profile.endpointOverride == nil, "endpointOverride defaults to nil")
    }

    await test("ProviderCapabilityProfile isEnabled defaults to true") {
        let profile = ProviderCapabilityProfile(capability: .general, family: .anthropic)
        try expect(profile.isEnabled == true, "isEnabled should default to true")
    }

    // MARK: ProviderFallbackChain.activeProfile() returns first enabled, skips disabled

    await test("ProviderFallbackChain.activeProfile() returns first enabled, skips disabled") {
        let disabled = ProviderCapabilityProfile(
            capability: .summarization, family: .anthropic, isEnabled: false
        )
        let enabled1 = ProviderCapabilityProfile(
            capability: .summarization, family: .openai, isEnabled: true
        )
        let enabled2 = ProviderCapabilityProfile(
            capability: .summarization, family: .google, isEnabled: true
        )
        let chain: ProviderFallbackChain = [disabled, enabled1, enabled2]
        let active = chain.activeProfile()
        try expect(active != nil, "activeProfile() should return non-nil")
        try expect(active?.family == .openai, "should skip disabled anthropic, return openai (first enabled)")
    }

    await test("ProviderFallbackChain.activeProfile() returns nil when all disabled") {
        let chain: ProviderFallbackChain = [
            ProviderCapabilityProfile(capability: .routing, family: .anthropic, isEnabled: false),
            ProviderCapabilityProfile(capability: .routing, family: .cursor, isEnabled: false),
        ]
        try expect(chain.activeProfile() == nil, "all-disabled chain should return nil")
    }

    await test("ProviderFallbackChain.activeProfile() returns nil for empty chain") {
        let chain: ProviderFallbackChain = []
        try expect(chain.activeProfile() == nil, "empty chain should return nil")
    }

    // MARK: ProviderProfileConfig chain(for:) and activeProfile(for:)

    await test("ProviderProfileConfig returns configured chain and active profile") {
        let profile = ProviderCapabilityProfile(
            capability: .quizGeneration, family: .anthropic, isEnabled: true
        )
        let config = ProviderProfileConfig(chains: [.quizGeneration: [profile]])
        let chain = config.chain(for: .quizGeneration)
        try expect(chain.count == 1, "chain should have 1 entry")
        let active = config.activeProfile(for: .quizGeneration)
        try expect(active?.family == .anthropic, "active profile should be anthropic")
        let missing = config.chain(for: .transcription)
        try expect(missing.isEmpty, "unconfigured capability returns empty chain")
        let nilActive = config.activeProfile(for: .transcription)
        try expect(nilActive == nil, "unconfigured capability returns nil active profile")
    }

    // MARK: ProviderSyntaxValidator returns [] for valid profile

    await test("ProviderSyntaxValidator returns [] for valid profile") {
        let validator = ProviderSyntaxValidator()
        let valid = ProviderCapabilityProfile(
            capability: .summarization,
            family: .openai,
            credentialRef: CredentialReference(credentialKey: "some-key"),
            modelId: "gpt-4o",
            endpointOverride: URL(string: "https://api.openai.com/v1/chat/completions"),
            isEnabled: true
        )
        let errors = validator.validateSyntax(valid)
        try expect(errors.isEmpty, "valid profile should produce no errors, got: \(errors.map(\.message))")
    }

    await test("ProviderSyntaxValidator returns [] when optional fields are nil") {
        let validator = ProviderSyntaxValidator()
        let minimal = ProviderCapabilityProfile(capability: .general, family: .anthropic)
        let errors = validator.validateSyntax(minimal)
        try expect(errors.isEmpty, "nil optional fields should be valid, got: \(errors.map(\.message))")
    }

    // MARK: ProviderSyntaxValidator returns error for empty modelId (non-nil) (D36)

    await test("ProviderSyntaxValidator returns error for empty modelId string (non-nil)") {
        let validator = ProviderSyntaxValidator()
        let profile = ProviderCapabilityProfile(
            capability: .titleGeneration,
            family: .openai,
            modelId: ""
        )
        let errors = validator.validateSyntax(profile)
        try expect(!errors.isEmpty, "empty modelId should produce validation errors")
        let hasModelIdError = errors.contains { $0.field == "modelId" }
        try expect(hasModelIdError, "error field should be 'modelId', got: \(errors.map(\.field))")
    }

    await test("ProviderSyntaxValidator returns error for whitespace-only modelId") {
        let validator = ProviderSyntaxValidator()
        let profile = ProviderCapabilityProfile(
            capability: .titleGeneration,
            family: .openai,
            modelId: "   "
        )
        let errors = validator.validateSyntax(profile)
        let hasModelIdError = errors.contains { $0.field == "modelId" }
        try expect(hasModelIdError, "whitespace-only modelId should be rejected")
    }

    await test("ProviderSyntaxValidator returns error for empty credentialRef.credentialKey (D23)") {
        let validator = ProviderSyntaxValidator()
        let profile = ProviderCapabilityProfile(
            capability: .transcription,
            family: .openai,
            credentialRef: CredentialReference(credentialKey: "")
        )
        let errors = validator.validateSyntax(profile)
        let hasRefError = errors.contains { $0.field == "credentialRef.credentialKey" }
        try expect(hasRefError, "empty credentialKey should be rejected, got: \(errors.map(\.field))")
    }

    // MARK: ProviderTestResult is constructible and has evidenceId: UUID

    await test("ProviderTestResult is constructible with evidenceId: UUID") {
        let id = UUID()
        let result = ProviderTestResult(
            capability: .transcription,
            success: true,
            message: "Test connection succeeded",
            evidenceId: id,
            testedAt: Date()
        )
        try expect(result.capability == .transcription, "capability")
        try expect(result.success == true, "success")
        try expect(result.evidenceId == id, "evidenceId roundtrip")
        try expect(!result.message.isEmpty, "message not empty")
    }

    await test("ProviderTestResult evidenceId defaults to a new UUID") {
        let r1 = ProviderTestResult(capability: .general, success: false, message: "fail")
        let r2 = ProviderTestResult(capability: .general, success: false, message: "fail")
        try expect(r1.evidenceId != r2.evidenceId, "default evidenceIds should be unique")
    }

    await test("ProviderTestResult is Codable (round-trip)") {
        let original = ProviderTestResult(
            capability: .quizGeneration,
            success: false,
            message: "Model not found",
            evidenceId: UUID(),
            testedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderTestResult.self, from: data)
        try expect(decoded.capability == original.capability, "capability round-trip")
        try expect(decoded.success == original.success, "success round-trip")
        try expect(decoded.evidenceId == original.evidenceId, "evidenceId round-trip")
        try expect(decoded.message == original.message, "message round-trip")
    }

    // MARK: ProviderCapabilityProfile Codable round-trip

    await test("ProviderCapabilityProfile Codable round-trip") {
        let original = ProviderCapabilityProfile(
            capability: .routing,
            family: .elevenLabs,
            credentialRef: CredentialReference(credentialKey: "el-key", label: "ElevenLabs"),
            modelId: "eleven_monolingual_v1",
            isEnabled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderCapabilityProfile.self, from: data)
        try expect(decoded.capability == original.capability, "capability round-trip")
        try expect(decoded.family == original.family, "family round-trip")
        try expect(decoded.modelId == original.modelId, "modelId round-trip")
        try expect(decoded.isEnabled == original.isEnabled, "isEnabled round-trip")
        try expect(decoded.credentialRef?.credentialKey == "el-key", "credentialKey round-trip")
        try expect(decoded.credentialRef?.label == "ElevenLabs", "label round-trip")
    }
}
