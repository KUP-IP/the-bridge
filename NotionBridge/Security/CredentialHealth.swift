// CredentialHealth.swift — Truthful per-credential validation state.
// v3.7.6 Wave 4a (premium Credentials vault).
//
// SSOT for "what does Bridge actually know about this credential's validity?".
// The vault UI renders the LAST-KNOWN result persisted here (NOT a live call
// per render); a live round-trip is performed only by `CredentialValidator`
// (off-main, time-bounded, never during tests) on explicit Revalidate /
// Validate-all / the weekly auto-validate job.
//
// TRUTHFULNESS INVARIANT (non-negotiable, see CLAUDE.md standing orders):
//   A credential that has NOT been validated, or that maps to NO real
//   programmatic validation method, is `.unchecked` — NEVER `.valid`. The only
//   way to reach `.valid` is a real successful round-trip against the service.
//
// This file is PURE (no network, no Keychain writes): the model, the
// service→method mapping, the health→badge-tone mapping, the persistence
// round-trip, the Touch-ID-gate decision helper, and the weekly-due decision
// helper. The live calls live in CredentialValidator.swift. Keeping the logic
// here pure is what lets the test suite cover it with zero flakiness / no live
// network.

import Foundation

// MARK: - CredentialHealth

/// The validation verdict for a single credential. `Equatable` so the UI and
/// tests can compare; `Codable` so it round-trips through the persistence store.
public enum CredentialHealth: Equatable, Sendable, Codable {
    /// A real validation round-trip succeeded.
    case valid
    /// Valid but expiring within `days` (e.g. a card nearing its expiry month).
    case expiring(days: Int)
    /// The service reported the credential as revoked / unauthorized (e.g. 401).
    case revoked
    /// Never validated, OR no programmatic validation method exists for this
    /// service. This is the TRUTHFUL default — never silently "Valid".
    case unchecked
    /// A validation attempt failed for a non-auth reason (network, timeout,
    /// malformed response). Carries a short human reason.
    case error(String)
}

// MARK: - Badge tone

/// The design's badge tones. Mapped 1:1 onto BridgeTokens signal colors by the
/// view layer (ok→emerald, warn→amber, bad→red, neutral→muted).
public enum CredentialBadgeTone: String, Equatable, Sendable {
    case ok       // valid
    case warn     // expiring
    case bad      // revoked / error
    case neutral  // unchecked
}

public extension CredentialHealth {
    /// Map a health verdict to a design badge tone. Pure + total.
    var badgeTone: CredentialBadgeTone {
        switch self {
        case .valid:        return .ok
        case .expiring:     return .warn
        case .revoked:      return .bad
        case .error:        return .bad
        case .unchecked:    return .neutral
        }
    }

    /// Short status label for the badge (truthful — no fabricated "Valid").
    var badgeLabel: String {
        switch self {
        case .valid:               return "Valid"
        case .expiring(let days):  return days <= 0 ? "Expired" : "Expires in \(days)d"
        case .revoked:             return "Revoked"
        case .unchecked:           return "Unchecked"
        case .error:               return "Check failed"
        }
    }

    /// Whether this verdict counts toward the hero "attention" stat
    /// (revoked + expiring + error). `unchecked` and `valid` do NOT.
    var needsAttention: Bool {
        switch self {
        case .revoked, .expiring, .error: return true
        case .valid, .unchecked:          return false
        }
    }

    /// Whether the row's primary action should become "Reconnect" (re-auth)
    /// rather than "Rotate" — per the design, revoked/invalid creds reconnect.
    var requiresReconnect: Bool {
        switch self {
        case .revoked, .error: return true
        case .valid, .expiring, .unchecked: return false
        }
    }
}

// MARK: - CredentialHealthRecord

