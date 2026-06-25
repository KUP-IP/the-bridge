// MemorySettingsTests.swift — PKT-MEM-102 Memory Settings + Inbox UI
// TheBridgeTests

import Foundation
import TheBridgeLib

func runMemorySettingsTests() async {
    print("\n🧠 Memory Settings + Inbox (PKT-MEM-102 / PKT-MEM-104)")

    await test("SettingsSection.memory is ordered after Connection and before Data Sources") {
        let order = SettingsSection.allCases.map { String(describing: $0) }
        guard let conn = order.firstIndex(of: "connection"),
              let mem = order.firstIndex(of: "memory"),
              let ds = order.firstIndex(of: "datasources") else {
            throw TestError.assertion("missing expected section cases in \(order)")
        }
        try expect(conn < mem && mem < ds, "memory order wrong: \(order)")
        try expect(SettingsSection.memory.rawValue == "Memory", "rawValue drift")
        try expect(SettingsSection.memory.displayName == "Memory", "displayName drift")
        try expect(SettingsSection.memory.icon == "brain.head.profile", "icon drift")
    }

    await test("MemorySection.tab resolves inbox|notion|agent anchors") {
        let inbox = await MainActor.run { MemorySection.tab(for: "inbox") }
        try expect(inbox == .inbox, "inbox anchor")
        let notion = await MainActor.run { MemorySection.tab(for: "notion") }
        try expect(notion == .notion, "notion anchor")
        let agent = await MainActor.run { MemorySection.tab(for: "agent") }
        try expect(agent == .agent, "agent anchor")
        let legacy = await MainActor.run { MemorySection.tab(for: "voice-memos") }
        try expect(legacy == .inbox, "voice-memos legacy anchor")
    }

    await test("bridge_settings_navigate resolves Memory and voice-memos alias") {
        let memory = await MainActor.run {
            BridgeSettingsAutomation.resolveSectionWithAnchor("Memory")
        }
        try expect(memory?.section == .memory, "Memory section")
        try expect(memory?.anchor == nil, "Memory default anchor")

        let inbox = await MainActor.run {
            BridgeSettingsAutomation.resolveSectionWithAnchor("memory")
        }
        try expect(inbox?.section == .memory, "memory lowercase")

        let explicit = await MainActor.run {
            BridgeSettingsAutomation.resolveSectionWithAnchor("Memory")
        }
        try expect(explicit?.section == .memory, "Memory display name")

        let alias = await MainActor.run {
            BridgeSettingsAutomation.resolveSectionWithAnchor("voice-memos")
        }
        try expect(alias?.section == .memory, "voice-memos → memory")
        try expect(alias?.anchor == "inbox", "voice-memos → inbox anchor")

        let review = await MainActor.run {
            BridgeSettingsAutomation.resolveSectionWithAnchor("review")
        }
        try expect(review?.section == .memory, "review shorthand")
        try expect(review?.anchor == "inbox", "review → inbox")
    }

    await test("SettingsUIValidationHarness includes Memory AX ids") {
        let ids = SettingsUIValidationHarness.expectedIdentifiers[.memory] ?? []
        try expect(ids.contains(BridgeAXID.Memory.tabBar), "tab bar id")
        try expect(ids.contains(BridgeAXID.Memory.tab("inbox")), "inbox tab id")
        try expect(ids.contains(BridgeAXID.Memory.tab("notion")), "notion tab id")
        try expect(ids.contains(BridgeAXID.Memory.tab("agent")), "agent tab id")
        try expect(ids.contains(BridgeAXID.Memory.inboxList), "inbox list id")
        try expect(ids.contains(BridgeAXID.Memory.dismiss), "dismiss id")
        try expect(ids.contains(BridgeAXID.Memory.notionList), "notion list id")
        try expect(ids.contains(BridgeAXID.Memory.agentList), "agent list id")
        try expect(ids.contains(BridgeAXID.Memory.agentScopeFilter), "agent scope filter id")
        try expect(ids.contains(BridgeAXID.Memory.agentTypeFilter), "agent type filter id")
        let chrome = Set([
            BridgeAXID.navRow(.memory),
            BridgeAXID.titleBar,
            BridgeAXID.control(.memory, "root"),
        ])
        let report = SettingsUIValidationHarness.validate(section: .memory, observedIdentifiers: chrome.union(Set(ids)))
        try expect(report.passed, "synthetic manifest self-check missing: \(report.missing)")
    }

    await test("VoiceMemoNotifier.classify splits review / no-transcript / routing-failed") {
        let noTx = VoiceMemoReceipt(memoId: "a", title: "A", skippedReason: "no transcript")
        let txFail = VoiceMemoReceipt(memoId: "b", title: "B", skippedReason: "transcription failed: boom")
        let review = VoiceMemoReceipt(
            memoId: "c", title: "C",
            outcomes: [VoiceMemoIntentOutcome(kind: .review, status: .review, detail: "low confidence")]
        )
        let failed = VoiceMemoReceipt(
            memoId: "d", title: "D",
            outcomes: [VoiceMemoIntentOutcome(kind: .memoryKeep, status: .failed, detail: "registry down")]
        )
        let counts = VoiceMemoNotifier.classify(receipts: [noTx, txFail, review, failed])
        try expect(counts.noTranscript == 2, "no-transcript count")
        try expect(counts.review == 1, "review count")
        try expect(counts.routingFailed == 1, "routing failed count")
        try expect(counts.needsNotification, "should notify")
    }

    await test("BridgeNotificationDeepLink userInfo carries section + anchor") {
        let info = BridgeNotificationDeepLink.userInfo(section: "Memory", anchor: "inbox")
        try expect(info[BridgeNotificationDeepLink.settingsSectionKey] as? String == "Memory", "section key")
        try expect(info[BridgeNotificationDeepLink.settingsAnchorKey] as? String == "inbox", "anchor key")
        let bare = BridgeNotificationDeepLink.userInfo(section: "Memory", anchor: nil)
        try expect(bare[BridgeNotificationDeepLink.settingsAnchorKey] == nil, "nil anchor omitted")
    }

    await test("MemoryNotionViewModel reports unconfigured memory entity") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem104-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer { BridgePaths.overrideHomeForTesting(nil) }

        let vm = await MainActor.run { MemoryNotionViewModel() }
        await vm.load(limit: 5)
        let configured = await MainActor.run { vm.entityConfigured }
        let status = await MainActor.run { vm.status }
        try expect(!configured, "memory entity not seeded in empty home")
        try expect(status.contains("Data Sources"), "guides operator to Data Sources")
    }

    await test("BridgeSettingsHeaderPreset covers memory section") {
        let spec = BridgeSettingsHeaderPreset.spec(for: .memory)
        try expect(spec.title == "Memory", "preset title")
        try expect(!spec.subtitle.isEmpty, "preset subtitle")
        try expect(spec.systemImage == "brain.head.profile", "preset icon")
    }

    await test("VoiceMemoReviewStore dismiss clears pending count for badge") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem102-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer { BridgePaths.overrideHomeForTesting(nil) }

        let entry = VoiceMemoReviewEntry(
            memoId: "m1",
            memoTitle: "Test memo",
            memoPath: "/tmp/test.m4a",
            intentKind: "review",
            confidence: 0.4,
            reason: "parser could not classify",
            transcriptExcerpt: "hello world"
        )
        try VoiceMemoReviewStore.enqueue(entry)
        try expect(VoiceMemoReviewStore.pendingEntries().count == 1, "one pending")
        try expect(VoiceMemoReviewStore.load().pendingCount == 1, "pendingCount")

        try expect(try VoiceMemoReviewStore.dismiss(id: entry.id), "dismiss ok")
        try expect(VoiceMemoReviewStore.pendingEntries().isEmpty, "queue empty after dismiss")
        await MainActor.run { MemoryReviewBadgeCounter.shared.refresh() }
        let badge = await MainActor.run { MemoryReviewBadgeCounter.shared.pendingCount }
        try expect(badge == 0, "badge counter cleared")
    }
}
