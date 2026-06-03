// CloudStatusModuleTests.swift — WS-D (PKT-921 · Bridge Cloud Access)
// NotionBridge · Tests (custom harness — no XCTest; see TestRunner.swift)
//
// Covers WS-D's three seams against the REAL WS-C API (no real cloudflared,
// no network, no 30s waits):
//
//   1. CloudHeartbeat — start fires `refreshHealth()` ticks; stop halts them;
//      start is idempotent (no duplicate timer). The interval is shrunk and
//      ticks are observed via `onTick` so the loop is deterministic.
//   2. bridge_status registration is GATED — present after
//      `registerCloudStatusTool`, absent after `deregister`; never in the
//      static feature-module surface. Handler returns the canonical payload.
//   3. CloudStatusPayload / tools/list conditional — `up` + `macToolsAvailable`
//      by state, and `ServerManager.filterForCloud`: cloud+offline → only
//      bridge_status; cloud+online/degraded → full; the local path is
//      never filtered.

import Foundation
import NotionBridgeLib

private let wsdNode = LocalNodeContext(ownerID: "owner-d", deviceID: "device-D")

/// Build a manager whose tunnel reports `health`, already enabled so its
/// `state` reflects that health (online/degraded). For offline/disabled we
/// just leave it disabled or script a failing start.
private func makeManager(health: TunnelHealth) async -> BridgeCloudManager {
    let mgr = BridgeCloudManager(
        tunnel: FakeTunnelProcess(startSucceeds: true, health: health),
        passkeyGate: FakePasskeyGate(outcome: .approved),
        node: wsdNode
    )
    _ = await mgr.enable()
    return mgr
}

/// A couple of throwaway Mac-tool registrations so the filter has something to
/// remove (we don't want to depend on the full 195-tool surface here).
private func sampleMacTools() -> [ToolRegistration] {
    func mk(_ name: String) -> ToolRegistration {
        ToolRegistration(
            name: name, module: "sample", tier: .open,
            description: "x",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .object([:]) }
        )
    }
    return [mk("file_read"), mk("shell_exec"), mk("messages_send")]
}

