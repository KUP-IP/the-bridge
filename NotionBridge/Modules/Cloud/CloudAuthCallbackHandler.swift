// CloudAuthCallbackHandler.swift — WS-F (Bridge Cloud Access · Enable flow)
// NotionBridge · Modules · Cloud
//
// The testable core of `AppDelegate.application(_:open:options:)`. Lives in
// the LIB target so the brittle parse → exchange → Keychain-write →
// Notification-post sequence is unit-tested headlessly; the AppDelegate
// method is a 3-line wrapper that hands the inbound URL to `handle(_:)`.
//
// Per the packet's hard rule, the token EXCHANGE goes through the injectable
// `CloudTokenExchanging` seam — unit tests inject a deterministic fake; no
// live WorkOS network call is ever made by the suite. The live exchange
// (real POST /oauth/token) requires PKT-810's tenant + WS-A and is the
// `URLSessionTokenExchange` production conformer.

import Foundation

/// Persists the exchanged WorkOS token. Production conformer writes the
/// Keychain (`KeychainManager`); tests inject an in-memory fake.
public protocol CloudTokenPersisting: Sendable {
    @discardableResult
    func persist(token: String) -> Bool
}

/// Production token sink — the real Keychain under `Key.cloudToken`.
public struct KeychainCloudTokenPersister: CloudTokenPersisting {
    public init() {}
    @discardableResult
    public func persist(token: String) -> Bool {
        KeychainManager.shared.saveCloudToken(token)
    }
}

/// Handles an inbound `bridge-auth://` callback URL end to end:
///   1. parse the URL into an auth code (or reject a malformed/denied one),
///   2. exchange the code for a WorkOS session token (injected seam),
///   3. persist the token (injected seam),
///   4. post `.cloudAuthCallbackReceived` with a `success: Bool` userInfo —
///      and NO token material — so the in-flight `EnableCloudAccessFlow`
///      advances (success) or fails (failure).
///
/// Returns whether the URL was a `bridge-auth` callback this handler owns
/// (so the AppDelegate can fall through for any other scheme). A malformed
/// `bridge-auth` URL is still "owned" (returns true) and posts a failure
/// notification.
public struct CloudAuthCallbackHandler: Sendable {
    private let config: WorkOSConfig
    private let exchange: CloudTokenExchanging
    private let persister: CloudTokenPersisting
    private let notificationCenter: NotificationCenter

    public init(
        config: WorkOSConfig = .resolved(),
        exchange: CloudTokenExchanging,
        persister: CloudTokenPersisting = KeychainCloudTokenPersister(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.config = config
        self.exchange = exchange
        self.persister = persister
        self.notificationCenter = notificationCenter
    }

    /// Returns `true` iff `url` is a `bridge-auth` callback this handler took
    /// responsibility for (kicking off the async exchange). A non-`bridge-auth`
    /// URL returns `false` and does nothing.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        switch CloudAuthCallback.parse(url) {
        case .code(let code):
            Task { await self.exchangeAndPost(code: code) }
            return true
        case .invalid(let reason):
            // Still a bridge-auth URL? Own it + post failure so the flow
            // fails fast rather than waiting out the 120s guard.
            if url.scheme?.lowercased() == "bridge-auth" {
                post(success: false)
                return true
            }
            _ = reason
            return false
        }
    }

    private func exchangeAndPost(code: String) async {
        do {
            let token = try await exchange.exchange(code: code, config: config)
            let ok = persister.persist(token: token)
            post(success: ok)
        } catch {
            post(success: false)
        }
    }

    private func post(success: Bool) {
        notificationCenter.post(
            name: .cloudAuthCallbackReceived,
            object: nil,
            userInfo: [cloudAuthSuccessKey: success]
        )
    }
}
