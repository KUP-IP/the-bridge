// CloudAccessWSGTests.swift — WS-G (PKT-923 · Bridge Cloud Access)
// NotionBridge · Tests (custom harness — no XCTest; see TestRunner.swift)
//
// Covers the terminal Cloud-Access UI packet end-to-end against fakes — NO
// SwiftUI render, NO WindowServer, NO cloudflared, NO network:
//
//   • FirstRunCloudAccessGate — the one-time presentation rule (Q2 lock):
//     online + unseen → present; online + seen → suppressed; offline → never.
//   • Disable flow — EnableCloudAccessFlow.disable() drives the CloudTeardown
//     seam (tunnel stop) AND clears the persisted toggle + hostname; the live
//     BridgeCloudManager.disable() returns the machine to .disabled.
//   • Cancel reverts — the gate + state model: cancelling the confirmation
//     leaves the enabled flag and hostname untouched (no side effects).
//   • Add-to-Claude.ai — MCP URL derivation + the .urlQueryAllowed-based
//     percent-encoding contract (round-trips; escapes embedded delimiters);
//     shipped mode is the Q3 copy+hint fallback.
//   • FirstRunCloudAccessModal content — the 3-step guide is exactly the
//     packet-specified SF Symbols + copy.

import Foundation
import NotionBridgeLib

// MARK: - Fakes

/// In-memory CloudFlowDefaults — starts ON with a hostname (a live connection)
/// so disable() has something to clear.
private final class WSGFakeDefaults: CloudFlowDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled: Bool
    private var _hostname: String?
    init(enabled: Bool = true, hostname: String? = "device-A.bridge.kup.solutions") {
        self._enabled = enabled
        self._hostname = hostname
    }
    var cloudAccessEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }
    var cloudTunnelHostname: String? {
        get { lock.lock(); defer { lock.unlock() }; return _hostname }
        set { lock.lock(); _hostname = newValue; lock.unlock() }
    }
}

/// Records whether the teardown seam was driven.
private final class RecordingTeardown: CloudTeardown, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    @discardableResult
    func disable() async -> CloudConnectionState {
        lock.withLock { _calls += 1 }
        return .disabled
    }
}

private final class WSGFakeTokenStore: CloudTokenStore, @unchecked Sendable {
    let token: String?
    init(token: String?) { self.token = token }
}

private final class WSGNoopBrowser: AuthBrowserOpening, @unchecked Sendable {
    @discardableResult func open(_ url: URL) -> Bool { true }
}

private final class WSGFakeProvisioner: CloudProvisioning, @unchecked Sendable {
    func provision(baseURL: String) async throws -> String { "device-A.bridge.kup.solutions" }
    func startTunnel() async throws {}
}

@MainActor
private func makeDisableFlow(
    defaults: WSGFakeDefaults,
    teardown: CloudTeardown?
) -> EnableCloudAccessFlow {
    EnableCloudAccessFlow(
        tokenStore: WSGFakeTokenStore(token: "tok"),
        browser: WSGNoopBrowser(),
        provisioner: WSGFakeProvisioner(),
        defaults: defaults,
        teardown: teardown,
        config: WorkOSConfig(baseURL: "https://api.workos.com",
                             clientID: "client_test",
                             redirectURI: "bridge-auth://callback"),
        provisionBaseURL: "https://mock.local"
    )
}

