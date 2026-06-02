// EnableCloudAccessFlowTests.swift — WS-F (Bridge Cloud Access · Enable flow)
// NotionBridge · Tests (custom harness — no XCTest; see main.swift)
//
// Drives the WS-F Enable flow end-to-end against fakes — NO NSWorkspace, NO
// Keychain prompt, NO cloudflared, NO live WorkOS network, NO real clock.
// Full live end-to-end QA is gated on PKT-810 (operator WorkOS tenant) +
// WS-A (live Worker); this suite covers every transition + edge against the
// configurable base URL + mock seams the packet mandates.
//
// Coverage (DoD / QA checklist):
//   • bridge-auth:// callback URL parse (code / wrong-scheme / wrong-host /
//     missing-code / workos-error).
//   • WorkOS auth URL builder (env-configurable client id + redirect, query
//     shape) + config resolution / placeholder fallback.
//   • CloudAuthCallbackHandler: parse → exchange (mock) → persist (mock) →
//     posts .cloudAuthCallbackReceived (success + failure userInfo).
//   • Flow state machine all paths: idle→checkingAccount→signingIn→
//     provisioning→connected; token-present skip-to-provisioning;
//     auth-callback success/failure; auth cancellation timeout (120s) →
//     .failed(.authCancelled) + toggle reverts; provision timeout (30s) →
//     .failed(.provisionTimeout); provision failure; cancel().
//   • ProvisioningPresentation mapping for every state.

import Foundation
import NotionBridgeLib

// MARK: - Fakes (deterministic seams)

private final class FakeTokenStore: CloudTokenStore, @unchecked Sendable {
    let token: String?
    init(token: String?) { self.token = token }
}

private final class RecordingBrowser: AuthBrowserOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []
    var opened: [URL] { lock.lock(); defer { lock.unlock() }; return _opened }
    @discardableResult
    func open(_ url: URL) -> Bool {
        lock.lock(); _opened.append(url); lock.unlock(); return true
    }
}

private final class FakeFlowDefaults: CloudFlowDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = true        // toggle starts ON (user flipped it on)
    private var _hostname: String?
    var cloudAccessEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }
    var cloudTunnelHostname: String? {
        get { lock.lock(); defer { lock.unlock() }; return _hostname }
        set { lock.lock(); _hostname = newValue; lock.unlock() }
    }
}

/// Provisioner mock: scripts provision()/startTunnel() success/throw, and can
/// hang forever (to trigger the 30s guard) via `neverReturns`.
private final class FakeProvisioner: CloudProvisioning, @unchecked Sendable {
    let hostname: String
    let provisionThrows: Bool
    let tunnelThrows: Bool
    let neverReturns: Bool
    init(hostname: String = "device-A.bridge.kup.solutions",
         provisionThrows: Bool = false,
         tunnelThrows: Bool = false,
         neverReturns: Bool = false) {
        self.hostname = hostname
        self.provisionThrows = provisionThrows
        self.tunnelThrows = tunnelThrows
        self.neverReturns = neverReturns
    }
    func provision(baseURL: String) async throws -> String {
        if neverReturns {
            // Park until cancelled (the 30s guard wins the race).
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if provisionThrows { throw CloudError.provisionFailed }
        return hostname
    }
    func startTunnel() async throws {
        if tunnelThrows { throw CloudError.provisionFailed }
    }
}

/// Clock whose `sleep(seconds:)` never resolves on its own — so a timeout
/// only fires when the test explicitly `fire()`s it. Lets the 120s / 30s
/// guards be exercised deterministically without real time.
private final class ManualClock: CloudClock, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// A pending sleep that never resolves on its own — but IS cancellation
    /// aware (a real `Task.sleep`-backed clock throws `CancellationError` on
    /// cancel, so the fake must too, or a losing timeout-guard task would
    /// never terminate and the enclosing task group would hang).
    func sleep(seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                } else {
                    continuations[id] = cont
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock(); let c = continuations.removeValue(forKey: id); lock.unlock()
            c?.resume(throwing: CancellationError())
        }
    }
    /// Resolve all pending sleeps (i.e. fire the timeout).
    func fire() {
        lock.lock(); let conts = Array(continuations.values); continuations = [:]; lock.unlock()
        for c in conts { c.resume() }
    }
}

