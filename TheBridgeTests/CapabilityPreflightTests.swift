// CapabilityPreflightTests.swift — PKT-1065C
// TheBridge · Tests
//
// Covers the intent-sensitive capability preflight (sub-packet C):
//   • intent classification (data-minimal `.none` by default)
//   • data-minimal guarantee: NO domain probe runs without an intent
//   • Reminders adapter: access status + writable/default-list discovery
//     WITHOUT broad reminder enumeration (the core smoke)
//   • bounded content read ONLY on a read intent — capped, never full-store
//   • access-denied path: probe reports unavailable, reads nothing
//   • capability entries + notes feed A's receipt; capabilityState downgrades
//     to LIMITED for a required domain that is unavailable, WITHOUT touching
//     the (SEPARATE) init finalState
//   • routing-roster quality (HEALTHY / SPARSE / EMPTY)
//   • operator summary surfaces supplemental tri-state + routing warnings
//   • bridge_initialize tool wires the preflight from the `intent` arg
//
// Hermetic: reuses the existing MockRemindersStore seam (no live EventKit /
// TCC) + a per-test throwaway HOME for the on-disk doctrine store.

import Foundation
import MCP
import TheBridgeLib

/// A self-contained reminders store that RECORDS whether `fetch(...)` (content
/// enumeration) was ever called, so tests can prove a cold/manage-only preflight
/// NEVER enumerates reminders. Access + list discovery are driven directly;
/// content is a fixed seed so bounded-read behavior is deterministic.
final class SpyRemindersStore: RemindersStoring, @unchecked Sendable {
    private let authStatus: RemindersAuthStatus
    private let lists_: [ReminderList]
    private let items: [ReminderItem]
    private(set) var fetchCallCount = 0
    private(set) var listsCallCount = 0

    init(authStatus: RemindersAuthStatus = .authorized, lists: [ReminderList]? = nil,
         seedItems: [ReminderItem] = []) {
        self.authStatus = authStatus
        self.lists_ = lists ?? [
            ReminderList(id: "list-default", title: "Reminders", isDefault: true, allowsModify: true)
        ]
        self.items = seedItems
    }

    func authorizationStatus() -> RemindersAuthStatus { authStatus }
    func ensureAccess() async throws {
        if authStatus != .authorized { throw RemindersModuleError.accessDenied }
    }
    func lists() async throws -> [ReminderList] {
        try await ensureAccess()
        listsCallCount += 1
        return lists_
    }
    func fetch(_ query: ReminderQuery) async throws -> [ReminderItem] {
        try await ensureAccess()
        fetchCallCount += 1
        var out = items
        if !query.includeCompleted { out = out.filter { !$0.completed } }
        return out
    }
    func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        throw RemindersModuleError.accessDenied  // not exercised by preflight
    }
    func update(id: String, _ draft: ReminderDraft) async throws -> ReminderItem {
        throw RemindersModuleError.notFound(id)
    }
    func setCompleted(id: String, completed: Bool) async throws -> ReminderItem {
        throw RemindersModuleError.notFound(id)
    }
    func delete(id: String) async throws { throw RemindersModuleError.notFound(id) }
}

