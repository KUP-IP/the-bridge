// VoiceMemoSuiteAuditTests.swift — Voice + Memory hub MCP audit (PKT-MEM-122)
// TheBridge · Tests
//
// Cross-tool invariants for voice_memo_* tools (and memory_* spot-checks).
// Complements VoiceMemoModuleTests with suite-wide contracts.

import Foundation
import MCP
import TheBridgeLib

private func makeVoiceRouter() async -> ToolRouter {
    let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
    await VoiceMemoModule.register(on: router)
    await MemoryModule.register(on: router)
    return router
}

private func camelCaseKeyOK(_ key: String) -> Bool {
    guard let first = key.first, first.isLowercase else { return false }
    return key.allSatisfy { $0.isLetter || $0.isNumber }
}

func runVoiceMemoSuiteAuditTests() async {
    print("\n\u{1F50E} Voice Memo Suite Audit (cross-tool invariants)")

    let expectedVoiceTools: Set<String> = [
        "voice_memo_list",
        "voice_memo_process",
        "voice_memo_review_list",
        "voice_memo_review_dismiss",
        "voice_memo_review_resolve",
        "voice_memo_transcript_refresh",
        "voice_memo_get",
        "voice_memo_commit",
        "voice_memo_triage_open",
        "voice_memo_triage_await",
    ]

    let router = await makeVoiceRouter()
    let voiceTools = await router.registrations(forModule: "voice")
    let liveNames = Set(voiceTools.map(\.name))

    await test("Voice suite: live tool count is exactly 10") {
        try expect(voiceTools.count == 10, "expected 10 voice tools, got \(voiceTools.count)")
        try expect(liveNames == expectedVoiceTools, "unexpected voice surface: \(liveNames.symmetricDifference(expectedVoiceTools))")
    }

    await test("Voice suite: every tool has explicit ToolAnnotationCatalog entry") {
        for name in expectedVoiceTools.sorted() {
            guard ToolAnnotationCatalog.annotations(for: name) != nil else {
                throw TestError.assertion("\(name) missing annotation catalog entry")
            }
        }
    }

    await test("Voice suite: camelCase schema keys") {
        for reg in voiceTools {
            guard case .object(let schema) = reg.inputSchema,
                  case .object(let props)? = schema["properties"] else { continue }
            for key in props.keys {
                try expect(camelCaseKeyOK(key), "\(reg.name) schema key '\(key)' must be camelCase")
            }
        }
    }

    await test("Voice suite: requiresConfirmation mirrors tier") {
        for reg in voiceTools {
            guard let ann = ToolAnnotationCatalog.annotations(for: reg.name) else { continue }
            let expected = reg.tier == .request || reg.neverAutoApprove
            try expect(ann.requiresConfirmation == expected,
                       "\(reg.name) requiresConfirmation mismatch tier=\(reg.tier.rawValue)")
        }
    }

    await test("Voice suite: read-only tools annotated read-only") {
        let readOnly = ["voice_memo_list", "voice_memo_review_list", "voice_memo_get", "voice_memo_triage_await"]
        for name in readOnly {
            guard let a = ToolAnnotationCatalog.annotations(for: name) else {
                throw TestError.assertion("\(name) missing annotation")
            }
            try expect(a.readOnlyHint == true && a.destructiveHint == false, "\(name) must be read-only")
        }
    }

    await test("Voice suite: triage_open rejects stdio-only opener") {
        await TriageSessionStore.shared.resetForTesting()
        TriageSessionStore.testAllowWithoutHTTPClient = false
        TriageSessionStore.testOpenerClientId = nil
        let (text, isError) = await router.dispatchFormatted(
            toolName: "voice_memo_triage_open",
            arguments: .object(["memoId": .string("test-memo-id")])
        )
        try expect(isError, "stdio-only must error")
        try expect(text.contains("stdio") || text.contains("HTTP"), "expected stdio rejection: \(text)")
    }

    await test("Voice suite: triage_await requires sessionHandle") {
        let (text, isError) = await router.dispatchFormatted(
            toolName: "voice_memo_triage_await",
            arguments: .object([:])
        )
        try expect(isError, "missing sessionHandle must error")
        try expect(text.contains("sessionHandle"), "error should mention sessionHandle: \(text)")
    }
}
