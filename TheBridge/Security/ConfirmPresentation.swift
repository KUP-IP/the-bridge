// ConfirmPresentation.swift — Confirm body host (not ATTENTION-only)
// TheBridge · Security
//
// #260 published a menu-bar badge + Dashboard Confirm card. Live-verify on
// installed main (PR #260) showed ATTENTION / "N Confirm waiting" working,
// then a status-item click cleared the badge and never presented
// Deny / Allow / Always Allow (MenuBarExtra `.window` on LSUIElement
// produced 0 AX windows; UN default/dismiss was mapped to Deny).
//
// This type is the single action path for:
//   • status-item / ATTENTION click
//   • remote (or local) Request publish
//   • SECURITY_APPROVAL banner tap / swipe-away
// Explicit Deny / Allow / Always Allow (and expiry) still resolve.
// Default tap and dismiss only present the Confirm body.

import Foundation
import UserNotifications

/// Result of a UN action or status-item click against an in-flight Confirm.
public enum ConfirmNotificationOutcome: Equatable, Sendable {
    /// Operator chose Deny / Allow / Always Allow — resume the gate.
    case resolve(SecurityApprovalDecision)
    /// Open the Confirm body. Do **not** clear pending or the badge.
    case presentBody
}

/// Keyboard / default-button role for Confirm actions (#264).
public enum ConfirmKeyboardRole: String, Sendable, Equatable {
    case cancel
    case none
}

/// Pure mapping + presented-state host for the Confirm body.
public enum ConfirmPresentation {
    public static let denyTitle = "Deny"
    public static let allowTitle = "Allow"
    public static let alwaysAllowTitle = "Always Allow"

    /// Titles shown on the Confirm body. Always Allow is on every
    /// Request card (#258) unless the prompt itself opts out.
    /// Order is Deny / Allow / Always Allow for the contract; the
    /// view paints Always Allow as the visual primary (#262).
    public static func actionTitles(allowAlwaysAllow: Bool) -> [String] {
        if allowAlwaysAllow {
            return [denyTitle, allowTitle, alwaysAllowTitle]
        }
        return [denyTitle, allowTitle]
    }

    /// Compact `SECURITY_APPROVAL` banner actions. **Allow is first** so a
    /// first-action / Focus / compact-button misfire is one-shot Allow and
    /// cannot persist a Notify sticky (#264). Always Allow stays the second
    /// visible compact action (macOS shows the first two without expanding).
    public static func compactBannerActionIdentifiers(allowAlwaysAllow: Bool) -> [String] {
        if allowAlwaysAllow {
            return [
                NotificationApprovalManager.allowActionIdentifier,
                NotificationApprovalManager.alwaysAllowActionIdentifier,
                NotificationApprovalManager.cancelActionIdentifier
            ]
        }
        return [
            NotificationApprovalManager.allowActionIdentifier,
            NotificationApprovalManager.cancelActionIdentifier
        ]
    }

    /// LSUIElement / AppKit keyboard role. Always Allow must never be the
    /// default button — Return / Focus delivery must not persist Notify (#264).
    public static func keyboardRole(forActionTitle title: String) -> ConfirmKeyboardRole {
        if title == denyTitle { return .cancel }
        return .none
    }

    /// Always Allow on the Confirm body is a tap-only control, not a
    /// SwiftUI `Button`. The first `Button` in an NSHostingController
    /// becomes AppKit's default button after layout and can fire without
    /// an Always Allow tap (#264 LIVE on f1c71cc7).
    public static let alwaysAllowIsDefaultCapableControl = false

    /// UN never persists Notify. Time Sensitive / LSUIElement can invoke
    /// ALWAYS_ALLOW with no tap (LIVE on b8045b61). Always Allow persist
    /// is Confirm-surface tap only (`applySurfaceDecision`).
    public static func shouldPersistNotifySticky(
        forNotificationActionIdentifier identifier: String
    ) -> Bool {
        _ = identifier
        return false
    }