/// Clock that resolves every sleep immediately — used where we want the
/// timeout guard to lose the race (it fires instantly but the work already
/// completed) OR to drive an instant-timeout case.
private final class ImmediateClock: CloudClock, @unchecked Sendable {
    func sleep(seconds: Double) async throws { /* return at once */ }
}

private final class FakeTokenExchange: CloudTokenExchanging, @unchecked Sendable {
    let token: String
    let throwsError: Bool
    init(token: String = "tok_live_fake", throwsError: Bool = false) {
        self.token = token; self.throwsError = throwsError
    }
    func exchange(code: String, config: WorkOSConfig) async throws -> String {
        if throwsError { throw CloudError.tokenExchangeFailed }
        return token
    }
}

private final class FakePersister: CloudTokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var _persisted: [String] = []
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    var persisted: [String] { lock.lock(); defer { lock.unlock() }; return _persisted }
    @discardableResult
    func persist(token: String) -> Bool {
        lock.lock(); _persisted.append(token); lock.unlock(); return succeeds
    }
}

// MARK: - Helpers

/// Poll the @MainActor flow's state until `predicate` holds or a bounded
/// number of poll cycles elapse. The fast path is cooperative `Task.yield()`
/// (fakes resolve in a few turns); but a transition that resolves a
/// timeout-guard via a background-executor continuation + a `withTaskGroup`
/// cancellation hop (the provision-timeout path) can need more scheduler
/// progress than pure yields guarantee under load. So after a short burst of
/// yields each cycle interleaves a tiny real sleep — guaranteeing wall-clock
/// progress for the off-actor continuation — which removes the load-sensitive
/// flake without weakening any assertion. Total worst-case wait stays well
/// under a second.
@MainActor
private func waitFor(
    _ flow: EnableCloudAccessFlow,
    _ predicate: @escaping (EnableCloudAccessState) -> Bool,
    maxYields: Int = 2000
) async -> Bool {
    var i = 0
    while i < maxYields {
        if predicate(flow.state) { return true }
        if i < 64 {
            await Task.yield()
        } else {
            // ~0.5ms per cycle — guarantees the off-actor continuation/cancel
            // hop gets real time even when the executor is saturated.
            try? await Task.sleep(nanoseconds: 500_000)
        }
        i += 1
    }
    return predicate(flow.state)
}

private let wsfConfig = WorkOSConfig(
    baseURL: "https://api.workos.com",
    clientID: "client_test",
    redirectURI: "bridge-auth://callback"
)

