// StatusBarController.swift — Observable State for Menu Bar + Popover
// V1-02: Manages connection count, tool count, uptime, and tool call count
// PKT-317: Added totalToolCalls counter for live server status in DashboardView
// PKT-320: Added notionTokenStatus for Notion API token health indicator
// V1-QUALITY-C2: Added connectedClients array for client identification.
//   Stores client name, version, and connection time from MCP initialize clientInfo.
// PKT-353: Added right-click context menu for Quit action (relocated from DashboardView footer).

import AppKit
import Observation

/// Lightweight tool metadata for UI display (PKT-350: F2).
public struct ToolInfo: Sendable, Identifiable {
    public let name: String
    public let module: String
    public let tier: String
    public let description: String
    public var id: String { name }

    public init(name: String, module: String, tier: String, description: String) {
        self.name = name
        self.module = module
        self.tier = tier
        self.description = description
    }
}

/// Connected client info parsed from MCP initialize request's clientInfo field.
public struct ConnectedClient: Sendable, Equatable {
    public let name: String
    public let version: String
    public let connectedAt: Date

    public init(name: String, version: String, connectedAt: Date = Date()) {
        self.name = name
        self.version = version
        self.connectedAt = connectedAt
    }
}

/// Observable state controller for the menu bar app.
/// Provides live connection count, registered tool count, total tool calls,
/// Notion token status, connected client info, and server uptime to the DashboardView popover.
/// All state updates are main-actor-isolated for safe SwiftUI binding.
@MainActor
@Observable
public final class StatusBarController {

    public init() {}

    // MARK: - Live Status

    /// Number of active client connections (SSE + stdio)
    public var activeConnections: Int = 0

    /// Number of registered MCP tools
    public var activeToolCount: Int = 0

    /// Total number of tool calls dispatched since server start
    public var totalToolCalls: Int = 0

    /// Server start time (nil if server not running)
    public var serverStartTime: Date? = nil

    /// Notion API token status: "connected", "disconnected", or "missing"
    public var notionTokenStatus: String = "missing"

    /// Detail message for Notion token status (e.g., source or error)
    public var notionTokenDetail: String = ""

    /// Full tool list for ToolRegistryView (PKT-350: F2).
    public var toolInfoList: [ToolInfo] = []

    // MARK: - Client Identification (V1-QUALITY-C2)

    /// Connected clients with name, version, and connection time.
    /// Populated from MCP initialize request's clientInfo field.
    public var connectedClients: [ConnectedClient] = []

    /// Pending removal tasks keyed by client name. Cancelled if the client reconnects within the grace period.
    private var pendingRemovals: [String: Task<Void, Never>] = [:]

    /// Grace period before removing a disconnected client from the UI (seconds).
    private let removalGracePeriod: UInt64 = 4_000_000_000  // 4s in nanoseconds

    /// Formatted uptime string
    public var uptimeString: String {
        guard let start = serverStartTime else { return "Not running" }
        let interval = Date().timeIntervalSince(start)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    /// Whether the MCP server is currently running
    public var isServerRunning: Bool {
        serverStartTime != nil
    }

    // MARK: - Right-Click Context Menu (PKT-353)

    /// Event monitor for right-click on the status bar area.
    /// Retained to allow cleanup if needed.
    private var eventMonitor: Any?

    /// Set up a right-click context menu with "Quit The Bridge" action.
    /// Uses a local event monitor to detect right-clicks on any NSStatusBarButton,
    /// then presents the context menu at the click location.
    /// Call once from AppDelegate.applicationDidFinishLaunching after a short delay
    /// to ensure MenuBarExtra has created its status item.
    public func setupContextMenu() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
            // Only trigger on clicks targeting a status bar button
            guard event.window?.className.contains("NSStatusBar") == true
                  || event.window is NSPanel else {
                return event
            }
            self?.showContextMenu(at: event)
            return nil  // Consume the event
        }
    }

    /// Build and display the context menu at the event location.
    private func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()

        let restartItem = NSMenuItem(
            title: "Restart The Bridge",
            action: #selector(AppDelegate.restartApp(_:)),
            keyEquivalent: ""
        )
        restartItem.target = NSApp.delegate
        menu.addItem(restartItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit The Bridge",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        // Position menu below the status item
        if let window = event.window {
            let location = NSPoint(x: event.locationInWindow.x, y: 0)
            menu.popUp(positioning: nil, at: location, in: window.contentView)
        }
    }

    // MARK: - Server Lifecycle

    /// Mark the server as started with the given tool count.
    public func markServerStarted(toolCount: Int) {
        serverStartTime = Date()
        activeToolCount = toolCount
        totalToolCalls = 0
        cancelAllPendingRemovals()
        connectedClients = []
    }

    /// Mark the server as stopped. Resets connections and uptime.
    public func markServerStopped() {
        serverStartTime = nil
        activeConnections = 0
        cancelAllPendingRemovals()
        connectedClients = []
    }

    /// Update the active connection count.
    public func updateConnections(_ count: Int) {
        activeConnections = count
    }

    /// Increment the tool call counter. Called by ServerManager after each dispatch.
    public func incrementToolCalls() {
        totalToolCalls += 1
    }

    /// Update Notion token status.
    public func updateNotionTokenStatus(_ status: String, detail: String = "") {
        notionTokenStatus = status
        notionTokenDetail = detail
    }

    // MARK: - Client Identification (V1-QUALITY-C2)

    /// Add a connected client. Called when MCP initialize request contains clientInfo.
    /// Cancels any pending debounced removal for this client (suppresses flicker on reconnect).
    public func addClient(name: String, version: String) {
        // Cancel pending removal if client reconnected within grace period
        pendingRemovals[name]?.cancel()
        pendingRemovals.removeValue(forKey: name)

        let client = ConnectedClient(name: name, version: version)
        // Replace existing entry with same name (reconnection)
        connectedClients.removeAll { $0.name == name }
        connectedClients.append(client)
        activeConnections = connectedClients.count
        print("[StatusBar] Client connected: \(name) v\(version) (total: \(connectedClients.count))")
    }

    /// Schedule removal of a disconnected client after a grace period.
    /// If the client reconnects before the grace period expires, removal is cancelled.
    public func removeClient(name: String) {
        // Cancel any existing pending removal for this client
        pendingRemovals[name]?.cancel()

        pendingRemovals[name] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.removalGracePeriod ?? 4_000_000_000)
            } catch {
                return  // Cancelled — client reconnected
            }
            guard let self, !Task.isCancelled else { return }
            self.connectedClients.removeAll { $0.name == name }
            self.activeConnections = self.connectedClients.count
            self.pendingRemovals.removeValue(forKey: name)
            print("[StatusBar] Client disconnected: \(name) (remaining: \(self.connectedClients.count))")
        }
    }

    /// Remove a disconnected client by session ID (best-effort match by index).
    /// Used when we don't have the client name at disconnect time.
    public func removeLastClient() {
        if !connectedClients.isEmpty {
            let removed = connectedClients.removeLast()
            activeConnections = connectedClients.count
            print("[StatusBar] Client disconnected: \(removed.name) (remaining: \(connectedClients.count))")
        }
    }

    /// Cancel all pending debounced removals.
    private func cancelAllPendingRemovals() {
        for (_, task) in pendingRemovals { task.cancel() }
        pendingRemovals.removeAll()
    }
}
