// ConfirmSurfaceSync.swift — LSUIElement force-front plan
// TheBridge · Security
//
// #262 LIVE FAIL on installed 2bd375aa (PR #269): Confirm NSPanel never
// appeared (`TheBridge windows=0`). PR #269 flipped `.regular` *inside*
// `ConfirmFrontApplicator.apply` *after* the panel was created while the
// app was still `.accessory`. LSUIElement windows created in accessory
// policy are omitted from `NSApp.windows` and AX/OCR.
//
// This type is the hermetic plan the live presenter must execute.
// TheBridgeTests has no WindowServer; it asserts the step order.

import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Ordered commands required to surface Confirm on an LSUIElement app.
public enum ConfirmSurfaceCommand: String, Sendable, Equatable {
    case setRegularActivationPolicy
    case unhideApp
    case activateIgnoringOtherApps
    case createOrReusePanel
    case applyFront
}

/// Accessory vs regular — hermetic stand-in for `NSApplication.activationPolicy`.
public enum ConfirmActivationPolicy: String, Sendable, Equatable {
    case accessory
    case regular
}

/// LSUIElement force-front contract. Live `ConfirmPanelController` /
/// `ConfirmFrontApplicator` must follow `forceSurfacePlan`.
public enum ConfirmSurfaceSync {
    /// Windows created while still `.accessory` do not join `NSApp.windows`.
    public static func mustPreparePolicyBeforeCreatingWindow(
        currentPolicy: ConfirmActivationPolicy
    ) -> Bool {
        currentPolicy == .accessory
    }

    /// Step list for a pending Request. Empty when nothing is in-flight.
    public static func forceSurfacePlan(
        currentPolicy: ConfirmActivationPolicy,
        pendingPromptCount: Int,
        hasVisibleConfirmWindow: Bool
    ) -> [ConfirmSurfaceCommand] {
        guard ConfirmDelivery.shouldPresentPanel(pendingPromptCount: pendingPromptCount) else {
            return []
        }
        var steps: [ConfirmSurfaceCommand] = []
        if currentPolicy == .accessory {
            steps.append(.setRegularActivationPolicy)
        }
        steps.append(.unhideApp)
        steps.append(.activateIgnoringOtherApps)
        if !hasVisibleConfirmWindow {
            steps.append(.createOrReusePanel)
        }
        steps.append(.applyFront)
        return steps
    }

    /// First create/front step index — tests assert it is after the policy flip.
    public static func firstWindowCommandIndex(
        in plan: [ConfirmSurfaceCommand]
    ) -> Int? {
        plan.firstIndex(where: {
            $0 == .createOrReusePanel || $0 == .applyFront
        })
    }
}

/// Direct AppKit sync so presentation does not depend only on
/// `NotificationCenter` + `MainActor.assumeIsolated` (PR #269 host observer).
public enum ConfirmPanelSyncBridge: Sendable {
    /// Live app sets this to `ConfirmPanelController.shared.sync`.
    nonisolated(unsafe) public static var sync: (@MainActor () -> Void)?

    public static func requestSync() {
        // Explicit Void return: a bare `Task { }` closure is inferred as
        // `() -> Task<Void?, Never>`, which does not match
        // `DispatchQueue.main.async(execute:)` (`DispatchWorkItem` / `() -> Void`).
        let work: () -> Void = {
            Task { @MainActor in
                sync?()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    public static func resetForTesting() {
        sync = nil
    }
}
