// EnableCloudAccessFlow.swift — WS-F (Bridge Cloud Access · Enable flow)
// NotionBridge · Modules · Cloud
//
// The @Observable state machine that drives the "Enable Cloud Access"
// toggle from OFF to a live, connected cloud node. It is the single source
// of truth `ProvisioningProgressView` renders and `RemoteAccessView` binds
// the toggle to.
//
//   .idle → .checkingAccount → .signingIn → .provisioning → .connected
//                                                          ↘ .failed(error)
//
//   • .checkingAccount — consult the Keychain for an existing WorkOS token.
//       Present  → skip the browser, go straight to .provisioning.
//       Absent   → .signingIn.
//   • .signingIn      — open the WorkOS auth URL in the system browser
//       (Q1 lock: system browser + bridge-auth:// callback, no WKWebView),
//       then await `.cloudAuthCallbackReceived`. A 120s cancellation guard
//       (user closed the browser without finishing) → .failed(.authCancelled).
//   • .provisioning   — BridgeCloudManager.provision() + startTunnel(),
//       under a 30s timeout → .failed(.provisionTimeout). Runs on the main
//       actor (the whole class is @MainActor).
//   • .connected      — persist the tunnel hostname to BridgeDefaults and
//       leave the toggle ON.
//   • .failed(error)  — revert BridgeDefaults.cloudAccessEnabled to false so
//       the toggle snaps back OFF; surface the error for the Retry button.
//
// EVERY external dependency is injected behind a Sendable seam so the whole
// machine is unit-testable headlessly — no NSWorkspace, no Keychain prompt,
// no cloudflared, no live WorkOS network, no real clock. The production
// wiring (real Keychain, NSWorkspace.open, the shared BridgeCloudManager,
// UserDefaults) is assembled in `EnableCloudAccessFlow.live()`.

import Foundation
import Observation

// MARK: - Errors

/// Why the Enable flow ended in `.failed`. Each maps to a user-facing line
/// in `ProvisioningProgressView`.
public enum CloudError: Error, Sendable, Equatable {
    /// No `.cloudAuthCallbackReceived` arrived within the 120s window — the
    /// user dismissed the browser without completing sign-in.
    case authCancelled
    /// The auth callback arrived but the code exchange reported failure.
    case authFailed
    /// The WorkOS authorization URL could not be built (misconfigured tenant).
    case authURLUnavailable
    /// The code→token exchange (POST /oauth/token) failed.
    case tokenExchangeFailed
    /// provision()/startTunnel() did not complete within the 30s window.
    case provisionTimeout
    /// provision()/startTunnel() threw.
    case provisionFailed

    public var userMessage: String {
        switch self {
        case .authCancelled:     return "Sign-in was cancelled."
        case .authFailed:        return "Sign-in did not complete."
        case .authURLUnavailable: return "Cloud sign-in is not configured."
        case .tokenExchangeFailed: return "Could not complete sign-in."
        case .provisionTimeout:  return "Setting up your Bridge timed out."
        case .provisionFailed:   return "Could not set up your Bridge."
        }
    }
}

// MARK: - States

/// The Enable-flow state. `Equatable` for deterministic test assertions;
/// `.failed` compares on the wrapped `CloudError`.
public enum EnableCloudAccessState: Sendable, Equatable {
    case idle
    case checkingAccount
    case signingIn
    case provisioning
    case connected
    case failed(CloudError)
}

// MARK: - Injectable seams

/// The Keychain-token half of the flow's dependencies. Production conformer
/// wraps `KeychainManager`; tests inject an in-memory fake (no Keychain
/// prompt). The flow only ever *reads* — the *write* happens in AppDelegate
/// on the callback.
public protocol CloudTokenStore: Sendable {
    var token: String? { get }
}

/// Opens the system browser for WorkOS sign-in. Production conformer calls
/// `NSWorkspace.shared.open`; tests inject a fake that records the URL
/// without opening anything.
public protocol AuthBrowserOpening: Sendable {
    /// Returns whether the URL was handed to the system to open.
    @discardableResult
    func open(_ url: URL) -> Bool
}

