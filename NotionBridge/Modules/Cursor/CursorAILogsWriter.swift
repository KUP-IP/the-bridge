// CursorAILogsWriter.swift — PKT-3.4.1-RESCUE Phase 3
// NotionBridge · Modules · Cursor
//
// Drains terminal Cursor agent runs (and the queued RedactionAuditEntry list
// for the same run) into a single Session-typed entry in AI LOGS DS
// (992fd5ac-d938-4be4-95fb-8ef18bd86bba).
//
// The DS schema (verified 2026-05-13) is the universal UEP telemetry log —
// not a Cursor-specific shape. Cursor-run metadata that doesn't fit a typed
// column lands in `Session Context` (rich_text) as compact JSON; the
// hash-only privacy posture is preserved by using `prompt_hash` not `prompt`.
//
// Schema mapping (see notion_datasource_get output for column ids):
//   Log Name (title)            → "Cursor run: <model>/<runtime> — <status>"
//   Log Type (select)           → "Session"
//   Platform (select)           → "Cursor"
//   Outcome (select)            → Success | Partial | Failure | Abandoned
//   Duration (number, seconds)  → endedAt - startedAt
//   Confidence (number)         → 1.0 succeeded · 0.5 cancelled · 0.0 failed
//   Session Context (rich_text) → JSON: { runId, runtime, model, repoPath,
//                                  prURL, costCents, lastEventId, promptHash,
//                                  forcedLocal, sensitiveRepoMatched }
//   Artifacts Created (rich_text) → JSON list of { kind, url?, label? }
//   Friction Signals (rich_text)  → rule IDs csv (or "none")

import Foundation

public actor CursorAILogsWriter {

    public static let shared = CursorAILogsWriter()

    /// Notion DS id for AI LOGS. Hardcoded SSOT; if the workspace migrates,
    /// update here and in `protocol.ts` SPEC §10.
    public static let aiLogsDataSourceId = "992fd5ac-d938-4be4-95fb-8ef18bd86bba"

    /// Pending writes deduplicated by runId. Allows the queue to absorb
    /// repeated terminal-event signals without producing duplicate rows.
    private var alreadyWritten = Set<String>()

    public init() {}

    /// Persist one terminal-state run + its audit context into AI LOGS DS.
    /// Idempotent on runId: a second call for the same run is a no-op.
    /// - Returns: the created Notion page id, or `nil` if skipped (already
    ///   written) or on transient failure (logged to stderr; queue retains
    ///   the audit entries so a future retry can be attempted).
    @discardableResult
    public func recordRun(
        _ run: CursorRun,
        audits: [RedactionAuditEntry],
        artifacts: [CursorArtifact]
    ) async -> String? {
        if alreadyWritten.contains(run.id) { return nil }

        do {
            let client = try await NotionClientRegistry.shared.getClient()
            let properties = buildProperties(run: run, audits: audits, artifacts: artifacts)
            let propertiesData = try JSONSerialization.data(withJSONObject: properties, options: [])

            let responseData = try await client.createPage(
                parentId: CursorAILogsWriter.aiLogsDataSourceId,
                parentType: "data_source_id",
                properties: propertiesData,
                children: nil
            )
            alreadyWritten.insert(run.id)
            if let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let id = obj["id"] as? String {
                return id
            }
            return nil
        } catch {
            FileHandle.standardError.write(Data(
                "[CursorAILogsWriter] write failed for run \(run.id): \(error.localizedDescription)\n".utf8
            ))
            return nil
        }
    }

    /// Reset internal dedup state — tests only.
    public func resetForTests() {
        alreadyWritten.removeAll()
    }

    // MARK: - Property builder

    public nonisolated func buildProperties(
        run: CursorRun,
        audits: [RedactionAuditEntry],
        artifacts: [CursorArtifact]
    ) -> [String: Any] {
        let outcome = Self.outcome(for: run.status)
        let confidence = Self.confidence(for: run.status)
        let durationSeconds = Self.durationSeconds(run: run)
        let titleText = "Cursor run: \(run.model)/\(run.runtime.rawValue) — \(run.status.rawValue)"

        let sessionContext = Self.sessionContextJSON(run: run, audits: audits)
        let artifactsBlob = Self.artifactsJSON(artifacts)
        let frictionSignals = Self.frictionSignalsText(audits)

        var properties: [String: Any] = [
            "Log Name": [
                "title": [["text": ["content": titleText]]]
            ],
            "Log Type": [
                "select": ["name": "Session"]
            ],
            "Platform": [
                "select": ["name": "Cursor"]
            ],
            "Outcome": [
                "select": ["name": outcome]
            ],
            "Session Context": [
                "rich_text": [["text": ["content": sessionContext]]]
            ],
            "Artifacts Created": [
                "rich_text": [["text": ["content": artifactsBlob]]]
            ],
            "Friction Signals": [
                "rich_text": [["text": ["content": frictionSignals]]]
            ]
        ]
        if let duration = durationSeconds {
            properties["Duration"] = ["number": duration]
        }
        properties["Confidence"] = ["number": confidence]
        return properties
    }

    // MARK: - Mappers (nonisolated for testability)

    public nonisolated static func outcome(for status: CursorRunStatus) -> String {
        switch status {
        case .succeeded: return "Success"
        case .failed:    return "Failure"
        case .cancelled: return "Abandoned"
        case .running, .queued, .unknown: return "Partial"
        }
    }

    public nonisolated static func confidence(for status: CursorRunStatus) -> Double {
        switch status {
        case .succeeded: return 1.0
        case .cancelled: return 0.5
        case .failed:    return 0.0
        default:         return 0.5
        }
    }

    public nonisolated static func durationSeconds(run: CursorRun) -> Double? {
        guard let end = run.endedAt else { return nil }
        return end.timeIntervalSince(run.startedAt)
    }

    public nonisolated static func sessionContextJSON(run: CursorRun, audits: [RedactionAuditEntry]) -> String {
        var dict: [String: Any] = [
            "runId": run.id,
            "runtime": run.runtime.rawValue,
            "model": run.model,
            "status": run.status.rawValue,
            "startedAt": ISO8601DateFormatter().string(from: run.startedAt)
        ]
        if let end = run.endedAt { dict["endedAt"] = ISO8601DateFormatter().string(from: end) }
        if let p = run.repoPath { dict["repoPath"] = p }
        if let p = run.prURL { dict["prURL"] = p }
        if let c = run.costCents { dict["costCents"] = c }
        if let l = run.lastEventId { dict["lastEventId"] = l }
        if let audit = audits.first {
            dict["promptHash"] = audit.promptHash
            dict["redactionCount"] = audit.count
            dict["ruleIds"] = audit.ruleIds
            dict["forcedLocal"] = audit.forcedLocal
            if let pattern = audit.sensitiveRepoMatched { dict["sensitiveRepoMatched"] = pattern }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    public nonisolated static func artifactsJSON(_ artifacts: [CursorArtifact]) -> String {
        let list = artifacts.map { a -> [String: Any] in
            var d: [String: Any] = ["kind": a.kind]
            if let u = a.url { d["url"] = u }
            if let l = a.label { d["label"] = l }
            if let m = a.mediaType { d["mediaType"] = m }
            return d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    public nonisolated static func frictionSignalsText(_ audits: [RedactionAuditEntry]) -> String {
        let allRules = Array(Set(audits.flatMap(\.ruleIds))).sorted()
        if allRules.isEmpty { return "none" }
        return allRules.joined(separator: ", ")
    }
}
