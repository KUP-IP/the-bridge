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
    }

    /// Evaluate whether any Settings-class windows are visible
    /// and toggle activation policy accordingly.
    public func evaluatePolicy() {
        let hasVisibleSettings = NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized && isSettingsWindow(window)
        }

        let currentPolicy = NSApp.activationPolicy()

        if hasVisibleSettings && currentPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
            // Brief delay before activate to avoid focus stealing (W1 risk mitigation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: false)
            }
            print("[WindowTracker] Activation policy → .regular (Settings visible)")
        } else if !hasVisibleSettings && currentPolicy != .accessory {
            NSApp.setActivationPolicy(.accessory)
            print("[WindowTracker] Activation policy → .accessory (no Settings windows)")
        }
    }

    /// Determines if a window is a Settings-class window.
    /// Matches SettingsWindowController ("The Bridge Settings") and
    /// SwiftUI Settings scene windows. Excludes popover, onboarding, etc.
    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        let title = window.title
        return title == "The Bridge Settings"
            || title == "Notion Bridge Settings"
            || title == "Settings"
            || title == "Preferences"
            || title.hasSuffix(" Settings")
            || title.hasSuffix(" Preferences")
    }
}