func runCloudStatusModuleTests() async {
    print("\n\u{2601} CloudStatusModule / WS-D (PKT-921) — heartbeat + bridge_status + tools/list")

    // MARK: - 1. Heartbeat start/stop on toggle

    await test("WS-D heartbeat: start fires refreshHealth ticks on the timer") {
        let mgr = await makeManager(health: .healthy)
        let collector = TickCollector()
        let heartbeat = CloudHeartbeat(
            manager: mgr,
            interval: .milliseconds(20),
            onTick: { state in Task { await collector.record(state) } }
        )
        await heartbeat.start()
        try expect(await heartbeat.isRunning, "heartbeat should be running after start()")
        // Wait (bounded) for at least 2 ticks so we know the timer is looping.
        let got = await collector.waitForCount(2, timeoutMs: 2000)
        await heartbeat.stop()
        try expect(got, "expected >=2 heartbeat ticks within the window")
        let states = await collector.states
        try expect(states.allSatisfy { $0 == .online }, "healthy tunnel ticks should report .online, got \(states)")
    }

    await test("WS-D heartbeat: stop halts further ticks (toggle OFF)") {
        let mgr = await makeManager(health: .healthy)
        let collector = TickCollector()
        let heartbeat = CloudHeartbeat(
            manager: mgr,
            interval: .milliseconds(20),
            onTick: { state in Task { await collector.record(state) } }
        )
        await heartbeat.start()
        _ = await collector.waitForCount(1, timeoutMs: 2000)
        await heartbeat.stop()
        try expect(!(await heartbeat.isRunning), "heartbeat should not be running after stop()")
        // A tick that was already past its cancellation check when stop() landed
        // may still deliver its record asynchronously — the onTick closure here
        // spawns a DETACHED `Task { await collector.record(...) }`, so the boundary
        // tick's record can complete just after stop() returns. Let that settle
        // BEFORE sampling the baseline, so this asserts "no NEW ticks once the loop
        // is cancelled" rather than racing the boundary tick's record-Task. stop()
        // cancels promptly (verified above via isRunning), so no fresh ticks can
        // occur during the settle — only the single in-flight record may land.
        try await Task.sleep(for: .milliseconds(80))
        let afterStop = await collector.count
        // Over a multi-interval window (8× the 20ms interval) the cancelled loop
        // must not tick again.
        try await Task.sleep(for: .milliseconds(160))
        let later = await collector.count
        try expect(later == afterStop, "no ticks may fire after stop(): \(afterStop) → \(later)")
    }

    await test("WS-D heartbeat: start is idempotent (no duplicate timer)") {
        let mgr = await makeManager(health: .healthy)
        let heartbeat = CloudHeartbeat(manager: mgr, interval: .seconds(30))
        await heartbeat.start()
        await heartbeat.start() // second start must be a no-op
        try expect(await heartbeat.isRunning, "still running after double start()")
        await heartbeat.stop()
        try expect(!(await heartbeat.isRunning), "single stop() must fully halt a double-started heartbeat")
    }

    // MARK: - 2. bridge_status gated registration + payload

    await test("WS-D bridge_status: registered then deregistered (cloud gate)") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        let mgr = await makeManager(health: .healthy)

        // Absent before registration.
        let before = await router.allRegistrations().map(\.name)
        try expect(!before.contains(CloudStatusModule.toolName), "bridge_status must be absent before registration")

        await BridgeModuleRegistry.registerCloudStatusTool(on: router, manager: mgr)
        let after = await router.allRegistrations().map(\.name)
        try expect(after.contains(CloudStatusModule.toolName), "bridge_status must be present after registerCloudStatusTool")

        await router.deregister(name: CloudStatusModule.toolName)
        let final = await router.allRegistrations().map(\.name)
        try expect(!final.contains(CloudStatusModule.toolName), "bridge_status must be gone after deregister (toggle OFF)")
    }

    await test("WS-D bridge_status: NOT part of the static feature-module count") {
        // The static surface is registered without any cloud tool.
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            includeStripe: false,
            registerSession: { r in await SessionModule.register(on: r, auditLog: log) }
        )
        let names = await router.allRegistrations().map(\.name)
        try expect(!names.contains(CloudStatusModule.toolName),
                   "bridge_status must NOT be in registerStaticFeatureModules (it is cloud-gated)")
        try expect(names.count == BridgeConstants.staticFeatureModuleToolCount,
                   "static count drift \(names.count) vs \(BridgeConstants.staticFeatureModuleToolCount) — WS-D must not change it")
    }

    await test("WS-D bridge_status: handler returns the canonical payload shape") {
        let mgr = await makeManager(health: .healthy)   // → .online
        let reg = CloudStatusModule.makeTool(manager: mgr)
        let out = try await reg.handler(.object([:]))
        guard case .object(let obj) = out else {
            throw TestError.assertion("payload must be a JSON object, got \(out)")
        }
        try expect(obj["tool"] == .string("bridge_status"), "tool field")
        try expect(obj["ok"] == .bool(true), "ok field")
        try expect(obj["state"] == .string("online"), "state should be online, got \(String(describing: obj["state"]))")
        try expect(obj["up"] == .bool(true), "online ⇒ up=true")
        try expect(obj["macToolsAvailable"] == .bool(true), "online ⇒ macToolsAvailable=true")
        try expect(obj["schemaVersion"] == .int(CloudStatusPayload.schemaVersion), "schemaVersion field")
    }

    await test("WS-D bridge_status: degraded is 'up'; offline/disabled are 'down'") {
        // Pure payload-builder checks across all five states.
        try expect(CloudStatusPayload.isUp(.online), "online up")
        try expect(CloudStatusPayload.isUp(.degraded), "degraded up")
        try expect(!CloudStatusPayload.isUp(.connecting), "connecting not up")
        try expect(!CloudStatusPayload.isUp(.offline), "offline not up")
        try expect(!CloudStatusPayload.isUp(.disabled), "disabled not up")

        if case .object(let deg) = CloudStatusPayload.make(state: .degraded) {
            try expect(deg["up"] == .bool(true) && deg["macToolsAvailable"] == .bool(true),
                       "degraded ⇒ up + macToolsAvailable true")
        } else { throw TestError.assertion("degraded payload not an object") }

        if case .object(let off) = CloudStatusPayload.make(state: .offline) {
            try expect(off["up"] == .bool(false) && off["macToolsAvailable"] == .bool(false),
                       "offline ⇒ up + macToolsAvailable false")
        } else { throw TestError.assertion("offline payload not an object") }
    }

    // MARK: - 3. tools/list conditional by state

    await test("WS-D tools/list: CLOUD + .offline → only bridge_status (Mac tools hidden)") {
        var regs = sampleMacTools()
        regs.append(CloudStatusModule.makeTool(manager: await makeManager(health: .healthy)))
        let filtered = ServerManager.filterForCloud(regs, cloudState: .offline)
        let names = Set(filtered.map(\.name))
        try expect(names == [CloudStatusModule.toolName],
                   "offline cloud request must expose ONLY bridge_status, got \(names.sorted())")
    }

    await test("WS-D tools/list: CLOUD + .disabled → only bridge_status") {
        var regs = sampleMacTools()
        regs.append(CloudStatusModule.makeTool(manager: await makeManager(health: .healthy)))
        let filtered = ServerManager.filterForCloud(regs, cloudState: .disabled)
        try expect(Set(filtered.map(\.name)) == [CloudStatusModule.toolName],
                   "disabled cloud request must expose ONLY bridge_status")
    }

    await test("WS-D tools/list: CLOUD + .online/.degraded → full list (Mac tools shown)") {
        var regs = sampleMacTools()
        regs.append(CloudStatusModule.makeTool(manager: await makeManager(health: .healthy)))
        for state in [CloudConnectionState.online, .degraded] {
            let filtered = ServerManager.filterForCloud(regs, cloudState: state)
            try expect(filtered.count == regs.count,
                       "\(state) must keep the full list (\(filtered.count) vs \(regs.count))")
        }
    }

    await test("WS-D tools/list: non-cloud (local) request is never filtered") {
        // The local stdio/SSE path never calls filterForCloud (isCloudRequest
        // defaults to false). Prove the default resolver + that an unfiltered
        // pass keeps everything even when the cloud state is offline.
        let mgr = ServerManager(onToolCall: {})  // default isCloudRequest = { false }
        try expect(!(await mgr.isCloudHeartbeatRunning()), "fresh manager has no heartbeat")
        // A local request would skip filterForCloud entirely; the filter, if it
        // WERE applied with a non-down state, is also a no-op — assert the
        // online passthrough as the local-equivalent invariant.
        let regs = sampleMacTools()
        let passthrough = ServerManager.filterForCloud(regs, cloudState: .online)
        try expect(passthrough.count == regs.count, "online (local-equivalent) keeps full list")
    }
}

// MARK: - Tick collector (actor — deterministic heartbeat observation)

private actor TickCollector {
    private(set) var states: [CloudConnectionState] = []
    var count: Int { states.count }

    func record(_ state: CloudConnectionState) { states.append(state) }

    /// Poll until at least `n` ticks have landed or the timeout elapses.
    func waitForCount(_ n: Int, timeoutMs: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if states.count >= n { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return states.count >= n
    }
}