func runCapabilityPreflightTests() async {
    print("\n\u{1F9EA} CapabilityPreflight (PKT-1065C · intent-sensitive preflight + Reminders adapter)")

    let fixedClock = Date(timeIntervalSince1970: 1_700_000_000)
    func ctx(connectionState: String = "local", macTools: Bool = true) -> BridgeInitializeContext {
        BridgeInitializeContext(client: "test", connectionState: connectionState,
                                macToolsAvailable: macTools, bridgeState: "running", now: fixedClock)
    }

    // ── intent classification ──────────────────────────────────────────
    await test("Preflight: classify() is data-minimal (.none) by default") {
        try expect(PreflightIntent.classify(nil) == .none)
        try expect(PreflightIntent.classify("") == .none)
        try expect(PreflightIntent.classify("summarize my inbox") == .none,
                   "unrelated intent stays data-minimal")
    }

    await test("Preflight: classify() distinguishes manage vs read reminders intent") {
        try expect(PreflightIntent.classify("add a reminder to buy milk") == .remindersManage)
        try expect(PreflightIntent.classify("what's on my reminders today") == .remindersRead)
        try expect(PreflightIntent.classify("list my reminders") == .remindersRead)
        try expect(PreflightIntent.classify("reminders.read") == .remindersRead,
                   "canonical token round-trips")
        try expect(PreflightIntent.classify("reminders.manage") == .remindersManage)
    }

    // ── data-minimal guarantee ─────────────────────────────────────────
    await test("Preflight: NO domain probe runs on a data-minimal (.none) handshake") {
        let spy = SpyRemindersStore()
        let registry = CapabilityPreflightRegistry(probes: [RemindersCapabilityProbe(store: spy)])
        try expect(registry.applicableProbes(for: .none).isEmpty, "no probe applies to .none")
        let results = await registry.run(intent: .none)
        try expect(results.isEmpty, "cold start runs zero probes")
        try expect(spy.listsCallCount == 0 && spy.fetchCallCount == 0,
                   "data-minimal handshake touches NO reminders API")
    }

    // ── CORE SMOKE: access + writable-list discovery WITHOUT enumeration ─
    await test("Preflight SMOKE: reminders.manage discovers access + writable list, NO enumeration") {
        let spy = SpyRemindersStore(lists: [
            ReminderList(id: "l-def", title: "Reminders", isDefault: true, allowsModify: true),
            ReminderList(id: "l-ro", title: "Shared", isDefault: false, allowsModify: false)
        ], seedItems: [
            ReminderItem(id: "r1", title: "should NOT be read", due: nil, listId: "l-def",
                         listTitle: "Reminders", completed: false, notes: nil, priority: 0)
        ])
        let registry = CapabilityPreflightRegistry(probes: [RemindersCapabilityProbe(store: spy)])
        let results = await registry.run(intent: .remindersManage)
        try expect(results.count == 1, "one reminders probe ran")
        let r = results[0]
        try expect(r.domain == "reminders")
        try expect(r.available, "a writable list exists → domain available")
        try expect(!r.contentRead, "manage intent must NOT read reminder content")
        try expect(spy.listsCallCount == 1, "lists discovery ran (access + writable-list)")
        try expect(spy.fetchCallCount == 0, "NO reminder enumeration on a manage intent")

        let caps = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.capability, $0) })
        try expect(caps["reminders.access"]?.available == true, "access status discovered")
        try expect(caps["reminders.writable_list"]?.available == true, "writable list discovered")
        try expect(caps["reminders.default_list"]?.available == true, "default list discovered")
        try expect(caps["reminders.content"] == nil, "no content entry without a read intent")
    }

    // ── bounded content read ONLY on read intent ───────────────────────
    await test("Preflight: reminders.read performs a BOUNDED content read (capped, not full-store)") {
        // Seed MORE items than the cap to prove the read is bounded.
        var seed: [ReminderItem] = []
        for i in 0..<(RemindersCapabilityProbe.contentReadCap + 4) {
            seed.append(ReminderItem(id: "r\(i)", title: "t\(i)", due: nil, listId: "l-def",
                                     listTitle: "Reminders", completed: false, notes: nil, priority: 0))
        }
        let spy = SpyRemindersStore(lists: [
            ReminderList(id: "l-def", title: "Reminders", isDefault: true, allowsModify: true)
        ], seedItems: seed)
        let registry = CapabilityPreflightRegistry(probes: [RemindersCapabilityProbe(store: spy)])
        let results = await registry.run(intent: .remindersRead)
        let r = results[0]
        try expect(r.contentRead, "read intent performs a bounded content read")
        try expect(spy.fetchCallCount == 1, "exactly one bounded fetch")
        let content = r.entries.first { $0.capability == "reminders.content" }
        try expect(content != nil, "content capability entry present on a read intent")
        // The detail must show the sample was capped, not the full store.
        try expect(content?.detail?.contains("sampled \(RemindersCapabilityProbe.contentReadCap)") == true,
                   "content read is capped at contentReadCap, got \(content?.detail ?? "nil")")
    }

    // ── access-denied path ─────────────────────────────────────────────
    await test("Preflight: access denied → probe reports unavailable + reads NOTHING") {
        let spy = SpyRemindersStore(authStatus: .denied)
        let registry = CapabilityPreflightRegistry(probes: [RemindersCapabilityProbe(store: spy)])
        let results = await registry.run(intent: .remindersRead)
        let r = results[0]
        try expect(!r.available, "denied access → domain unavailable")
        try expect(!r.contentRead, "denied access reads no content")
        try expect(spy.listsCallCount == 0 && spy.fetchCallCount == 0,
                   "denied access short-circuits BEFORE any list/content read")
        let access = r.entries.first { $0.capability == "reminders.access" }
        try expect(access?.available == false && access?.detail == "denied")
    }

    await test("Preflight: writable-list absent → probe unavailable + operator note") {
        let spy = SpyRemindersStore(lists: [
            ReminderList(id: "l-ro", title: "Shared", isDefault: true, allowsModify: false)
        ])
        let registry = CapabilityPreflightRegistry(probes: [RemindersCapabilityProbe(store: spy)])
        let r = (await registry.run(intent: .remindersManage))[0]
        try expect(!r.available, "no writable list → domain unavailable for writes")
        try expect(r.notes.contains { $0.contains("no writable list") },
                   "operator note explains the write gap")
    }

    // ── probe results feed A's receipt; capability axis downgrade ──────
    await test("Preflight: probe entries + notes flow into the receipt capability axis") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let spy = SpyRemindersStore(lists: [
                ReminderList(id: "l-def", title: "Reminders", isDefault: true, allowsModify: true)
            ])
            let probeResults = await CapabilityPreflightRegistry(
                probes: [RemindersCapabilityProbe(store: spy)]).run(intent: .remindersManage)
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(), supplemental: [], telemetryEventRef: "evt-p1",
                intent: .remindersManage, probeResults: probeResults)
            try expect(receipt.preflightIntent == .remindersManage, "receipt records the intent")
            try expect(receipt.capabilityMatrix.contains { $0.capability == "reminders.access" },
                       "probe entries merged into A's capability matrix")
            try expect(receipt.capabilityMatrix.contains { $0.capability == "mac_tools" },
                       "base matrix entries preserved alongside probe entries")
            try expect(receipt.capabilityState == .full, "writable reminders → still FULL")
        }
    }

    await test("Preflight: an unavailable required domain downgrades capabilityState to LIMITED, NOT finalState") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let spy = SpyRemindersStore(authStatus: .denied)  // domain unavailable
            let probeResults = await CapabilityPreflightRegistry(
                probes: [RemindersCapabilityProbe(store: spy)]).run(intent: .remindersRead)
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(connectionState: "local", macTools: true), supplemental: [],
                telemetryEventRef: "evt-p2", intent: .remindersRead, probeResults: probeResults)
            try expect(receipt.finalState == .complete,
                       "init axis stays COMPLETE — a domain gap is NOT an init failure")
            try expect(receipt.capabilityState == .limited,
                       "capability axis downgrades to LIMITED for the unavailable required domain")
            try expect(!receipt.capabilityNotes.isEmpty, "operator notes surface the gap")
        }
    }

    await test("Preflight: data-minimal receipt carries NO probe entries or notes") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(), supplemental: [], telemetryEventRef: "evt-p3")
            try expect(receipt.preflightIntent == .none)
            try expect(receipt.capabilityNotes.isEmpty, "no probe notes on a data-minimal handshake")
            try expect(!receipt.capabilityMatrix.contains { $0.capability.hasPrefix("reminders.") },
                       "no reminders entries without an intent")
        }
    }

    // ── routing-roster quality ─────────────────────────────────────────
    await test("Preflight: RoutingRosterQuality.assess (HEALTHY / SPARSE / EMPTY)") {
        try expect(RoutingRosterQuality.assess(rendered: "") == .empty)
        try expect(RoutingRosterQuality.assess(rendered: RoutingIndex.render([])) == .empty,
                   "the 'None registered yet' digest is EMPTY")
        let one = RoutingIndex.render([
            RoutingSkillSummary(slug: "a", name: "A", domain: nil, maturity: nil,
                                description: "d", triggers: [], antiTriggers: [])
        ])
        try expect(RoutingRosterQuality.assess(rendered: one) == .sparse, "1 entry < threshold → SPARSE")
        let many = RoutingIndex.render((0..<5).map {
            RoutingSkillSummary(slug: "s\($0)", name: "S\($0)", domain: nil, maturity: nil,
                                description: "d", triggers: [], antiTriggers: [])
        })
        try expect(RoutingRosterQuality.assess(rendered: many) == .healthy, "5 entries → HEALTHY")
    }

    // ── operator summary ───────────────────────────────────────────────
    await test("Preflight: operator summary surfaces supplemental tri-state + routing quality") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let operative = StandingOrderSummary(id: "a", title: "Real directive", scope: .global,
                                                 updatedAt: fixedClock, archived: false)
            let temp = StandingOrderSummary(id: "b", title: "TEMP note", scope: .global,
                                            updatedAt: fixedClock, archived: false)
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(), supplemental: [operative, temp], telemetryEventRef: "evt-p4")
            let summary = receipt.operatorSummary
            try expect(summary.contains("2 found"), "found count in summary")
            try expect(summary.contains("1 operative"), "operative count in summary")
            try expect(summary.contains("1 ignored"), "ignored count in summary")
            try expect(summary.contains("Routing roster:"), "routing state + quality in summary")
            try expect(summary.contains(receipt.routingRosterQuality.rawValue),
                       "routing quality label in summary")
        }
    }

    await test("Preflight: operator summary includes probe notes when an intent ran") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let spy = SpyRemindersStore(authStatus: .denied)
            let probeResults = await CapabilityPreflightRegistry(
                probes: [RemindersCapabilityProbe(store: spy)]).run(intent: .remindersManage)
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(), supplemental: [], telemetryEventRef: "evt-p5",
                intent: .remindersManage, probeResults: probeResults)
            let summary = receipt.operatorSummary
            try expect(summary.contains("Preflight intent: reminders.manage"))
            try expect(summary.contains("Reminders access is denied"),
                       "capability note surfaced in the operator summary")
        }
    }

    // ── receipt serialization carries the new fields ───────────────────
    await test("Preflight: receiptValue serializes routingRosterQuality/preflightIntent/operatorSummary") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(), supplemental: [], telemetryEventRef: "evt-p6")
            guard case .object(let d) = BridgeInitializeModule.receiptValue(receipt) else {
                throw TestError.assertion("receiptValue must be an object")
            }
            for key in ["routingRosterQuality", "preflightIntent", "capabilityNotes", "operatorSummary"] {
                try expect(d[key] != nil, "receipt Value missing new field '\(key)'")
            }
        }
    }

    await test("Preflight: receipt Codable round-trips the new capability fields") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let spy = SpyRemindersStore(lists: [
                ReminderList(id: "l-def", title: "Reminders", isDefault: true, allowsModify: true)
            ])
            let probeResults = await CapabilityPreflightRegistry(
                probes: [RemindersCapabilityProbe(store: spy)]).run(intent: .remindersManage)
            let receipt = BridgeInitializeService.buildReceipt(
                context: ctx(), supplemental: [], handshakeId: "hs-c", telemetryEventRef: "evt-p7",
                intent: .remindersManage, probeResults: probeResults)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let back = try dec.decode(HandshakeReceipt.self, from: try enc.encode(receipt))
            try expect(back == receipt, "Codable round-trip lossless incl. new fields")
            try expect(back.preflightIntent == .remindersManage)
            try expect(back.routingRosterQuality == receipt.routingRosterQuality)
        }
    }

    // ── end-to-end via the tool: intent arg wires the preflight ────────
    await test("Preflight: bridge_initialize with a reminders intent runs the probe end-to-end") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let spy = SpyRemindersStore(lists: [
                ReminderList(id: "l-def", title: "Reminders", isDefault: true, allowsModify: true)
            ])
            let reg = BridgeInitializeModule.makeTool(
                contextProvider: { client in
                    BridgeInitializeContext(client: client, connectionState: "local",
                                            macToolsAvailable: true, bridgeState: "running", now: fixedClock)
                },
                preflightProvider: { CapabilityPreflightRegistry(probes: [RemindersCapabilityProbe(store: spy)]) }
            )
            let result = try await reg.handler(.object(["intent": .string("add a reminder")]))
            guard case .object(let d) = result else { throw TestError.assertion("expected object") }
            try expect(d["preflightIntent"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } == "reminders.manage")
            try expect(spy.listsCallCount == 1, "tool ran the reminders probe (list discovery)")
            try expect(spy.fetchCallCount == 0, "manage intent did NOT enumerate reminders")
        }
    }

    await test("Preflight: bridge_initialize with NO intent runs NO domain probe (data-minimal)") {
        try await withPreflightTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nx")
            let spy = SpyRemindersStore()
            let reg = BridgeInitializeModule.makeTool(
                contextProvider: { client in
                    BridgeInitializeContext(client: client, connectionState: "local",
                                            macToolsAvailable: true, bridgeState: "running", now: fixedClock)
                },
                preflightProvider: { CapabilityPreflightRegistry(probes: [RemindersCapabilityProbe(store: spy)]) }
            )
            _ = try await reg.handler(.object([:]))
            try expect(spy.listsCallCount == 0 && spy.fetchCallCount == 0,
                       "a handshake with no intent touches NO domain API")
        }
    }
}

// Per-test throwaway HOME (mirrors withInitTempHome).
private func withPreflightTempHome(_ body: () async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("CapabilityPreflight-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body()
}
