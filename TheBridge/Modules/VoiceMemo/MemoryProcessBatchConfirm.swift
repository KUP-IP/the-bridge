// MemoryProcessBatchConfirm.swift — UI-free batch commit orchestrator (PKT-MEM-123)
// TheBridge · Modules · VoiceMemo
//
// Pure ordering, validation, and aggregation for the V1 Process center Confirm flow.
// Sequential `voice_memo_commit` calls remain in the SwiftUI layer; this module owns
// lane-priority ordering, registry pre-checks, tag eligibility, and summary strings.

import Foundation
import MCP

public enum MemoryProcessBatchConfirm {

    /// Lane-priority rank (matches `VoiceMemoIntentElection` — reminder highest).
    private static let lanePriority: [VoiceMemoIntentKind: Int] = [
        .reminder: 4,
        .agentMemory: 3,
        .registryUpdate: 2,
        .memoryKeep: 1,
    ]

    // MARK: - Tag eligibility

    /// Executable intent rows may appear as checkable tags; review lanes are display-only.
    public static func isTagCheckable(_ row: CockpitIntentRow) -> Bool {
        row.kind != .review
    }

    /// Default checked set on load: the single primary row when checkable.
    public static func defaultCheckedIntentIds(rows: [CockpitIntentRow]) -> Set<String> {
        Set(rows.filter { $0.isPrimary && isTagCheckable($0) }.map(\.intentId))
    }

    // MARK: - Commit ordering

    /// Checked rows in lane-priority order (reminder → agent_memory → registry_update → memory_keep),
    /// stable tie-break by `intentId`.
    public static func commitOrder(checkedIds: Set<String>, rows: [CockpitIntentRow]) -> [CockpitIntentRow] {
        rows
            .filter { checkedIds.contains($0.intentId) && isTagCheckable($0) }
            .sorted { a, b in
                let pa = lanePriority[a.kind] ?? 0
                let pb = lanePriority[b.kind] ?? 0
                if pa != pb { return pa > pb }
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                return a.intentId < b.intentId
            }
    }

    // MARK: - Registry pre-Confirm validation

