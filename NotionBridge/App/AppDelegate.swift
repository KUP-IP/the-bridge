// AppDelegate.swift — App Lifecycle + MCP Server + SMAppService Auto-Launch
// Notion Bridge v1: Unified binary — starts MCP server on launch, stops on quit
// PKT-317: Merged server runtime into NotionBridge via ServerManager
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

/// Manages app lifecycle, auto-launch registration, and MCP server lifecycle.
/// The server starts in a detached Task on launch (Nudge Server pattern) so the
/// SwiftUI main thread is never blocked. StatusBarController receives live updates
/// for connections, tool calls, Notion token status, and uptime.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
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

    /// V1-QUALITY-C2: Onboarding window controller for first-launch experience.
    private lazy var onboardingController = OnboardingWindowController(
        permissionManager: permissionManager
    )

    /// V1-QUALITY-C2: Settings window controller for gear icon / Cmd+, access.
    private lazy var settingsController = SettingsWindowController(
        statusBar: statusBar,
        permissionManager: permissionManager
    )

    public override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // PKT-431: Force revalidation on every appcast fetch to prevent stale NSURLSession cache.
        updaterController.updater.httpHeaders = ["Cache-Control": "no-cache"]
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // PKT-487 → PKT-1 v3.5: Dock label uses the new display name
        // (executable bundle name is still "NotionBridge" — that's the
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

        CredentialsFeature.migrateIfNeeded()

        // PKT-441: One-time Stripe key migration to unified credential vault
        Task { await ConnectionRegistry.shared.migrateStripeKeyIfNeeded() }

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

        // PKT-349 B2: Observe reset onboarding notification from Settings.
        // Dispatch to MainActor to satisfy Swift 6 strict concurrency.
        NotificationCenter.default.addObserver(forName: .resetOnboarding, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.onboardingController.show()
            }
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

        reopenSettingsIfRequested()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        print("[The Bridge] Shutting down MCP server...")
        serverTask?.cancel()
        serverTask = nil
        if let manager = serverManager {
            Task { await manager.stopSSE() }
        }

        // cmd-w3: tear down the palette hot-key if it was registered.
        // No-op when the gate was off (commandBridge == nil).
        commandBridge?.unregisterHotkey()
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

    // MARK: - Public API (V1-QUALITY-C2)

    /// Open the Settings window. WS-H (PKT-804): optional `section` deep-links
    /// the menu-bar quick-page straight to a Settings section.
    public func openSettings(section: SettingsSection? = nil) {
        settingsController.show(section: section)
    }

    /// PKT-430: Trigger manual Sparkle update check.
    public func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Restart app from context menu.
    @objc public func restartApp(_ sender: Any?) {
        NotionBridgeLib.restartApp(reopenSettings: true)
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
        // productionDefault when unset/corrupt) so a rebind survives a
        // relaunch and a fresh install still gets the default ⌃⌥⌘C.
        let hotkey = HotkeyConfig.loadPersisted()
        let provider = RegistrySkillsCommandProvider()
        let manager = CommandsManager()
        let coordinator = CommandPaletteCoordinator(provider: provider, manager: manager)
        let box = CommandBridgeController(hotkey: hotkey, coordinator: coordinator)
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
        print("[The Bridge] Commands palette enabled — registry-backed, clipboard-only — hot-key \(registered ? "registered" : "registration FAILED") (\(hotkey.displayString))")
    }

    /// Whether the Commands-palette global hot-key is currently
    /// registered. Drives the Settings status row (Active vs the red
    /// "⚠ Shortcut unavailable"). False when the palette is off or the
    /// Carbon registration failed (the combo is owned by another app).
    public var isCommandsPaletteHotkeyRegistered: Bool {
        // Reads the single observable source of truth (kept in lock-step
        // with the live `commandBridge` via the publish* calls). Public
        // signature unchanged for existing call sites.
        commandsController.isRegistered
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
        // We persist the pref via the controller (registrar nil here so
        // it only writes the pref + a clean interim state), then do the
        // Carbon work and let `startCommandsPalette()` /
        // `publishUnregistered()` publish the authoritative final state.
        commandsController.setEnabled(enabled, registrar: nil)
        if enabled {
            // Honor a kill-switch env override even on a live toggle:
            // if the env explicitly forces OFF, don't construct.
            guard Self.shouldStartCommandsPalette() else {
                print("[The Bridge] Commands palette toggle ON ignored — \(CommandsPaletteGate.enableEnvKey)=0 forces it OFF")
                return
            }
            startCommandsPalette() // builds box + publishes real registration
        } else {
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
