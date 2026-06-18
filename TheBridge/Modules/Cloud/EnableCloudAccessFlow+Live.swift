// EnableCloudAccessFlow+Live.swift — WS-F (Bridge Cloud Access · Enable flow)
// TheBridge · Modules · Cloud
//
// Production conformers for the Enable-flow seams + the `.live()` factory
// that assembles the real machine: the real Keychain, NSWorkspace browser
// open, UserDefaults-backed toggle, and a caller-supplied provisioner +
// provisioning base URL (configurable so the live Worker endpoint, WS-A, is
// the only place a real network call ever appears — gated on PKT-810).
//
// None of this is exercised by the unit suite: the tests inject the fakes
// directly. This file is the wiring `RemoteAccessView` uses at runtime.

import Foundation
import AppKit

// MARK: - Production: Keychain-backed token store

/// Reads the WorkOS cloud token from the real Keychain.
public struct KeychainCloudTokenStore: CloudTokenStore {
    public init() {}
    public var token: String? { KeychainManager.shared.cloudToken }
}

// MARK: - Production: system-browser opener (Q1 lock)

/// Opens the WorkOS auth URL in the user's default browser via NSWorkspace.
public struct SystemBrowserOpener: AuthBrowserOpening {
    public init() {}
    @discardableResult
    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Production: UserDefaults-backed flow defaults

/// Reads/writes the Enable-flow's two `BridgeDefaults` keys against the real
/// `UserDefaults`.
public final class UserDefaultsCloudFlowDefaults: CloudFlowDefaults, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var cloudAccessEnabled: Bool {
        get { defaults.bool(forKey: BridgeDefaults.cloudAccessEnabled) }
        set { defaults.set(newValue, forKey: BridgeDefaults.cloudAccessEnabled) }
    }

    public var cloudTunnelHostname: String? {
        get { defaults.string(forKey: BridgeDefaults.cloudTunnelHostname) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: BridgeDefaults.cloudTunnelHostname)
            } else {
                defaults.removeObject(forKey: BridgeDefaults.cloudTunnelHostname)
            }
        }
    }
}

// MARK: - .live() factory

@MainActor
public extension EnableCloudAccessFlow {
    /// Assemble the production Enable flow. `provisioner` is the live
    /// `BridgeCloudManager` (on `main` per the packet); `provisionBaseURL`
    /// is the WS-A Worker endpoint (configurable — defaults to the env var
    /// `BRIDGE_CLOUD_BASE_URL` or a documented placeholder so the build runs
    /// before WS-A is live).
    static func live(
        provisioner: CloudProvisioning,
        provisionBaseURL: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EnableCloudAccessFlow {
        let baseURL = provisionBaseURL
            ?? environment["BRIDGE_CLOUD_BASE_URL"]
            ?? "https://cloud.kup.solutions"
        return EnableCloudAccessFlow(
            tokenStore: KeychainCloudTokenStore(),
            browser: SystemBrowserOpener(),
            provisioner: provisioner,
            defaults: UserDefaultsCloudFlowDefaults(),
            // WS-G: the production provisioner (BridgeCloudManager) is also the
            // teardown seam — disable() stops the tunnel. Non-teardown
            // provisioners simply don't supply one (Disable becomes a
            // state/defaults clear with no tunnel stop).
            teardown: provisioner as? CloudTeardown,
            config: .resolved(environment: environment),
            provisionBaseURL: baseURL
        )
    }
}