    /// Registry intents among the checked set that still need a picker row selection.
    public static func missingRegistryConfiguration(
        checkedIds: Set<String>,
        rows: [CockpitIntentRow],
        selectedRowIdByIntentId: [String: String]
    ) -> [CockpitIntentRow] {
        commitOrder(checkedIds: checkedIds, rows: rows).filter { row in
            guard row.kind == .registryUpdate else { return false }
            guard MemoryProcessCockpit.needsPicker(for: row, allRows: rows) else { return false }
            let picked = selectedRowIdByIntentId[row.intentId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return picked.isEmpty
        }
    }

    // MARK: - Confirm gating + trust summary

    /// True when at least one checkable intent is checked and every checked intent has a commit preview.
    public static func canConfirm(checkedIds: Set<String>, rows: [CockpitIntentRow]) -> Bool {
        let ordered = commitOrder(checkedIds: checkedIds, rows: rows)
        guard !ordered.isEmpty else { return false }
        return ordered.allSatisfy { MemoryProcessCockpit.commitValuePreview(for: $0) != nil }
    }

    /// Human-readable reason when Confirm is disabled.
    public static func confirmDisabledReason(checkedIds: Set<String>, rows: [CockpitIntentRow]) -> String? {
        let ordered = commitOrder(checkedIds: checkedIds, rows: rows)
        if ordered.isEmpty { return "Select at least one intent tag." }
        if let missing = ordered.first(where: { MemoryProcessCockpit.commitValuePreview(for: $0) == nil }) {
            return "No commit preview for \(MemoryHubCockpitLabels.intentKind(missing.kind)) — cannot commit blind."
        }
        return nil
    }

    /// One summary line per checked intent for the trust strip above Confirm.
    public static func confirmSummaryLines(
        checkedIds: Set<String>,
        rows: [CockpitIntentRow],
        plan: VoiceMemoPlan
    ) -> [(intentId: String, label: String, preview: String)] {
        commitOrder(checkedIds: checkedIds, rows: rows).compactMap { row in
            let label = MemoryProcessCockpit.commitWriteLabel(for: row) ?? "Will write"
            let preview = MemoryProcessCockpit.confirmPreviewText(for: row, plan: plan)
            let truncated = preview.count > 200 ? String(preview.prefix(197)) + "…" : preview
            return (row.intentId, label, truncated)
        }
    }

    // MARK: - Commit response parsing

    /// Parse a `voice_memo_commit` envelope. `needsManual` is never treated as success.
    public static func parseCommitResponse(_ env: [String: Value]) -> (ok: Bool, needsManual: Bool, detail: String) {
        var ok = false
        var detail = ""
        var needsManual = false
        if case .bool(let b)? = env["ok"] { ok = b }
        if case .string(let d)? = env["detail"] { detail = d }
        if case .bool(true)? = env["needsManual"] {
            needsManual = true
            ok = false
        }
        return (ok, needsManual, detail)
    }

    // MARK: - Batch execution (UI + integration tests)

    /// Sequential commit loop — continues after per-intent failure. Activity logging stays in the UI layer.
    public static func executeBatch(
        memoId: String,
        checkedIds: Set<String>,
        rows: [CockpitIntentRow],
        selectedRowIdByIntentId: [String: String],
        commit: @Sendable (CockpitIntentRow, [String: Value]) async throws -> [String: Value]
    ) async -> [BatchCommitOutcome] {
        let ordered = commitOrder(checkedIds: checkedIds, rows: rows)
        var outcomes: [BatchCommitOutcome] = []
        for row in ordered {
            let rowId = selectedRowIdByIntentId[row.intentId]
            let args = MemoryProcessCockpit.commitArguments(memoId: memoId, row: row, selectedRowId: rowId)
            var ok = false
            var needsManual = false
            var detail = ""
            do {
                let env = try await commit(row, args)
                let parsed = parseCommitResponse(env)
                ok = parsed.ok
                needsManual = parsed.needsManual
                detail = parsed.detail
            } catch {
                detail = error.localizedDescription
            }
            outcomes.append(BatchCommitOutcome(
                intentId: row.intentId, kind: row.kind, ok: ok, needsManual: needsManual,
                detail: detail, receiptHash: nil
            ))
        }
        return outcomes
    }

    // MARK: - Batch result aggregation

    public struct BatchCommitOutcome: Sendable, Equatable {
        public let intentId: String
        public let kind: VoiceMemoIntentKind
        public let ok: Bool
        public let needsManual: Bool
        public let detail: String
        public let receiptHash: String?

        public init(intentId: String, kind: VoiceMemoIntentKind, ok: Bool, needsManual: Bool, detail: String, receiptHash: String?) {
            self.intentId = intentId
            self.kind = kind
            self.ok = ok
            self.needsManual = needsManual
            self.detail = detail
            self.receiptHash = receiptHash
        }
    }

    public struct BatchCommitResult: Sendable, Equatable {
        public let outcomes: [BatchCommitOutcome]
        public let processedGateCleared: Bool

        public var anySuccess: Bool { outcomes.contains { $0.ok } }
        public var allSucceeded: Bool { !outcomes.isEmpty && outcomes.allSatisfy { $0.ok } }
        public var successCount: Int { outcomes.filter(\.ok).count }
        public var totalCount: Int { outcomes.count }

        public init(outcomes: [BatchCommitOutcome], processedGateCleared: Bool) {
            self.outcomes = outcomes
            self.processedGateCleared = processedGateCleared
        }
    }

    public static func aggregateStatusMessage(result: BatchCommitResult) -> String {
        let ok = result.successCount
        let total = result.totalCount
        if total == 0 { return "No intents committed." }
        if ok == total {
            return "Committed \(ok)/\(total) intent\(total == 1 ? "" : "s")."
        }
        let manual = result.outcomes.filter(\.needsManual).count
        var parts = ["Committed \(ok)/\(total)"]
        if manual > 0 { parts.append("\(manual) need manual follow-up") }
        let failed = total - ok - manual
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: "; ") + "."
    }

    /// Triage `emitCommitted` detail string — single event after batch with rich context.
    public static func triageCommittedDetail(result: BatchCommitResult) -> String {
        let kinds = result.outcomes.filter(\.ok).map { $0.kind.rawValue }.joined(separator: ", ")
        let lastHash = result.outcomes.last(where: { $0.ok })?.receiptHash ?? ""
        var detail = "committed \(result.successCount)/\(result.totalCount)"
        if !kinds.isEmpty { detail += ": \(kinds)" }
        if !lastHash.isEmpty { detail += "; lastReceipt=\(lastHash)" }
        return detail
    }
}
