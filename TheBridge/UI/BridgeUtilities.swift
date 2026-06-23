// BridgeUtilities.swift — Shared app-level utilities for The Bridge UI.
// PKT-547: Extracted restartApp() out of PermissionView so DashboardView and
//   PermissionView can share a single restart implementation. Spawns a detached
//   shell that re-opens the bundle after a short delay, then terminates the
//   current instance.

import AppKit
import Foundation

public extension NSApplication {
    /// Relaunch the current app bundle after a brief delay, then terminate.
    /// Proven pattern: spawn `/bin/sh -c "sleep 1 && open '<bundle>'"` so the
    /// replacement process outlives the terminate() call.
    func restartBridge() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open '\(bundlePath)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}
