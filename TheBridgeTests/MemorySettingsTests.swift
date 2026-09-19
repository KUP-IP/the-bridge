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

    await test("MemorySection.tab resolves new + legacy anchors (2026-07-03 3-tab redesign)") {
        // New vocabulary
        let memos = await MainActor.run { MemorySection.tab(for: "memos") }
        try expect(memos == .memos, "memos anchor")
        let recall = await MainActor.run { MemorySection.tab(for: "recall") }
        try expect(recall == .recall, "recall anchor")
        let settings = await MainActor.run { MemorySection.tab(for: "settings") }
        try expect(settings == .settings, "settings anchor")
        // Legacy 5-tab aliases — must keep resolving so already-shipped MCP calls/
        // notifications/bookmarked deep-links don't silently land nowhere.
        let inbox = await MainActor.run { MemorySection.tab(for: "inbox") }
        try expect(inbox == .memos, "inbox legacy anchor → memos")
        let process = await MainActor.run { MemorySection.tab(for: "process") }
        try expect(process == .memos, "process legacy anchor → memos")
        let notion = await MainActor.run { MemorySection.tab(for: "notion") }
        try expect(notion == .recall, "notion legacy anchor → recall (Notion tab retired)")
        let agent = await MainActor.run { MemorySection.tab(for: "agent") }
        try expect(agent == .recall, "agent legacy anchor → recall")
        let processing = await MainActor.run { MemorySection.tab(for: "processing") }
        try expect(processing == .settings, "processing legacy anchor → settings")
        let legacy = await MainActor.run { MemorySection.tab(for: "voice-memos") }
        try expect(legacy == .memos, "voice-memos legacy anchor → memos")
    }

    await test("MemoryNavigationAnchor compound memoId and filter, new + legacy heads") {
        let proc = MemoryNavigationAnchor.resolve("process/memo-xyz")
        try expect(proc.tab == .memos, "process legacy → memos tab")
        try expect(proc.memoId == "memo-xyz", "memo id")
        let memos = MemoryNavigationAnchor.resolve("memos/memo-xyz")
        try expect(memos.tab == .memos, "memos tab")
        try expect(memos.memoId == "memo-xyz", "memo id via new head")
        let filt = MemoryNavigationAnchor.resolve("inbox/awaitingAgent")
        try expect(filt.tab == .memos, "inbox legacy → memos")
        try expect(filt.inboxFilter == .awaitingAgent, "filter")
        let activity = MemoryNavigationAnchor.resolve("activity")
        try expect(activity.tab == .memos, "activity → memos")
    }

    await test("BridgeSettingsAutomation.memoryResolvedValue encodes tab and memoId") {
        let val = await MainActor.run {
            BridgeSettingsAutomation.memoryResolvedValue(anchor: "process/m1")
        }
        guard case .object(let obj) = val else {
            throw TestError.assertion("expected object resolved payload")
        }
        try expect(obj["tab"] == .string("memos"), "tab field (process legacy anchor resolves to memos)")
        try expect(obj["memoId"] == .string("m1"), "memoId field")
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

    await test("SettingsUIValidationHarness includes Memory AX ids (2026-07-03 3-tab redesign)") {
        let ids = SettingsUIValidationHarness.expectedIdentifiers[.memory] ?? []
        try expect(ids.contains(BridgeAXID.Memory.tabBar), "tab bar id")
        try expect(ids.contains(BridgeAXID.Memory.tab("memos")), "memos tab id")
        try expect(ids.contains(BridgeAXID.Memory.tab("recall")), "recall tab id")
        try expect(ids.contains(BridgeAXID.Memory.tab("settings")), "settings tab id")
        try expect(ids.contains(BridgeAXID.Memory.dismiss), "dismiss id (Memos-tab inbox action)")
        try expect(ids.contains(BridgeAXID.Memory.notionOpen), "notionOpen id (Memos-tab filed-in-Notion link)")
        try expect(ids.contains(BridgeAXID.Memory.Memos.list), "memos list id")
        try expect(ids.contains(BridgeAXID.Memory.Memos.search), "memos search id")
        try expect(ids.contains(BridgeAXID.Memory.Recall.list), "recall list id")
        try expect(ids.contains(BridgeAXID.Memory.Recall.searchField), "recall search id")
        try expect(ids.contains(BridgeAXID.Memory.Settings.pane), "settings pane id")
        try expect(ids.contains(BridgeAXID.Memory.Settings.curatorMode), "settings curator mode id")
        let chrome = Set([
            BridgeAXID.navRow(.memory),
            BridgeAXID.titleBar,
            BridgeAXID.sidebarToggle,
            BridgeAXID.contentPane,
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
