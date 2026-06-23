// AppDelegate.swift — App Lifecycle + MCP Server + SMAppService Auto-Launch
// The Bridge v1: Unified binary — starts MCP server on launch, stops on quit
// PKT-317: Merged server runtime into TheBridge via ServerManager
// PKT-318: Added SSE transport startup on :9700
// PKT-329: SSE port now configurable via NOTION_BRIDGE_PORT env var
// PKT-320: Added Notion API token validation on startup
// PKT-332: Added single-instance guard to prevent duplicate processes at boot
// PKT-341: Login item guard, TCC early check, LogManager + signal handlers
// V1-QUALITY-C2: OnboardingWindowController on first launch, SettingsWindowController
//   for gear icon / Cmd+, access. Client identification callbacks from SSE server.
// PKT-353: Right-click context menu setup for Quit action
// PKT-357 F15: App Nap prevention via NSProcessInfo activity assertion
// V1-PATCH-003: Rapid restart detection (B1-B3) — detect 3+ launches in 2 min,
//   defer non-critical init by 5s to let app stabilize

import AppKit
import SwiftUI
import ServiceManagement
import Sparkle

private let reopenSettingsAfterRestartKey = "reopenSettingsAfterRestart"

@MainActor
func restartApp(reopenSettings: Bool = false) {
    if reopenSettings {
        UserDefaults.standard.set(true, forKey: reopenSettingsAfterRestartKey)
    }

    // Spawn a detached shell process that survives app termination,
    // waits briefly, then relaunches the app via `open`.
    let bundlePath = Bundle.main.bundlePath
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 1 && open '\(bundlePath)'"]
    try? task.run()

    NSApp.terminate(nil)
}

/// PKT-341: Signal handler for crash resilience.
/// Flushes log file descriptor, then re-raises with default handler.
/// Only calls async-signal-safe functions (fsync, signal, raise).
private func crashFlushHandler(_ sig: Int32) {
    let fd = _logManagerFD
    if fd >= 0 {
        fsync(fd)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// PKT-932: minimal `SPUUpdaterDelegate` that logs update-check outcomes and
/// errors. The updater was previously created with `updaterDelegate: nil`, so a
/// failed/aborted check (or "no update found") produced no log and no UI — the
/// reason "Check for Updates" silently did nothing. These NSLog lines surface
/// the actual outcome in the unified log (filter: process == "TheBridge").
///
/// fix(sparkle), 2026-06-05: also carries the staged-update integrity guards.
/// The 2026-06-05 incident was a raced staged-update swap that left the SPM
/// resource bundle without a `Contents/` dir → `Bundle.module` trap → menu-bar
/// crash-loop. The DEFINITIVE fix is graceful degradation at the load site
/// (`MenuBarIconResolver`); this delegate adds the BEST-EFFORT pre-swap defense
/// the Sparkle API allows:
///   • `shouldProceedWithUpdate` — the only abort-capable hook. It runs BEFORE
///     download/extract, so it cannot validate the STAGED bundle (it doesn't
///     exist yet), but it CAN refuse to install on top of an already-corrupt
///     RUNNING app (a poisoned base) so an update never perpetuates corruption.
///   • `didExtractUpdate` / `willInstallUpdate` — VOID notification hooks (they
///     cannot abort the install — that is performed by Sparkle's sandboxed
///     Installer XPC service the app cannot reach). We use them to log the
///     install transition so a future corruption is diagnosable in the unified
///     log. See docs/release/sparkle-troubleshooting.md for why the post-extract
///     pre-swap surface cannot cleanly abort.
private final class UpdaterLogger: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("[Bridge][Updater] found valid update: \(item.versionString)")
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        NSLog("[Bridge][Updater] no update found (already current): \(error.localizedDescription)")
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        NSLog("[Bridge][Updater] check ABORTED: \(ns.domain)#\(ns.code) — \(error.localizedDescription)")
    }

    /// fix(sparkle): the ONLY abort-capable Sparkle hook (Swift `throws` form of
    /// `updater:shouldProceedWithUpdate:updateCheck:error:`). Throwing here makes
    /// Sparkle NOT download/install the update. We veto only when the CURRENTLY-
    /// RUNNING app's SPM resource bundle is already structurally corrupt: an
    /// install-on-top from a poisoned base risks perpetuating the crash-loop, and
    /// the operator should recover via clear-staging + `make install-copy` first
    /// (see docs/release/sparkle-troubleshooting.md). This does NOT (and cannot
    /// here) validate the staged bundle — that doesn't exist until after extract.
    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        switch StagedUpdateValidator.validateRunningApp() {
        case .ok:
            NSLog("[Bridge][Updater] proceeding with \(updateItem.versionString) — running-app resource bundle OK")
        case .corrupt(let bundleName, let reason):
            NSLog("[Bridge][Updater] ABORT update \(updateItem.versionString): running app already corrupt (\(bundleName)): \(reason). Recover with clear-staging + make install-copy.")
            throw NSError(
                domain: "com.notionbridge.updater",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "The Bridge's resource bundle (\(bundleName)) is corrupt. "
                    + "Please reinstall before updating (clear Sparkle staging + reinstall) — "
                    + "see docs/release/sparkle-troubleshooting.md."]
            )
        }
    }

    /// fix(sparkle): VOID notification — logs the extract transition. Cannot
    /// abort the install (no return value); the validate-and-abort post-extract
    /// surface does not exist in Sparkle (documented).
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        NSLog("[Bridge][Updater] extracted \(item.versionString) — install pending (swap performed by Sparkle Installer XPC)")
    }

    /// fix(sparkle): VOID notification — logs immediately before the swap so a
    /// post-update corruption can be correlated to this install in the log.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        NSLog("[Bridge][Updater] will install \(item.versionString) — if the menu-bar icon is missing after relaunch the resource bundle was corrupted; the app still boots (SF Symbol fallback). See docs/release/sparkle-troubleshooting.md.")
    }
}

