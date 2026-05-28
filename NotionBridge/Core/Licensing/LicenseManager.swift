// LicenseManager.swift — PKT-909 (Sell/Distribute v3 · 1) W1+W2+W5
// NotionBridge · Core · Licensing
//
// The single source of truth for the 30-day trial gate + paid-license
// activation in The Bridge. One actor; the rest of the codebase reads
// `LicenseManager.shared.status` synchronously via `currentStatus()`
// (cached, recomputed on writes) and awaits the actor only for
// activation / reset flows.
//
// ─── Grandfather safety contract (W2) ─────────────────────────────────
//
// Existing v3.4.x → v3.6.0 auto-update users predate the trial gate.
// They MUST NEVER see a countdown. Detection: PathMigration's sentinel
// file (`.bridge-migration-v3.5-complete`) lives in BridgePaths.
// applicationSupport on every install that came through the v3.5 path
// migration. On `loadOrInit()`:
//
//   • If license.json exists → use it as-is.
//   • Else if the migration sentinel exists → write a synthetic
//     grandfather state (grandfathered:true, no token, no trial timer
//     ever shown). This is the SAFETY CONTRACT.
//   • Else → fresh install: seed firstLaunchAt = now, no grandfather
//     flag, trial timer starts.
//
// The sentinel check is idempotent (same outcome on every launch);
// loadOrInit is called once per process. A grandfathered state is sticky
// — even if the user later deletes the migration sentinel, license.json
// keeps `grandfathered:true` and they never see a trial.

import Foundation
import CryptoKit

// MARK: - LicenseManager actor