/// The toggle-backing store the flow reverts on `.failed` and writes the
/// hostname into on success. Production conformer wraps `UserDefaults`
/// (`BridgeDefaults` keys); tests inject an in-memory fake.
public protocol CloudFlowDefaults: AnyObject, Sendable {
    var cloudAccessEnabled: Bool { get set }
    var cloudTunnelHostname: String? { get set }
}

/// Async-sleep seam so the 120s / 30s timeouts are deterministic in tests
/// (the fake resolves instantly or never, on demand). Production uses
/// `Task.sleep`.
public protocol CloudClock: Sendable {
    /// Sleep for `seconds`, or throw `CancellationError` if cancelled.
    func sleep(seconds: Double) async throws
}

/// Production clock backed by `Task.sleep`.
public struct TaskClock: CloudClock {
    public init() {}
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Flow

@MainActor
@Observable
public final class EnableCloudAccessFlow {

    /// The current state — the single source of truth the UI renders.
    public private(set) var state: EnableCloudAccessState = .idle

    // Injected dependencies (all seams; production values via `.live()`).
    private let tokenStore: CloudTokenStore
    private let browser: AuthBrowserOpening
    private let provisioner: CloudProvisioning
    private let defaults: CloudFlowDefaults
    private let config: WorkOSConfig
    /// Configurable provisioning base URL (mocks in tests; PKT-810/WS-A live).
    private let provisionBaseURL: String
    private let clock: CloudClock
    private let authTimeout: Double
    private let provisionTimeout: Double
    private let notificationCenter: NotificationCenter

    /// The in-flight auth callback observer token, removed when sign-in
    /// resolves (or the flow is cancelled).
    private var authObserver: NSObjectProtocol?
    /// The 120s auth-cancellation guard task.
    private var authTimeoutTask: Task<Void, Never>?
    /// The provisioning task (30s-guarded), retained so cancellation works.
    private var provisionTask: Task<Void, Never>?
    /// Continuation the auth-callback notification resumes.
    private var authContinuation: CheckedContinuation<Bool, Never>?

    public init(
        tokenStore: CloudTokenStore,
        browser: AuthBrowserOpening,
        provisioner: CloudProvisioning,
        defaults: CloudFlowDefaults,
        config: WorkOSConfig = .resolved(),
        provisionBaseURL: String,
        clock: CloudClock = TaskClock(),
        authTimeout: Double = 120,
        provisionTimeout: Double = 30,
        notificationCenter: NotificationCenter = .default
    ) {
        self.tokenStore = tokenStore
        self.browser = browser
        self.provisioner = provisioner
        self.defaults = defaults
        self.config = config
        self.provisionBaseURL = provisionBaseURL
        self.clock = clock
        self.authTimeout = authTimeout
        self.provisionTimeout = provisionTimeout
        self.notificationCenter = notificationCenter
    }

    // MARK: - Entry point

    /// Begin (or retry) the Enable flow. Idempotent against a run already in
    /// flight (a second `start()` while signing-in/provisioning is ignored).
    public func start() {
        switch state {
        case .signingIn, .provisioning, .checkingAccount:
            return // already running
        case .idle, .connected, .failed:
            break // (re)start — .failed is the Retry path
        }

        state = .checkingAccount

        // Keychain token present → skip the browser sign-in step entirely.
        if let token = tokenStore.token, !token.isEmpty {
            beginProvisioning()
            return
        }

        beginSignIn()
    }

    /// Cancel an in-flight run (toggle flipped OFF mid-flow). Tears down the
    /// observer + guards and returns to `.idle` WITHOUT marking `.failed`
    /// (an explicit user cancel is not an error to surface).
    public func cancel() {
        teardownAuthWait()
        provisionTask?.cancel()
        provisionTask = nil
        // WS-D (PKT-921): an explicit OFF toggle must also persist the master
        // state and stop the heartbeat / deregister `bridge_status`. (The flow
        // never set `.failed` here, so without this the running ServerManager
        // would keep a stale heartbeat after a mid-flow cancel.)
        defaults.cloudAccessEnabled = false
        postCloudAccessEnabledDidChange(false)
        state = .idle
    }