/// Manages app lifecycle, auto-launch registration, and MCP server lifecycle.
/// The server starts in a detached Task on launch (Nudge Server pattern) so the
/// SwiftUI main thread is never blocked. StatusBarController receives live updates
/// for connections, tool calls, Notion token status, and uptime.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    /// PKT-1005 (Pillar A/B): a stable, identity-correct handle to the LIVE
    /// AppDelegate. The app is wired via `@NSApplicationDelegateAdaptor`, under
    /// which `NSApp.delegate as? AppDelegate` can FAIL to cast — `NSApp.delegate`
    /// may hand back a SwiftUI wrapper, not this instance. That fragile cast is
    /// exactly why `bridge_settings_navigate` historically reported a false
    /// "no app window host present" and never opened the window. We assign this
    /// weak self-reference in `applicationDidFinishLaunching` so the automation
    /// surface (BridgeSettingsAutomation) can reach the real `settingsController`
    /// host WITHOUT the cast. `weak` so it never keeps a torn-down delegate alive.
    @MainActor public private(set) static weak var shared: AppDelegate?

    private var serverTask: Task<Void, Never>?
    private var serverManager: ServerManager?

    /// cmd-w3: the Commands palette. Default-OFF and additive-isolated —
    /// constructed ONLY when `BRIDGE_ENABLE_COMMANDS=1`
    /// (`CommandsPaletteGate`). When the gate is off this stays `nil`, no
    /// Carbon hot-key is registered, no NSPanel exists, and the app is
    /// byte-for-byte its prior stdio+SSE self (same proof shape as the
    /// streamableHTTP connector-gating decision). The gating DECISION is
    /// unit-tested headlessly; the hot-key firing / panel / cross-app
    /// paste are an explicit operator manual-smoke (W3 GUI ceiling).
    private var commandBridge: CommandBridgeController?

    /// v3.7.6: standalone Dashboard popover presented by the Command Bridge
    /// palette's leading bridge-mark. A small borderless panel (Option A —
    /// reuses `DashboardView`), anchored at the same bottom-centre placement
    /// the palette uses. Held so it can be re-shown / dismissed.
    private var commandBridgeDashboardPanel: NSPanel?
    private var commandBridgeDashboardResignObserver: Any?

    /// cmd-ux W1: the single `@Observable` source of truth for the
    /// Settings → Commands section. The AppDelegate owns exactly one
    /// instance; every registration / enable / hotkey transition is
    /// pushed INTO it (via `commandsRegistrar`) so the SwiftUI status
    /// row — which reads it through `@Environment` — is always live.
    /// This structurally fixes Bug 2 (the old plain-computed snapshot
    /// never re-read the live registration state).
    public let commandsController = CommandsController()

    // PKT-357 F15: Activity token to prevent App Nap
    private var activityToken: NSObjectProtocol?

    // WS-5b: periodic + wake-aware credential auto-validate.
    /// Hourly timer that runs the weekly auto-validate when due. A long-running
    /// app would otherwise never re-validate until relaunch (the on-launch check
    /// only fires once). Timers don't fire while the machine is asleep, so a
    /// wake observer (below) re-checks on resume.
    private var autoValidateTimer: Timer?
    /// `NSWorkspace.didWakeNotification` observer token, removed on teardown.
    private var didWakeObserver: NSObjectProtocol?
    /// How often the timer fires to check the "is auto-validate due?" policy.
    private static let autoValidatePollInterval: TimeInterval = 60 * 60 // 1 hour

    /// Observable state for the DashboardView popover.
    /// Owned here so it's available before the first SwiftUI render.
    public let statusBar = StatusBarController()

    /// PKT-341: Permission manager owned by AppDelegate for early TCC check
    /// on applicationDidFinishLaunching (not just on popover open).
    public let permissionManager = PermissionManager()

    /// PKT-369 W3: Shared window tracker for activation policy switching.
    /// Observes Settings window lifecycle and toggles .accessory ↔ .regular.
    public let windowTracker = WindowTracker()

    /// PKT-430: Sparkle auto-updater controller for delivering post-launch updates.
    private let updaterController: SPUStandardUpdaterController

    /// PKT-932: strong-held updater delegate that LOGS update outcomes/errors.
    /// The controller was previously created with `updaterDelegate: nil`, which
    /// swallowed every check failure silently (no error, no log, no UI) — the
    /// reason "Check for Updates" appeared to do nothing.
    private let updaterLogger: UpdaterLogger

    /// V1-QUALITY-C2: Onboarding window controller for first-launch experience.
    private lazy var onboardingController = OnboardingWindowController(
        permissionManager: permissionManager
    )

    /// V1-QUALITY-C2: Settings window controller for gear icon / Cmd+, access.
    /// cmd-ux W1 (instance-identity fix): pass THIS AppDelegate's single
    /// `commandsController` straight in, so the Settings UI observes the exact
    /// instance the launch/enable/rebind registration paths publish into. The
    /// controller previously self-resolved this via `NSApp.delegate as?
    /// AppDelegate` with a `?? CommandsController()` fallback; when the cast
    /// missed it observed a fresh, never-registered controller and the header
    /// falsely read "⚠ Shortcut not active" even though ⌃⌘B was live.
    private lazy var settingsController = SettingsWindowController(
        statusBar: statusBar,
        permissionManager: permissionManager,
        commandsController: commandsController
    )

    /// Detect the standalone TheBridgeTests executable. The test harness
    /// constructs a real `AppDelegate()` (e.g. to assert the Commands palette
    /// master toggle persists), and the harness pumps a live main run loop to
    /// service MainActor + CFRunLoop system callbacks. With `startingUpdater:
    /// true`, Sparkle schedules an automatic appcast check on the main dispatch
    /// queue; once that async fetch returns INTO the pumped main run loop it can
    /// present an `NSAlert runModal` (a new-version / permission dialog), which
    /// wedges the main thread in a nested modal event loop and hangs/SIGTRAPs the
    /// suite at teardown. A headless unit-test binary must never auto-check for
    /// updates, so we start the updater disarmed in that process (production
    /// startup is unchanged). Mirrors the SecurityGate.runningInTestProcess idiom.
    private static var runningInTestProcess: Bool {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        // Match the current test-binary name (`TheBridgeTests` → `thebridgetests`);
        // legacy `notionbridgetests` still accepted. Kept in lockstep with the
        // SwiftPM test target name + SecurityGate.runningInTestProcess.
        if processName.contains("thebridgetests") || processName.contains("notionbridgetests") { return true }
        let args = CommandLine.arguments.joined(separator: " ").lowercased()
        return args.contains("thebridgetests") || args.contains("notionbridgetests")
    }

    public override init() {
        let logger = UpdaterLogger()
        updaterLogger = logger
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !Self.runningInTestProcess,
            updaterDelegate: logger,
            userDriverDelegate: nil
        )
        // PKT-431: Force revalidation on every appcast fetch to prevent stale NSURLSession cache.
        updaterController.updater.httpHeaders = ["Cache-Control": "no-cache"]
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // PKT-1005: publish the identity-correct self-reference for the
        // automation surface (see `AppDelegate.shared`). Set first so any early
        // MCP-driven open/navigate reaches the real host, not a failed cast.
        Self.shared = self

        // PKT-487 → PKT-1 v3.5: Dock label uses the new display name
        // (executable bundle name is still "TheBridge" — that's the
        // SPM target identifier baked into the binary).
        ProcessInfo.processInfo.processName = "The Bridge"

        // PKT-332: Single-instance guard — prevent duplicate processes from
        // SMAppService login item + Terminal session restore + manual launch
        let allowMulti = CommandLine.arguments.contains("--multi-instance")
        guard allowMulti || ensureSingleInstance() else {
            print("[The Bridge] Another instance is already running — exiting")
            NSApplication.shared.terminate(nil)
            return
        }

        // PKT-1 v3.5: Rename migration. Idempotent + atomic; no-ops on every
        // launch after the first successful run. Runs BEFORE any subsystem
        // touches Application Support so they see canonical paths.
        do {
            let report = try PathMigration.runOnce(log: { print("[PathMigration] \($0)") })
            if !report.alreadyComplete {
                print("[PathMigration] migrated support:\(report.supportItemsMoved) logs:\(report.logsItemsMoved) collisions:\(report.collisionsRenamed)")
            }
        } catch {
            // Non-fatal: subsystems will still create the canonical dir on first
            // write. We surface the error so it shows up in launch logs.
            print("[PathMigration] WARNING: migration failed: \(error)")
        }

        // PKT-977 Wave 2: demote stale reference memories on launch (best-effort).
        Task {
            do {
                let report = try await MemoryStore.shared.consolidationSweep()
                if report.referenceDemoted > 0 || report.expiredTombstoned > 0 {
                    print("[Memory] consolidation: referenceDemoted=\(report.referenceDemoted) expired=\(report.expiredTombstoned)")
                }
            } catch {
                print("[Memory] WARNING: consolidation sweep failed: \(error)")
            }
        }

        // PKT-909 (Sell/Distribute v3 · 1): bootstrap the licensing gate.
        // MUST come AFTER PathMigration — the grandfather detection looks
        // at PathMigration's sentinel file. First-launch users seed
        // firstLaunchAt = now here; existing 3.4.x → 3.6.0 auto-update
        // users land as `.grandfathered` and never see a countdown.
        Task {
            do {
                let status = try await LicenseManager.shared.loadOrInit()
                print("[Licensing] bootstrap: \(status.pillLabel)")
            } catch {
                print("[Licensing] WARNING: loadOrInit failed: \(error)")
            }
        }

        CredentialsFeature.migrateIfNeeded()

        // PKT-933: One-time keychain access-group continuity check (no-op until
        // the entitled build is installed; never destructive).
        Task { CredentialManager.shared.migrateToAccessGroupIfNeeded() }

        // the-bridge keychain UX: one-time re-authorization so each stored item
        // carries an explicit always-allow-self ACL — the fix for recurring
        // "enter your password to allow access" prompts. Surfaces at most one
        // prompt per stale item, then re-saves under the clean ACL so all future
        // reads are silent. Guarded by a UserDefaults flag → runs once.
        Task.detached { KeychainManager.shared.reauthorizeIfNeeded() }

        // PKT-441: One-time Stripe key migration to unified credential vault
        Task { await ConnectionRegistry.shared.migrateStripeKeyIfNeeded() }

        // v3.7.6 Wave 4a: Weekly credential auto-validate (on-launch fallback).
        // The Jobs infra hosts launchd LaunchAgents whose action chains are MCP
        // tool invocations executed via SSE — it cannot cleanly host an INTERNAL
        // Swift call like CredentialValidator.validateAll(). So the weekly cadence
        // is implemented as a persisted lastAutoValidateAt + an on-launch
        // "if toggle ON AND >7d since last run → validate" check (the documented
        // fallback). Real + observable: results persist to CredentialHealthStore
        // and surface as the rows' last-known badges + "checked <relative>" line.
        //
        // WS-5b: the on-launch check alone never re-fires for a long-running app.
        // We additionally install an hourly timer + an NSWorkspace wake observer
        // that re-run the SAME due-gated path (so they never double-run within a
        // 7-day window). All three share `runCredentialAutoValidateIfDue()`.
        runCredentialAutoValidateIfDue()
        startCredentialAutoValidateScheduling()

        registerAutoLaunch()

        // PKT-357 F15: Prevent App Nap — keep MCP server alive during idle.
        // Menu bar apps with .menuBarExtraStyle(.window) can be suspended by macOS.
        // This activity assertion tells the system the app is doing meaningful work.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "MCP server must remain active for client connections"
        )
        print("[The Bridge] App Nap prevention activity started")

        // PKT-341: Bootstrap LogManager for crash-resilient disk logging
        Task {
            await LogManager.shared.bootstrap()
        }

        // PKT-340 V2-SCHEDULER: Bootstrap JobsManager (opens SQLite, scans missed executions)
        Task {
            await JobsManager.shared.bootstrap()
        }

        // PKT-341: Install signal handlers for crash breadcrumbs
        installSignalHandlers()

        // V1-PATCH-003 B1/B2: Rapid restart detection — defer TCC if restarting too fast
        let rapidRestart = detectRapidRestart()
        if rapidRestart {
            // B2: Defer non-critical init by 5s to let app stabilize
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await permissionManager.checkAllAsync()
            }
        } else {
            // PKT-369 N3: Check TCC permissions on launch (async to include notifications)
            Task { await permissionManager.checkAllAsync() }
        }

        // V3-QUALITY B4: Migrate plaintext tokens to Keychain on first launch
        ConfigManager.shared.migrateTokensToKeychain()

        startMCPServer()
        validateNotionToken()

        // cmd-w3: opt-in Commands palette (default-OFF, additive-isolated).
        maybeStartCommandsPalette()

        // PKT-353: Set up right-click context menu for Quit action on status item
        statusBar.setupContextMenu()

        // PKT-350 F1: Re-validate token when changed from Settings
        NotificationCenter.default.addObserver(forName: .notionTokenDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.validateNotionToken()
            }
        }

        // Remote access config changed — invalidate all active MCP sessions so clients
        // reconnect with the updated tunnel URL / bearer token.
        NotificationCenter.default.addObserver(forName: .remoteAccessConfigDidChange, object: nil, queue: .main) { [weak self] _ in
            Task {
                await self?.serverManager?.invalidateAllSessions(reason: "remote access config changed")
            }
        }

        // WS-D (PKT-921): Bridge Cloud Access master toggle flipped — start/stop
        // the health heartbeat and register/deregister the `bridge_status` MCP
        // tool on the running server WITHOUT a relaunch. (Launch-time wiring is
        // handled inside ServerManager.setup() from BridgeDefaults.)
        NotificationCenter.default.addObserver(forName: .cloudAccessEnabledDidChange, object: nil, queue: .main) { [weak self] note in
            let enabled = (note.userInfo?[cloudAccessEnabledKey] as? Bool) ?? BridgeDefaults.cloudAccessEnabledValue
            Task {
                await self?.serverManager?.setCloudAccessEnabled(enabled)
            }
        }

        // PKT-349 B2: Observe reset onboarding notification from Settings.
        // Dispatch to MainActor to satisfy Swift 6 strict concurrency.
        NotificationCenter.default.addObserver(forName: .resetOnboarding, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.onboardingController.show()
            }
        }

        // PKT-879 (v3.6.4): land users in the Dashboard, not raw Settings.
        // When the wizard completes, flash the Dock badge / menu bar so
        // the user notices the menu bar icon is the next interaction.
        // We deliberately do NOT open the Settings window here.
        NotificationCenter.default.addObserver(forName: .onboardingDidComplete, object: nil, queue: .main) { _ in
            // requestUserAttention is the canonical macOS API for
            // "hey, look over here" without stealing focus or windows.
            NSApp.requestUserAttention(.informationalRequest)
            print("[Onboarding] Completed — user attention requested for menu bar Dashboard")
        }

        // Keep permission state fresh after returning from System Settings.
        // PKT-369 N3: Use async variant to include notification status
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.permissionManager.checkAllAsync()
            }
        }

        // V1-QUALITY-C2: Show first-launch onboarding window
        onboardingController.showIfNeeded()

        // v3.7·1: Kick off a non-blocking refresh of the on-disk
        // skills cache. The routing index + Standing Orders composer
        // both read this cache; refreshing on launch keeps it within
        // the TTL window for the next handshake. Deferred 3 s so it
        // never contends with MCP server startup or token validation.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            SkillsManager().kickoffBackgroundCacheRefresh()
        }

        reopenSettingsIfRequested()
    }

    // MARK: - WS-5b: periodic + wake-aware credential auto-validate

    /// Run the weekly credential auto-validate IFF the policy says it is due
    /// (toggle ON + never run, or >7d since last run). Reuses the existing
    /// off-main, 10s-timeout, persist-only-real-results `CredentialValidator`.
    /// Idempotent against rapid re-entry: it re-reads `isDue` (which is gated on
    /// the persisted `lastRun`) so the timer + wake observer + launch path never
    /// double-run within the 7-day window.
    private func runCredentialAutoValidateIfDue() {
        Task {
            guard CredentialAutoValidatePolicy.isDue(
                enabled: CredentialAutoValidatePolicy.isEnabled(),
                lastRun: CredentialAutoValidatePolicy.lastRun()
            ) else { return }
            _ = await CredentialValidator.shared.validateAll()
            CredentialAutoValidatePolicy.recordRun()
        }
    }

    /// Install the hourly poll timer + the wake observer. A `Timer` does not
    /// fire while the machine is asleep, so the `NSWorkspace.didWakeNotification`
    /// observer re-checks on resume — together they guarantee a long-running app
    /// re-validates on the weekly cadence without a relaunch.
    private func startCredentialAutoValidateScheduling() {
        autoValidateTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.autoValidatePollInterval,
            repeats: true
        ) { [weak self] _ in
            // Timer fires on the main run loop; hop to the MainActor to touch
            // AppDelegate state, then the async validate runs off-main.
            Task { @MainActor in self?.runCredentialAutoValidateIfDue() }
        }
        // Tolerance lets the OS coalesce the fire for power efficiency.
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        autoValidateTimer = timer

        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runCredentialAutoValidateIfDue() }
            // PKT-381 (Scheduler Resilience): on wake, reconcile + drain any
            // scheduled occurrences that were missed while the Mac slept past a
            // slot. launchd coalesces a sleep-spanning miss into at most one
            // wake-run; this is the durable catch-up that also covers slots
            // launchd dropped. Idempotent — deduped against job_executions.
            Task.detached { await JobsManager.shared.onWakeOrHeartbeatOnline() }
        }
    }

    /// Tear down the WS-5b timer + wake observer.
    private func stopCredentialAutoValidateScheduling() {
        autoValidateTimer?.invalidate()
        autoValidateTimer = nil
        if let observer = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            didWakeObserver = nil
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        print("[The Bridge] Shutting down MCP server...")
        // ITEM [session]: write the clean-shutdown marker SYNCHRONOUSLY here so
        // it lands even though `applicationWillTerminate` cannot reliably await
        // the async `stopSSE()` Task before the process exits (same constraint
        // as the LogManager flush). This preserves the durable session snapshot
        // and stamps the run as cleanly-ended, so on the next launch a returning
        // client gets the resumable re-initialize signal instead of a hard-404.
        // The async `stop()` path (below) ALSO writes the marker; both are
        // idempotent.
        SessionPersistenceStore.recordCleanShutdownSync(reason: "app quit")
        serverTask?.cancel()
        serverTask = nil
        if let manager = serverManager {
            Task { await manager.stopSSE() }
        }

        // WS-5b: stop the periodic auto-validate timer + wake observer.
        stopCredentialAutoValidateScheduling()

        // cmd-w3: tear down the palette hot-key AND its single Carbon event
        // handler if it was registered. No-op when the gate was off
        // (commandBridge == nil). Full teardown (not just unregisterHotkey)
        // so no application-level handler outlives the controller.
        commandBridge?.teardownEventHandler()
        commandBridge = nil

        // PKT-357 F15: End activity assertion
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }

        // PKT-341: Flush LogManager before exit
        Task {
            await LogManager.shared.flush()
            await LogManager.shared.close()
        }

        statusBar.markServerStopped()
        print("[The Bridge] Server stopped.")
    }

    /// PKT-369 W2: Dock icon click opens or brings Settings to front.
    /// When activation policy is .regular (Settings open), clicking the dock
    /// icon should either open Settings or bring it to the foreground.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: - WS-F: bridge-auth:// callback (Bridge Cloud Access)

    /// Handle inbound `bridge-auth://callback?code=…` URLs opened against the
    /// app's registered CFBundleURLTypes scheme. Delegates the brittle
    /// parse → WorkOS token-exchange → Keychain-write → Notification-post to
    /// the unit-tested `CloudAuthCallbackHandler` (lib). The in-flight
    /// `EnableCloudAccessFlow` observes `.cloudAuthCallbackReceived` to
    /// advance from `.signingIn` to `.provisioning`.
    ///
    /// The code→token exchange runs server-side in the kup-worker
    /// (`/auth/exchange`), which holds the WorkOS secret; the Mac only relays
    /// its one-time code (WS-F remediation 2026-06-10).
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.scheme?.lowercased() {
            case "bridge-auth":
                NSLog("[WS-F] bridge-auth callback received: host=\(url.host ?? "nil")")
                cloudAuthCallbackHandler.handle(url)
            case "bridge":
                // PKT-1005 (Pillar A): bridge://settings/<section> deep-link.
                // Coexists with the bridge-auth OAuth callback above — routed
                // strictly by scheme so the cloud-auth path is untouched.
                handleBridgeDeepLink(url)
            default:
                break
            }
        }
    }

    /// PKT-1005: handle a `bridge://settings/<section>` deep-link. The host
    /// names the surface ("settings") and the first path component names the
    /// section ("skills", "security", …, resolved via the same back-compat
    /// aliases bridge_settings_navigate accepts). Opens the Settings window
    /// from cold and deep-links to the section; an unknown/empty section just
    /// opens Settings at the last-selected section.
    private func handleBridgeDeepLink(_ url: URL) {
        guard url.host?.lowercased() == "settings" else {
            NSLog("[PKT-1005] bridge:// deep-link with unknown host=\(url.host ?? "nil") — ignored")
            return
        }
        let rawSection = url.pathComponents.first(where: { $0 != "/" && !$0.isEmpty })
        let section = rawSection.flatMap { BridgeSettingsAutomation.resolveSection($0) }
        NSLog("[PKT-1005] bridge://settings deep-link → section=\(section.map { $0.rawValue } ?? "nil")")
        openSettings(section: section)
    }

    /// The WS-F callback handler, assembled over the production seams
    /// (worker-backed exchange + Keychain persistence).
    private lazy var cloudAuthCallbackHandler = CloudAuthCallbackHandler(
        exchange: WorkerTokenExchange()
    )

    // MARK: - Public API (V1-QUALITY-C2)

    /// Open the Settings window. WS-H (PKT-804): optional `section` deep-links
    /// the menu-bar quick-page straight to a Settings section.
    public func openSettings(section: SettingsSection? = nil) {
        settingsController.show(section: section)
    }

    /// PKT-1006 R3: bring the Bridge app to the FOREGROUND without opening any
    /// specific window (operator-resolved Q1 — not Dashboard, not Settings).
    /// As an `LSUIElement` (menu-bar) app we are normally `.accessory`, so we
    /// flip to `.regular` and activate — the same foreground primitive
    /// `checkForUpdates()` uses. The trailing bridge-mark in the Command Bridge
    /// routes here via the identity-correct `AppDelegate.shared` handle (the
    /// PKT-1005 pattern), replacing the fragile `NSApp.delegate as? AppDelegate`
    /// cast that silently missed under `@NSApplicationDelegateAdaptor`.
    public func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// PKT-430 / PKT-932: Trigger a manual Sparkle update check.
    /// As an `LSUIElement` app we may not be frontmost when the check returns,
    /// so activate first to ensure Sparkle's update window/alert surfaces; and
    /// log the updater's checkable state so a silent no-op (the historical
    /// PKT-932 bug) is diagnosable in the unified log rather than vanishing.
    public func checkForUpdates() {
        // LSUIElement (menu-bar) app: become a regular app so Sparkle's update
        // window/alert can surface as a focused window, then activate.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let u = updaterController.updater
        NSLog("[Bridge][Updater] checkForUpdates tapped — canCheckForUpdates=\(u.canCheckForUpdates) sessionInProgress=\(u.sessionInProgress) feedURL=\(u.feedURL?.absoluteString ?? "nil")")
        // Guarantee user-visible feedback. Sparkle silently ignores a manual
        // check when it cannot start one — most commonly because an automatic
        // download/install session is already in progress (canCheckForUpdates ==
        // false). Historically that produced a dead button with no UI at all.
        // Surface an explicit alert in that state instead of no-op'ing.
        guard u.canCheckForUpdates else {
            let alert = NSAlert()
            if u.sessionInProgress {
                alert.messageText = "An update is already in progress"
                alert.informativeText = "The Bridge is downloading or preparing an update in the background. Quit and reopen The Bridge to finish installing it."
            } else {
                alert.messageText = "Updates are unavailable right now"
                alert.informativeText = "The updater isn’t ready to check at the moment. Please try again in a few seconds."
            }
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSLog("[Bridge][Updater] manual check unavailable — surfaced alert (sessionInProgress=\(u.sessionInProgress))")
            alert.runModal()
            return
        }
        updaterController.checkForUpdates(nil)
    }

    /// Restart app from context menu.
    @objc public func restartApp(_ sender: Any?) {
        TheBridgeLib.restartApp(reopenSettings: true)
    }

    // MARK: - Signal Handlers

    /// PKT-341: Install signal handlers for SIGTERM and SIGABRT.
    /// Ensures log data is flushed to disk before process exits.
    private func installSignalHandlers() {
        signal(SIGTERM, crashFlushHandler)
        signal(SIGABRT, crashFlushHandler)
        print("[The Bridge] Signal handlers installed (SIGTERM, SIGABRT)")
    }

    // MARK: - Rapid Restart Detection (V1-PATCH-003)

    private static let rapidLaunchTimeKey = "com.notionbridge.lastLaunchTime"
    private static let rapidLaunchCountKey = "com.notionbridge.rapidLaunchCount"
    /// 2-minute window for detecting rapid restart cycles.
    private static let rapidRestartWindow: TimeInterval = 120
    /// 3 launches within the window triggers deferred init.
    private static let rapidRestartThreshold = 3

    /// V1-PATCH-003 B1: Detect rapid restart cycle (3+ launches in 2 min).
    /// Returns true if the app has restarted too frequently, indicating a potential
    /// main-thread blocking crash loop. B3: Logs detection for diagnostics.
    private func detectRapidRestart() -> Bool {
        let now = Date().timeIntervalSince1970
        let lastLaunch = UserDefaults.standard.double(forKey: Self.rapidLaunchTimeKey)
        let count = UserDefaults.standard.integer(forKey: Self.rapidLaunchCountKey)

        UserDefaults.standard.set(now, forKey: Self.rapidLaunchTimeKey)
        print("[The Bridge] detectRapidRestart: set lastLaunchTime=\(now)")

        let elapsed = now - lastLaunch
        if elapsed < Self.rapidRestartWindow && lastLaunch > 0 {
            let newCount = count + 1
            UserDefaults.standard.set(newCount, forKey: Self.rapidLaunchCountKey)
            if newCount >= Self.rapidRestartThreshold {
                print("[The Bridge] ⚠️ RAPID RESTART CYCLE: \(newCount) launches in \(Int(elapsed))s — deferring non-critical init by 5s")
                UserDefaults.standard.synchronize()
                return true
            }
            print("[The Bridge] Launch \(newCount)/\(Self.rapidRestartThreshold) within restart window (\(Int(elapsed))s)")
            UserDefaults.standard.synchronize()
            return false
        } else {
            // Outside window — reset counter
            UserDefaults.standard.set(1, forKey: Self.rapidLaunchCountKey)
            UserDefaults.standard.synchronize()
            print("[The Bridge] detectRapidRestart: outside window, reset count=1")
            return false
        }
    }

    // MARK: - Single-Instance Guard

    /// PKT-332: Detect if another instance of this app is already running.
    /// Uses NSRunningApplication to check by bundle identifier.
    /// Returns true if this is the only instance, false if a duplicate exists.
    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "kup.solutions.notion-bridge"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let myPID = ProcessInfo.processInfo.processIdentifier

        let others = running.filter { $0.processIdentifier != myPID }
        if let existing = others.first {
            print("[The Bridge] Duplicate instance detected — PID \(existing.processIdentifier) is already running (my PID: \(myPID))")
            return false
        }

        print("[The Bridge] Single-instance check passed (PID: \(myPID))")
        return true
    }

    private func reopenSettingsIfRequested() {
        guard UserDefaults.standard.bool(forKey: reopenSettingsAfterRestartKey) else {
            return
        }
        UserDefaults.standard.removeObject(forKey: reopenSettingsAfterRestartKey)
        settingsController.show()
    }

    // MARK: - MCP Server

    private func startMCPServer() {
        let statusBar = self.statusBar

        // V1-QUALITY-C2: Client identification callback — updates StatusBarController
        let onClientConnected: @MainActor @Sendable (String, String) -> Void = { name, version in
            statusBar.addClient(name: name, version: version)
        }

        // PKT-366 F13: Client disconnection callback — updates StatusBarController
        let onClientDisconnected: @MainActor @Sendable (String) -> Void = { name in
            statusBar.removeClient(name: name)
        }

        let args = CommandLine.arguments
        var toolAllowlist: Set<String>? = nil
        if let idx = args.firstIndex(of: "--allow-tools"), idx + 1 < args.count {
            let path = args[idx + 1]
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let data = try? Data(contentsOf: url),
               let list = try? JSONDecoder().decode([String].self, from: data) {
                toolAllowlist = Set(list)
                print("[The Bridge] Loaded tool allowlist (\(toolAllowlist?.count ?? 0) tools) from \(path)")
            } else {
                print("[The Bridge] ⚠️ Failed to load allowlist from \(path)")
            }
        }

        let manager = ServerManager(
            onToolCall: {
                statusBar.incrementToolCalls()
            },
            onClientConnected: onClientConnected,
            onClientDisconnected: onClientDisconnected,
            toolAllowlist: toolAllowlist
        )
        self.serverManager = manager

        serverTask = Task.detached {
            let toolCount = await manager.setup()
            await manager.requestSecurityNotificationPermission()
            let port = manager.ssePort

            // PKT-350 F2: Populate tool info for ToolRegistryView
            let toolInfos = await manager.allToolInfo()
            await MainActor.run {
                statusBar.markServerStarted(toolCount: toolCount)
                statusBar.toolInfoList = toolInfos
            }
            print("[The Bridge] MCP server started with \(toolCount) tools (stdio + SSE :\(port))")

            // Run both transports concurrently
            await withTaskGroup(of: Void.self) { group in
                // stdio transport (existing)
                group.addTask {
                    do {
                        try await manager.run()
                    } catch is CancellationError {
                        print("[The Bridge] stdio transport cancelled")
                    } catch {
                        print("[The Bridge] stdio error: \(error.localizedDescription)")
                    }
                }

                // SSE transport (configurable port via NOTION_BRIDGE_PORT)
                // PKT-332: SSEServer.start() now handles bind failures gracefully —
                // if port is in use, it logs and returns without crashing
                group.addTask {
                    do {
                        try await manager.runSSE()
                    } catch is CancellationError {
                        print("[SSE] Transport cancelled")
                    } catch {
                        print("[SSE] Transport error: \(error.localizedDescription)")
                    }
                }

                // PKT-800 S3 (corrected): NO streamableHTTP task is added
                // here. The connector's `/mcp` endpoint is already served
                // by the unconditional `runSSE()` task above (the shared
                // `SSEServer` NIO listener hosts `/mcp` via
                // `StatefulHTTPServerTransport` since PKT-318/336). Adding a
                // gated `runStreamableHTTP()` task would call
                // `SSEServer.start()` a SECOND time concurrently and
                // double-`bind` the same `127.0.0.1:<ssePort>` — the second
                // bind fails "address in use" and is silently swallowed.
                // Connector auth gating is independent of this task: it is
                // built in `ServerManager.setup()` iff
                // `transportRouter.isActive(.streamableHTTP)`
                // (`BRIDGE_ENABLE_HTTP=1`), unchanged. With the env var
                // unset this task group is byte-for-byte the prior
                // stdio+SSE pair; with it set the only difference is the
                // connector-auth context in the single shared listener — no
                // second bind ever occurs.
            }

            await MainActor.run {
                statusBar.markServerStopped()
            }
        }
    }

    // MARK: - Commands Palette (cmd-w3 — default-OFF, additive-isolated)

    /// Pure gating decision, factored OUT of the GUI path so it is
    /// unit-testable headlessly (no NSApp, no hot-key, no panel) — the
    /// same shape as the streamableHTTP connector-gating decision test.
    /// Returns `true` iff the palette should be constructed for this
    /// environment + persisted preference. The palette is now ON BY
    /// DEFAULT: the env var only force-overrides ("1" on / "0" off);
    /// otherwise the persisted master toggle (default true) decides.
    public nonisolated static func shouldStartCommandsPalette(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        CommandsPaletteGate(environment: environment).isEnabled
    }

    /// Construct + register the palette IFF the gate is on. No-op (and no
    /// side effects whatsoever — no hot-key, no panel, no CommandsManager)
    /// when off. The descriptor source is the EXISTING skills registry
    /// (`RegistrySkillsCommandProvider` over `BridgeDefaults.skills`):
    /// every enabled registry entry is a selectable command. On Enter the
    /// resolved page body is written to the system clipboard.
    private func maybeStartCommandsPalette() {
        guard Self.shouldStartCommandsPalette() else {
            print("[The Bridge] Commands palette disabled (master toggle off; set \(CommandsPaletteGate.enableEnvKey)=1 to force on)")
            return
        }
        startCommandsPalette()
    }

    /// cmd-ux W1: the registrar seam the `CommandsController` drives.
    /// Returns a thin adapter over the live `CommandBridgeController` so the
    /// observable state machine and the Carbon glue stay decoupled (the
    /// state machine is unit-tested with an in-memory fake; this adapter
    /// is the production wiring). `nil` when the palette isn't built.
    private var commandsRegistrar: CommandsRegistrar? {
        guard let box = commandBridge else { return nil }
        return CommandBridgeRegistrarAdapter(box: box)
    }

    /// Idempotently build the palette + register the hot-key. Safe to
    /// call repeatedly: if `commandBridge` already exists this is a no-op
    /// (the hot-key stays registered). Used by both startup and the
    /// live Settings toggle. Publishes the REAL registration outcome
    /// into the observable `commandsController` so Settings is live.
    private func startCommandsPalette() {
        if let existing = commandBridge {
            // Already constructed. If a prior Carbon registration failed
            // (the combo was owned by another app at the time), retry it
            // now — the conflicting app may have since released the
            // hot-key. registerHotkey() is idempotent (a no-op `true`
            // when already registered), so this is safe on every call
            // and is the recovery path for a ⌃B collision without a
            // full relaunch.
            if !existing.isRegistered {
                let ok = existing.registerHotkey()
                print("[The Bridge] Commands palette hot-key re-registration \(ok ? "succeeded" : "still FAILED") (\(existing.hotkeyConfig.displayString))")
            }
            commandsController.publishRegistration(
                isRegistered: existing.isRegistered,
                status: existing.lastRegisterStatus,
                hotkey: existing.hotkeyConfig
            )
            return
        }
        // Change B: load the operator-recorded hot-key (falls back to
        // productionDefault ⌃⌘B when unset/corrupt) so a rebind survives a
        // relaunch and a fresh install still gets the default ⌃⌘B.
        let hotkey = HotkeyConfig.loadPersisted()
        let provider = RegistrySkillsCommandProvider()
        let manager = CommandsManager()
        let coordinator = CommandPaletteCoordinator(provider: provider, manager: manager)
        let box = CommandBridgeController(hotkey: hotkey, coordinator: coordinator)
        // v3.7.6: the palette's leading bridge-mark presents the Dashboard
        // popover. The App layer owns the StatusBar / PermissionManager the
        // dashboard reads, so we inject the presenter here.
        box.presentDashboard = { [weak self, weak box] in
            self?.presentCommandBridgeDashboard(anchoredTo: box)
        }
        let registered = box.registerHotkey()
        self.commandBridge = box
        // Publish the TRUE launch-registration outcome into the single
        // observable source of truth (fixes Bug 2 structurally — the
        // status row now reflects the real registration state, live).
        commandsController.publishRegistration(
            isRegistered: box.isRegistered,
            status: box.lastRegisterStatus,
            hotkey: box.hotkeyConfig
        )
        // v4 enterprise-grade: if the FIRST launch registration failed with a
        // transient collision (another login-item / app racing for ⌃⌘B at
        // boot, which then releases it), schedule a single bounded retry. This
        // closes the real-world "registered nothing at launch, stayed inactive
        // forever" gap without the operator having to toggle Commands off/on.
        if !box.isRegistered, case .collision = box.lastRegisterStatus {
            scheduleLaunchHotkeyRetry()
        }
        print("[The Bridge] Commands palette enabled — registry-backed, clipboard-only — hot-key \(registered ? "registered" : "registration FAILED") (\(hotkey.displayString))")
    }

    /// Number of launch-retry attempts remaining for a transient ⌃⌘B
    /// collision. Bounded so a genuine, persistent collision (the combo is
    /// really owned by another app) surfaces the `.comboInUse` warning rather
    /// than retrying forever.
    private var launchHotkeyRetriesRemaining = 3

    /// v4 enterprise-grade: re-attempt the launch hot-key registration after a
    /// short delay when the first attempt hit a transient collision. Re-runs
    /// the idempotent `registerHotkey()` (the handler is install-once, so this
    /// is a single clean Carbon call) and republishes the real outcome so the
    /// status row flips to Active the instant the combo frees up. Stops after a
    /// bounded number of tries OR as soon as registration succeeds.
    private func scheduleLaunchHotkeyRetry() {
        guard launchHotkeyRetriesRemaining > 0 else {
            print("[The Bridge] Commands hot-key still unavailable after launch retries — leaving the conflict surfaced")
            return
        }
        launchHotkeyRetriesRemaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let box = self.commandBridge, !box.isRegistered else { return }
            let ok = box.registerHotkey()
            self.commandsController.publishRegistration(
                isRegistered: box.isRegistered,
                status: box.lastRegisterStatus,
                hotkey: box.hotkeyConfig
            )
            if ok {
                print("[The Bridge] Commands hot-key registered on launch retry (\(box.hotkeyConfig.displayString))")
            } else if case .collision = box.lastRegisterStatus {
                self.scheduleLaunchHotkeyRetry()   // still taken — try again (bounded)
            }
        }
    }

    /// v3.7.6: present the standalone Dashboard popover for the Command Bridge
    /// palette's leading bridge-mark (Option A — reuse `DashboardView` in a
    /// small borderless `NSPanel`). Anchored at the same bottom-centre placement
    /// the palette uses so it appears "off the bar". Toggles closed if already
    /// open; dismisses on resign-key (click-away).
    private func presentCommandBridgeDashboard(anchoredTo box: CommandBridgeController?) {
        // Toggle: a second bridge-mark tap (or re-entry while open) closes it.
        if let existing = commandBridgeDashboardPanel, existing.isVisible {
            dismissCommandBridgeDashboard()
            return
        }

        let host = NSHostingController(
            rootView: DashboardView(
                statusBar: statusBar,
                permissionManager: permissionManager,
                onOpenSettings: { [weak self] section in
                    self?.dismissCommandBridgeDashboard()
                    self?.openSettings(section: section)
                }
            )
        )
        // Size to the SwiftUI content (DashboardView is a fixed 300pt-wide,
        // content-height popover).
        let fitting = host.view.fittingSize
        let size = NSSize(width: max(fitting.width, 300),
                          height: max(fitting.height, 200))

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.wantsLayer = true
        // Rounded card backing so the borderless panel reads as a popover.
        host.view.layer?.cornerRadius = 14
        host.view.layer?.masksToBounds = true
        host.view.layer?.backgroundColor = BridgeTokens.canvasNSColor.cgColor
        panel.contentView = host.view

        // Same bottom-centre placement the palette uses (reuses the controller's
        // PURE, unit-tested screen-pick + origin math).
        let screenFrames = NSScreen.screens.map { $0.visibleFrame }
        if let target = CommandBridgeController.pickScreenFrame(
            screens: screenFrames,
            keyWindowFrame: NSApp.keyWindow?.frame,
            mouseLocation: NSEvent.mouseLocation,
            mainScreenFrame: NSScreen.main?.visibleFrame
        ) {
            panel.setFrameOrigin(
                CommandBridgeController.placementOrigin(
                    screenVisibleFrame: target, panelSize: size
                )
            )
        }

        commandBridgeDashboardPanel = panel
        commandBridgeDashboardResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissCommandBridgeDashboard() }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func dismissCommandBridgeDashboard() {
        if let obs = commandBridgeDashboardResignObserver {
            NotificationCenter.default.removeObserver(obs)
            commandBridgeDashboardResignObserver = nil
        }
        commandBridgeDashboardPanel?.orderOut(nil)
        commandBridgeDashboardPanel = nil
    }

    /// Whether the Commands-palette global hot-key is currently
    /// registered. Drives the Settings status row (Active vs the red
    /// "⚠ Shortcut unavailable"). False when the palette is off or the
    /// Carbon registration failed (the combo is owned by another app).
    public var isCommandsPaletteHotkeyRegistered: Bool {
        // Read the LIVE `commandBridge` (the Carbon truth) first; fall back to
        // the observable mirror only when the palette isn't built. The mirror
        // can be transiently reset by a registrar-less `setEnabled`, so the box
        // is authoritative for "is the hot-key actually live right now".
        commandBridge?.isRegistered ?? commandsController.isRegistered
    }

    /// The combo the Settings recorder should display. The live
    /// controller's config when the palette is running, else the
    /// persisted value (falls back to `productionDefault`). Lets the
    /// recorder show the right glyph even while the palette is OFF.
    public var commandsHotkeyConfig: HotkeyConfig {
        // Reads the single observable source of truth (initialised from
        // the persisted value, updated on every publish/rebind). Public
        // signature unchanged for existing call sites.
        commandsController.hotkeyConfig
    }

    /// The structured outcome of the last Carbon registration attempt, read
    /// from the LIVE `commandBridge` (the Carbon truth) so the Settings status
    /// row never shows "⚠ Shortcut not active" while the hot-key is in fact
    /// registered. The observable mirror can be transiently reset to
    /// `.unattempted` by a registrar-less `setEnabled`; the box is the truth.
    /// Falls back to the controller's published value when the palette is off.
    public var commandsLastRegisterStatus: HotkeyRegisterStatus {
        commandBridge?.lastRegisterStatus ?? commandsController.lastRegisterStatus
    }

    /// Live enable/disable entrypoint for the Settings master toggle.
    /// Persists the preference, then registers/unregisters the global
    /// hot-key WITHOUT a relaunch. Idempotent and safe when `commandBridge`
    /// is nil (disable becomes a clean no-op). An explicit
    /// `BRIDGE_ENABLE_COMMANDS` env override still wins on next launch;
    /// this only writes the persisted pref the gate consults when no
    /// env override is present.
    public func setCommandsPaletteEnabled(_ enabled: Bool) {
        // Public signature preserved; the body now routes through the
        // single observable `CommandsController` for the persisted-pref
        // write + observable `enabled`/state transition. The Carbon
        // construction/teardown stays here (the AppDelegate owns
        // `commandBridge`); the controller publishes the REAL resulting
        // registration so Settings is always live.
        //
        // We persist the pref via the controller (`applyEnabledPreference`,
        // which writes the pref + `enabled` WITHOUT touching the registration
        // status), then do the Carbon work and let `startCommandsPalette()` /
        // `publishUnregistered()` publish the authoritative final status.
        //
        // Ordering note (v4 status-truth fix): when `enabled == true` is
        // requested but a `BRIDGE_ENABLE_COMMANDS=0` kill-switch forces it
        // OFF, the controller must NOT be left at `enabled=true` +
        // `.unattempted` — that renders as a permanent false "⚠ Shortcut not
        // active". So on the kill-switch path we re-publish a clean disabled
        // state instead of returning with the interim enabled flag set.
        if enabled {
            // Persist + reflect the master toggle WITHOUT clobbering the
            // registration-status fields: the registrar-nil `setEnabled(true)`
            // we used to call here ran `publishUnregistered()` as an interim,
            // momentarily resetting a just-published `.registered` to
            // `.unattempted` before `startCommandsPalette()` re-published. The
            // sole writer of registration truth on this path is the
            // `publishRegistration` inside `startCommandsPalette()` below.
            commandsController.applyEnabledPreference(true)
            // Honor a kill-switch env override even on a live toggle:
            // if the env explicitly forces OFF, don't construct.
            guard Self.shouldStartCommandsPalette() else {
                print("[The Bridge] Commands palette toggle ON ignored — \(CommandsPaletteGate.enableEnvKey)=0 forces it OFF")
                // Don't leave a false "enabled but unattempted" warning state —
                // settle to a clean disabled state (toggle off + clean status).
                commandBridge?.unregisterHotkey()
                commandBridge = nil
                commandsController.setEnabled(false, registrar: nil)
                return
            }
            startCommandsPalette() // builds box + publishes real registration
        } else {
            commandsController.applyEnabledPreference(false)
            commandBridge?.unregisterHotkey()
            commandBridge = nil
            commandsController.publishUnregistered()
            print("[The Bridge] Commands palette disabled via Settings — hot-key unregistered")
        }
    }

    /// Live-rebind the Commands-palette global hot-key from the Settings
    /// recorder (Change B). Persists the new `HotkeyConfig` FIRST (so a
    /// relaunch keeps it even if the live re-register loses a race), then
    /// re-registers without a relaunch via the controller's idempotent
    /// unregister+register path. Returns whether the NEW combo registered
    /// successfully so the recorder can reflect Active vs the red
    /// "⚠ unavailable" status. On failure the controller restores the
    /// prior working registration; the persisted value still reflects the
    /// user's intent so they can free the combo and relaunch, or pick
    /// another in-place.
    ///
    /// If the palette is currently OFF (no `commandBridge`) we still persist
    /// — the recorded combo takes effect when the palette is next enabled
    /// — and report `false` (nothing is registered while disabled).
    @discardableResult
    public func setCommandsHotkey(_ config: HotkeyConfig) -> Bool {
        // Public signature preserved; the persist + live-rebind +
        // observable-state publish is now the single
        // `CommandsController.setHotkey(_:registrar:)`. It persists FIRST
        // (relaunch-safe), rebinds via the registrar adapter (when the
        // palette is built), and publishes the REAL outcome
        // (isRegistered + lastRegisterStatus + the live combo) so the
        // Settings status row updates immediately and a true ⌃⌥⌘C
        // collision is distinguishable from a plumbing failure.
        let ok = commandsController.setHotkey(config, registrar: commandsRegistrar)
        if commandBridge == nil {
            print("[The Bridge] Commands hot-key recorded (\(config.displayString)) — palette is OFF; applies when re-enabled")
        } else {
            print("[The Bridge] Commands hot-key rebind \(ok ? "succeeded" : "FAILED (combo taken — kept prior)") (\(config.displayString))")
        }
        return ok
    }

    /// W4 (3.4.1): explicit retry path for the Settings "retry" button —
    /// re-attempts the SAME currently-recorded combo. A transient Carbon
    /// `RegisterEventHotKey` collision (e.g. another app momentarily
    /// holding the same combo) can clear without the operator hunting
    /// for the master toggle. No-op when the palette is disabled.
    @discardableResult
    public func retryHotkeyRegistration() -> Bool {
        guard commandBridge != nil else { return false }
        return setCommandsHotkey(commandsController.hotkeyConfig)
    }

    // MARK: - Notion Token Validation

    /// Validate Notion API token on startup. Updates StatusBarController with result.
    private func validateNotionToken() {
        let statusBar = self.statusBar

        Task.detached {
            // Check if token is available at all
            let tokenStatus = NotionTokenResolver.checkStatus()

            switch tokenStatus {
            case .missing:
                await MainActor.run {
                    statusBar.updateNotionTokenStatus("missing", detail: "Set NOTION_API_TOKEN or add to ~/.config/the-bridge/config.json")
                }
                print("[The Bridge] Notion API token not found")

            case .available(let source):
                // Token found — validate with a test API call
                await MainActor.run {
                    statusBar.updateNotionTokenStatus("disconnected", detail: "Validating...")
                }
                print("[The Bridge] Notion API token found (source: \(source)), validating...")

                do {
                    let client = try NotionClient()
                    let result = await client.validate()

                    await MainActor.run {
                        if result.success {
                            statusBar.updateNotionTokenStatus("connected", detail: result.message)
                            print("[The Bridge] Notion API token validated ✅ (\(result.message))")
                        } else {
                            statusBar.updateNotionTokenStatus("disconnected", detail: result.message)
                            print("[The Bridge] Notion API token validation failed: \(result.message)")
                        }
                    }
                } catch {
                    await MainActor.run {
                        statusBar.updateNotionTokenStatus("disconnected", detail: error.localizedDescription)
                    }
                    print("[The Bridge] Notion client init failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Auto-Launch

    /// Syncs SMAppService login-item registration with the user's launchAtLogin preference.
    /// - launchAtLogin false (default): unregisters any existing entry — no login item.
    /// - launchAtLogin true: unregisters stale entries from previous builds first (binary
    ///   swap leaves orphaned entries), then re-registers cleanly.
    /// BUG-FIX: Was called unconditionally on every launch, ignoring user preference,
    /// causing duplicates after each binary swap and phantom re-registration after TCC restarts.
    private func registerAutoLaunch() {
        let service = SMAppService.mainApp
        let launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false

        if launchAtLogin {
            // Clean up stale entries from previous builds before re-registering
            try? service.unregister()
            do {
                try service.register()
                print("[The Bridge] Auto-launch registered via SMAppService (\(service.status.rawValue))")
            } catch {
                print("[The Bridge] SMAppService registration failed: \(error.localizedDescription)")
            }
        } else {
            // User preference is off — ensure no login item exists
            if service.status != .notRegistered {
                try? service.unregister()
                print("[The Bridge] Auto-launch unregistered (launchAtLogin = false)")
            } else {
                print("[The Bridge] Auto-launch not active (launchAtLogin = false)")
            }
        }
    }
}

// ============================================================
// MARK: - CommandBridgeRegistrarAdapter (cmd-ux W1)
//
//   The production conformance of `CommandsRegistrar`: a thin,
//   stateless adapter that forwards the controller's register/unregister/
//   rebind intent to the live Carbon-backed `CommandBridgeController` and
//   translates the controller's `Bool`/`isRegistered`/`lastRegisterStatus`
//   into the structured `HotkeyRegisterStatus`. Keeps the observable
//   state machine (unit-tested with an in-memory fake) decoupled from
//   the Carbon glue (operator-smoke ceiling).
// ============================================================

@MainActor
final class CommandBridgeRegistrarAdapter: CommandsRegistrar {
    private let box: CommandBridgeController
    init(box: CommandBridgeController) { self.box = box }

    var isRegistered: Bool { box.isRegistered }
    var currentHotkey: HotkeyConfig { box.hotkeyConfig }

    @discardableResult
    func register() -> HotkeyRegisterStatus {
        _ = box.registerHotkey()
        return box.lastRegisterStatus
    }

    func unregister() { box.unregisterHotkey() }

    @discardableResult
    func rebind(to config: HotkeyConfig) -> HotkeyRegisterStatus {
        _ = box.rebind(to: config)
        return box.lastRegisterStatus
    }
}