public actor LicenseManager {

    public static let shared = LicenseManager()

    // MARK: Configuration

    /// Trial duration in seconds. 30 days; expressed as Int64 (unix
    /// seconds) to match the on-disk timestamps.
    public static let trialDuration: Int64 = 30 * 24 * 60 * 60   // 30 days

    /// Filename inside `BridgePaths.applicationSupport`.
    public static let stateFilename = "license.json"

    /// Test-injectable clock; production uses `Date()` directly.
    public typealias Clock = @Sendable () -> Date
    private let clock: Clock

    /// The verified public key used to validate pasted tokens. Held as a
    /// property so tests can inject a freshly-generated public key
    /// without touching the bundled key. nil ⇒ no paste activation path.
    private let publicKey: Curve25519.Signing.PublicKey?

    // MARK: State (in-memory cache; mirror of file)

    private var state: LicenseState
    private var cachedStatus: LicenseStatus

    // MARK: Init

    /// Public initializer for tests. Production uses `.shared`.
    public init(
        publicKey: Curve25519.Signing.PublicKey? = LicensePublicKey.bundled(),
        clock: @escaping Clock = { Date() }
    ) {
        self.publicKey = publicKey
        self.clock     = clock
        // Best-effort load on init. Errors fall back to a transient
        // "fresh install" state in memory — but loadOrInit() persists
        // it on first explicit call. Until then everything is read-only.
        self.state = Self.loadFromDisk(clock: clock)
                  ?? Self.synthesizeInitialState(clock: clock)
        self.cachedStatus = Self.computeStatus(state: self.state, clock: clock)
    }

    // MARK: Public API

    /// Idempotent setup. Call once at app launch (AppDelegate). If
    /// license.json is absent, this is the call that creates it — either
    /// as a grandfathered file (PathMigration sentinel present) or a
    /// fresh-install file with firstLaunchAt = now.
    @discardableResult
    public func loadOrInit() throws -> LicenseStatus {
        if let onDisk = Self.loadFromDisk(clock: clock) {
            self.state = onDisk
        } else {
            // Fresh state path. The grandfather check happens HERE — we
            // overwrite firstLaunchAt + grandfathered if the migration
            // sentinel exists.
            var fresh = Self.synthesizeInitialState(clock: clock)
            if Self.migrationSentinelExists() {
                fresh.grandfathered = true
            }
            try Self.writeToDisk(fresh)
            self.state = fresh
        }
        self.cachedStatus = Self.computeStatus(state: self.state, clock: clock)
        return self.cachedStatus
    }

    /// Synchronous read for hot paths (UI render, tool dispatch). The
    /// cache is refreshed whenever the actor writes state, so the only
    /// time this lies is if external code edits license.json out of
    /// band — supported, but the next loadOrInit() catches up.
    public func currentStatus() -> LicenseStatus {
        return cachedStatus
    }

    /// Current on-disk state. Returned by value for safe reading off the
    /// actor.
    public func currentState() -> LicenseState {
        return state
    }

    /// Activate a paid license from a pasted token. Verifies signature
    /// against the bundled key, persists, and returns the new status.
    /// Throws `LicenseVerifyError` on bad signature / malformed token /
    /// no bundled key.
    @discardableResult
    public func activate(token raw: String) throws -> LicenseStatus {
        guard let publicKey = self.publicKey else {
            throw LicenseVerifyError.invalidPublicKey
        }
        let payload = try LicenseToken.verify(raw, publicKey: publicKey)

        var next = state
        next.token = LicenseState.StoredToken(raw: raw, payload: payload)
        // Re-entering activate after expiry clears the acknowledgement
        // so the UI doesn't keep the "expired" pill stuck.
        next.trialExpiredAcknowledged = false
        try Self.writeToDisk(next)
        state = next
        cachedStatus = Self.computeStatus(state: next, clock: clock)
        return cachedStatus
    }

    /// Remove an installed license. The trial timer is NOT reset (the
    /// user already had their 30 days). Used by Settings → Advanced →
    /// "Remove license" + Factory Reset.
    @discardableResult
    public func deactivate() throws -> LicenseStatus {
        var next = state
        next.token = nil
        try Self.writeToDisk(next)
        state = next
        cachedStatus = Self.computeStatus(state: next, clock: clock)
        return cachedStatus
    }

    /// Mark the user as having seen the "trial expired" UI. Does not
    /// change anything else; the gate stays expired until activation.
    public func acknowledgeTrialExpired() throws {
        guard !state.trialExpiredAcknowledged else { return }
        var next = state
        next.trialExpiredAcknowledged = true
        try Self.writeToDisk(next)
        state = next
        // No status change.
    }

    /// Factory-reset hook. Removes license.json so the next launch
    /// reruns loadOrInit() (which re-checks the grandfather sentinel —
    /// existing users stay grandfathered, new users start a fresh trial).
    public func factoryReset() throws {
        let url = Self.fileURL()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        // Don't auto-reinit here: AppDelegate calls loadOrInit() at next
        // launch. We reset the in-memory state to a synthetic blank so
        // any reads between now and that call see a defined value.
        state = Self.synthesizeInitialState(clock: clock)
        cachedStatus = Self.computeStatus(state: state, clock: clock)
    }

    // MARK: - Pure status derivation

    /// Derive the gate's view of the world from a LicenseState + a clock.
    /// Pure: same inputs, same output. The two trial-expiry boundary
    /// invariants:
    ///   1. days remaining is INCLUSIVE on the high end (29 → 28 → … →
    ///      1 → expired). A user with 23h59m left sees "1 day left",
    ///      not "0 days left".
    ///   2. The transition to .trialExpired happens precisely at
    ///      firstLaunchAt + trialDuration. Equal-to or past => expired.
    public static func computeStatus(state: LicenseState, clock: Clock) -> LicenseStatus {
        if state.grandfathered {
            return .grandfathered
        }
        if let stored = state.token {
            let now = Int64(clock().timeIntervalSince1970)
            if let exp = stored.payload.exp, now >= exp {
                return .licenseExpired(payload: stored.payload)
            }
            return .licensed(payload: stored.payload)
        }
        // Trial path
        let now = Int64(clock().timeIntervalSince1970)
        let endsAt = state.firstLaunchAt + LicenseManager.trialDuration
        if now >= endsAt {
            return .trialExpired
        }
        let remaining = endsAt - now
        let days = max(1, Int((remaining + (86400 - 1)) / 86400))   // ceil to whole days, floor 1
        return .trial(daysRemaining: days)
    }

    // MARK: - Disk I/O

    public static func fileURL() -> URL {
        BridgePaths.applicationSupport.appendingPathComponent(stateFilename)
    }

    public static func loadFromDisk(clock: Clock) -> LicenseState? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(LicenseState.self, from: data)
    }

    public static func writeToDisk(_ state: LicenseState) throws {
        // Ensure parent exists; safe to call repeatedly.
        try BridgePaths.ensureApplicationSupport()
        let url = fileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        // Atomic write via .atomic option (POSIX rename semantics on
        // macOS); never leaves a half-written file behind.
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - PathMigration sentinel (SAFETY CONTRACT)

    /// True iff PathMigration has run on this install (existing 3.4.x
    /// → 3.6.0 upgrader). Read-only: the sentinel is owned by
    /// PathMigration; LicenseManager only checks for its presence.
    public static func migrationSentinelExists() -> Bool {
        let sentinel = BridgePaths.applicationSupport.appendingPathComponent(PathMigration.sentinelName)
        return FileManager.default.fileExists(atPath: sentinel.path)
    }

    // MARK: - Helpers

    /// Synthesize a fresh-install state. Used by init() before the first
    /// loadOrInit() call, and by factoryReset() to reset the in-memory
    /// mirror cleanly.
    public static func synthesizeInitialState(clock: Clock) -> LicenseState {
        return LicenseState(firstLaunchAt: Int64(clock().timeIntervalSince1970))
    }
}
