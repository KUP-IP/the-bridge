// ScreenCaptureKitBoundary.swift — SCK main-actor boundary + watchdog
// TheBridge · Modules
//
// Root-cause fix for the "SWIFT TASK CONTINUATION MISUSE: leaked its
// continuation without resuming it" hang.
//
// `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)` delivers
// its reply on the MAIN run loop. When the async call is made from an
// OFF-MAIN-ACTOR context (the standalone test harness's nonisolated top-level
// `await`, a `Task.detached`, or any nonisolated async caller), the checked
// continuation is never resumed and the call HANGS FOREVER — and the leaked
// continuation poisons the cooperative thread pool, so the hang surfaces as a
// wandering, intermittent stall elsewhere in the suite. Masked in production
// because the GUI app's tool dispatch runs on the main actor (which the running
// NSApplication run loop services); it surfaced as the suite's local hangs.
//
// FIX (a) — correctness in production: run the SCK call on the MAIN ACTOR, so
// its main-run-loop reply lands on the context the GUI app actually services.
//
// FIX (b) — robustness everywhere, incl. the headless test harness: a watchdog
// that runs on a LIBDISPATCH thread (NOT the Swift cooperative pool). This
// matters because in a headless process there is no NSApplication run loop
// draining the main actor, so the main-actor SCK call can still fail to resume;
// a cooperative-pool watchdog (`Task.sleep`) would itself be wedged by the very
// pool starvation it is trying to rescue. A libdispatch timer fires on its own
// thread regardless of cooperative-pool state, resumes the awaiting
// continuation with a thrown `Timeout`, and lets the caller (and the suite)
// proceed instead of hanging forever. (b) is defense-in-depth — it does NOT
// replace (a); in the GUI app the SCK reply wins the race long before the
// watchdog.
//
// NOTE: callers MUST still gate on `CGPreflightScreenCaptureAccess()` BEFORE
// invoking this helper, so the headless / TCC-denied path short-circuits fast
// and never enters SCK at all.

import ScreenCaptureKit
import CoreGraphics
import Dispatch
import Foundation

enum SCKBoundary {

    /// Thrown when the SCK call does not resume within `timeout` seconds.
    /// In the GUI app this never fires (the SCK reply arrives in milliseconds);
    /// it exists so an off-main / no-run-loop context surfaces a fast error
    /// instead of a permanent hang.
    struct Timeout: Error, CustomStringConvertible {
        var description: String {
            "ScreenCaptureKit.excludingDesktopWindows timed out (no continuation resume)"
        }
    }

    /// Fetch on-screen shareable content on the MAIN ACTOR, guarded by a
    /// libdispatch watchdog so it can never hang forever.
    ///
    /// Callers are responsible for verifying `CGPreflightScreenCaptureAccess()`
    /// first — this helper assumes the grant is present and enters SCK directly.
    static func fetchShareableContent(timeout: Double = 6.0) async throws -> SCShareableContent {
        // Single-shot resume guard. Synchronous + lock-based on purpose: the
        // SCK completion and the libdispatch watchdog race on DIFFERENT threads,
        // and an actor-hop guard would itself depend on the (possibly wedged)
        // cooperative pool. A plain lock is thread-safe and pool-independent.
        let guardBox = ResumeOnceGuard()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SCShareableContent, Error>) in
            // (a) Root-cause fix: SCK call on the main actor.
            Task { @MainActor in
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if guardBox.claim() { cont.resume(returning: content) }
                } catch {
                    if guardBox.claim() { cont.resume(throwing: error) }
                }
            }

            // (b) Watchdog on a libdispatch thread — fires even if the Swift
            // cooperative pool is starved by a leaked SCK continuation. Resumes
            // the awaiting continuation so the caller proceeds; the abandoned
            // main-actor Task above only ever resumes ITS (already-claimed)
            // continuation, so no double-resume.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if guardBox.claim() { cont.resume(throwing: Timeout()) }
            }
        }
    }

    /// Thread-safe single-shot claim: the first `claim()` returns true, every
    /// later one returns false. Guarantees the checked continuation is resumed
    /// exactly once across the SCK-completion / watchdog race.
    private final class ResumeOnceGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
