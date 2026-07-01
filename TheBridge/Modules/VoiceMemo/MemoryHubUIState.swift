// MemoryHubUIState.swift — Process-active notification gate inputs (PKT-MEM-120)
// TheBridge · Modules · VoiceMemo

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Tracks whether Memory → Process is the active operator surface for notification suppression.
@MainActor
public enum MemoryHubUIState {
    private static var memorySectionVisible = false
    private static var processTabSelected = false

    /// Hermetic test seam — when set, `appActive` returns this value.
    nonisolated(unsafe) public static var testAppActiveOverride: Bool?

    public static func setMemorySectionVisible(_ visible: Bool) {
        memorySectionVisible = visible
    }

    public static func setProcessTabSelected(_ selected: Bool) {
        processTabSelected = selected
    }

    public static var processSelected: Bool {
        memorySectionVisible && processTabSelected
    }

    public static var appActive: Bool {
        if let testAppActiveOverride { return testAppActiveOverride }
        #if canImport(AppKit)
        return NSApplication.shared.isActive
        #else
        return false
        #endif
    }

    public static var shouldSuppressNotifications: Bool {
        MemoryHubNotificationGate.shouldSuppress(appActive: appActive, processSelected: processSelected)
    }
}
