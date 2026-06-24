// VoiceMemoModels.swift — Registry-Centric Voice Router (Wave 1)
// TheBridge · Modules · VoiceMemo
//
// Intent taxonomy for the morning Voice Memos curator. `memory_keep` is the
// Keep OS branded lane: durable notes filed in the Notion Memory registry
// entity — distinct from `agent_memory` (Bridge SQLite) and `reminder`
// (Apple Reminders).

import Foundation

/// A discovered Voice Memos recording on disk.
public struct VoiceMemoRecording: Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let title: String
    public let recordedAt: Date
    public let transcript: String?
    public let transcriptSource: VoiceMemoTranscriptSource

    public init(
        id: String,
        path: String,
        title: String,
        recordedAt: Date,
        transcript: String?,
        transcriptSource: VoiceMemoTranscriptSource = .none
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.recordedAt = recordedAt
        self.transcript = transcript
        self.transcriptSource = transcriptSource
    }

    public var hasTranscript: Bool {
        guard let t = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return transcriptSource == .apple
        }
        return !t.isEmpty
    }
}

/// Routed write lane — `memory_keep` targets the Notion Memory registry entity.
public enum VoiceMemoIntentKind: String, Sendable, Codable, CaseIterable {
    case reminder
    case memoryKeep = "memory_keep"
    case agentMemory = "agent_memory"
    case registryUpdate = "registry_update"
    case review
}

/// One executable intent extracted from a transcript.
public struct VoiceMemoIntent: Sendable, Equatable {
    public var kind: VoiceMemoIntentKind
    public var confidence: Double
    /// Registry entity key (`contact`, `project`, `packet`, `memory`, …).
    public var entityKey: String?
    /// Human hint used to match a registry row title.
    public var entityHint: String?
    public var title: String?
    public var body: String?
    public var dueISO8601: String?
    /// Canonical registry field keys → string values for create/update.
    public var fields: [String: String]

    public init(
        kind: VoiceMemoIntentKind,
        confidence: Double,
        entityKey: String? = nil,
        entityHint: String? = nil,
        title: String? = nil,
        body: String? = nil,
        dueISO8601: String? = nil,
        fields: [String: String] = [:]
    ) {
        self.kind = kind
        self.confidence = confidence
        self.entityKey = entityKey
        self.entityHint = entityHint
        self.title = title
        self.body = body
        self.dueISO8601 = dueISO8601
        self.fields = fields
    }
}

/// Parser output for one memo.
public struct VoiceMemoPlan: Sendable, Equatable {
    public var generatedTitle: String
    public var skipMemoryKeep: Bool
    public var summary: String
    public var actions: [String]
    public var intents: [VoiceMemoIntent]

    public init(
        generatedTitle: String,
        skipMemoryKeep: Bool,
        summary: String,
        actions: [String],
        intents: [VoiceMemoIntent]
    ) {
        self.generatedTitle = generatedTitle
        self.skipMemoryKeep = skipMemoryKeep
        self.summary = summary
        self.actions = actions
        self.intents = intents
    }
}

/// Result of executing one intent.
public struct VoiceMemoIntentOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case executed, skipped, review, failed, dryRun }

    public var kind: VoiceMemoIntentKind
    public var status: Status
    public var detail: String

    public init(kind: VoiceMemoIntentKind, status: Status, detail: String) {
        self.kind = kind
        self.status = status
        self.detail = detail
    }
}

/// Per-memo processing receipt returned in the tool envelope.
public struct VoiceMemoReceipt: Sendable, Equatable {
    public var memoId: String
    public var title: String
    public var skippedReason: String?
    public var outcomes: [VoiceMemoIntentOutcome]

    public init(memoId: String, title: String, skippedReason: String? = nil, outcomes: [VoiceMemoIntentOutcome] = []) {
        self.memoId = memoId
        self.title = title
        self.skippedReason = skippedReason
        self.outcomes = outcomes
    }
}
