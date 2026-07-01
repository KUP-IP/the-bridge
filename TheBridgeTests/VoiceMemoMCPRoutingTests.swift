// VoiceMemoMCPRoutingTests.swift — PKT-MEM-120 Auto+MCP Execute defer + presence
// TheBridge · Tests
//
// Hermetic coverage for MCP client presence, Auto-mode Execute defer when an
// interactive MCP session is connected, awaiting-agent review tags, activity
// receipts, notifier lanes, and the Process-tab notification suppression gate.

import Foundation
import MCP
import TheBridgeLib

private func withMCPRoutingTempHome<T>(_ body: () async throws -> T) async rethrows -> T {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("VoiceMemoMCP-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer { BridgePaths.overrideHomeForTesting(nil); try? fm.removeItem(at: tmp) }
    return try await body()
}

private func withCuratorMode(_ mode: VoiceMemoCuratorMode, _ body: () async throws -> Void) async rethrows {
    let key = BridgeDefaults.voiceMemoCuratorMode
    let prior = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.set(mode.rawValue, forKey: key)
    defer {
        if let prior { UserDefaults.standard.set(prior, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    try await body()
}

private func withMCPOverride(_ connected: Bool?, _ body: () async throws -> Void) async rethrows {
    let prior = MCPClientPresence.testOverride
    MCPClientPresence.testOverride = connected
    defer { MCPClientPresence.testOverride = prior }
    try await body()
}

private func planStub(provenance: ParseProvenance = .heuristic) -> VoiceMemoPlan {
    VoiceMemoPlan(
        generatedTitle: "Memo title",
        skipMemoryKeep: false,
        summary: "summary",
        actions: [],
        intents: [VoiceMemoIntent(kind: .review, confidence: 0.5, title: "Memo title")],
        provenance: provenance,
        degraded: false
    )
}

func runVoiceMemoMCPRoutingTests() async {
    print("\n🔀 Voice Memo MCP routing — PKT-MEM-120")

    // MARK: MCPClientPresence

    await test("mcpPresence_connectAndDisconnect_withGrace") {
        await MCPClientPresence.shared.resetForTesting()
        MCPClientPresence.testOverride = nil
        await MCPClientPresence.shared.recordConnect(name: "Cursor")
        try expect(await MCPClientPresence.shared.hasConnectedClient, "connected after recordConnect")
        try expect(await MCPClientPresence.shared.primaryClientName == "Cursor", "primary client name")
        await MCPClientPresence.shared.recordDisconnect(name: "Cursor")
        try expect(await MCPClientPresence.shared.hasConnectedClient, "still connected during grace")
        try? await Task.sleep(nanoseconds: MCPClientPresence.disconnectGraceNanoseconds + 200_000_000)
        try expect(await MCPClientPresence.shared.hasConnectedClient == false, "removed after grace")
        await MCPClientPresence.shared.resetForTesting()
    }

    await test("mcpPresence_testOverride_seam") {
        await MCPClientPresence.shared.resetForTesting()
        try await withMCPOverride(true) {
            try expect(await MCPClientPresence.shared.hasConnectedClient, "override true")
        }
        try await withMCPOverride(false) {
            try expect(await MCPClientPresence.shared.hasConnectedClient == false, "override false")
        }
    }

    // MARK: deferExecuteToAgent routing

    await test("deferExecute_agentMode_alwaysTrue") {
        try await withCuratorMode(.agent) {
            try await withMCPOverride(false) {
                try expect(await VoiceMemoCuratorRouter.deferExecuteToAgent(), "agent mode defers even without MCP")
            }
        }
    }

    await test("deferExecute_autoMode_mcpConnected_defers") {
        try await withCuratorMode(.auto) {
            try await withMCPOverride(true) {
                try expect(await VoiceMemoCuratorRouter.deferExecuteToAgent(), "auto + MCP ⇒ defer")
            }
        }
    }

    await test("deferExecute_autoMode_alone_autonomous") {
        try await withCuratorMode(.auto) {
            try await withMCPOverride(false) {
                try expect(await VoiceMemoCuratorRouter.deferExecuteToAgent() == false, "auto alone ⇒ autonomous")
            }
        }
    }

    await test("deferExecute_cloudMode_neverDefers") {
        try await withCuratorMode(.cloud) {
            try await withMCPOverride(true) {
                try expect(await VoiceMemoCuratorRouter.deferExecuteToAgent() == false, "cloud mode ⇒ no defer")
            }
        }
    }

    // MARK: Review tags

    await test("reviewTag_explicitAwaitingAgent") {
        let entry = VoiceMemoReviewEntry(
            memoId: "m1",
            memoTitle: "t",
            intentKind: "review",
            confidence: 0.5,
            reason: "any",
            transcriptExcerpt: "",
            reviewTag: VoiceMemoReviewTag.awaitingAgent.rawValue
        )
        try expect(entry.effectiveReviewTag == .awaitingAgent, "explicit tag wins")
    }

    await test("reviewTag_derivedFromDeferReason") {
        let entry = VoiceMemoReviewEntry(
            memoId: "m1",
            memoTitle: "t",
            intentKind: "review",
            confidence: 0.5,
            reason: "auto — MCP connected; awaiting agent commit",
            transcriptExcerpt: ""
        )
        try expect(entry.effectiveReviewTag == .awaitingAgent, "defer reason ⇒ awaitingAgent")
    }

    // MARK: Activity + notifier

    await test("recordAgentDeferred_writesExecuteReceipt") {
        try await withMCPRoutingTempHome {
            let recording = VoiceMemoRecording(id: "m1", path: "/tmp/m1.m4a", title: "t", recordedAt: Date(), transcript: "hi")
            VoiceMemoProcessor.recordAgentDeferred(recording: recording, plan: planStub(provenance: .cloud), reason: "auto — MCP connected")
            let event = MemoryHubActivityLog.recent(limit: 5).first { $0.action == "agent_deferred" }
            try expect(event != nil, "agent_deferred activity event")
            try expect(event?.provenance == "cloud", "carries plan provenance")
            try expect(event?.phase == .execute, "execute phase")
        }
    }

    await test("notifier_classifiesAgentDeferredLane") {
        let receipts = [
            VoiceMemoReceipt(memoId: "a", title: "t", skippedReason: "deferred to connected MCP agent"),
            VoiceMemoReceipt(memoId: "b", title: "t", skippedReason: "already processed"),
        ]
        let counts = VoiceMemoNotifier.classify(receipts: receipts)
        try expect(counts.agentDeferred == 1, "one agent-deferred skip")
        try expect(counts.needsNotification, "agent defer triggers notification lane")
    }

    await test("notifier_agentDeferred_suppressedWhenProcessActive") {
        let priorApp = MemoryHubUIState.testAppActiveOverride
        MemoryHubUIState.testAppActiveOverride = true
        defer { MemoryHubUIState.testAppActiveOverride = priorApp }
        try await MainActor.run {
            MemoryHubUIState.setMemorySectionVisible(true)
            MemoryHubUIState.setProcessTabSelected(true)
            try expect(MemoryHubUIState.shouldSuppressNotifications, "Process tab active ⇒ suppress")
            MemoryHubUIState.setProcessTabSelected(false)
            try expect(MemoryHubUIState.shouldSuppressNotifications == false, "other tab ⇒ deliver")
            MemoryHubUIState.setMemorySectionVisible(false)
        }
    }

    // MARK: Cockpit labels (PKT-MEM-120 W2)

    await test("cockpitLabels_provenanceShort_and_diffBadge") {
        try expect(MemoryHubCockpitLabels.provenanceShort(.cloud, degraded: false) == "Cloud", "cloud short")
        try expect(MemoryHubCockpitLabels.provenanceShort(.heuristic, degraded: true) == "Degraded", "degraded short")
        try expect(MemoryHubCockpitLabels.diffBadgeLabel("added") == "Added", "diff added")
        try expect(MemoryHubCockpitLabels.awaitingAgentLabel() == "Awaiting agent", "awaiting agent chip")
    }

    await test("inboxFilter_includesAwaitingAgent") {
        let cases = await MainActor.run { MemorySection.InboxFilter.allCases.map(\.rawValue) }
        try expect(cases.contains("awaitingAgent"), "awaiting agent filter case")
        try expect(VoiceMemoReviewTag.awaitingAgent.inboxLabel == "Awaiting agent", "label matches tag")
    }
}