/// A persisted last-known result for one credential: the verdict + when it was
/// checked. `checkedAt == nil` means "never checked" (paired with `.unchecked`).
public struct CredentialHealthRecord: Equatable, Sendable, Codable {
    public var health: CredentialHealth
    public var checkedAt: Date?

    public init(health: CredentialHealth, checkedAt: Date? = nil) {
        self.health = health
        self.checkedAt = checkedAt
    }

    /// The truthful default for a credential we have no record for.
    public static let unchecked = CredentialHealthRecord(health: .unchecked, checkedAt: nil)
}

// MARK: - Validation method mapping (PURE)

/// How (if at all) a given credential can be validated against a live service.
/// `.unsupported` is the truthful terminal state for any credential with no
/// real programmatic check — it maps to `.unchecked` health, never `.valid`.
public enum CredentialValidationMethod: Equatable, Sendable {
    /// Notion token introspection (reuses ConnectionHealthChecker → NotionClient.validate()).
    case notionTokenIntrospect(connection: String)
    /// Stripe account fetch (reuses StripeClient.retrieveAccountInfo()).
    case stripeAccountFetch
    /// A card credential — validated by local expiry math (no network).
    case cardExpiry
    /// No real programmatic validation exists for this credential. Stays `.unchecked`.
    case unsupported
}

public enum CredentialValidationMapper {
    /// Normalize a stored service slug ("api_key:stripe", "notion", …) to a
    /// lowercase provider key. Mirrors CredentialToolDependencies / the row's
    /// `serviceProvider` so the mapping is consistent across the vault.
    public static func normalizedProvider(forService service: String) -> String {
        let lower = service.lowercased()
        if lower.hasPrefix("api_key:") {
            return String(lower.dropFirst("api_key:".count))
        }
        return lower
    }

    /// Map a credential (service slug + type) to its real validation method.
    /// PURE — does NO network. Returns `.unsupported` for anything without a
    /// real programmatic check, which the validator turns into `.unchecked`
    /// (the truthfulness invariant: unmappable → never `.valid`).
    ///
    /// - For Notion, the connection name defaults to the account (the per-
    ///   workspace connection key) so token introspect targets the right token.
    public static func method(forService service: String, type: CredentialType, account: String) -> CredentialValidationMethod {
        // Cards are validated purely locally (expiry), regardless of slug.
        if type == .card {
            return .cardExpiry
        }
        switch normalizedProvider(forService: service) {
        case "notion":
            // The CredentialManager stores the connection/workspace as the
            // account; fall back to the slug if account is empty.
            let conn = account.isEmpty ? "notion" : account
            return .notionTokenIntrospect(connection: conn)
        case "stripe":
            return .stripeAccountFetch
        default:
            // Generic API keys / passwords: no safe programmatic check.
            return .unsupported
        }
    }

    /// Whether a credential is validatable at all (false → it will stay
    /// `.unchecked`). Convenience for the UI's "Revalidate" affordance.
    public static func isValidatable(service: String, type: CredentialType, account: String) -> Bool {
        method(forService: service, type: type, account: account) != .unsupported
    }
}

// MARK: - Card expiry math (PURE)

public enum CredentialCardExpiry {
    /// Compute health for a card from its expiry month/year. Pure, deterministic
    /// against a supplied `now` (tests pass a fixed date). Returns:
    ///   • `.revoked`  → already past the end of the expiry month (treated as
    ///                   needing re-entry; the design's "expired card" state).
    ///   • `.expiring` → within `windowDays` of the cutoff.
    ///   • `.valid`    → comfortably in the future.
    ///   • `.unchecked`→ missing/garbage expiry data (truthful: we don't know).
    public static func health(
        expMonth: Int?,
        expYear: Int?,
        now: Date = Date(),
        windowDays: Int = 60,
        calendar: Calendar = .current
    ) -> CredentialHealth {
        guard let month = expMonth, let year = expYear,
              (1...12).contains(month), year >= 2000,
              let firstOfExpiryMonth = calendar.date(from: DateComponents(year: year, month: month)),
              // The card is valid THROUGH the expiry month; cutoff is the first
              // of the following month.
              let cutoff = calendar.date(byAdding: .month, value: 1, to: firstOfExpiryMonth)
        else {
            return .unchecked
        }

        if now >= cutoff {
            return .revoked
        }
        let daysLeft = calendar.dateComponents([.day], from: now, to: cutoff).day ?? 0
        if daysLeft <= windowDays {
            return .expiring(days: max(daysLeft, 0))
        }
        return .valid
    }
}

