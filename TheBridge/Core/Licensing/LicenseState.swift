// LicenseState.swift — PKT-909 (Sell/Distribute v3 · 1) W1+W2
// TheBridge · Core · Licensing
//
// On-disk shape of `~/Library/Application Support/The Bridge/license.json`.
//
// One file holds EVERYTHING the gate needs to know:
//   - whether a paid license is installed (and its signed token)
//   - the install's first-launch timestamp (drives the trial timer)
//   - the trial outcome (active / expired / converted-to-paid)
//   - the grandfather flag for 3.4.x → 3.6.0 upgraders (safety contract)
//
// The file is REWRITTEN ATOMICALLY (write-to-tmp + rename) so a crash
// mid-write can never produce a half-state. Missing file => "fresh
// install" — LicenseManager.loadOrInit() seeds the first-launch
// timestamp + persists.
//
// DESIGN NOTE: we deliberately keep all licensing state in one JSON
// file, NOT UserDefaults. UserDefaults is fine for prefs but creates
// awkward debug + reset paths for licensing (each key is opaque, you
// can't `cat ~/Library/.../license.json | jq`). One JSON file under
// the BridgePaths canonical home keeps support reproducible.

import Foundation

/// On-disk license state. Codable so the JSON shape is stable across
/// versions; new optional fields are forwards-tolerant via default
/// values on Decodable.
public struct LicenseState: Codable, Equatable, Sendable {

    /// Schema version. Increment on breaking change; loadOrInit handles
    /// older versions in a single forward-only migration block.
    public static let currentVersion = 1
    public var version: Int

    /// First-launch timestamp, set ONCE on install. The trial timer is
    /// derived from this; we never recompute it.
    public var firstLaunchAt: Int64

    /// Optional paid-or-grandfather token. nil = trial mode.
    public var token: StoredToken?

    /// True once the trial window has elapsed without a paid token. Set
    /// by the gate so a future paid activation flips back to active
    /// without losing the "user has seen the expired state" signal.
    public var trialExpiredAcknowledged: Bool

    /// True for users upgraded from a pre-trial-gate version (PathMigration
    /// sentinel present at install). Independent of `token`: a
    /// grandfathered user can still paste a paid key, the grandfather
    /// flag just means "no trial countdown was ever shown".
    public var grandfathered: Bool

    public init(version: Int = LicenseState.currentVersion,
                firstLaunchAt: Int64,
                token: StoredToken? = nil,
                trialExpiredAcknowledged: Bool = false,
                grandfathered: Bool = false) {
        self.version = version
        self.firstLaunchAt = firstLaunchAt
        self.token = token
        self.trialExpiredAcknowledged = trialExpiredAcknowledged
        self.grandfathered = grandfathered
    }

    /// Forwards-tolerant decoding: missing fields fall back to defaults so
    /// a v1 file can be read by future v2 code (and vice versa, until a
    /// real breaking change forces version bump).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version                   = try c.decodeIfPresent(Int.self, forKey: .version) ?? LicenseState.currentVersion
        self.firstLaunchAt             = try c.decode(Int64.self, forKey: .firstLaunchAt)
        self.token                     = try c.decodeIfPresent(StoredToken.self, forKey: .token)
        self.trialExpiredAcknowledged  = try c.decodeIfPresent(Bool.self, forKey: .trialExpiredAcknowledged) ?? false
        self.grandfathered             = try c.decodeIfPresent(Bool.self, forKey: .grandfathered) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case version, firstLaunchAt, token, trialExpiredAcknowledged, grandfathered
    }

    /// Wire form of an installed token — both the raw token string the
    /// user pasted (so we can re-verify next launch) and a snapshot of
    /// the parsed payload (so the UI can show "Licensed to X" without
    /// re-running CryptoKit on every render).
    public struct StoredToken: Codable, Equatable, Sendable {
        public var raw: String
        public var payload: LicenseTokenPayload
        public init(raw: String, payload: LicenseTokenPayload) {
            self.raw = raw
            self.payload = payload
        }
    }
}

// MARK: - Computed trial status

/// What the gate decides on read. Pure derivation from LicenseState +
/// current time + trial duration.
public enum LicenseStatus: Equatable, Sendable {
    /// No paid token, trial still running. `daysRemaining` is the
    /// inclusive count (1 means "less than a day left but not zero
    /// yet"). Always >= 1 here.
    case trial(daysRemaining: Int)

    /// No paid token, trial elapsed.
    case trialExpired

    /// Paid token verified; `expiresAt` is nil for perpetual licenses.
    case licensed(payload: LicenseTokenPayload)

    /// Paid token's expiry has passed (subscription, time-limited
    /// promo). The token itself is still here so the UI can show
    /// "renew" copy rather than "paste a key".
    case licenseExpired(payload: LicenseTokenPayload)

    /// User was upgraded from a pre-gate version. No countdown ever
    /// shown. This is the SAFETY CONTRACT outcome.
    case grandfathered
}

public extension LicenseStatus {

    /// True when the bridge should dispatch tools normally. Used by the
    /// trial-gate (BridgeToolError.trialExpired) and the menu-bar.
    var isActive: Bool {
        switch self {
        case .trial, .licensed, .grandfathered:
            return true
        case .trialExpired, .licenseExpired:
            return false
        }
    }

    /// True when the user has a "real" paid or upgrade-grandfathered
    /// license (not in a trial). Used to suppress the trial countdown.
    var isLicensedOrGrandfathered: Bool {
        switch self {
        case .licensed, .grandfathered:
            return true
        case .trial, .trialExpired, .licenseExpired:
            return false
        }
    }

    /// Short human-readable label for the status pill in Settings.
    var pillLabel: String {
        switch self {
        case .trial(let days):
            return days == 1 ? "Trial — 1 day left" : "Trial — \(days) days left"
        case .trialExpired:    return "Trial expired"
        case .licensed:        return "Licensed"
        case .licenseExpired:  return "License expired"
        case .grandfathered:   return "Licensed (3.x)"
        }
    }
}
