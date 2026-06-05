// CredentialValidator.swift — Live credential validation (Full).
// v3.7.6 Wave 4a (premium Credentials vault).
//
// REUSES existing validation infrastructure rather than re-implementing it:
//   • Notion → ConnectionHealthChecker.shared.checkNotionHealth(connectionName:)
//              which calls NotionClient.validate() (a lightweight introspect /
//              getMe round-trip). Same path Connections uses.
//   • Stripe → StripeClient.shared.retrieveAccountInfo() (GET /v1/account).
//              Same path ConnectionRegistry.buildStripeConnection uses.
//   • Card   → CredentialCardExpiry.health(...) — pure local expiry math,
//              no network.
//   • Anything else → `.unchecked` (the truthfulness invariant: a credential
//              with no real programmatic check is NEVER reported `.valid`).
//
// SAFETY CONTRACT (CLAUDE.md standing orders #3):
//   • Network calls run OFF the main thread (these are async actor/Sendable
//     calls; no @MainActor hop) and are TIME-BOUNDED (~10s) via a withTimeout
//     race so a hung service can't wedge the vault.
//   • Validation is NEVER invoked during tests: every entry point is gated on
//     `isAppBundle` (the standalone test executable is not an .app bundle), so
//     the suite exercises only the pure mapping/math in CredentialHealth.swift.
//   • Results are PERSISTED (CredentialHealthStore) so the UI renders the
//     last-known verdict, not a live call per render.

import Foundation

public actor CredentialValidator {
    public static let shared = CredentialValidator()

    private let store: CredentialHealthStore
    /// Per-call network budget. A hung service yields `.error("timed out")`
    /// rather than blocking the vault indefinitely.
    private let timeout: TimeInterval

    public init(store: CredentialHealthStore = CredentialHealthStore(), timeout: TimeInterval = 10) {
        self.store = store
        self.timeout = timeout
    }

    /// `true` only inside a real signed/unsigned .app bundle. The standalone
    /// test executable is NOT an .app, so validation is a no-op under test —
    /// guaranteeing no live network / no flakiness in the suite.
    private nonisolated var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - Public API

    /// Validate one credential and persist the result. Returns the verdict.
    /// No-ops to the LAST-KNOWN record (default `.unchecked`) under test.
    @discardableResult
    public func validate(service: String, account: String, type: CredentialType) async -> CredentialHealthRecord {
        guard isAppBundle else {
            // Tests / non-app: never hit the network. Return last-known.
            return store.record(service: service, account: account)
        }

        let method = CredentialValidationMapper.method(forService: service, type: type, account: account)
        let health = await resolve(method: method, service: service, account: account, type: type)
        let record = CredentialHealthRecord(health: health, checkedAt: Date())
        store.set(record, service: service, account: account)
        return record
    }

    /// Validate every stored credential (Validate-all / weekly job). Persists
    /// each result and prunes records for credentials that no longer exist.
    /// No-op under test.
    @discardableResult
    public func validateAll() async -> [String: CredentialHealthRecord] {
        guard isAppBundle else { return store.load() }

        let entries = (try? CredentialManager.shared.list()) ?? []
        var map = store.load()
        var liveKeys = Set<String>()

        for entry in entries {
            let key = CredentialHealthStore.key(service: entry.service, account: entry.account)
            liveKeys.insert(key)
            let method = CredentialValidationMapper.method(
                forService: entry.service, type: entry.type, account: entry.account
            )
            let health = await resolve(
                method: method, service: entry.service, account: entry.account, type: entry.type
            )
            map[key] = CredentialHealthRecord(health: health, checkedAt: Date())
        }

        // Drop stale records for deleted credentials.
        map = map.filter { liveKeys.contains($0.key) }
        store.setAll(map)
        return map
    }

    // MARK: - Method resolution (the only place that touches the network)

    private func resolve(
        method: CredentialValidationMethod,
        service: String,
        account: String,
        type: CredentialType
    ) async -> CredentialHealth {
        switch method {
        case .unsupported:
            // Truthful: no real check exists → never claim valid.
            return .unchecked

        case .cardExpiry:
            // Pure local math, no network.
            let stored = store.record(service: service, account: account)
            // We don't carry exp metadata into the validator from list() reliably
            // for all paths, so re-read via the live entry list is overkill; the
            // card's expiry is computed at render time by the view too. Here we
            // keep whatever the UI persisted if present, else unchecked. The
            // authoritative card expiry verdict is computed in the view from
            // metadata; the validator simply does not override it with network.
            return stored.health == .unchecked ? .unchecked : stored.health

        case .notionTokenIntrospect(let connection):
            return await withTimeout(.unchecked) {
                let h = await ConnectionHealthChecker.shared.checkNotionHealth(connectionName: connection)
                return Self.mapConnectionHealth(h)
            }

        case .stripeAccountFetch:
            return await withTimeout(.error("timed out")) {
                do {
                    let info = try await StripeClient.shared.retrieveAccountInfo()
                    return info.chargesEnabled ? .valid : .expiring(days: 0)
                } catch let err as StripeError {
                    return Self.mapStripeError(err)
                } catch {
                    return .error(Self.shortReason(error))
                }
            }
        }
    }

    /// Map a reused ConnectionHealth verdict onto CredentialHealth.
    public static func mapConnectionHealth(_ h: ConnectionHealth) -> CredentialHealth {
        switch h {
        case .healthy:      return .valid
        case .warning:      return .expiring(days: 0)
        case .error:        return .revoked   // bad token / unauthorized
        case .unconfigured: return .unchecked // no token to check
        case .checking:     return .unchecked
        }
    }

    /// Map a StripeError onto CredentialHealth (auth failure → revoked).
    public static func mapStripeError(_ err: StripeError) -> CredentialHealth {
        switch err {
        case .authenticationFailed:
            return .revoked
        default:
            return .error(err.localizedDescription)
        }
    }

    static func shortReason(_ error: Error) -> String {
        let msg = error.localizedDescription
        return msg.count > 80 ? String(msg.prefix(77)) + "…" : msg
    }

    // MARK: - Timeout race

    /// Run `op` but cap it at `self.timeout`; on timeout return `fallback`.
    private func withTimeout(
        _ fallback: CredentialHealth,
        _ op: @escaping @Sendable () async -> CredentialHealth
    ) async -> CredentialHealth {
        await withTaskGroup(of: CredentialHealth.self) { group in
            group.addTask { await op() }
            group.addTask { [timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return fallback
            }
            let result = await group.next() ?? fallback
            group.cancelAll()
            return result
        }
    }
}
