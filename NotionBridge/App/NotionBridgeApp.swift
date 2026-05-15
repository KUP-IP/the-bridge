// NotionBridgeApp.swift — @main App Entry Point
// Notion Bridge v2: macOS Tahoe 26 — Liquid Glass
// PKT-353: Removed sparkle fallback, content-adaptive popover, Liquid Glass adoption.
// v2.3 (PKT-804): Cursor integration retired — MenuBarExtra label renders
//   the Bridge icon (NB text fallback when the icon asset is unavailable).
// Previous history: PKT-317, PKT-341, PKT-342, V1-QUALITY-C2, PKT-349 B1
// No Dock icon — pure menu bar app via MenuBarExtra pattern

import SwiftUI
import NotionBridgeLib

/// Load menu bar icon from SPM resource bundle.
/// Uses the bridge logo as a template image for the menu bar.
/// Source PNGs are RGBA with clean transparency (low-alpha pixels pre-zeroed).
/// PKT-353: Unified to Bundle.module (SPM executable target with processed resources).
/// Bundle.main kept as secondary lookup for .app packaging scenarios.
/// Icon sized at 30pt for optimal display on notched MacBook Pro menu bars.
private func loadMenuBarIcon() -> NSImage? {
    let nsImage: NSImage? =
        Bundle.module.image(forResource: "MenuBarIcon")
        ?? Bundle.main.image(forResource: "MenuBarIcon")
    guard let nsImage else { return nil }
    nsImage.size = NSSize(width: 30, height: 30)
    nsImage.isTemplate = true
    return nsImage
}

@main
struct NotionBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Pre-load the icon once to avoid repeated loading in body evaluations
    private let menuBarIcon: NSImage? = loadMenuBarIcon()

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
            if let menuBarIcon {
                Image(nsImage: menuBarIcon)
            } else {
                Text("NB")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
