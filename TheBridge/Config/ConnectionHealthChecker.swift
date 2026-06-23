// ConnectionHealthChecker.swift — Connection Health Status & Validation
// TheBridge · Config
// PKT-368 D1: Per-connection health badge logic
// PKT-440: Optimistic last-known-good status + reduced cache TTL
//
// Provides health status enum and validation utilities for workspace connections.
// Supports Notion (via NotionClientRegistry) and Google Drive (via token check).
// Uses actor isolation for thread-safe caching of health results.

import Foundation

// MARK: - Connection Health Status

/// Health status for a configured connection.
/// Used by the Connections tab to display colored badges per connection.
public enum ConnectionHealth: String, Sendable {
    case healthy       // Token valid, API reachable — 🟢 green
    case warning       // Token expiring soon or intermittent — 🟡 yellow
    case error         // Token invalid/expired, API unreachable — 🔴 red
    case unconfigured  // No token set — ⚪ gray
    case checking      // Currently validating — 🟠 orange (transient)

    public var label: String {
        switch self {
        case .healthy:       return "Connected"
        case .warning:       return "Token Expiring"
        case .error:         return "Disconnected"
        case .unconfigured:  return "Not Configured"
        case .checking:      return "Checking…"
        }
    }

    public var systemImage: String {
        switch self {
        case .healthy:       return "circle.fill"
        case .warning:       return "exclamationmark.circle.fill"
        case .error:         return "xmark.circle.fill"
        case .unconfigured:  return "circle.dashed"
        case .checking:      return "circle.dotted"
        }
    }

    /// Whether this status represents a usable connection.
    public var isUsable: Bool {
        self == .healthy || self == .warning
    }
}

// MARK: - Connection Health Checker

/// Actor-based health checker with time-based caching.
/// Validates connections by attempting lightweight API calls.
/// PKT-440: Maintains a `lastKnown` dict that persists results across cache expiry,
/// so callers can display the last validated status instead of "Checking…".
public actor ConnectionHealthChecker {

    public static let shared = ConnectionHealthChecker()

    /// Timed cache — entries expire after `cacheDuration` seconds.
    private var cache: [String: (health: ConnectionHealth, timestamp: Date)] = [:]
    private let cacheDuration: TimeInterval = 30  // PKT-440: reduced from 60s

    /// Last-known-good (or last-known-bad) status. Never expires — only replaced
    /// by a newer validation result or cleared by `invalidate`/`invalidateAll`.
    /// Used by `lastKnownHealth()` so the UI can show a real status instead of `.checking`.
    private var lastKnown: [String: ConnectionHealth] = [:]

    private init() {}

    // MARK: - Last Known Health (PKT-440)

    /// Returns the last validated health for a connection without triggering a recheck.
    /// Returns `nil` if no prior validation result exists for this connection.
    public func lastKnownHealth(connectionName: String) -> ConnectionHealth? {
        let key = "notion:\(connectionName)"
        return lastKnown[key]
    }

    /// Returns the last validated health for an arbitrary key (e.g. "stripe:default").
    public func lastKnownHealthForKey(_ key: String) -> ConnectionHealth? {
        return lastKnown[key]
    }

    /// Store a last-known result for an arbitrary key (used by ConnectionRegistry
    /// for non-Notion connections like Stripe).
    public func setLastKnown(_ health: ConnectionHealth, forKey key: String) {
        lastKnown[key] = health
    }

    // MARK: - Notion Connection Health

    /// Check health of a Notion connection by attempting a lightweight API call.
    /// Uses NotionClientRegistry to get the client, then calls getMe().
    public func checkNotionHealth(connectionName: String) async -> ConnectionHealth {
        let key = "notion:\(connectionName)"
        if let cached = cache[key],
           Date().timeIntervalSince(cached.timestamp) < cacheDuration {
            return cached.health
        }

        do {
            let client = try await NotionClientRegistry.shared.getClient(workspace: connectionName)
            // Attempt lightweight validate() — cheapest health check on NotionClient
            let result = await client.validate()
            guard result.success else {
                let health = ConnectionHealth.error
                cache[key] = (health, Date())
                lastKnown[key] = health
                return health
            }
            let health = ConnectionHealth.healthy
            cache[key] = (health, Date())
            lastKnown[key] = health
            return health
        } catch {
            let errorStr = error.localizedDescription.lowercased()
            let health: ConnectionHealth
            if errorStr.contains("no token") || errorStr.contains("not configured") || errorStr.contains("not found") {
                health = .unconfigured
            } else {
                health = .error
            }
            cache[key] = (health, Date())
            lastKnown[key] = health
            return health
        }
    }


    // MARK: - Cache Management

    /// Invalidate cached health for a specific connection.
    /// Note: lastKnown is preserved so optimistic display still works.
    public func invalidate(connectionName: String) {
        cache.removeValue(forKey: "notion:\(connectionName)")
    }

    /// Invalidate all cached health statuses.
    /// Clears timed cache but preserves lastKnown for optimistic display.
    public func invalidateAll() {
        cache.removeAll()
    }

    /// Full reset — clears both timed cache and last-known results.
    /// Used on factory reset or when connections are reconfigured.
    public func resetAll() {
        cache.removeAll()
        lastKnown.removeAll()
    }
}
