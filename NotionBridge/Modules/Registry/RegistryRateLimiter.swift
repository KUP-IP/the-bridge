// RegistryRateLimiter.swift — Data-Source Registry (Wave 2)
// NotionBridge · Modules · Registry
//
// Decision 4 rate limiting: a SINGLE centralized request gate at the Notion
// API boundary, ceiling 2 req/s (headroom under Notion's ~3/s cap). The
// existing per-`NotionClient` 3/s token bucket is per-connection, so a burst
// of domain-verb reads or overlapping sync cycles across workspaces could
// still spike the global rate. Every registry call passes through THIS shared
// gate first, so calls never fail from rate-limiting — they wait a few hundred
// ms (invisible), and the global rate stays bounded.
//
// Mechanism: each `acquire()` synchronously RESERVES the next slot (advancing
// `nextAllowed` before any suspension), so even under actor re-entrancy the
// reserved instants are strictly spaced by `minInterval`. The caller then
// sleeps until its reserved slot. FIFO-fair in practice because reservation is
// the first thing acquire does.

import Foundation

public actor RegistryRateLimiter {
    public static let shared = RegistryRateLimiter()

    private let minInterval: Duration
    private var nextAllowed: ContinuousClock.Instant?

    /// - Parameter maxRequestsPerSecond: global ceiling (default 2.0 —
    ///   Decision 4). `<= 0` disables throttling (tests).
    public init(maxRequestsPerSecond: Double = 2.0) {
        self.minInterval = maxRequestsPerSecond > 0
            ? .seconds(1.0 / maxRequestsPerSecond)
            : .zero
    }

    /// Wait (if needed) until this caller's reserved slot. Never throws; a
    /// cancelled sleep simply returns early (the caller proceeds — the gate is
    /// a smoother, not a hard barrier).
    public func acquire() async {
        guard minInterval > .zero else { return }
        let now = ContinuousClock.now
        let scheduled = (nextAllowed.map { $0 > now ? $0 : now }) ?? now
        nextAllowed = scheduled.advanced(by: minInterval)
        let wait = now.duration(to: scheduled)
        if wait > .zero {
            try? await Task.sleep(for: wait)
        }
    }

    /// Run `body` after acquiring a slot — the ergonomic wrapper every gateway
    /// call uses.
    public func throttled<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        return try await body()
    }
}