    // MARK: - .signingIn

    private func beginSignIn() {
        guard let url = WorkOSAuthURLBuilder.authorizationURL(for: config) else {
            fail(.authURLUnavailable)
            return
        }
        state = .signingIn

        // Observe the AppDelegate callback (code already exchanged + token
        // written to Keychain by the time this fires). The userInfo success
        // flag distinguishes a real sign-in from a WorkOS error callback.
        authObserver = notificationCenter.addObserver(
            forName: .cloudAuthCallbackReceived,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let ok = (note.userInfo?[cloudAuthSuccessKey] as? Bool) ?? true
            MainActor.assumeIsolated { self?.authCallbackArrived(success: ok) }
        }

        // 120s cancellation guard.
        authTimeoutTask = Task { [weak self, authTimeout, clock] in
            try? await clock.sleep(seconds: authTimeout)
            if Task.isCancelled { return }
            await MainActor.run { self?.authTimedOut() }
        }

        browser.open(url)
    }

    private func authCallbackArrived(success: Bool) {
        guard state == .signingIn else { return }
        teardownAuthWait()
        if success {
            beginProvisioning()
        } else {
            fail(.authFailed)
        }
    }

    private func authTimedOut() {
        guard state == .signingIn else { return }
        teardownAuthWait()
        fail(.authCancelled)
    }

    private func teardownAuthWait() {
        if let obs = authObserver {
            notificationCenter.removeObserver(obs)
            authObserver = nil
        }
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
    }

    // MARK: - .provisioning

    private func beginProvisioning() {
        state = .provisioning
        provisionTask = Task { [weak self] in
            await self?.runProvisioning()
        }
    }

    private func runProvisioning() async {
        // Race the provision work against the 30s guard. Whichever finishes
        // first wins; the loser is cancelled.
        let result: Result<String, CloudError> = await withTaskGroup(
            of: Result<String, CloudError>?.self
        ) { [provisioner, provisionBaseURL, clock, provisionTimeout] group in
            group.addTask {
                do {
                    let host = try await provisioner.provision(baseURL: provisionBaseURL)
                    try await provisioner.startTunnel()
                    return .success(host)
                } catch is CancellationError {
                    return nil
                } catch {
                    return .failure(.provisionFailed)
                }
            }
            group.addTask {
                do {
                    try await clock.sleep(seconds: provisionTimeout)
                    return .failure(.provisionTimeout)
                } catch {
                    return nil // cancelled by the winner
                }
            }
            // First non-nil result wins.
            var outcome: Result<String, CloudError> = .failure(.provisionFailed)
            for await value in group {
                if let value {
                    outcome = value
                    group.cancelAll()
                    break
                }
            }
            return outcome
        }

        if Task.isCancelled { return }
        switch result {
        case .success(let host):
            succeed(hostname: host)
        case .failure(let err):
            fail(err)
        }
    }

    // MARK: - Terminal transitions

    private func succeed(hostname: String) {
        defaults.cloudTunnelHostname = hostname
        defaults.cloudAccessEnabled = true
        // WS-D (PKT-921): tell the running ServerManager to start the heartbeat
        // + register `bridge_status` now that cloud access is ON (no relaunch).
        postCloudAccessEnabledDidChange(true)
        state = .connected
    }

    private func fail(_ error: CloudError) {
        // Revert the toggle to OFF so the switch snaps back (DoD).
        defaults.cloudAccessEnabled = false
        // WS-D (PKT-921): cloud access reverted to OFF — stop the heartbeat +
        // deregister `bridge_status`.
        postCloudAccessEnabledDidChange(false)
        state = .failed(error)
    }

    /// WS-D (PKT-921): notify observers (AppDelegate → ServerManager) that the
    /// `cloudAccessEnabled` master state changed, so the heartbeat +
    /// `bridge_status` registration track the toggle live.
    private func postCloudAccessEnabledDidChange(_ enabled: Bool) {
        notificationCenter.post(
            name: .cloudAccessEnabledDidChange,
            object: nil,
            userInfo: [cloudAccessEnabledKey: enabled]
        )
    }
}
