// WindowTracker.swift — Dynamic Activation Policy for Settings Windows
// PKT-369 W1/W3: Switches between .accessory (menu bar only) and .regular
// (Dock icon + Cmd+Tab + Mission Control) based on Settings window visibility.
//
// Both SettingsWindowController (gear icon) and SwiftUI Settings scene (Cmd+,)
// are tracked via global NSWindow notifications. No manual registration needed.
//
// W4: LSUIElement remains true in Info.plist — policy is overridden at runtime only.

import AppKit

/// Tracks Settings window lifecycle and toggles NSApplication activation policy.
/// When any Settings-class window is visible → .regular (Dock + Cmd+Tab).
/// When no Settings-class windows are visible → .accessory (menu bar only).
@MainActor
public final class WindowTracker {
    private var observers: [NSObjectProtocol] = []
    private var isRecoveringConfirm = false

    public init() {
        setupObservers()
        print("[WindowTracker] Initialized — observing Settings window lifecycle")
    }

    private func setupObservers() {
        // Track when any window becomes key (visible + focused)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.evaluatePolicy() }
            }
        )

        // Track when any window is about to close
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // Brief delay to allow window close to complete
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    self?.evaluatePolicy()
                }
            }
        )

        // Also track window ordering changes (e.g., miniaturize/deminiaturize)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.evaluatePolicy() }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.evaluatePolicy() }
            }
        )
        // Confirm uses orderOut (not close) — willClose never fires.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .confirmPanelDidChange,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.evaluatePolicy() }
            }
        )
    }

    /// Evaluate whether any Settings-class or Confirm windows are visible
    /// and toggle activation policy accordingly. Confirm must keep `.regular`
    /// (#262) — accessory LSUIElement windows hide on deactivate.
    public func evaluatePolicy() {
        let pendingConfirmCount = PendingApprovalSurface.shared.pendingCount
        // Become regular *before* looking for / creating the panel. Accessory
        // creation is why live `TheBridge windows=0` (#262 on 2bd375aa).
        if pendingConfirmCount > 0 {
            ConfirmFrontApplicator.prepareApp()
        }
        let hasVisibleSettings = NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized && isSettingsWindow(window)
        }
        var hasVisibleConfirm = NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized
                && ConfirmDelivery.isConfirmWindowTitle(window.title)
        }
        // Panel can lose the first orderFront (LSUIElement / Task hop).
        // Re-sync while a Request is still pending so the body returns.
        if pendingConfirmCount > 0 && !hasVisibleConfirm && !isRecoveringConfirm {
            isRecoveringConfirm = true
            ConfirmPanelController.shared.sync()
            isRecoveringConfirm = false
            hasVisibleConfirm = NSApp.windows.contains { window in
                window.isVisible && !window.isMiniaturized
                    && ConfirmDelivery.isConfirmWindowTitle(window.title)
            }
        }

        let currentPolicy = NSApp.activationPolicy()
        let wantRegular = ConfirmDelivery.shouldUseRegularActivationPolicy(
            hasVisibleSettings: hasVisibleSettings,
            hasVisibleConfirm: hasVisibleConfirm,
            pendingConfirmCount: pendingConfirmCount
        )

        if wantRegular && currentPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
            // Confirm steals focus; Settings still uses the W1 delayed activate.
            if hasVisibleConfirm {
                NSApp.activate(ignoringOtherApps: true)
                print("[WindowTracker] Activation policy → .regular (Confirm visible)")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: false)
                }
                print("[WindowTracker] Activation policy → .regular (Settings visible)")
            }
        } else if !wantRegular && currentPolicy != .accessory {
            NSApp.setActivationPolicy(.accessory)
            print("[WindowTracker] Activation policy → .accessory (no Settings/Confirm windows)")
        }
    }

    /// Determines if a window is a Settings-class window.
    /// Matches SettingsWindowController ("The Bridge Settings") and
    /// SwiftUI Settings scene windows. Excludes popover, onboarding, etc.
    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        let title = window.title
        return title == "The Bridge Settings"
            || title == "The Bridge Settings"
            || title == "Settings"
            || title == "Preferences"
            || title.hasSuffix(" Settings")
            || title.hasSuffix(" Preferences")
    }
}
