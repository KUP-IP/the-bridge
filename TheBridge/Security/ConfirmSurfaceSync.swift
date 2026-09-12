// ConfirmSurfaceSync.swift — LSUIElement force-front plan
// TheBridge · Security
//
// #262 LIVE FAIL on installed b8045b61 (PR #271): Confirm NSPanel never
// appeared (`TheBridge windows=0`). PR #271 flipped `.regular` *inside*
// `prepareApp` then created the window on the **same run-loop turn**.
// WindowServer still treats that create as LSUIElement accessory, so the
// window is omitted from `NSApp.windows` / AX / OCR.
//
// This type is the sequencer the live presenter must execute — not a
// parallel plan that tests check while AppKit takes another path.
// `ConfirmWindowServerProbe` models the live miss: create without a
// yield after `.regular` → windows stay empty.

import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Ordered commands required to surface Confirm on an LSUIElement app.
public enum ConfirmSurfaceCommand: String, Sendable, Equatable {
    case setRegularActivationPolicy
    case unhideApp
    case activateIgnoringOtherApps
    /// WindowServer must observe the policy flip before the window exists.
    case yieldForWindowServer
    case createOrReusePanel
    case applyFront
}

/// Accessory vs regular — hermetic stand-in for `NSApplication.activationPolicy`.
public enum ConfirmActivationPolicy: String, Sendable, Equatable {
    case accessory
    case regular
}

/// Live / test surface the sequencer drives. AppKit is one runtime;
/// `ConfirmWindowServerProbe` is the hermetic WindowServer stand-in.
@MainActor
public protocol ConfirmSurfaceRuntime: AnyObject {
    var currentPolicy: ConfirmActivationPolicy { get }
    var hasVisibleConfirmWindow: Bool { get }
    func apply(_ command: ConfirmSurfaceCommand)
}

/// LSUIElement force-front contract. Live `ConfirmPanelController`
/// must call `run` — tests fail if create happens without the yield.
public enum ConfirmSurfaceSync {
    /// Windows created while still `.accessory` do not join `NSApp.windows`.
    public static func mustPreparePolicyBeforeCreatingWindow(
        currentPolicy: ConfirmActivationPolicy
    ) -> Bool {
        currentPolicy == .accessory
    }

    /// Same-turn create after `setActivationPolicy(.regular)` is still
    /// omitted by WindowServer (LIVE on b8045b61 / PR #271).
    public static func windowJoinsAppWindows(
        policy: ConfirmActivationPolicy,
        yieldedAfterRegular: Bool
    ) -> Bool {
        policy == .regular && yieldedAfterRegular
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
            steps.append(.yieldForWindowServer)
            steps.append(.createOrReusePanel)
        }
        steps.append(.applyFront)
        return steps
    }

    /// First create step — tests assert it is after policy flip AND yield.
    public static func firstWindowCommandIndex(
        in plan: [ConfirmSurfaceCommand]
    ) -> Int? {
        plan.firstIndex(of: .createOrReusePanel)
    }

    public static func yieldIndex(in plan: [ConfirmSurfaceCommand]) -> Int? {
        plan.firstIndex(of: .yieldForWindowServer)
    }

    /// Next-turn hop so WindowServer observes `.regular` before create.
    public static func scheduleAfterWindowServerYield(
        _ work: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.async {
            Task { @MainActor in
                work()
            }
        }
    }

    /// Drive `runtime` through `forceSurfacePlan`. Yield hops via `hop`
    /// (live: next main-queue turn; tests: sync `{ $0() }` or a recorder).
    /// `hop` is `@escaping` because the yield recursion captures it inside
    /// the work closure (`-strict-concurrency=complete`).
    @MainActor
    public static func run(
        pendingPromptCount: Int,
        runtime: ConfirmSurfaceRuntime,
        hop: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
            scheduleAfterWindowServerYield(work)
        }
    ) {
        let plan = forceSurfacePlan(
            currentPolicy: runtime.currentPolicy,
            pendingPromptCount: pendingPromptCount,
            hasVisibleConfirmWindow: runtime.hasVisibleConfirmWindow
        )
        applyRemaining(ArraySlice(plan), runtime: runtime, hop: hop)
    }

    @MainActor
    private static func applyRemaining(
        _ commands: ArraySlice<ConfirmSurfaceCommand>,
        runtime: ConfirmSurfaceRuntime,
        hop: @escaping (@escaping @MainActor () -> Void) -> Void
    ) {
        var rest = commands
        while let command = rest.first {
            rest = rest.dropFirst()
            runtime.apply(command)
            if command == .yieldForWindowServer {
                let remaining = Array(rest)
                let resume = hop
                resume {
                    applyRemaining(remaining[...], runtime: runtime, hop: resume)
                }
                return
            }
        }
    }
}

/// Hermetic WindowServer. Accessory create, or regular create without a
/// yield after the policy flip, leaves `windows` empty — the live miss.
@MainActor
public final class ConfirmWindowServerProbe: ConfirmSurfaceRuntime {
    public var currentPolicy: ConfirmActivationPolicy
    public private(set) var executed: [ConfirmSurfaceCommand] = []
    public private(set) var windows: [String] = []
    public private(set) var yieldCount = 0
    private var yieldedAfterRegular = false

    public init(policy: ConfirmActivationPolicy = .accessory) {
        self.currentPolicy = policy
    }

    public var hasVisibleConfirmWindow: Bool { !windows.isEmpty }

    public func apply(_ command: ConfirmSurfaceCommand) {
        executed.append(command)
        switch command {
        case .setRegularActivationPolicy:
            currentPolicy = .regular
            yieldedAfterRegular = false
        case .unhideApp, .activateIgnoringOtherApps:
            break
        case .yieldForWindowServer:
            yieldCount += 1
            if currentPolicy == .regular {
                yieldedAfterRegular = true
            }
        case .createOrReusePanel:
            if ConfirmSurfaceSync.windowJoinsAppWindows(
                policy: currentPolicy,
                yieldedAfterRegular: yieldedAfterRegular
            ) {
                windows.append(ConfirmPanelController.windowTitle)
            }
        case .applyFront:
            break
        }
    }

    /// PR #271 presenter: policy + activate + create on one turn (no yield).
    public func applySkippedYieldCreate() {
        apply(.setRegularActivationPolicy)
        apply(.unhideApp)
        apply(.activateIgnoringOtherApps)
        apply(.createOrReusePanel)
        apply(.applyFront)
    }
}

/// Live app sets `makeRuntime` to AppKit; tests inject the WindowServer probe.
public enum ConfirmSurfaceSession {
    nonisolated(unsafe) public static var makeRuntime:
        @MainActor ([PendingApprovalPrompt]) -> any ConfirmSurfaceRuntime = { prompts in
            ConfirmAppKitSurfaceRuntime(prompts: prompts)
        }

    public static func resetForTesting() {
        makeRuntime = { prompts in
            ConfirmAppKitSurfaceRuntime(prompts: prompts)
        }
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