// MARK: - Touch-ID gate decision (PURE)

public enum CredentialRevealGate {
    /// UserDefaults key for the "Require Touch ID to reveal" policy toggle.
    public static let requireTouchIDKey = "com.notionbridge.credentials.requireTouchIDToReveal"

    /// Whether a sensitive reveal action (copy / rotate / reveal) must pass a
    /// biometric gate. PURE decision helper: ON → gate; OFF → pass through.
    public static func shouldGate(requireTouchID: Bool) -> Bool {
        requireTouchID
    }

    /// Read the persisted toggle (defaults OFF — opt-in).
    public static func isRequired(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: requireTouchIDKey)
    }
}

// MARK: - Weekly auto-validate decision (PURE)

public enum CredentialAutoValidatePolicy {
    /// UserDefaults key for the "Auto-validate weekly" policy toggle.
    public static let enabledKey = "com.notionbridge.credentials.autoValidateWeekly"
    /// UserDefaults key for the persisted last auto-validate timestamp.
    public static let lastRunKey = "com.notionbridge.credentials.lastAutoValidateAt"

    /// The cadence: 7 days.
    public static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// PURE decision helper: is an auto-validate run due?
    ///   • toggle OFF                       → never due.
    ///   • toggle ON + never run            → due.
    ///   • toggle ON + >7d since last run   → due.
    ///   • toggle ON + <=7d since last run  → not due.
    public static func isDue(enabled: Bool, lastRun: Date?, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) > interval
    }

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func lastRun(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastRunKey) as? Date
    }

    public static func recordRun(_ date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastRunKey)
    }
}

// MARK: - Persistence store (UserDefaults-backed, PURE round-trip)

/// Persists last-known `CredentialHealthRecord`s keyed by a stable credential
/// key (service|account). Backed by UserDefaults as a single JSON blob so the
/// vault can render last-known results without a live call. The encode/decode
/// is pure and fully testable against an injected `UserDefaults` (tests use a
/// throwaway suite — never the shared defaults).
public struct CredentialHealthStore {
    public static let storageKey = "com.notionbridge.credentials.health.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Stable key for a credential. Service + account uniquely identify a
    /// Keychain item in this vault.
    public static func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }

    /// Load the full map (key → record). Empty if absent / corrupt.
    public func load() -> [String: CredentialHealthRecord] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let map = try? JSONDecoder().decode([String: CredentialHealthRecord].self, from: data)
        else { return [:] }
        return map
    }

    /// Read one record (truthful default `.unchecked` when absent).
    public func record(service: String, account: String) -> CredentialHealthRecord {
        load()[Self.key(service: service, account: account)] ?? .unchecked
    }

    /// Persist one record, merging into the existing map.
    public func set(_ record: CredentialHealthRecord, service: String, account: String) {
        var map = load()
        map[Self.key(service: service, account: account)] = record
        persist(map)
    }

    /// Persist a whole map (used by validateAll to write atomically).
    public func setAll(_ map: [String: CredentialHealthRecord]) {
        persist(map)
    }

    /// Prune records whose keys are no longer in `liveKeys` (deleted creds).
    public func prune(keeping liveKeys: Set<String>) {
        let map = load().filter { liveKeys.contains($0.key) }
        persist(map)
    }

    private func persist(_ map: [String: CredentialHealthRecord]) {
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