func runEnableCloudAccessFlowTests() async {
    print("\n\u{2601} EnableCloudAccessFlow / WS-F Enable-flow Tests")

    // MARK: - Callback URL parsing

    await test("WS-F parse: valid bridge-auth://callback?code=… → .code") {
        let url = URL(string: "bridge-auth://callback?code=abc123")!
        try expect(CloudAuthCallback.parse(url) == .code("abc123"),
                   "expected .code(abc123), got \(CloudAuthCallback.parse(url))")
    }

    await test("WS-F parse: wrong scheme → .invalid") {
        let url = URL(string: "https://callback?code=abc")!
        if case .invalid = CloudAuthCallback.parse(url) {} else {
            throw TestError.assertion("expected .invalid for non-bridge-auth scheme")
        }
    }

    await test("WS-F parse: wrong host → .invalid") {
        let url = URL(string: "bridge-auth://wrong?code=abc")!
        if case .invalid = CloudAuthCallback.parse(url) {} else {
            throw TestError.assertion("expected .invalid for wrong host")
        }
    }

    await test("WS-F parse: missing code → .invalid") {
        let url = URL(string: "bridge-auth://callback")!
        if case .invalid = CloudAuthCallback.parse(url) {} else {
            throw TestError.assertion("expected .invalid for missing code")
        }
    }

    await test("WS-F parse: workos error param → .invalid") {
        let url = URL(string: "bridge-auth://callback?error=access_denied")!
        if case .invalid = CloudAuthCallback.parse(url) {} else {
            throw TestError.assertion("expected .invalid for error param")
        }
    }

    // MARK: - Auth URL builder + config

    await test("WS-F authURL: query carries client_id + redirect_uri + code response") {
        let url = WorkOSAuthURLBuilder.authorizationURL(for: wsfConfig)
        guard let url else { throw TestError.assertion("authorizationURL was nil") }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        func val(_ n: String) -> String? { items.first { $0.name == n }?.value }
        try expect(val("client_id") == "client_test", "client_id missing/wrong")
        try expect(val("redirect_uri") == "bridge-auth://callback", "redirect_uri missing/wrong")
        try expect(val("response_type") == "code", "response_type must be code")
        try expect(url.path.hasSuffix("/user_management/authorize"),
                   "unexpected auth path: \(url.path)")
    }

    await test("WS-F config: env override wins; absent falls back to placeholder") {
        let resolved = WorkOSConfig.resolved(environment: [
            "WORKOS_CLIENT_ID": "client_env",
        ])
        try expect(resolved.clientID == "client_env", "env client id should win")
        try expect(resolved.baseURL == WorkOSConfig.placeholder.baseURL,
                   "absent base URL should fall back to placeholder")
        let empty = WorkOSConfig.resolved(environment: [:])
        try expect(empty == .placeholder, "empty env should equal placeholder")
    }

    // MARK: - CloudAuthCallbackHandler

    await test("WS-F handler: valid code → exchanges, persists, posts success") {
        let center = NotificationCenter()
        let persister = FakePersister(succeeds: true)
        let handler = CloudAuthCallbackHandler(
            config: wsfConfig,
            exchange: FakeTokenExchange(token: "tok_X"),
            persister: persister,
            notificationCenter: center
        )
        let box = NotificationBox()
        let obs = center.addObserver(forName: .cloudAuthCallbackReceived, object: nil, queue: nil) { note in
            box.record(note.userInfo?[cloudAuthSuccessKey] as? Bool)
        }
        defer { center.removeObserver(obs) }

        let owned = handler.handle(URL(string: "bridge-auth://callback?code=c1")!)
        try expect(owned, "handler should own a bridge-auth callback URL")
        // Drive the async exchange to completion.
        var i = 0
        while box.value == nil && i < 2000 { await Task.yield(); i += 1 }
        try expect(box.value == true, "expected success=true notification, got \(String(describing: box.value))")
        try expect(persister.persisted == ["tok_X"], "token should be persisted exactly once")
    }

    await test("WS-F handler: exchange failure → posts success=false, persists nothing") {
        let center = NotificationCenter()
        let persister = FakePersister()
        let handler = CloudAuthCallbackHandler(
            config: wsfConfig,
            exchange: FakeTokenExchange(throwsError: true),
            persister: persister,
            notificationCenter: center
        )
        let box = NotificationBox()
        let obs = center.addObserver(forName: .cloudAuthCallbackReceived, object: nil, queue: nil) { note in
            box.record(note.userInfo?[cloudAuthSuccessKey] as? Bool)
        }
        defer { center.removeObserver(obs) }

        _ = handler.handle(URL(string: "bridge-auth://callback?code=c1")!)
        var i = 0
        while box.value == nil && i < 2000 { await Task.yield(); i += 1 }
        try expect(box.value == false, "expected success=false on exchange failure")
        try expect(persister.persisted.isEmpty, "no token should be persisted on failure")
    }

    await test("WS-F handler: non-bridge-auth URL is not owned") {
        let handler = CloudAuthCallbackHandler(exchange: FakeTokenExchange())
        let owned = handler.handle(URL(string: "https://example.com/callback?code=c1")!)
        try expect(!owned, "handler must not claim a non-bridge-auth URL")
    }

    await test("WS-F handler: malformed bridge-auth URL is owned + posts failure") {
        let center = NotificationCenter()
        let handler = CloudAuthCallbackHandler(
            config: wsfConfig, exchange: FakeTokenExchange(), notificationCenter: center
        )
        let box = NotificationBox()
        let obs = center.addObserver(forName: .cloudAuthCallbackReceived, object: nil, queue: nil) { note in
            box.record(note.userInfo?[cloudAuthSuccessKey] as? Bool)
        }
        defer { center.removeObserver(obs) }
        let owned = handler.handle(URL(string: "bridge-auth://callback")!) // no code
        try expect(owned, "a bridge-auth URL (even malformed) is owned")
        var i = 0
        while box.value == nil && i < 2000 { await Task.yield(); i += 1 }
        try expect(box.value == false, "malformed callback posts success=false")
    }

    // MARK: - State machine: token-present skip-to-provisioning

    await test("WS-F flow: Keychain token present → skips sign-in → .connected (no browser)") {
        await MainActor.run {} // hop on
        let browser = RecordingBrowser()
        let defaults = FakeFlowDefaults()
        let flow = await MainActor.run {
            EnableCloudAccessFlow(
                tokenStore: FakeTokenStore(token: "existing"),
                browser: browser,
                provisioner: FakeProvisioner(hostname: "host-1"),
                defaults: defaults,
                config: wsfConfig,
                provisionBaseURL: "https://mock.local",
                clock: ImmediateClock()
            )
        }
        await MainActor.run { flow.start() }
        let ok = await waitFor(flow) { $0 == .connected }
        try expect(ok, "expected .connected; got \(await MainActor.run { flow.state })")
        try expect(browser.opened.isEmpty, "browser must NOT open when a token is present")
        try expect(defaults.cloudTunnelHostname == "host-1", "hostname should be persisted on success")
        try expect(defaults.cloudAccessEnabled == true, "toggle stays ON on success")
    }

    // MARK: - State machine: full sign-in path

    await test("WS-F flow: no token → opens browser → .signingIn; callback → .provisioning → .connected") {
        let center = NotificationCenter()
        let browser = RecordingBrowser()
        let defaults = FakeFlowDefaults()
        let flow = await MainActor.run {
            EnableCloudAccessFlow(
                tokenStore: FakeTokenStore(token: nil),
                browser: browser,
                provisioner: FakeProvisioner(hostname: "host-2"),
                defaults: defaults,
                config: wsfConfig,
                provisionBaseURL: "https://mock.local",
                clock: ManualClock(),   // never auto-times-out
                notificationCenter: center
            )
        }
        await MainActor.run { flow.start() }
        let signing = await waitFor(flow) { $0 == .signingIn }
        try expect(signing, "expected .signingIn after start with no token")
        try expect(browser.opened.count == 1, "browser should open exactly once")
        // Simulate the AppDelegate callback (token already written).
        center.post(name: .cloudAuthCallbackReceived, object: nil,
                    userInfo: [cloudAuthSuccessKey: true])
        let connected = await waitFor(flow) { $0 == .connected }
        try expect(connected, "expected .connected after successful callback")
        try expect(defaults.cloudTunnelHostname == "host-2", "hostname persisted")
    }

    await test("WS-F flow: callback failure → .failed(.authFailed) → toggle reverts") {
        let center = NotificationCenter()
        let defaults = FakeFlowDefaults()
        let flow = await MainActor.run {
            EnableCloudAccessFlow(
                tokenStore: FakeTokenStore(token: nil),
                browser: RecordingBrowser(),
                provisioner: FakeProvisioner(),
                defaults: defaults,
                config: wsfConfig,
                provisionBaseURL: "https://mock.local",
                clock: ManualClock(),
                notificationCenter: center
            )
        }
        await MainActor.run { flow.start() }
        _ = await waitFor(flow) { $0 == .signingIn }
        center.post(name: .cloudAuthCallbackReceived, object: nil,
                    userInfo: [cloudAuthSuccessKey: false])
        let failed = await waitFor(flow) { $0 == .failed(.authFailed) }
        try expect(failed, "expected .failed(.authFailed)")
        try expect(defaults.cloudAccessEnabled == false, "toggle must revert to OFF on failure")
    }

    // MARK: - Auth cancellation timeout (120s)

    await test("WS-F flow: auth timeout (120s) → .failed(.authCancelled) → toggle reverts") {
        let clock = ManualClock()
        let defaults = FakeFlowDefaults()
        let flow = await MainActor.run {
            EnableCloudAccessFlow(
                tokenStore: FakeTokenStore(token: nil),
                browser: RecordingBrowser(),
                provisioner: FakeProvisioner(),
                defaults: defaults,
                config: wsfConfig,
                provisionBaseURL: "https://mock.local",
                clock: clock,
                notificationCenter: NotificationCenter()
            )
        }
        await MainActor.run { flow.start() }
        _ = await waitFor(flow) { $0 == .signingIn }
        clock.fire()  // the 120s guard elapses with no callback
        let failed = await waitFor(flow) { $0 == .failed(.authCancelled) }
        try expect(failed, "expected .failed(.authCancelled) on auth timeout")
        try expect(defaults.cloudAccessEnabled == false, "toggle reverts on auth timeout")
    }

    // MARK: - Provision timeout (30s)

    await test("WS-F flow: provision timeout (30s) → .failed(.provisionTimeout)") {
        let clock = ManualClock()
        let defaults = FakeFlowDefaults()
        let flow = await MainActor.run {
            EnableCloudAccessFlow(
                tokenStore: FakeTokenStore(token: "existing"),  // straight to provisioning
                browser: RecordingBrowser(),
                provisioner: FakeProvisioner(neverReturns: true),
                defaults: defaults,
                config: wsfConfig,
                provisionBaseURL: "https://mock.local",
                clock: clock
            )
        }
        await MainActor.run { flow.start() }
        let provisioning = await waitFor(flow) { $0 == .provisioning }
        try expect(provisioning, "expected .provisioning (token present)")
        clock.fire()  // the 30s provision guard elapses
        let failed = await waitFor(flow) { $0 == .failed(.provisionTimeout) }
        try expect(failed, "expected .failed(.provisionTimeout)")
        try expect(defaults.cloudAccessEnabled == false, "toggle reverts on provision timeout")
    }

    await test("WS-F flow: provision() throws → .failed(.provisionFailed)") {
        let defaults = FakeFlowDefaults()
        let flow = await MainActor.run {
            EnableCloudAccessFlow(
                tokenStore: FakeTokenStore(token: "existing"),
                browser: RecordingBrowser(),
                provisioner: FakeProvisioner(provisionThrows: true),
                defaults: defaults,
                config: wsfConfig,
                provisionBaseURL: "https://mock.local",
                clock: ManualClock()  // guard never fires; the throw wins
            )
        }
        await MainActor.run { flow.start() }
        let failed = await waitFor(flow) { if case .failed = $0 { return true }; return false }
        try expect(failed, "expected .failed when provision throws")
        let state = await MainActor.run { flow.state }
        try expect(state == .failed(.provisionFailed), "expected .provisionFailed, got \(state)")
    }

    // MARK: - cancel() (toggle OFF mid-flow)

    await test("WS-F flow: cancel() during sign-in → back to .idle, no .failed") {
        let flow = await MainActor.run {
            EnableCloudAccessFlow(
                tokenStore: FakeTokenStore(token: nil),
                browser: RecordingBrowser(),
                provisioner: FakeProvisioner(),
                defaults: FakeFlowDefaults(),
                config: wsfConfig,
                provisionBaseURL: "https://mock.local",
                clock: ManualClock(),
                notificationCenter: NotificationCenter()
            )
        }
        await MainActor.run { flow.start() }
        _ = await waitFor(flow) { $0 == .signingIn }
        await MainActor.run { flow.cancel() }
        let idle = await MainActor.run { flow.state == .idle }
        try expect(idle, "cancel() should return the flow to .idle")
    }

    await test("WS-F flow: start() is idempotent while signing in (no second browser open)") {
        let browser = RecordingBrowser()
        let flow = await MainActor.run {
            EnableCloudAccessFlow(
                tokenStore: FakeTokenStore(token: nil),
                browser: browser,
                provisioner: FakeProvisioner(),
                defaults: FakeFlowDefaults(),
                config: wsfConfig,
                provisionBaseURL: "https://mock.local",
                clock: ManualClock(),
                notificationCenter: NotificationCenter()
            )
        }
        await MainActor.run { flow.start() }
        _ = await waitFor(flow) { $0 == .signingIn }
        await MainActor.run { flow.start() }  // second call — should be ignored
        try expect(browser.opened.count == 1, "second start() must not reopen the browser")
        await MainActor.run { flow.cancel() }  // tear down the in-flight auth wait
    }

    // MARK: - ProvisioningPresentation mapping

    await test("WS-F presentation: every state maps to the spec'd UI") {
        let idle = ProvisioningPresentation.make(for: .idle)
        try expect(idle.indicator == .none && !idle.showsRetry && !idle.showsURL,
                   ".idle should show nothing")

        let checking = ProvisioningPresentation.make(for: .checkingAccount)
        try expect(checking.indicator == .spinner, ".checkingAccount → spinner")

        let signing = ProvisioningPresentation.make(for: .signingIn)
        try expect(signing.indicator == .browser && signing.title.contains("browser"),
                   ".signingIn → browser affordance + copy")

        let prov = ProvisioningPresentation.make(for: .provisioning)
        try expect(prov.indicator == .spinner && prov.title.contains("Setting up"),
                   ".provisioning → spinner + 'Setting up your Bridge…'")

        let connected = ProvisioningPresentation.make(for: .connected)
        try expect(connected.indicator == .success && connected.showsURL && connected.title == "Connected",
                   ".connected → checkmark + URL + 'Connected'")

        let failed = ProvisioningPresentation.make(for: .failed(.provisionTimeout))
        try expect(failed.indicator == .failure && failed.showsRetry,
                   ".failed → error glyph + Retry")
        try expect(failed.title == CloudError.provisionTimeout.userMessage,
                   ".failed title should surface the error message")
    }

    // MARK: - BridgeCloudManager provisioning seam

    await test("WS-F manager: provision() returns a hostname; startTunnel() brings state online") {
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: true, health: .healthy),
            passkeyGate: FakePasskeyGate(outcome: .approved),
            node: LocalNodeContext(ownerID: "owner-1", deviceID: "device-A")
        )
        let host = try await mgr.provision(baseURL: "https://mock.local")
        try expect(host.contains("device-A"), "hostname should derive from the node device id: \(host)")
        try await mgr.startTunnel()
        let state = await mgr.state
        try expect(state == .online, "startTunnel() with a healthy fake tunnel → .online, got \(state)")
    }
}

/// Thread-safe one-shot box for capturing a notification payload from a
/// non-main observer queue.
private final class NotificationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return _value }
    func record(_ v: Bool?) { lock.lock(); if _value == nil { _value = v }; lock.unlock() }
}
