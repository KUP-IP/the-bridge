// KeepReviewModel.swift — KEEP review model contracts (D15/D19/D20/D43 / PKT-MEM-115)
// TheBridge · Modules · Voice
//
// Defines the typed review status states, review metadata struct, Notion property name
// contracts, and the required schema field manifest used by ensureReviewSchema (D43).

import Foundation

// MARK: — D20 KEEP Review States

/// The SRS-like review lifecycle state of a KEEP memory row (D20).
/// `unknown` provides forward-compatibility for values not in this enum.
public enum KeepReviewStatus: String, Codable, Sendable, CaseIterable {
    case new
    case learning
    case review
    case mastered
    case archived
    /// Forward-compat fallback for unknown raw values encountered during decode.
    case unknown
}

// MARK: — D19 KEEP Review Metadata

/// Review + optional SRS metadata stored in Notion Memory rows and mirrored to local
/// cache (D10 / D19). All fields are optional to allow partial updates; defaults are
/// applied at init for required fields.
public struct KeepReviewMetadata: Codable, Sendable, Equatable {
    // MARK: Required review fields (D19)
    /// Review lifecycle state (D20). Defaults to `.new` for freshly created rows.
    public var reviewStatus: KeepReviewStatus
    /// When the operator should next review this row. `nil` = not yet scheduled.
    public var nextReviewAt: Date?
    /// When the operator last reviewed this row. `nil` = never reviewed.
    public var lastReviewedAt: Date?
    /// Operator-assigned recall quality score (0.0 – 1.0 clamped). 0.0 = unknown / not rated.
    public var recallScore: Double

    // MARK: Optional SRS fields (D19)
    /// SRS review interval in days.
    public var reviewInterval: Int?
    /// SRS ease factor.
    public var ease: Double?
    /// SRS lapse count (how many times the card was forgotten).
    public var lapseCount: Int?
    /// SRS total review count.
    public var reviewCount: Int?
    /// Optional quiz prompt shown to the operator.
    public var prompt: String?
    /// Optional expected answer for the quiz prompt.
    public var answer: String?
    /// Source voice memo ID that created this memory row (if applicable).
    public var sourceMemoId: String?

    public init(
        reviewStatus: KeepReviewStatus = .new,
        nextReviewAt: Date? = nil,
        lastReviewedAt: Date? = nil,
        recallScore: Double = 0.0,
        reviewInterval: Int? = nil,
        ease: Double? = nil,
        lapseCount: Int? = nil,
        reviewCount: Int? = nil,
        prompt: String? = nil,
        answer: String? = nil,
        sourceMemoId: String? = nil
    ) {
        self.reviewStatus = reviewStatus
        self.nextReviewAt = nextReviewAt
        self.lastReviewedAt = lastReviewedAt
        // Clamp recallScore to [0.0, 1.0]
        self.recallScore = min(1.0, max(0.0, recallScore))
        self.reviewInterval = reviewInterval
        self.ease = ease
        self.lapseCount = lapseCount
        self.reviewCount = reviewCount
        self.prompt = prompt
        self.answer = answer
        self.sourceMemoId = sourceMemoId
    }
}

// MARK: — Notion Property Name Contracts (D15 / D43)

/// Canonical Notion property names for KEEP review fields.
/// These are the display names used when binding or auto-creating database properties (D43).
public enum KeepSchemaContract {
    public static let notionPropReviewStatus    = "Review Status"
    public static let notionPropNextReviewAt    = "Next Review"
    public static let notionPropLastReviewedAt  = "Last Reviewed"
    public static let notionPropRecallScore     = "Recall Score"
}

// MARK: — Required Schema Field Manifest (D43)

/// Describes one required KEEP review field in the Notion Memory database schema.
public struct KeepRequiredSchemaField: Sendable, Equatable {
    /// The Notion database property display name (matches `KeepSchemaContract`).
    public let propName: String
    /// The Notion property type string (e.g. `"select"`, `"date"`, `"number"`).
    public let notionType: String

    public init(propName: String, notionType: String) {
        self.propName = propName
        self.notionType = notionType
    }

    /// All 4 required KEEP review fields that must exist in the Notion Memory database (D15/D43).
    public static let allRequired: [KeepRequiredSchemaField] = [
        KeepRequiredSchemaField(propName: KeepSchemaContract.notionPropReviewStatus,   notionType: "select"),
        KeepRequiredSchemaField(propName: KeepSchemaContract.notionPropNextReviewAt,   notionType: "date"),
        KeepRequiredSchemaField(propName: KeepSchemaContract.notionPropLastReviewedAt, notionType: "date"),
        KeepRequiredSchemaField(propName: KeepSchemaContract.notionPropRecallScore,    notionType: "number"),
    ]
}
