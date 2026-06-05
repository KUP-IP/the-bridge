// PermissionsModule.swift — Unified TCC permission status (fb-permissions)
// NotionBridge · Modules
//
// One tool: `permissions_status` (open) — probes every macOS TCC category the
// app surfaces in Settings and returns a single, agent-readable snapshot so an
// assistant can answer "do you have Reminders/Calendar/Contacts access?" and,
// when a grant is missing, tell the user exactly where to flip the switch.
//
// ── WHY A DEDICATED TOOL ───────────────────────────────────────────────────
// Before this, the only TCC truth lived in the @MainActor UI `PermissionManager`
// (PermissionsSection). An MCP agent had no way to read grant state — every tool
// failed opaquely when a permission was missing (the "invisible-grant trap").
// `permissions_status` exposes the full grant matrix in one read-only call.
//
// ── PROBE STRATEGY (and the headless-hang carve-out) ───────────────────────
// All categories EXCEPT Automation are read from synchronous, direct TCC APIs
// (AXIsProcessTrusted / CGPreflightScreenCaptureAccess / a Full-Disk sentinel
// read / CNContactStore / EKEventStore / UNUserNotificationCenter). These never
// block and never trigger a prompt — they report current state only.
//
// Automation has NO direct API; PermissionManager probes it with NSAppleScript,
// which REQUIRES a live AppKit run loop and HANGS in a headless CLI/test runner
// (this is exactly why TestRunner skips runPermissionManagerTests()). To stay
// safe in every host, the Automation row reports a per-target hint and is only
// actively probed when `probeAutomation` is requested AND a bundle context
// exists. The pure status assembler (`PermissionsProbe`) is fully synchronous
// and injectable, so the unit tests exercise the whole contract without TCC.

import AppKit
import Contacts
@preconcurrency import EventKit
import Foundation
import MCP
import UserNotifications

// MARK: - Pure probe layer (testable, no live TCC required)

/// A single category's resolved status. Plain value so the assembler and its
/// tests never touch live EventKit / Contacts / AX / CG APIs.
public struct PermissionStatusRow: Sendable, Equatable {
    /// Machine identifier == `PermissionManager.Grant.tccCategory` (rawValue).
    public let category: String
    /// Human label (e.g. "Screen Recording").
    public let displayName: String
    /// True only when the category is fully usable (granted / limited / fullAccess).
    public let granted: Bool
    /// Detailed state: granted | denied | unknown | partial | restartRecommended.
    public let state: String
    /// One-line System Settings path the operator can act on when not granted.
    public let settingsHint: String

    public init(
        category: String,
        displayName: String,
        granted: Bool,
        state: String,
        settingsHint: String
    ) {
        self.category = category
        self.displayName = displayName
        self.granted = granted
        self.state = state
        self.settingsHint = settingsHint
    }
}

/// Pure assembler for the `permissions_status` payload. Maps a
/// `[Grant: GrantStatus]` snapshot into ordered `PermissionStatusRow`s using the
/// SSOT metadata on `PermissionManager.Grant` (displayName + settingsHint). No
/// I/O — the live probe lives in `PermissionsModule.probeAll()`; tests feed a
/// synthetic snapshot straight into `rows(from:)`.
public enum PermissionsProbe {

    /// Map a single `GrantStatus` to (granted, state-string).
    public static func resolve(_ status: PermissionManager.GrantStatus) -> (granted: Bool, state: String) {
        switch status {
        case .granted:            return (true,  "granted")
        case .denied:             return (false, "denied")
        case .unknown:            return (false, "unknown")
        case .partiallyGranted:   return (false, "partial")
        case .restartRecommended: return (false, "restartRecommended")
        }
    }

    /// Build ordered rows from a category→status snapshot. Categories absent
    /// from `snapshot` default to `.unknown` so the output always covers the
    /// full `Grant.allCases` matrix (no silently-missing category).
    public static func rows(
        from snapshot: [PermissionManager.Grant: PermissionManager.GrantStatus]
    ) -> [PermissionStatusRow] {
        PermissionManager.Grant.allCases.map { grant in
            let status = snapshot[grant] ?? .unknown
            let (granted, state) = resolve(status)
            return PermissionStatusRow(
                category: grant.tccCategory,
                displayName: grant.displayName,
                granted: granted,
                state: state,
                settingsHint: grant.settingsHint
            )
        }
    }

