// PendingApprovalSurface.swift — in-app Confirm fallback
// TheBridge · Security
//
// Request-tier approvals are posted as UN notifications. On a menu-bar
// (LSUIElement) app those banners are easy to miss: Focus, notification
// style None, Time Sensitive not enabled, or a content extension that
// hides default title/body. The MCP caller now gets `awaiting_approval`
// immediately (#263) while this surface keeps ATTENTION > 0 and the
// menu-bar Confirm card — especially for remote-origin (cloud) sessions.
//
// This surface is origin-agnostic. SecurityGate publishes as soon as a
// Confirm is requested (local or remote). The Dashboard popover and
// Security ATTENTION tile read it. Allow / Always Allow / Deny here
// resume the same continuation (or late-Allow ticket) as the
// SECURITY_APPROVAL notification actions.

import Foundation
import Observation

public struct PendingApprovalPrompt: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let toolName: String
    public let module: String
    public let allowAlwaysAllow: Bool
    public let origin: ToolDispatchOrigin
    public let createdAt: Date

    public init(
        id: String,
        title: String,
        body: String,
        toolName: String,
        module: String = "",
        allowAlwaysAllow: Bool,
        origin: ToolDispatchOrigin,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.toolName = toolName
        self.module = module
        self.allowAlwaysAllow = allowAlwaysAllow
        self.origin = origin
        self.createdAt = createdAt
    }

    public var coalesceKey: String {
        NotificationApprovalManager.coalesceKey(
            allowAlwaysAllowAction: allowAlwaysAllow,
            title: title,
            body: body
        )
    }
}

/// In-flight Confirm prompts that the menu bar / Settings ATTENTION tile
/// must show even when the UN banner is not visible.
public final class PendingApprovalSurface: @unchecked Sendable {
    public static let shared = PendingApprovalSurface()

    private let lock = NSLock()
    private var items: [String: PendingApprovalPrompt] = [:]

    public init() {}

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    public func snapshot() -> [PendingApprovalPrompt] {
        lock.lock()
        defer { lock.unlock() }
        return items.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func prompt(id: String) -> PendingApprovalPrompt? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }

    public func publish(_ prompt: PendingApprovalPrompt) {
        lock.lock()
        items[prompt.id] = prompt
        lock.unlock()
        postChange()
    }

    public func remove(id: String) {
        lock.lock()
        let removed = items.removeValue(forKey: id) != nil
        lock.unlock()
        if removed { postChange() }
    }

    public func removeMatching(title: String, body: String, allowAlwaysAllow: Bool) {
        let key = NotificationApprovalManager.coalesceKey(
            allowAlwaysAllowAction: allowAlwaysAllow,
            title: title,
            body: body
        )
        lock.lock()
        let ids = items.values.filter { $0.coalesceKey == key }.map(\.id)
        for id in ids { items.removeValue(forKey: id) }
        let changed = !ids.isEmpty
        lock.unlock()
        if changed { postChange() }
    }

    /// Menu-bar / Settings Allow · Always Allow · Deny. The live
    /// `NotificationApprovalManager` observes `.pendingApprovalSurfaceSubmit`
    /// and resumes the same path as a SECURITY_APPROVAL action.
    public func submit(id: String, decision: SecurityApprovalDecision) {
        NotificationCenter.default.post(
            name: .pendingApprovalSurfaceSubmit,
            object: nil,
            userInfo: [
                PendingApprovalSurfaceUserInfo.idKey: id,
                PendingApprovalSurfaceUserInfo.decisionKey: decision.surfaceRaw
            ]
        )
    }

    public func resetForTesting() {
        lock.lock()
        items.removeAll()
        lock.unlock()
        postChange()
    }

    private func postChange() {
        let post = {
            NotificationCenter.default.post(name: .pendingApprovalSurfaceDidChange, object: nil)
            // Direct presenter sync — do not rely only on NC observers
            // (`MainActor.assumeIsolated` / AppDelegate Task hop).
            ConfirmPanelSyncBridge.requestSync()
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }
}

public enum PendingApprovalSurfaceUserInfo {
    public static let idKey = "id"
    public static let decisionKey = "decision"
}

/// Security ATTENTION tile = vault issues + in-flight Confirm prompts.
public enum SecurityPostureMetrics {
    public static func attentionTotal(credentialIssues: Int, pendingApprovals: Int) -> Int {
        max(0, credentialIssues) + max(0, pendingApprovals)
    }
}

/// Menu-bar badge + Dashboard binding. Refreshes on the surface change note.
@MainActor
@Observable
public final class PendingApprovalBadgeCounter {
    public static let shared = PendingApprovalBadgeCounter()
    public private(set) var pendingCount: Int = 0
    private var observer: NSObjectProtocol?

    public init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .pendingApprovalSurfaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    public func refresh() {
        pendingCount = PendingApprovalSurface.shared.pendingCount
    }
}

extension SecurityApprovalDecision {
    public var surfaceRaw: String {
        switch self {
        case .allow: return "allow"
        case .deny: return "deny"
        case .alwaysAllow: return "alwaysAllow"
        case .pending: return "pending"
        }
    }

    public static func fromSurfaceRaw(_ raw: String) -> SecurityApprovalDecision? {
        switch raw {
        case "allow": return .allow
        case "deny": return .deny
        case "alwaysAllow": return .alwaysAllow
        default: return nil
        }
    }
}
