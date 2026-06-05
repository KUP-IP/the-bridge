// NotionBridgeApp.swift — @main App Entry Point
// Notion Bridge v2: macOS Tahoe 26 — Liquid Glass
// PKT-353: Removed sparkle fallback, content-adaptive popover, Liquid Glass adoption.
// v2.3 (PKT-804): Cursor integration retired — MenuBarExtra label renders
//   the Bridge icon (NB text fallback when the icon asset is unavailable).
// Previous history: PKT-317, PKT-341, PKT-342, V1-QUALITY-C2, PKT-349 B1
// No Dock icon — pure menu bar app via MenuBarExtra pattern

import SwiftUI
import NotionBridgeLib

/// Load the menu bar icon — NEVER fatal (fix(sparkle), 2026-06-05).
///
/// HISTORY: this used to read the icon via the SPM-generated `Bundle.module`
/// accessor. That accessor is synthesized to TRAP (`_assertionFailure`) when
/// the resource bundle is missing or corrupt — so a raced Sparkle staged-update
/// swap that left `NotionBridge_NotionBridge.bundle` without a `Contents/` dir
/// made this function SIGTRAP on EVERY launch (a bootable-but-crash-looping app
/// needing manual recovery).
///
/// We now delegate to `MenuBarIconResolver`, which resolves the icon through
/// non-trapping `Bundle(path:)` candidate lookups and falls back to a system
/// SF Symbol if the resource bundle / asset is unloadable. It ALWAYS returns a
/// usable image, so the app always boots. (Bundle.module is never touched on the
/// launch path.) Icon sized at 30pt for notched MacBook Pro menu bars.
@MainActor
private func loadMenuBarIcon() -> NSImage {
    MenuBarIconResolver.makeMenuBarImage()
}

@main
struct NotionBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Pre-load the icon once to avoid repeated loading in body evaluations.
    /// Always non-nil — `loadMenuBarIcon()` degrades to an SF Symbol rather than
    /// returning nil / trapping (fix(sparkle), 2026-06-05).
    private let menuBarIcon: NSImage = loadMenuBarIcon()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                statusBar: appDelegate.statusBar,
                permissionManager: appDelegate.permissionManager,
                onOpenSettings: { section in
                    appDelegate.openSettings(section: section)
                }
            )
        } label: {
            // Always an image: a resource icon when the SPM bundle is intact,
            // otherwise the SF Symbol fallback from MenuBarIconResolver. The
            // "NB" text fallback is no longer reachable — the resolver never
            // returns nil — but the icon is always present so the menu-bar item
            // stays clickable even with a corrupt resource bundle.
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