    /// SECURITY_APPROVAL actions only. Unknown / default / dismiss /
    /// banner Always Allow present the body — they must not grant, must
    /// not Deny, and must not persist. Allow / Cancel still resolve.
    public static func outcome(forNotificationActionIdentifier identifier: String) -> ConfirmNotificationOutcome {
        switch identifier {
        case NotificationApprovalManager.allowActionIdentifier:
            return .resolve(.allow)
        case NotificationApprovalManager.alwaysAllowActionIdentifier:
            return .presentBody
        case NotificationApprovalManager.cancelActionIdentifier:
            return .resolve(.deny)
        case UNNotificationDefaultActionIdentifier,
             UNNotificationDismissActionIdentifier:
            return .presentBody
        default:
            return .presentBody
        }
    }
}

/// AppKit Confirm panel. The host calls this after every surface-driven
/// present/hide so live fronting does not depend on AppDelegate's
/// `Task { @MainActor }` hop (#262 LIVE on f1c71cc7). The surface
/// observer itself is `MainActor.assumeIsolated` on `queue: .main` —
/// no second Task hop.
@MainActor
public protocol ConfirmPanelPresenting: AnyObject {
    func syncConfirmPanel()
}

/// In-process Confirm body. AppKit presents a sticky Confirm window from
/// this state; tests assert presentation without a WindowServer window.
@MainActor
@Observable
public final class ConfirmPanelHost {
    public static let shared = ConfirmPanelHost()

    public private(set) var isPresented: Bool = false
    public private(set) var prompts: [PendingApprovalPrompt] = []
    public private(set) var lastPresentReason: PresentReason = .none
    /// Live app sets this to `ConfirmPanelController`. Tests inject a recorder.
    public weak var presenter: ConfirmPanelPresenting?
    private var surfaceObserver: NSObjectProtocol?

    public enum PresentReason: String, Sendable, Equatable {
        case none
        case statusItemClick
        case pendingRequest
        case notificationPresentBody
    }

    public init() {
        bindToSurface()
    }

    /// Observe `pendingApprovalSurfaceDidChange` so a remote MCP
    /// `awaiting_approval` publish auto-presents without AppDelegate.
    public func bindToSurface() {
        guard surfaceObserver == nil else { return }
        surfaceObserver = NotificationCenter.default.addObserver(
            forName: .pendingApprovalSurfaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main already delivers on the main thread. A second
            // Task hop races status-item click vs. surface re-assert
            // (CI flake on be574b51: lastPresentReason overwritten
            // before the next MainActor.run). Same pattern as
            // EnableCloudAccessFlow's auth callback.
            MainActor.assumeIsolated {
                self?.handleSurfaceChange()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .pendingApprovalSurfacePresentBody,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePresentBodyRequest()
            }
        }
    }

    public var badgeCount: Int {
        PendingApprovalSurface.shared.pendingCount
    }

    /// Flattened Deny / Allow / Always Allow titles for the visible cards.
    public var visibleActionTitles: [String] {
        guard isPresented, let first = prompts.first else { return [] }
        return ConfirmPresentation.actionTitles(allowAlwaysAllow: first.allowAlwaysAllow)
    }

    /// Status-item / ATTENTION click. Opens the body when anything is
    /// pending. Never toggles closed and never clears the surface.
    public func handleStatusItemClick() {
        refreshPrompts()
        guard !prompts.isEmpty else { return }
        isPresented = true
        lastPresentReason = .statusItemClick
        presenter?.syncConfirmPanel()
    }

    /// Surface publish / remove. A new pending Request **always** presents
    /// the body (remote and local — origin is not a second gate). ATTENTION
    /// badge alone is not sufficient (#262). Empty → hide.
    public func handleSurfaceChange() {
        refreshPrompts()
        if prompts.isEmpty {
            isPresented = false
            lastPresentReason = .none
        } else {
            isPresented = true
            lastPresentReason = .pendingRequest
        }
        presenter?.syncConfirmPanel()
    }

    /// Banner tap or swipe-away: same body as a status-item click.
    public func handlePresentBodyRequest() {
        refreshPrompts()
        guard !prompts.isEmpty else { return }
        isPresented = true
        lastPresentReason = .notificationPresentBody
        presenter?.syncConfirmPanel()
    }

    public func resetForTesting() {
        isPresented = false
        prompts = []
        lastPresentReason = .none
        presenter = nil
        bindToSurface()
    }

    private func refreshPrompts() {
        prompts = PendingApprovalSurface.shared.snapshot()
    }
}
