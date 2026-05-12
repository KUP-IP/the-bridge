// CursorNewRunFormLogic.swift — PKT-3.4.2 Wave 5b (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Pure form-validation + cost-estimation logic for the New Cursor Agent Run
// modal. Extracted from `CursorNewRunView` so unit tests (PKT-3.4.2 F4) can
// exercise the validation predicates and cost math without instantiating the
// SwiftUI view hierarchy.
//
// All members are `nonisolated` and Sendable-safe — the surface is pure.

import Foundation

public enum CursorNewRunFormLogic {

    // MARK: - Constants

    /// Minimum wall-cap minutes accepted by the modal.
    public static let minWallCapMinutes: Int = 1
    /// Maximum wall-cap minutes accepted by the modal.
    public static let maxWallCapMinutes: Int = 240
    /// Cost rate for cloud composer-2 runs in cents per minute.
    /// (Heuristic; the real cost comes from the sidecar in PKT-3.4.1.W2.)
    public static let cloudCostPerMinuteCents: Int = 12

    // MARK: - Trimming

    public static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Validators

    public static func isPromptValid(_ prompt: String) -> Bool {
        !trimmed(prompt).isEmpty
    }

    public static func isRepoValid(_ repoPath: String) -> Bool {
        !trimmed(repoPath).isEmpty
    }

    public static func isWallCapValid(_ minutes: Int) -> Bool {
        minutes >= minWallCapMinutes && minutes <= maxWallCapMinutes
    }

    /// Whether the form is in a submittable state. Does not account for an
    /// already-in-flight submission (the view layer guards on that
    /// separately via its `submitting` state flag).
    public static func canSubmit(
        prompt: String,
        repoPath: String,
        wallCapMinutes: Int
    ) -> Bool {
        isPromptValid(prompt)
            && isRepoValid(repoPath)
            && isWallCapValid(wallCapMinutes)
    }

    // MARK: - Cost estimation

    /// Estimated cost in cents for a run with the given runtime + wall cap.
    /// Cloud = `wallCapMinutes * cloudCostPerMinuteCents`. Local = 0.
    /// Negative wall caps are clamped to 0.
    public static func estimatedCostCents(
        runtime: CursorRuntimeKind,
        wallCapMinutes: Int
    ) -> Int {
        switch runtime {
        case .local:
            return 0
        case .cloud:
            return max(0, wallCapMinutes) * cloudCostPerMinuteCents
        }
    }
}
