// MemoryHubFoundationActivityTests.swift — D12/D19/D20/D24/D43 foundation contracts
// TheBridgeTests
//
// Tests for ACTIVITY event taxonomy, retention policy, evidenceId uniqueness,
// KeepReviewStatus state set, KeepReviewMetadata defaults, KeepSchemaContract names,
// and KeepRequiredSchemaField manifest.

import Foundation
import TheBridgeLib

private func makeFoundationEvent(
    memoId: String = "test-memo",
    phase: MemoryHubActivityEvent.Phase = .execute,
    eventType: MemoryHubActivityEventType = .memoProcessed,
    action: String = "test_action",
    status: String = "ok",
    detail: String = "test",
    timestamp: String = "2026-06-27T09:00:00Z"
) -> MemoryHubActivityEvent {
    MemoryHubActivityEvent(
        timestamp: timestamp, memoId: memoId, phase: phase, eventType: eventType,
        action: action, status: status, provenance: "test", actor: "harness", detail: detail
    )
}

public func runMemoryHubActivityTests() async {
    print("\n📋 Memory Hub Foundation — ACTIVITY taxonomy + KEEP review contracts (D12/D19/D20/D24/D43)")

    // MARK: — D12 Event Type Taxonomy

    await test("activity_eventType_allD12CasesCompileAndAccessible") {
        let allCases = MemoryHubActivityEventType.allCases
        let rawValues = Set(allCases.map(\.rawValue))

        // Memo lifecycle
        try expect(rawValues.contains("memoProcessed"),      "memoProcessed present")
        try expect(rawValues.contains("memoTranscribed"),    "memoTranscribed present")
        try expect(rawValues.contains("memoSummarized"),     "memoSummarized present")
        try expect(rawValues.contains("memoTitleGenerated"), "memoTitleGenerated present")

        // Disposition
        try expect(rawValues.contains("dispositionDismissed"),      "dispositionDismissed present")
        try expect(rawValues.contains("dispositionMarkHandled"),    "dispositionMarkHandled present")
        try expect(rawValues.contains("dispositionSaveToKeep"),     "dispositionSaveToKeep present")
        try expect(rawValues.contains("dispositionSaveForAgents"),  "dispositionSaveForAgents present")
        try expect(rawValues.contains("dispositionCreateReminder"), "dispositionCreateReminder present")
        try expect(rawValues.contains("dispositionTrash"),          "dispositionTrash present")

        // KEEP sync
        try expect(rawValues.contains("keepSyncSuccess"),      "keepSyncSuccess present")
        try expect(rawValues.contains("keepSyncError"),        "keepSyncError present")
        try expect(rawValues.contains("keepFieldAutoCreated"), "keepFieldAutoCreated present")

        // Agent memory
        try expect(rawValues.contains("agentMemoryCreated"),   "agentMemoryCreated present")
        try expect(rawValues.contains("agentMemoryEdited"),    "agentMemoryEdited present")
        try expect(rawValues.contains("agentMemoryForgotten"), "agentMemoryForgotten present")

        // Provider calls
        try expect(rawValues.contains("providerCallStarted"),   "providerCallStarted present")
        try expect(rawValues.contains("providerCallCompleted"), "providerCallCompleted present")
        try expect(rawValues.contains("providerCallFailed"),    "providerCallFailed present")
        try expect(rawValues.contains("providerTestRun"),       "providerTestRun present")

        // Migration
        try expect(rawValues.contains("migrationRun"),   "migrationRun present")
        try expect(rawValues.contains("migrationError"), "migrationError present")

        // Forward-compat
        try expect(rawValues.contains("unknown"), "unknown forward-compat case present")
    }

    await test("activity_eventType_unknownForwardCompat_decodesGracefully") {
        let jsonData = #"{"eventType":"futureEventType2030"}"#.data(using: .utf8)!
        struct Wrapper: Codable { let eventType: MemoryHubActivityEventType }
        let decoded = try? JSONDecoder().decode(Wrapper.self, from: jsonData)
        try expect(decoded?.eventType == .unknown,
                   "unknown raw value decodes to .unknown, got \(String(describing: decoded?.eventType))")
    }

    await test("activity_eventType_stampedOnEvent") {
        let event = makeFoundationEvent(eventType: .dispositionSaveToKeep)
        try expect(event.eventType == .dispositionSaveToKeep, "eventType stamped on event")
    }

    await test("activity_eventType_defaultsToUnknown_whenOmitted") {
        let event = MemoryHubActivityEvent(
            timestamp: "2026-06-27T00:00:00Z", memoId: "x",
            phase: .execute, action: "legacy_action",
            status: "ok", provenance: "test", actor: "harness", detail: "ok"
        )
        try expect(event.eventType == .unknown, "default eventType is .unknown for legacy-style callers, got \(event.eventType)")
    }

    // MARK: — D24 evidenceId uniqueness

    await test("activity_evidenceId_isUUID_uniquePerEvent") {
        let e1 = makeFoundationEvent(action: "first")
        let e2 = makeFoundationEvent(action: "second")
        try expect(e1.evidenceId != e2.evidenceId,
                   "consecutive events have different evidenceIds: \(e1.evidenceId) vs \(e2.evidenceId)")
    }

    await test("activity_evidenceId_roundTripsViaJSON") {
        let original = makeFoundationEvent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(MemoryHubActivityEvent.self, from: data)
        try expect(decoded.evidenceId == original.evidenceId, "evidenceId survives JSON round-trip")
    }

    await test("activity_evidenceId_isUUIDType") {
        let event = makeFoundationEvent()
        // Compile-time assertion: evidenceId is UUID (not String)
        let _: UUID = event.evidenceId
        try expect(true, "evidenceId is UUID type (compile-time check)")
    }

    // MARK: — D24 Retention constants

    await test("activity_retention_constants_matchD24") {
        try expect(MemoryHubActivityLog.maxEvents == 2000,
                   "D24: maxEvents is 2000, got \(MemoryHubActivityLog.maxEvents)")
        try expect(MemoryHubActivityLog.maxAgeDays == 90,
                   "D24: maxAgeDays is 90, got \(MemoryHubActivityLog.maxAgeDays)")
    }

    // MARK: — D20 KeepReviewStatus

    await test("keep_reviewStatus_hasAllSixCases") {
        let expected: Set<String> = ["new", "learning", "review", "mastered", "archived", "unknown"]
        let actual = Set(KeepReviewStatus.allCases.map(\.rawValue))
        try expect(actual == expected, "KeepReviewStatus has exactly 6 cases: actual=\(actual) expected=\(expected)")
    }

    await test("keep_reviewStatus_allCasesCount_isSix") {
        try expect(KeepReviewStatus.allCases.count == 6,
                   "CaseIterable yields 6 cases, got \(KeepReviewStatus.allCases.count)")
    }

    // MARK: — D19 KeepReviewMetadata

    await test("keep_reviewMetadata_defaultRecallScoreIsZero") {
        let meta = KeepReviewMetadata()
        try expect(meta.recallScore == 0.0, "default recallScore is 0.0, got \(meta.recallScore)")
    }

    await test("keep_reviewMetadata_defaultStatusIsNew") {
        let meta = KeepReviewMetadata()
        try expect(meta.reviewStatus == .new, "default reviewStatus is .new, got \(meta.reviewStatus)")
    }

    await test("keep_reviewMetadata_recallScoreClampedAbove") {
        let meta = KeepReviewMetadata(recallScore: 1.5)
        try expect(meta.recallScore == 1.0, "recallScore clamped to 1.0 when given 1.5, got \(meta.recallScore)")
    }

    await test("keep_reviewMetadata_recallScoreClampedBelow") {
        let meta = KeepReviewMetadata(recallScore: -0.5)
        try expect(meta.recallScore == 0.0, "recallScore clamped to 0.0 when given -0.5, got \(meta.recallScore)")
    }

    // MARK: — D15 KeepSchemaContract

    await test("keep_schemaContract_reviewStatusNonEmpty") {
        try expect(!KeepSchemaContract.notionPropReviewStatus.isEmpty,
                   "notionPropReviewStatus is non-empty")
    }

    await test("keep_schemaContract_exactPropertyNames") {
        try expect(KeepSchemaContract.notionPropReviewStatus   == "Review Status", "Review Status name")
        try expect(KeepSchemaContract.notionPropNextReviewAt   == "Next Review",   "Next Review name")
        try expect(KeepSchemaContract.notionPropLastReviewedAt == "Last Reviewed", "Last Reviewed name")
        try expect(KeepSchemaContract.notionPropRecallScore    == "Recall Score",  "Recall Score name")
    }

    // MARK: — D43 KeepRequiredSchemaField

    await test("keep_requiredSchemaFields_exactlyFour") {
        let count = KeepRequiredSchemaField.allRequired.count
        try expect(count == 4, "allRequired has exactly 4 entries, got \(count)")
    }

    await test("keep_requiredSchemaFields_propNamesMatchContract") {
        let names = Set(KeepRequiredSchemaField.allRequired.map(\.propName))
        try expect(names.contains(KeepSchemaContract.notionPropReviewStatus),   "allRequired includes Review Status")
        try expect(names.contains(KeepSchemaContract.notionPropNextReviewAt),   "allRequired includes Next Review")
        try expect(names.contains(KeepSchemaContract.notionPropLastReviewedAt), "allRequired includes Last Reviewed")
        try expect(names.contains(KeepSchemaContract.notionPropRecallScore),    "allRequired includes Recall Score")
    }

    await test("keep_requiredSchemaFields_notionTypesPresent") {
        for field in KeepRequiredSchemaField.allRequired {
            try expect(!field.notionType.isEmpty, "notionType non-empty for '\(field.propName)'")
        }
    }
}