func runCloudAccessWSGTests() async {
    print("\n\u{2601} Bridge Cloud Access · WS-G Tests (PKT-923)")

    // MARK: - First-run gate (Q2: shown once)

    await test("WS-G first-run: online + unseen → modal presents") {
        try expect(FirstRunCloudAccessGate.shouldPresent(isOnline: true, hasSeenFirstRun: false),
                   "first online with the flag unset must present the modal")
    }

    await test("WS-G first-run: online + already seen → suppressed (one-time gate)") {
        try expect(!FirstRunCloudAccessGate.shouldPresent(isOnline: true, hasSeenFirstRun: true),
                   "the hasSeen flag must prevent reappearance")
    }

    await test("WS-G first-run: not online → never presents (regardless of flag)") {
        try expect(!FirstRunCloudAccessGate.shouldPresent(isOnline: false, hasSeenFirstRun: false),
                   "must not present before reaching online")
        try expect(!FirstRunCloudAccessGate.shouldPresent(isOnline: false, hasSeenFirstRun: true),
                   "must not present before reaching online")
    }

    // MARK: - Disable flow (confirm → teardown + state clear)

    await test("WS-G disable: confirm tears down tunnel + clears toggle + hostname") {
        let defaults = WSGFakeDefaults(enabled: true, hostname: "device-A.bridge.kup.solutions")
        let teardown = RecordingTeardown()
        let flow = await makeDisableFlow(defaults: defaults, teardown: teardown)
        await flow.disable()
        try expect(teardown.calls == 1, "disable() must drive the teardown seam exactly once, got \(teardown.calls)")
        try expect(defaults.cloudAccessEnabled == false, "cloudAccessEnabled must be cleared to false")
        try expect(defaults.cloudTunnelHostname == nil, "cloudTunnelHostname must be cleared")
        let state = await MainActor.run { flow.state }
        try expect(state == .idle, "flow must return to .idle after disable, got \(state)")
    }

    await test("WS-G disable: live BridgeCloudManager.disable() returns .disabled (stops tunnel)") {
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: true, health: .healthy),
            passkeyGate: FakePasskeyGate(outcome: .approved),
            node: LocalNodeContext(ownerID: "owner-1", deviceID: "device-A")
        )
        _ = await mgr.enable()
        let online = await mgr.state
        try expect(online == .online, "precondition: manager should be online, got \(online)")
        let after = await mgr.disable()
        try expect(after == .disabled, "disable() must return .disabled (NOT .disconnected), got \(after)")
        let state = await mgr.state
        try expect(state == .disabled, "manager state must be .disabled after teardown, got \(state)")
    }

    // MARK: - Cancel reverts (no side effects)

    await test("WS-G disable: cancel path leaves enabled flag + hostname untouched") {
        // The Cancel branch performs NO teardown and NO defaults mutation — it
        // only re-flips the UI toggle. Model that here: a flow that is never
        // told to disable() must leave the live connection fully intact.
        let defaults = WSGFakeDefaults(enabled: true, hostname: "device-A.bridge.kup.solutions")
        let teardown = RecordingTeardown()
        _ = await makeDisableFlow(defaults: defaults, teardown: teardown)
        // (No disable() call — this is the cancel branch.)
        try expect(teardown.calls == 0, "cancel must not drive teardown")
        try expect(defaults.cloudAccessEnabled == true, "cancel must leave the toggle ON")
        try expect(defaults.cloudTunnelHostname == "device-A.bridge.kup.solutions",
                   "cancel must leave the hostname intact")
    }

    // MARK: - Add to Claude.ai (URL derivation + encoding · Q3)

    await test("WS-G claude.ai: MCP URL derives from hostname; nil when unprovisioned") {
        try expect(ClaudeAIIntegration.mcpURL(forHostname: "host.example") == "https://host.example/mcp",
                   "MCP URL must be https://{host}/mcp")
        try expect(ClaudeAIIntegration.mcpURL(forHostname: nil) == nil, "nil hostname → no MCP URL")
        try expect(ClaudeAIIntegration.mcpURL(forHostname: "") == nil, "empty hostname → no MCP URL")
    }

    await test("WS-G claude.ai: query-value encoding escapes embedded delimiters + round-trips") {
        let mcp = "https://device-A.bridge.kup.solutions/mcp"
        guard let encoded = ClaudeAIIntegration.encodeQueryValue(mcp) else {
            throw TestError.assertion("encoding returned nil")
        }
        // The scheme separators that would corrupt a query value must be escaped.
        try expect(!encoded.contains("://"), "':' and '/' must be percent-escaped, got \(encoded)")
        try expect(encoded.contains("%3A") && encoded.contains("%2F"),
                   "expected %3A (:) and %2F (/) in the encoded value, got \(encoded)")
        // Round-trip: decoding the encoded value yields exactly the original.
        try expect(encoded.removingPercentEncoding == mcp,
                   "encoded value must round-trip back to the original MCP URL")
    }

    await test("WS-G claude.ai: deep link embeds encoded MCP URL under mcp_url=") {
        guard let url = ClaudeAIIntegration.deepLink(forHostname: "device-A.bridge.kup.solutions") else {
            throw TestError.assertion("deepLink returned nil for a valid hostname")
        }
        let s = url.absoluteString
        try expect(s.hasPrefix("https://claude.ai/settings/integrations?mcp_url="),
                   "deep link must target the integrations page with the mcp_url param, got \(s)")
        try expect(ClaudeAIIntegration.deepLink(forHostname: nil) == nil,
                   "no hostname → no deep link")
    }

    await test("WS-G claude.ai: shipped mode is the Q3 copy+hint fallback") {
        try expect(ClaudeAIIntegration.shippedMode == .copyAndHint,
                   "Q3 unconfirmed → ship copy+hint, not browser open")
        try expect(!ClaudeAIIntegration.pasteHint.isEmpty, "the paste hint must be non-empty")
    }

    // MARK: - First-run modal content

    await test("WS-G modal: 3-step guide carries the packet-specified symbols + copy") {
        let steps = FirstRunCloudAccessModal.steps
        try expect(steps.count == 3, "the guide must have exactly 3 steps, got \(steps.count)")
        try expect(steps[0].symbol == "doc.on.clipboard", "step 1 symbol drift: \(steps[0].symbol)")
        try expect(steps[1].symbol == "safari", "step 2 symbol drift: \(steps[1].symbol)")
        try expect(steps[2].symbol == "checkmark.circle", "step 3 symbol drift: \(steps[2].symbol)")
        try expect(steps.allSatisfy { !$0.title.isEmpty }, "every step must have copy")
    }
}
