// VoiceMemoStageTimeout.swift — per-stage timeout wrapper (GH #73)
// TheBridge · Modules · VoiceMemo
//
// GH #73: `voice_memo_process(mode: "single", ...)` could stall with no
// completion payload and no review-queue entry. Likely failure area per the
// issue write-up: intent parsing/classification, provider routing,
// registry target resolution, or a Notion/Reminder write — none of
// which were individually bounded at the ORCHESTRATION level (each
// HTTP request has a `timeoutInterval`, but nothing capped the full
// async chain: parse → summarize → registry resolve → write, several of
// which can each independently hang on a stuck network call or a slow
// Notion round-trip).
//
// This file provides ONE generic race-based timeout primitive — mirrors
// `CredentialValidator.withTimeout` (the codebase's existing timeout-race
// pattern) generalized to `async throws` with a typed timeout error instead
// of a fallback value, so callers can turn "took too long" into the SAME
// graceful BLOCKED → REVIEW path every other VoiceMemoError already uses,
// never an indefinite hang and never a silent nothing.

import Foundation

public enum VoiceMemoStageTimeoutError: Error, LocalizedError, Equatable, Sendable {
    case timedOut(stage: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let stage, let seconds):
            return "stage '\(stage)' exceeded its \(Int(seconds))s timeout — aborted to avoid an indefinite hang"
        }
    }
}

public enum VoiceMemoStageTimeout {

    /// Default per-stage ceilings (SPEC: bounded, not tuned per-call).
    /// Transcription can legitimately be the slowest stage (Parakeet on a long
    /// recording) so it gets the longest budget; understand/parse and the
    /// write/dispatch stage share a tighter, still-generous budget — well
    /// above Ollama's own 180s HTTP timeout would allow retries to still
    /// resolve, but short enough that a genuinely wedged call is caught
    /// within a single `voice_memo_process` invocation rather than hanging
    /// the MCP call indefinitely.
    public static let transcribeSeconds: TimeInterval = 240
    public static let understandSeconds: TimeInterval = 200
    public static let executeSeconds: TimeInterval = 60

    /// Test-only seam: when set, EVERY budget passed to `run(stage:seconds:)` is
    /// scaled by this factor before the race starts. Production code never sets
    /// this (nil ⇒ ×1, the real named-constant budgets above are used verbatim —
    /// this seam does not change the documented rule, only how fast a hermetic
    /// test can prove the race actually fires). Lets a test assert "an operation
    /// slower than its stage budget times out and the caller still returns a
    /// structured result" in well under a second instead of waiting out a
    /// real 60–240s production budget.
    nonisolated(unsafe) public static var testBudgetScale: Double?

    /// Race `operation` against a `seconds`-long sleep. Returns the
    /// operation's result if it finishes first; throws
    /// `VoiceMemoStageTimeoutError.timedOut(stage:seconds:)` if the timer
    /// wins. The loser is cancelled — a timed-out operation does not keep
    /// running in the background after this function returns.
    public static func run<T: Sendable>(
        stage: String,
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let effectiveSeconds = testBudgetScale.map { seconds * $0 } ?? seconds
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(effectiveSeconds, 0) * 1_000_000_000))
                throw VoiceMemoStageTimeoutError.timedOut(stage: stage, seconds: effectiveSeconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw VoiceMemoStageTimeoutError.timedOut(stage: stage, seconds: effectiveSeconds)
            }
            return first
        }
    }
}
