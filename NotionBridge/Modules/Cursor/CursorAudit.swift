// CursorAudit.swift — PKT-3.4.3 (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Audit payload for Cursor hardening events. Captures the metadata that the
// AI LOGS DS writer (PKT-3.4.1.W2) will drain into a Session-type entry.
//
// Privacy posture:
//   - `promptHash` is sha256 hex of the *original* prompt; the prompt itself
//     is never persisted.
//   - `ruleIds` records WHICH rules matched but never WHAT matched.
//   - `count` is the total match count (across all rules).
//
// Wave 1 of PKT-3.4.3 (this packet): DTO + actor-queued accumulator on
// CursorRuntime. Notion DS write path lives in PKT-3.4.1.W2 (it owns the
// NotionAPIClient wire). Hardening tests observe the queue directly.

import Foundation

public struct RedactionAuditEntry: Sendable, Equatable, Codable {

    /// Run id from the sidecar, when known. `nil` at queue time because the
    /// sidecar assigns ids AFTER the hardening pass runs. PKT-3.4.1.W2 will
    /// populate this when it drains the queue.
    public let runId: String?

    /// Total redaction count across all matched rules.
    public let count: Int

    /// Rule IDs that matched at least once, in match order (deduplicated).
    public let ruleIds: [String]

    /// sha256(originalPrompt) hex. Used as the AI LOGS reference for the
    /// hash-only audit retention path (3.4.3 IN scope).
    public let promptHash: String

    /// Repo path passed to `cursor_agent_run` (for cross-reference with
    /// `sensitiveRepoMatched`). May be `nil` for cloud-only runs that don't
    /// specify a repo.
    public let repoPath: String?

    /// Sensitive-repo glob pattern that matched, if any. `nil` means the repo
    /// was not on the sensitive allowlist.
    public let sensitiveRepoMatched: String?

    /// `true` when the caller requested runtime=cloud but the sensitive-repo
    /// allowlist forced runtime=local. Drives the "extra approval required"
    /// UX signal in PKT-3.4.2's new-run modal.
    public let forcedLocal: Bool

    /// Bridge clock at which the hardening pass ran.
    public let redactedAt: Date

    public init(
        runId: String?,
        count: Int,
        ruleIds: [String],
        promptHash: String,
        repoPath: String?,
        sensitiveRepoMatched: String?,
        forcedLocal: Bool,
        redactedAt: Date
    ) {
        self.runId = runId
        self.count = count
        self.ruleIds = ruleIds
        self.promptHash = promptHash
        self.repoPath = repoPath
        self.sensitiveRepoMatched = sensitiveRepoMatched
        self.forcedLocal = forcedLocal
        self.redactedAt = redactedAt
    }
}

/// Result of the pre-dispatch hardening pass. Bundles the scrubbed prompt,
/// effective runtime, and the verdicts that produced them. Caller (currently
/// `CursorRuntime.agentRun`; W2's live IPC path) uses these to dispatch.
public struct CursorGateVerdict: Sendable, Equatable {
    public let scrubbedPrompt: String
    public let effectiveRuntime: CursorRuntimeKind
    public let sensitivity: SensitiveRepoMatcher.Verdict
    public let redaction: PromptRedactor.Result
    /// The audit entry that was queued onto CursorRuntime's pending queue.
    public let auditQueued: RedactionAuditEntry

    public init(
        scrubbedPrompt: String,
        effectiveRuntime: CursorRuntimeKind,
        sensitivity: SensitiveRepoMatcher.Verdict,
        redaction: PromptRedactor.Result,
        auditQueued: RedactionAuditEntry
    ) {
        self.scrubbedPrompt = scrubbedPrompt
        self.effectiveRuntime = effectiveRuntime
        self.sensitivity = sensitivity
        self.redaction = redaction
        self.auditQueued = auditQueued
    }
}
