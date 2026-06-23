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

// MARK: - Provision base-URL resolution (Packet E W2)

public extension EnableCloudAccessFlow {
    /// config.json key for the durable cloud control-plane base URL.
    nonisolated static var provisionBaseURLConfigKey: String { "cloudBaseURL" }

    /// Documented placeholder used when no layer supplies a base URL, so the
    /// build runs before the WS-A Worker endpoint is live.
    nonisolated static var defaultProvisionBaseURL: String { "https://cloud.kup.solutions" }

    /// Resolves the WS-A Worker provisioning base URL with a durable precedence
    /// (Packet E W2, mirroring `ProtectedResourceMetadataProvider`): explicit
    /// `arg` → `BRIDGE_CLOUD_BASE_URL` env → config.json (`cloudBaseURL`,
    /// per-install) → `defaultProvisionBaseURL`. Blank layers are skipped. No
    /// build-baked layer (the control-plane host is a deployment choice, not a
    /// binary constant). Pure + nonisolated so the precedence is unit-testable
    /// off the `@MainActor` `.live()` factory; `.live()` delegates here, so the
    /// two cannot drift.
    nonisolated static func resolvedProvisionBaseURL(
        arg: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: (String) -> String? = { ConfigManager.shared.value(forKey: $0) as? String }
    ) -> String {
        arg?.cloudNonEmpty
            ?? environment["BRIDGE_CLOUD_BASE_URL"]?.cloudNonEmpty
            ?? config(provisionBaseURLConfigKey)?.cloudNonEmpty
            ?? defaultProvisionBaseURL
    }
}

// MARK: - .live() factory

@MainActor
public extension EnableCloudAccessFlow {
    /// Assemble the production Enable flow. `provisioner` is the live
    /// `BridgeCloudManager` (on `main` per the packet); `provisionBaseURL`
    /// is the WS-A Worker endpoint, resolved with a durable precedence
    /// (Packet E W2, mirroring `ProtectedResourceMetadataProvider`):
    /// explicit arg → `BRIDGE_CLOUD_BASE_URL` env → config.json
    /// (`cloudBaseURL`, per-install) → a documented placeholder so the build
    /// runs before WS-A is live. No build-baked layer: the cloud control-plane
    /// host is an operator/deployment choice, not a binary constant.
    /// `configValue` is injectable so this stays pure under test.
    static func live(
        provisioner: CloudProvisioning,
        provisionBaseURL: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configValue: (String) -> String? = { ConfigManager.shared.value(forKey: $0) as? String }
    ) -> EnableCloudAccessFlow {
        let baseURL = resolvedProvisionBaseURL(
            arg: provisionBaseURL, environment: environment, config: configValue)
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

// MARK: - Small private helpers

private extension String {
    /// Trimmed value, or `nil` when blank — so a blank layer is skipped in
    /// the `arg ?? env ?? config` precedence chain (Packet E W2 resolution).
    var cloudNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
