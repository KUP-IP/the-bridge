// PermissionManager.swift — TCC Grant Detection Logic
// V1-02: Detects grant status for all 5 required TCC permissions
// V1-QUALITY-POLISH (PKT-346 D2): Added requestContactsAccess()
// V1-03 (BUG-FIX): Dynamic Automation target probing — Chrome, Contacts,
//   and future targets are probed alongside System Events and Messages.
//   Fixes: NotionBridge invisible in Automation prefs when Chrome was the
//   first Apple Event target (TCC prompt silently suppressed on Sequoia).
// PKT-362 D3: Added grantCheckingState and animatedRecheckAll() for animated re-check.
// V1-PATCH-003: Offloaded NSAppleScript automation probes to background thread via
//   Task.detached to eliminate main-thread blocking that caused macOS to sever the
//   Dock/WindowServer connection. checkAll() and checkAutomation() are now async.
// PKT-391 (V1-PATCH-003 v3): Replaced Process/osascript probe with NSAppleScript on
//   DispatchQueue.global() to fix TCC identity mismatch. Probes now use the same
//   binary identity (NotionBridge.app) as applescript_exec, eliminating -1743 errors.
// PKT-362 D5: Added systemSettingsURL to Grant for deep links in Settings.
// PKT-362 D6: Added needsRestart flag and restart transition tracking.
//
// Detection methods per grant:
//   - Accessibility: AXIsProcessTrusted() — direct API
//   - Screen Recording: CGPreflightScreenCaptureAccess() — direct API
//   - Full Disk Access: Probe Messages chat.db readability — no direct API
//   - Automation: Probe via NSAppleScript to each target app — no direct API
//   - Contacts: CNContactStore.authorizationStatus(for:) — direct API
//     (.limited = user chose “Selected Contacts…”; counts as granted for UI/tools)
//
// Warning: macOS 15+ (Sequoia): Screen Recording permission expires weekly.
// Apple enforces a 7-day re-authorization window for Screen Recording.
// There is NO API to detect when the permission will expire — only
// whether it is currently granted. The app should call checkAll()
// periodically (e.g., on popover open) to detect expiration promptly.
// Users will see a system prompt to re-authorize. This is an Apple
// platform constraint, not a bug.

import Foundation
import Observation
import AppKit
import Contacts
@preconcurrency import EventKit
import UserNotifications

/// Detects TCC (Transparency, Consent, and Control) grant status
/// for all six macOS permissions surfaced in Settings (v1 grants).
@MainActor
@Observable
public final class PermissionManager {

    public init() {}