    /// Render rows into the MCP wire `Value` (the `{categories, summary}` object).
    public static func payload(from rows: [PermissionStatusRow]) -> Value {
        let categories: [Value] = rows.map { row in
            .object([
                "category": .string(row.category),
                "displayName": .string(row.displayName),
                "granted": .bool(row.granted),
                "status": .string(row.state),
                "settingsHint": .string(row.settingsHint)
            ])
        }
        let grantedCount = rows.filter(\.granted).count
        let missing = rows.filter { !$0.granted }.map(\.category)
        return .object([
            "categories": .array(categories),
            "summary": .object([
                "granted": .int(grantedCount),
                "total": .int(rows.count),
                "allGranted": .bool(grantedCount == rows.count),
                "missing": .array(missing.map { .string($0) })
            ])
        ])
    }
}

// MARK: - Module

public enum PermissionsModule {

    public static let moduleName = "permissions"

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "permissions_status",
            module: moduleName,
            tier: .open,
            description: "Probe every macOS TCC permission category (Accessibility, Screen Recording, Full Disk Access, Automation, Notifications, Contacts, Reminders, Calendar) and return each as {category, granted, status, settingsHint}, plus a granted/total summary. Read-only — never triggers a system prompt. Use this to diagnose why a Mac tool failed (the invisible-grant trap) and to tell the user exactly which System Settings switch to flip.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "category": .object([
                        "type": .string("string"),
                        "description": .string("Optional. Restrict the report to a single category (accessibility, screenRecording, fullDiskAccess, automation, notifications, contacts, reminders, calendar). Omit to report all.")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Permissions Status",
                whenToUse: [
                    "diagnosing why a Mac tool returned a permission/capability error",
                    "answering whether the app has Reminders / Calendar / Contacts / Screen Recording access",
                    "telling the user which System Settings pane to open to grant a missing permission"
                ],
                whenNotToUse: [
                    "to request or trigger a permission prompt (this tool is read-only)"
                ],
                relatedTools: ["system_info", "ax_query", "reminders_list", "calendar_list"]
            ),
            handler: { arguments in
                let only: PermissionManager.Grant? = {
                    if case .object(let args) = arguments,
                       case .string(let c) = args["category"],
                       !c.trimmingCharacters(in: .whitespaces).isEmpty {
                        return PermissionManager.Grant(rawValue: c)
                    }
                    return nil
                }()

                // If a category filter was supplied but is unrecognized, fail
                // with the valid set rather than silently returning everything.
                if case .object(let args) = arguments,
                   case .string(let c) = args["category"],
                   !c.trimmingCharacters(in: .whitespaces).isEmpty,
                   only == nil {
                    let valid = PermissionManager.Grant.allCases.map(\.rawValue).joined(separator: ", ")
                    throw ToolRouterError.invalidArguments(
                        toolName: "permissions_status",
                        reason: "unknown category '\(c)'. Valid categories: \(valid)."
                    )
                }

                let snapshot = await probeAll(only: only)
                var rows = PermissionsProbe.rows(from: snapshot)
                if let only {
                    rows = rows.filter { $0.category == only.tccCategory }
                }
                return PermissionsProbe.payload(from: rows)
            }
        ))
    }

    // MARK: - Live probes (direct TCC APIs — synchronous, no prompts, no hang)

    /// Probe the live TCC state for every category (or just `only`). Uses the
    /// same direct-API reads `PermissionManager` uses, EXCEPT Automation, which
    /// is reported from a non-blocking heuristic (its NSAppleScript probe needs
    /// an AppKit run loop and would hang headless — see file header).
    static func probeAll(
        only: PermissionManager.Grant? = nil
    ) async -> [PermissionManager.Grant: PermissionManager.GrantStatus] {
        let targets = only.map { [$0] } ?? PermissionManager.Grant.allCases
        var snapshot: [PermissionManager.Grant: PermissionManager.GrantStatus] = [:]
        for grant in targets {
            snapshot[grant] = await probe(grant)
        }
        return snapshot
    }

    static func probe(_ grant: PermissionManager.Grant) async -> PermissionManager.GrantStatus {
        switch grant {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .fullDiskAccess:
            return probeFullDiskAccess()
        case .contacts:
            let s = CNContactStore.authorizationStatus(for: .contacts)
            if PermissionManager.isContactsAuthorizationSufficient(s) { return .granted }
            switch s {
            case .denied, .restricted: return .denied
            default: return .unknown
            }
        case .reminders:
            return mapEventKit(EKEventStore.authorizationStatus(for: .reminder))
        case .calendar:
            return mapEventKit(EKEventStore.authorizationStatus(for: .event))
        case .notifications:
            return await probeNotifications()
        case .automation:
            return probeAutomationNonBlocking()
        }
    }

    /// EventKit authorization → GrantStatus. `.writeOnly` cannot read back, so
    /// it fails closed to `.denied` for reporting (parity with PermissionManager).
    private static func mapEventKit(_ status: EKAuthorizationStatus) -> PermissionManager.GrantStatus {
        switch status {
        case .authorized, .fullAccess: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Full Disk Access: probe a TCC-protected sentinel file's readability. No
    /// direct API exists. Mirrors PermissionManager.checkFullDiskAccess().
    private static func probeFullDiskAccess() -> PermissionManager.GrantStatus {
        guard let libURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return .unknown
        }
        let sentinels = [
            libURL.appendingPathComponent("Messages/chat.db").path,
            libURL.appendingPathComponent("Safari/History.db").path,
            libURL.appendingPathComponent("Mail/V10/MailData/Envelope Index").path
        ]
        let fm = FileManager.default
        let existing = sentinels.filter { fm.fileExists(atPath: $0) }
        let readable = existing.filter { fm.isReadableFile(atPath: $0) }
        if !readable.isEmpty { return .granted }
        if !existing.isEmpty { return .denied }
        return .unknown
    }

    /// Notifications: read current settings without prompting. In a non-bundle
    /// (CLI/test) context UNUserNotificationCenter crashes, so fail to `.unknown`.
    private static func probeNotifications() async -> PermissionManager.GrantStatus {
        guard Bundle.main.bundleIdentifier != nil else { return .unknown }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            let hasSurface = settings.alertSetting == .enabled
                || settings.badgeSetting == .enabled
                || settings.soundSetting == .enabled
                || settings.notificationCenterSetting == .enabled
            return hasSurface ? .granted : .partiallyGranted
        case .denied: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Automation: NO direct API and the NSAppleScript probe needs a live AppKit
    /// run loop (it hangs headless — see file header). Rather than block the MCP
    /// dispatcher, read the last-known per-target grants the UI PermissionManager
    /// already cached in TCC.db where readable; otherwise report `.unknown`. This
    /// keeps `permissions_status` fast and prompt-free in every host. The truthful
    /// way to actively re-probe Automation is the in-app Permissions pane.
    private static func probeAutomationNonBlocking() -> PermissionManager.GrantStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tccPath = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.isReadableFile(atPath: tccPath) else {
            // No Full Disk Access → cannot read TCC.db → state is genuinely unknown.
            return .unknown
        }
        let grants = queryAutomationTCC(dbPath: tccPath)
        guard !grants.isEmpty else { return .unknown }
        // The canonical Automation targets mirror PermissionManager.automationTargets
        // but are pinned here as a nonisolated constant: the live registry on
        // PermissionManager is @MainActor-isolated and this probe runs off the main
        // actor (so it never blocks the dispatcher). Targets are stable.
        let total = automationTargetBundleIDs.count
        let grantedCount = automationTargetBundleIDs.filter { grants[$0] == true }.count
        if grantedCount == 0 { return .denied }
        if grantedCount == total { return .granted }
        return .partiallyGranted
    }

    /// Nonisolated mirror of `PermissionManager.automationTargets` bundle IDs.
    /// (System Events, Messages, Chrome, Contacts.app, Reminders.app.)
    static let automationTargetBundleIDs: [String] = [
        "com.apple.systemevents",
        "com.apple.MobileSMS",
        "com.google.Chrome",
        "com.apple.AddressBook",
        "com.apple.reminders",
    ]

    /// Read AppleEvents grants for our bundle from TCC.db. auth_value==2 → granted.
    /// Returns empty on any failure (caller treats empty as `.unknown`).
    private static func queryAutomationTCC(dbPath: String) -> [String: Bool] {
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
                    if parts.count >= 2, let authValue = Int(parts[1]) {
                        results[parts[0]] = (authValue == 2)
                    }
                }
            }
        } catch {
            return [:]
        }
        return results
    }
}