    /// True when Contacts allows reads: full access (`.authorized`) or user-selected subset (`.limited`).
    public nonisolated static func isContactsAuthorizationSufficient(_ status: CNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .limited: return true
        case .notDetermined, .denied, .restricted: return false
        @unknown default: return false
        }
    }

    // MARK: - Types

    /// The six TCC-related grants surfaced in Settings and the menu bar Dashboard.
    public enum Grant: String, CaseIterable, Identifiable, Sendable {
        case accessibility
        case screenRecording
        case fullDiskAccess
        case automation
        case notifications
        case contacts
        case reminders
        case calendar

        public var id: String { rawValue }

        /// V1 grants used by current onboarding/settings surfaces.
        public static var v1Cases: [Grant] {
            allCases
        }

        /// PKT-388 D1-1: Grants that can be prompted directly via API.
        public var isAutoGrantable: Bool {
            switch self {
            case .contacts, .notifications, .automation:
                return true
            case .accessibility, .screenRecording, .fullDiskAccess, .reminders, .calendar:
                return false
            }
        }

        /// Grants surfaced during onboarding.
        /// Only include permissions users can actively grant from this flow.
        public static var onboardingCases: [Grant] {
            v1Cases.filter(\.isActionableInOnboarding)
        }

        public var isActionableInOnboarding: Bool {
            switch self {
            case .contacts:
                return false
            default:
                return true
            }
        }

        public var displayName: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .fullDiskAccess: return "Full Disk Access"
            case .automation: return "Automation"
            case .notifications: return "Notifications"
            case .contacts: return "Contacts"
            case .reminders: return "Reminders"
            case .calendar: return "Calendar"
            }
        }

        /// PKT-362 D5: System Settings deep link URL per grant.
        public var systemSettingsURL: URL? {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .fullDiskAccess:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            case .automation:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            case .notifications:
                return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
            case .contacts:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
            case .reminders:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
            case .calendar:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            }
        }
    }

    /// Status of a single TCC grant.
    public enum GrantStatus: Equatable, Sendable {
        case granted
        case denied
        case unknown
        case partiallyGranted
        case restartRecommended
    }

    /// Probe-backed evidence for a grant status decision.
    public struct GrantEvidence: Equatable, Sendable {
        public let source: String
        public let observed: String
        public let detail: String
        public let checkedAt: Date
    }

    // MARK: - Automation Target Registry

    /// Defines an application that NotionBridge may send Apple Events to.
    /// Each target is probed during `checkAutomation()`. On first probe,
    /// macOS will show the TCC consent prompt for that target, registering
    /// NotionBridge in the Automation preferences pane.
    public struct AutomationTarget: Sendable, Identifiable {
        public let bundleID: String
        public let name: String
        public let probe: String
        public var id: String { bundleID }
    }

    /// All known Automation targets. Add new entries here when NotionBridge
    /// needs to control additional applications via Apple Events.
    /// Order: most critical first (System Events, Messages, Chrome, Contacts).
    public static let automationTargets: [AutomationTarget] = [
        AutomationTarget(
            bundleID: "com.apple.systemevents",
            name: "System Events",
            probe: """
                tell application "System Events"
                    return name of first process whose frontmost is true
                end tell
            """
        ),
        AutomationTarget(
            bundleID: "com.apple.MobileSMS",
            name: "Messages",
            probe: """
                tell application "Messages"
                    return name
                end tell
            """
        ),
        AutomationTarget(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            probe: """
                tell application "Google Chrome"
                    return name
                end tell
            """
        ),
        AutomationTarget(
            bundleID: "com.apple.AddressBook",
            name: "Contacts",
            probe: """
                tell application "Contacts"
                    return name
                end tell
            """
        ),
        AutomationTarget(
            bundleID: "com.apple.reminders",
            name: "Reminders",
            probe: """
                tell application "Reminders"
                    return name
                end tell
            """
        ),
    ]

    // MARK: - State

    public private(set) var accessibilityStatus: GrantStatus = .unknown
    public private(set) var screenRecordingStatus: GrantStatus = .unknown
    public private(set) var fullDiskAccessStatus: GrantStatus = .unknown
    public private(set) var automationStatus: GrantStatus = .unknown
    public private(set) var contactsStatus: GrantStatus = .unknown
    public private(set) var notificationStatus: GrantStatus = .unknown
    public private(set) var remindersStatus: GrantStatus = .unknown
    public private(set) var calendarStatus: GrantStatus = .unknown

    /// Per-target Automation grant results. Key = bundleID.
    public private(set) var automationTargetGrants: [String: Bool] = [:]

    /// Backward-compatible accessors for existing code.
    public var automationSystemEventsGranted: Bool {
        automationTargetGrants["com.apple.systemevents"] ?? false
    }
    public var automationMessagesGranted: Bool {
        automationTargetGrants["com.apple.MobileSMS"] ?? false
    }
    public var automationChromeGranted: Bool {
        automationTargetGrants["com.google.Chrome"] ?? false
    }
    public var automationContactsGranted: Bool {
        automationTargetGrants["com.apple.AddressBook"] ?? false
    }
    public var automationRemindersGranted: Bool {
        automationTargetGrants["com.apple.reminders"] ?? false
    }

    public private(set) var lastCheckedAt: Date?
    public private(set) var accessibilityEvidence: GrantEvidence?
    public private(set) var screenRecordingEvidence: GrantEvidence?
    public private(set) var fullDiskAccessEvidence: GrantEvidence?
    public private(set) var automationEvidence: GrantEvidence?
    public private(set) var contactsEvidence: GrantEvidence?
    public private(set) var notificationEvidence: GrantEvidence?
    public private(set) var remindersEvidence: GrantEvidence?
    public private(set) var calendarEvidence: GrantEvidence?

    /// One-shot per process: requestAuthorization when status is still notDetermined (syncs System Settings–only grants).
    private var notificationAuthorizationSyncAttempted = false

    /// PKT-362 D3: Per-grant checking state for animated re-check feedback.
    /// Key = grant, value = true while that row is in "Checking…" state.
    public private(set) var grantCheckingState: [Grant: Bool] = [:]

    /// PKT-362 D6: Batched restart flag. Set when a restart-required grant
    /// (Screen Recording, Full Disk Access) transitions to .granted.
    /// Reset on app launch (init default = false).
    public private(set) var needsRestart: Bool = false


    /// PKT-484: Automation targets with detected TCC csreq mismatch.
    /// Non-empty when TCC.db shows auth_value=2 but probe returns false.
    public private(set) var csreqMismatchTargets: [AutomationTarget] = []

    /// PKT-484: True when csreq mismatch is detected and user action is recommended.
    public var hasCsreqMismatch: Bool { !csreqMismatchTargets.isEmpty }

    /// PKT-362 D6: Grants that require an app restart to take full effect.
    public static let restartRequiredGrants: Set<Grant> = [.screenRecording, .fullDiskAccess]

    // MARK: - Public API

    /// Returns the current status for the given grant.
    public func status(for grant: Grant) -> GrantStatus {
        switch grant {
        case .accessibility: return accessibilityStatus
        case .screenRecording: return screenRecordingStatus
        case .fullDiskAccess: return fullDiskAccessStatus
        case .automation: return automationStatus
        case .notifications: return notificationStatus
        case .contacts: return contactsStatus
        case .reminders: return remindersStatus
        case .calendar: return calendarStatus
        }
    }

    /// Check all TCC grants including async automation probes.
    /// V1-PATCH-003: Now async — automation probes run on background thread
    /// to prevent main-thread blocking that caused Dock connection severing.
    /// Call on popover open and periodically to detect re-grant needs.
    ///
    /// PKT-548: Notifications are intentionally excluded from checkAll() because
    /// they require the async UNUserNotificationCenter API and a cold-start
    /// requestAuthorization() dance (see checkNotifications). Including them here
    /// would couple sync TCC probes to the notification permission lifecycle.
    /// Use checkAllAsync() (includes notifications, runs in parallel) or
    /// recheckAllForTruth() when notification status is needed.
    public func checkAll() async {
        checkAccessibility()
        checkScreenRecording()
        checkFullDiskAccess()
        await checkAutomation()
        checkContacts()
        checkReminders()
        checkCalendar()
        lastCheckedAt = Date()
    }

    /// PKT-369 N3: Async variant of checkAll() that includes notification status.
    /// Ensures notification authorization is checked alongside synchronous TCC grants.
    /// Use at all call sites where async context is available.
    ///
    /// PKT-548: Runs checkNotifications() in parallel with checkAll() so that the
    /// Dashboard does not flash "Unknown" while waiting on the 10s-capped
    /// Automation NSAppleScript probes. Notifications resolve in <100ms; there is
    /// no reason to serialize them behind TCC probes.
    public func checkAllAsync() async {
        async let notifications: Void = checkNotifications()
        await checkAll()
        await notifications
    }

    /// Active reconciliation pass intended for "truth sync" from UI.
    /// Re-runs all probes and briefly waits for TCC state propagation.
    public func recheckAllForTruth() async {
        await checkAll()
        await checkNotifications()
        try? await Task.sleep(nanoseconds: 300_000_000)
        checkAccessibility()
        checkScreenRecording()
        checkFullDiskAccess()
        await checkAutomation()
        checkContacts()
        checkReminders()
        checkCalendar()
        await checkNotifications()
        lastCheckedAt = Date()
    }

    /// PKT-362 D3: Animated recheck — sets per-row "Checking…" state,
    /// performs recheck, then clears state with staggered timing (0.1s per row).
    /// PermissionView observes grantCheckingState and animates transitions.
    public func animatedRecheckAll() async {
        // Set all v1 grants to "checking"
        for grant in Grant.v1Cases {
            grantCheckingState[grant] = true
        }

        // Perform actual recheck
        await recheckAllForTruth()

        // Stagger clear per-row for visual effect
        for grant in Grant.v1Cases {
            try? await Task.sleep(nanoseconds: 100_000_000)
            grantCheckingState[grant] = false
        }
    }

    /// PKT-362 D6: Reset the needsRestart flag (e.g., after user restarts).
    public func resetNeedsRestart() {
        needsRestart = false
    }

    // MARK: - Detection Methods

    /// Accessibility: AXIsProcessTrusted() — direct API, synchronous Bool.
    /// Returns .granted if the app has Accessibility permission.
    public func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .granted : .denied
        accessibilityEvidence = .init(
            source: "AXIsProcessTrusted()",
            observed: trusted ? "trusted=true" : "trusted=false",
            detail: "Accessibility trust is read directly from AX API.",
            checkedAt: Date()
        )
    }

    /// Trigger Accessibility permission prompt. Returns current trust state.
    @discardableResult
    public func requestAccessibilityAccess() -> Bool {
        // Avoid direct reference to global CFString var to satisfy Swift 6 concurrency checks.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityStatus = trusted ? .granted : .denied
        accessibilityEvidence = .init(
            source: "AXIsProcessTrustedWithOptions(prompt=true)",
            observed: trusted ? "trusted=true" : "trusted=false",
            detail: "Prompt was requested; if still false, grant in Accessibility settings.",
            checkedAt: Date()
        )
        return trusted
    }

    /// Screen Recording: CGPreflightScreenCaptureAccess() — direct API.
    ///
    /// Warning: macOS 15+ (Sequoia) limitation:
    /// Screen Recording permission expires every 7 days. Apple enforces
    /// a weekly re-authorization prompt. There is no API to detect the
    /// remaining time on the grant — only whether it is currently active.
    /// When expired, this will return .denied until the user re-authorizes.
    ///
    /// PKT-362 D6: Tracks transitions to .granted for restart batching.
    public func checkScreenRecording() {
        let previousStatus = screenRecordingStatus
        let granted = CGPreflightScreenCaptureAccess()
        screenRecordingStatus = granted ? .granted : .denied
        // PKT-362 D6: Detect transition to .granted for restart-required grant
        if previousStatus != .granted && screenRecordingStatus == .granted {
            needsRestart = true
        }
        screenRecordingEvidence = .init(
            source: "CGPreflightScreenCaptureAccess()",
            observed: granted ? "granted=true" : "granted=false",
            detail: granted
                ? "Screen Recording is currently active."
                : "Grant may require prompt + relaunch depending on macOS behavior.",
            checkedAt: Date()
        )
    }

    /// Trigger Screen Recording prompt where available. Returns current grant state.
    @discardableResult
    public func requestScreenRecordingAccess() -> Bool {
        if #available(macOS 11.0, *) {
            _ = CGRequestScreenCaptureAccess()
        }
        let previousStatus = screenRecordingStatus
        let granted = CGPreflightScreenCaptureAccess()
        screenRecordingStatus = granted ? .granted : .restartRecommended
        // PKT-362 D6: Detect transition to .granted for restart-required grant
        if previousStatus != .granted && screenRecordingStatus == .granted {
            needsRestart = true
        }
        screenRecordingEvidence = .init(
            source: "CGRequestScreenCaptureAccess() + CGPreflightScreenCaptureAccess()",
            observed: granted ? "granted=true" : "granted=false",
            detail: granted
                ? "Screen Recording appears granted."
                : "Prompted but not yet active; relaunch may be required.",
            checkedAt: Date()
        )
        return granted
    }

    /// Full Disk Access: No direct API available.
    /// Probes the Messages database readability as a TCC-protected sentinel file.
    /// This file requires Full Disk Access. If readable, FDA is granted.
    /// Uses FileManager.urls(for:in:) to locate the user domain path.
    ///
    /// PKT-362 D6: Tracks transitions to .granted for restart batching.
    public func checkFullDiskAccess() {
        let previousStatus = fullDiskAccessStatus
        guard let libURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            fullDiskAccessStatus = .unknown
            return
        }
        let sentinels = [
            libURL.appendingPathComponent("Messages/chat.db").path,
            libURL.appendingPathComponent("Safari/History.db").path,
            libURL.appendingPathComponent("Mail/V10/MailData/Envelope Index").path
        ]
        let fm = FileManager.default
        let existing = sentinels.filter { fm.fileExists(atPath: $0) }
        let readable = existing.filter { fm.isReadableFile(atPath: $0) }

        if !readable.isEmpty {
            fullDiskAccessStatus = .granted
            fullDiskAccessEvidence = .init(
                source: "File readability probe",
                observed: "readable_sentinels=\(readable.count)",
                detail: "Readable protected files: \(readable.joined(separator: ", "))",
                checkedAt: Date()
            )
        } else if !existing.isEmpty {
            fullDiskAccessStatus = .denied
            fullDiskAccessEvidence = .init(
                source: "File readability probe",
                observed: "existing=\(existing.count), readable=0",
                detail: "Protected files exist but are unreadable. Likely Full Disk Access not granted.",
                checkedAt: Date()
            )
        } else {
            // Cannot infer if no protected sentinel files exist on this machine.
            fullDiskAccessStatus = .unknown
            fullDiskAccessEvidence = .init(
                source: "File readability probe",
                observed: "existing=0",
                detail: "No sentinel files were found to infer Full Disk Access state.",
                checkedAt: Date()
            )
        }
        // PKT-362 D6: Detect transition to .granted for restart-required grant
        if previousStatus != .granted && fullDiskAccessStatus == .granted {
            needsRestart = true
        }
    }

    /// Automation: No direct API available.
    /// Probes all registered automation targets by executing a minimal
    /// NSAppleScript against each. On first probe to a new target, macOS
    /// will show the TCC consent prompt for that target, registering
    /// NotionBridge in the Automation preferences pane.
    ///
    /// V1-03: Dynamic target probing. Previously only checked System Events
    /// and Messages. Now probes all targets in `automationTargets`, including
    /// Chrome and Contacts. This fixes the bug where Chrome Apple Events
    /// were silently denied because no probe ever triggered the TCC prompt.
    /// V1-PATCH-003: Now async — probes run via Task.detached on background thread.
    public func checkAutomation() async {
        var results: [String: Bool] = [:]
        for target in Self.automationTargets {
            results[target.bundleID] = await runAppleScriptProbe(target.probe)
        }
        automationTargetGrants = results

        let grantedCount = results.values.filter { $0 }.count
        let totalCount = results.count

        switch grantedCount {
        case totalCount:
            automationStatus = .granted
        case 0:
            automationStatus = .denied
        default:
            automationStatus = .partiallyGranted
        }

        // Build per-target status string for evidence
        let targetDetails = Self.automationTargets.map { target in
            let granted = results[target.bundleID] ?? false
            return "\(target.name)=\(granted ? "granted" : "denied")"
        }.joined(separator: ", ")

        automationEvidence = .init(
            source: "NSAppleScript probe (\(totalCount) targets)",
            observed: "\(grantedCount)/\(totalCount) granted: \(targetDetails)",
            detail: "Automation is target-specific; each target app requires its own TCC consent. "
                + "Probing a target for the first time triggers the macOS permission prompt.",
            checkedAt: Date()
        )

        // PKT-484: Check for csreq mismatches after probing
        detectCsreqMismatch()
    }

    /// Request Automation permission by re-probing all targets.
    /// On macOS Sequoia, fresh probes to un-granted targets will trigger
    /// the TCC consent prompt. This is non-destructive — it does NOT
    /// reset existing grants via tccutil.
    ///
    /// V1-03: Replaced destructive tccutil reset approach. The old method
    /// (`tccutil reset AppleEvents kup.solutions.notion-bridge`) wiped ALL
    /// existing Automation grants (Messages, System Events, etc.), which
    /// broke working functionality. Now we simply re-probe, which is safe.
    public func requestAutomationAccess() async {
        // Brief pause then re-probe all targets to trigger any missing prompts.
        // Each un-granted target will show a macOS TCC consent dialog.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await checkAutomation()
    }

    // MARK: - PKT-484: TCC csreq Mismatch Detection

    /// PKT-484: Detect TCC csreq mismatch — entries where auth_value=2 (granted)
    /// but the NSAppleScript probe returns false (denied at runtime).
    /// Root cause: auth_reason=4 (Settings toggle) stores a stale csreq blob
    /// from a previous code signature. macOS validates csreq on every Apple Event
    /// dispatch — signature mismatch = silent denial (-1743).
    public func detectCsreqMismatch() {
        // Compare TCC-reported grants with actual probe results
        var mismatched: [AutomationTarget] = []

        // Query TCC.db for our bundle's AppleEvents entries
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tccPath = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.isReadableFile(atPath: tccPath) else {
            // Cannot read TCC.db (no Full Disk Access) — skip detection
            csreqMismatchTargets = []
            return
        }

        // Read TCC entries for our bundle
        let tccGrants = queryTCCAutomationGrants(dbPath: tccPath)

        for target in Self.automationTargets {
            let probeGranted = automationTargetGrants[target.bundleID] ?? false
            let tccGranted = tccGrants[target.bundleID] ?? false

            // Mismatch: TCC says granted (auth_value=2) but probe says denied
            if tccGranted && !probeGranted {
                mismatched.append(target)
            }
        }

        csreqMismatchTargets = mismatched
        if !mismatched.isEmpty {
            let names = mismatched.map(\.name).joined(separator: ", ")
            print("[PermissionManager] csreq mismatch detected for: \(names)")
        }
    }

    /// PKT-484: Query TCC.db for AppleEvents grants for our bundle.
    /// Returns a map of indirect_object_identifier (target bundle ID) to granted.
    /// auth_value=2 means granted; anything else means not granted.
    private func queryTCCAutomationGrants(dbPath: String) -> [String: Bool] {
        var results: [String: Bool] = [:]

        let query = """
            SELECT indirect_object_identifier, auth_value
            FROM access
            WHERE service = 'kTCCServiceAppleEvents'
            AND client = 'kup.solutions.notion-bridge'
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-separator", "|", dbPath, query]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if let data = try? pipe.fileHandleForReading.readToEnd(),
               let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    let parts = line.components(separatedBy: "|")
                    if parts.count >= 2,
                       let authValue = Int(parts[1]) {
                        results[parts[0]] = (authValue == 2)
                    }
                }
            }
        } catch {
            print("[PermissionManager] TCC.db query failed: \(error.localizedDescription)")
        }

        return results
    }

    /// PKT-484: Reset all AppleEvents TCC grants and re-probe.
    /// WARNING: tccutil resets ALL AppleEvents grants for our bundle (not per-target).
    /// All automation targets will need re-authorization via consent prompts.
    /// This must be an explicit user action — never called automatically.
    public func resetAndReauthorizeAutomation() async {
        print("[PermissionManager] Resetting AppleEvents TCC grants via tccutil...")

        // Step 1: tccutil reset
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "AppleEvents", "kup.solutions.notion-bridge"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            print("[PermissionManager] tccutil reset exit code: \(process.terminationStatus)")
        } catch {
            print("[PermissionManager] tccutil reset failed: \(error.localizedDescription)")
            return
        }

        // Step 2: Wait for tccd cache invalidation
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Step 3: Re-probe all targets (triggers fresh consent prompts)
        await checkAutomation()

        // Step 4: Log per-target results
        for target in Self.automationTargets {
            let granted = automationTargetGrants[target.bundleID] ?? false
            print("[PermissionManager] Post-reset: \(target.name) = \(granted ? "granted" : "pending re-auth")")
        }
    }

    /// Contacts: CNContactStore.authorizationStatus(for:) — direct API.
    /// Maps `.authorized` and `.limited` to `.granted` (limited = user picked specific contacts).
    public func checkContacts() {
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        if Self.isContactsAuthorizationSufficient(authStatus) {
            contactsStatus = .granted
        } else {
            switch authStatus {
            case .denied, .restricted:
                contactsStatus = .denied
            default:
                contactsStatus = .unknown
            }
        }
        contactsEvidence = .init(
            source: "CNContactStore.authorizationStatus(for: .contacts)",
            observed: "status=\(String(describing: authStatus))",
            detail:
                "authorized/limited both allow contact reads; limited means the user chose Selected Contacts.",
            checkedAt: Date()
        )
    }

    /// Contacts: Request access — triggers the macOS system prompt.
    /// Call before opening System Settings so the app appears in the Contacts panel.
    /// PKT-346 D2: Added to support permission triggering on Grant tap.
    public func requestContactsAccess() async -> Bool {
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        do {
            let granted = try await Task { @MainActor in
                try await CNContactStore().requestAccess(for: .contacts)
            }.value
            contactsStatus = granted ? .granted : .denied
            contactsEvidence = .init(
                source: "CNContactStore.requestAccess(for: .contacts)",
                observed: granted ? "granted=true" : "granted=false",
                detail: "This reflects the result of an explicit Contacts authorization request.",
                checkedAt: Date()
            )
            return granted
        } catch {
            contactsStatus = .denied
            contactsEvidence = .init(
                source: "CNContactStore.requestAccess(for: .contacts)",
                observed: "error",
                detail: "Contacts authorization threw error: \(error.localizedDescription)",
                checkedAt: Date()
            )
            return false
        }
    }

    /// Reminders: EKEventStore.authorizationStatus(for: .reminder) — direct API.
    /// Mirrors EventKitRemindersStore: `.authorized`/`.fullAccess` map to .granted;
    /// `.denied`/`.restricted` to .denied; `.notDetermined` to .unknown. EventKit's
    /// `.writeOnly` does not apply to reminders in practice — fail-closed to .denied.
    public func checkReminders() {
        let authStatus = EKEventStore.authorizationStatus(for: .reminder)
        switch authStatus {
        case .authorized, .fullAccess:
            remindersStatus = .granted
        case .denied, .restricted, .writeOnly:
            remindersStatus = .denied
        case .notDetermined:
            remindersStatus = .unknown
        @unknown default:
            remindersStatus = .unknown
        }
        remindersEvidence = .init(
            source: "EKEventStore.authorizationStatus(for: .reminder)",
            observed: "status=\(authStatus.rawValue)",
            detail: "Reminders access is read directly from the EventKit authorization API.",
            checkedAt: Date()
        )
    }

    /// Reminders: Request access — triggers the macOS system prompt when
    /// `.notDetermined`, then rechecks. Mirrors EventKitRemindersStore.ensureAccess().
    @discardableResult
    public func requestRemindersAccess() async -> Bool {
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToReminders()
            } else {
                _ = await withCheckedContinuation { cont in
                    store.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
                }
            }
        }
        checkReminders()
        return remindersStatus == .granted
    }

    /// Calendar: EKEventStore.authorizationStatus(for: .event) — direct API.
    /// Mirrors EventKitCalendarStore: `.authorized`/`.fullAccess` map to .granted;
    /// `.denied`/`.restricted` to .denied; `.notDetermined` to .unknown. EventKit's
    /// `.writeOnly` grant cannot read events back — fail-closed to .denied for the UI.
    public func checkCalendar() {
        let authStatus = EKEventStore.authorizationStatus(for: .event)
        switch authStatus {
        case .authorized, .fullAccess:
            calendarStatus = .granted
        case .denied, .restricted, .writeOnly:
            calendarStatus = .denied
        case .notDetermined:
            calendarStatus = .unknown
        @unknown default:
            calendarStatus = .unknown
        }
        calendarEvidence = .init(
            source: "EKEventStore.authorizationStatus(for: .event)",
            observed: "status=\(authStatus.rawValue)",
            detail: "Calendar access is read directly from the EventKit authorization API.",
            checkedAt: Date()
        )
    }

    /// Calendar: Request access — triggers the macOS system prompt when
    /// `.notDetermined`, then rechecks. Mirrors EventKitCalendarStore.ensureAccess().
    @discardableResult
    public func requestCalendarAccess() async -> Bool {
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
                }
            }
        }
        checkCalendar()
        return calendarStatus == .granted
    }

    /// Notifications: UNUserNotificationCenter — async API.
    /// Unlike synchronous TCC checks, notification status requires async.
    /// Called from recheckAllForTruth() and animatedRecheckAll().
    /// checkAll() remains synchronous and skips this check.
    public func checkNotifications() async {
        // V3-QUALITY: Guard against CLI context (test runner has no bundle → UNUserNotificationCenter crashes)
        guard Bundle.main.bundleIdentifier != nil else {
            print("[PermissionManager] Skipping notification check — no bundle context (CLI/test runner)")
            return
        }
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        // If the user enabled alerts in System Settings but never ran an in-app request, macOS can leave
        // authorizationStatus at notDetermined until requestAuthorization runs once.
        if settings.authorizationStatus == .notDetermined, !notificationAuthorizationSyncAttempted {
            notificationAuthorizationSyncAttempted = true
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                print("[PermissionManager] requestAuthorization during checkNotifications: \(error.localizedDescription)")
            }
            settings = await center.notificationSettings()
        }
        // PKT-369 N1: Diagnostic probe — log raw authorization status
        print("[PermissionManager] N1 diagnostic: authorizationStatus=\(settings.authorizationStatus.rawValue) (0=notDetermined, 1=denied, 2=authorized, 3=provisional, 4=ephemeral)")
        applyNotificationSettings(settings)
        notificationEvidence = .init(
            source: "UNUserNotificationCenter.notificationSettings()",
            observed: notificationSettingsObservedString(settings),
            detail: notificationSettingsDetail(settings),
            checkedAt: Date()
        )
    }

    /// Request notification authorization. Triggers system prompt if .notDetermined.
    /// PKT-369 N2: Always uses notificationSettings() as the source of truth after
    /// requestAuthorization(). The boolean return from requestAuthorization is unreliable
    /// when authorization was determined externally (e.g., granted via System Settings) —
    /// it returns false even though the permission IS granted (UNErrorDomain error 1).
    public func requestNotificationAccess() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("[PermissionManager] requestAuthorization error: \(error.localizedDescription)")
        }
        // N2: Source of truth — notificationSettings() reflects actual macOS grant state
        let settings = await center.notificationSettings()
        print("[PermissionManager] N2 source-of-truth: authorizationStatus=\(settings.authorizationStatus.rawValue)")
        applyNotificationSettings(settings)
        let granted = notificationStatus == .granted
        notificationEvidence = .init(
            source: "requestAuthorization + notificationSettings() [N2 source-of-truth]",
            observed: notificationSettingsObservedString(settings),
            detail: notificationSettingsDetail(settings),
            checkedAt: Date()
        )
        return granted
    }

    private func applyNotificationSettings(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            let hasDeliverySurface = settings.alertSetting == .enabled
                || settings.badgeSetting == .enabled
                || settings.soundSetting == .enabled
                || settings.notificationCenterSetting == .enabled
            notificationStatus = hasDeliverySurface ? .granted : .partiallyGranted
        case .denied:
            notificationStatus = .denied
        case .notDetermined:
            notificationStatus = .unknown
        @unknown default:
            notificationStatus = .unknown
        }
    }

    private func notificationSettingsObservedString(_ settings: UNNotificationSettings) -> String {
        "authorizationStatus=\(settings.authorizationStatus.rawValue), alert=\(settings.alertSetting.rawValue), sound=\(settings.soundSetting.rawValue), badge=\(settings.badgeSetting.rawValue), center=\(settings.notificationCenterSetting.rawValue)"
    }

    private func notificationSettingsDetail(_ settings: UNNotificationSettings) -> String {
        switch notificationStatus {
        case .granted:
            return "Notifications are authorized and at least one delivery surface is enabled for Notion Bridge."
        case .partiallyGranted:
            return "Notifications are authorized, but all visible delivery surfaces are disabled. Open System Settings > Notifications and enable alerts, Notification Center, sound, or badges for Notion Bridge."
        case .denied:
            return "Notifications were denied for Notion Bridge in System Settings."
        case .unknown:
            return "macOS has not resolved the notification prompt for Notion Bridge yet."
        case .restartRecommended:
            return "Notification settings changed and may require a relaunch to reflect accurately."
        }
    }

    // MARK: - UX helpers

    public func statusLabel(for grant: Grant) -> String {
        switch status(for: grant) {
        case .granted:
            return "Granted"
        case .denied:
            return "Not Granted"
        case .unknown:
            return "Unknown"
        case .partiallyGranted:
            return "Partially Granted"
        case .restartRecommended:
            return "Restart Recommended"
        }
    }

    public func remediation(for grant: Grant) -> String {
        switch grant {
        case .accessibility:
            return "Enable in System Settings > Privacy & Security > Accessibility."
        case .screenRecording:
            return "Enable in Screen Recording. Relaunch Notion Bridge if status does not update."
        case .fullDiskAccess:
            return "Enable in Full Disk Access. Relaunch Notion Bridge to ensure new entitlement is observed."
        case .automation:
            if automationStatus == .partiallyGranted {
                let denied = Self.automationTargets.filter {
                    !(automationTargetGrants[$0.bundleID] ?? false)
                }.map(\.name)
                return "Grant Automation access for: \(denied.joined(separator: ", ")). Open System Settings > Privacy & Security > Automation. Automation for Contacts.app is separate from Contacts privacy access."
            }
            return "Enable Automation targets used by tools (System Events, Messages, Chrome, Contacts, Reminders). Automation for Contacts.app is separate from Contacts privacy access."
        case .notifications:
            if notificationStatus == .unknown {
                return "Click Allow to trigger the macOS Notifications prompt. If macOS still does not resolve the state, Notion Bridge should open Notifications settings automatically."
            }
            if notificationStatus == .partiallyGranted {
                return "Notifications are authorized, but delivery is muted. Open System Settings > Notifications and enable alerts, Notification Center, sound, or badges for Notion Bridge."
            }
            return "Open System Settings > Notifications and enable Notion Bridge if notifications were denied."
        case .contacts:
            if contactsStatus == .unknown {
                return "Click Allow to trigger the macOS Contacts prompt. If macOS does not resolve the state, Notion Bridge should open Contacts settings automatically."
            }
            return "Open System Settings > Privacy & Security > Contacts and enable Notion Bridge. Contacts privacy access is separate from Automation access for Contacts.app."
        case .reminders:
            if remindersStatus == .unknown {
                return "Click Allow to trigger the macOS Reminders prompt. If macOS does not resolve the state, open System Settings > Privacy & Security > Reminders and enable Notion Bridge."
            }
            return "Open System Settings > Privacy & Security > Reminders and enable Notion Bridge."
        case .calendar:
            if calendarStatus == .unknown {
                return "Click Allow to trigger the macOS Calendar prompt. If macOS does not resolve the state, open System Settings > Privacy & Security > Calendars and enable Notion Bridge."
            }
            return "Open System Settings > Privacy & Security > Calendars and enable Notion Bridge."
        }
    }

    public func debugDetail(for grant: Grant) -> String? {
        switch grant {
        case .automation:
            let details = Self.automationTargets.map { target in
                let granted = automationTargetGrants[target.bundleID] ?? false
                return "\(target.name): \(granted ? "granted" : "not granted")"
            }.joined(separator: " · ")
            return details
        case .fullDiskAccess where fullDiskAccessStatus == .unknown:
            return "No protected sentinel files found to infer Full Disk Access."
        default:
            return nil
        }
    }

    public func evidence(for grant: Grant) -> GrantEvidence? {
        switch grant {
        case .accessibility: return accessibilityEvidence
        case .screenRecording: return screenRecordingEvidence
        case .fullDiskAccess: return fullDiskAccessEvidence
        case .automation: return automationEvidence
        case .notifications: return notificationEvidence
        case .contacts: return contactsEvidence
        case .reminders: return remindersEvidence
        case .calendar: return calendarEvidence
        }
    }

    // MARK: - Public Target Query

    /// Check if a specific application has Automation permission.
    /// Useful for pre-flight checks before sending Apple Events.
    public func isAutomationGranted(forBundleID bundleID: String) -> Bool {
        automationTargetGrants[bundleID] ?? false
    }

    /// Returns the list of automation targets that are currently denied.
    public var deniedAutomationTargets: [AutomationTarget] {
        Self.automationTargets.filter {
            !(automationTargetGrants[$0.bundleID] ?? false)
        }
    }

    // MARK: - Internal probes

    /// PKT-391 (V1-PATCH-003 v3): Use NSAppleScript in-process on DispatchQueue.global()
    /// to align TCC identity with applescript_exec. Both now use NotionBridge.app's
    /// TCC entry, eliminating the identity split where probes authorized /usr/bin/osascript
    /// but execution ran as NotionBridge.app (causing runtime -1743 errors).
    ///
    /// V1-PATCH-003 v2 used Process("/usr/bin/osascript") to avoid main-thread blocking.
    /// V1-PATCH-003 v3 returns to NSAppleScript but on DispatchQueue.global(qos:) instead
    /// of Task.detached. NSAppleScript's internal dispatch_sync to main thread for TCC
    /// validation is brief (<100ms) — the full execution runs on the GCD thread.
    /// 10s timeout per probe guards against hangs (V1-PATCH-003 regression gate).
    private func runAppleScriptProbe(_ source: String) async -> Bool {
        let probeSource = source
        return await withCheckedContinuation { continuation in
            // Thread-safe one-shot guard — ensures continuation is resumed exactly once
            // even if both the timeout and the probe complete near-simultaneously.
            final class ResumeOnce: @unchecked Sendable {
                private let lock = NSLock()
                private var didResume = false
                func tryResume() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if didResume { return false }
                    didResume = true
                    return true
                }
            }
            let resumeOnce = ResumeOnce()

            // Safety timeout: 10s per probe (guards against main-thread deadlock
            // or target app hang). Returns false (denied) on timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                guard resumeOnce.tryResume() else { return }
                continuation.resume(returning: false)
            }

            // Run NSAppleScript on GCD global queue (not Swift cooperative pool).
            // NSAppleScript.executeAndReturnError() may dispatch_sync to main for
            // TCC validation — this is a brief check, not the full execution.
            // The @MainActor caller (checkAutomation) has `await`-suspended,
            // so main thread is free to service the dispatch_sync.
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: probeSource)
                var errorInfo: NSDictionary?
                let _ = appleScript?.executeAndReturnError(&errorInfo)

                guard resumeOnce.tryResume() else { return }

                if errorInfo != nil {
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }
}
