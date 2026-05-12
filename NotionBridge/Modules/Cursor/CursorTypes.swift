// CursorTypes.swift — PKT-3.4.1 (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Bridge-side DTOs for the cursor-sidecar JSON-RPC surface. Provides the
// interface boundary so @cursor/sdk changes touch only the Node sidecar
// adapter, not the Swift module. Mirrors cursor-sidecar/SPEC.md §3 + §10.

import Foundation

// MARK: - Enums

public enum CursorRuntimeKind: String, Codable, Sendable, CaseIterable {
    case local
    case cloud
}

public enum CursorRunStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case unknown
}

// MARK: - DTOs

public struct CursorRun: Codable, Sendable, Equatable {
    public let id: String
    public let runtime: CursorRuntimeKind
    public let model: String
    public let status: CursorRunStatus
    public let startedAt: Date
    public let endedAt: Date?
    public let costCents: Int?
    public let repoPath: String?
    public let prURL: String?
    public let lastEventId: String?

    public init(
        id: String,
        runtime: CursorRuntimeKind,
        model: String,
        status: CursorRunStatus,
        startedAt: Date,
        endedAt: Date? = nil,
        costCents: Int? = nil,
        repoPath: String? = nil,
        prURL: String? = nil,
        lastEventId: String? = nil
    ) {
        self.id = id
        self.runtime = runtime
        self.model = model
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.costCents = costCents
        self.repoPath = repoPath
        self.prURL = prURL
        self.lastEventId = lastEventId
    }
}

public struct CursorArtifact: Codable, Sendable, Equatable {
    /// One of: "pr_url" | "file" | "log" | "diff" | "session".
    public let kind: String
    public let url: String?
    public let label: String?
    public let mediaType: String?

    public init(kind: String, url: String? = nil, label: String? = nil, mediaType: String? = nil) {
        self.kind = kind
        self.url = url
        self.label = label
        self.mediaType = mediaType
    }
}

public struct CursorEvent: Codable, Sendable, Equatable {
    /// SSE event id (used for Last-Event-ID reconnect per SPEC §8).
    public let id: String
    public let runId: String
    /// One of: "token" | "tool_call" | "status" | "artifact" | "re_attached" | "error".
    public let kind: String
    public let timestamp: Date
    /// Simple string-keyed payload (richer types live in the sidecar adapter).
    public let payload: [String: String]?

    public init(
        id: String,
        runId: String,
        kind: String,
        timestamp: Date,
        payload: [String: String]? = nil
    ) {
        self.id = id
        self.runId = runId
        self.kind = kind
        self.timestamp = timestamp
        self.payload = payload
    }
}

public struct CursorCapability: Sendable, Equatable {
    public let ok: Bool
    public let reason: String?
    public let nodePath: String?
    public let nodeVersion: String?
    public let sidecarPath: String?
    public let sidecarVersion: String?
    public let hasApiKey: Bool

    public init(
        ok: Bool,
        reason: String? = nil,
        nodePath: String? = nil,
        nodeVersion: String? = nil,
        sidecarPath: String? = nil,
        sidecarVersion: String? = nil,
        hasApiKey: Bool = false
    ) {
        self.ok = ok
        self.reason = reason
        self.nodePath = nodePath
        self.nodeVersion = nodeVersion
        self.sidecarPath = sidecarPath
        self.sidecarVersion = sidecarVersion
        self.hasApiKey = hasApiKey
    }
}

// MARK: - Errors

/// Mirrors the sidecar error registry from SPEC.md §4.
public enum CursorError: Error, LocalizedError, Sendable {
    /// 10001
    case notImplemented(String)
    /// 10002
    case capabilityMissing(String)
    /// 10003
    case authFailed(String)
    /// 10004
    case sdkError(String)
    /// 10005
    case costCapTripped(String)
    /// 10006
    case timeout(String)
    /// Bridge-side (Swift) IPC / spawn errors.
    case spawnFailed(String)
    case ipcError(String)
    case invalidArgument(String)
    /// Pass-through for sidecar errors with an arbitrary code.
    case sidecarError(code: Int, message: String, data: String?)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let r):    return "not_implemented: \(r)"
        case .capabilityMissing(let r): return "capability_missing: \(r)"
        case .authFailed(let r):        return "auth_failed: \(r)"
        case .sdkError(let r):          return "sdk_error: \(r)"
        case .costCapTripped(let r):    return "cost_cap_tripped: \(r)"
        case .timeout(let r):           return "timeout: \(r)"
        case .spawnFailed(let r):       return "spawn_failed: \(r)"
        case .ipcError(let r):          return "ipc_error: \(r)"
        case .invalidArgument(let r):   return "invalid_argument: \(r)"
        case .sidecarError(let c, let m, _): return "sidecar_error[\(c)]: \(m)"
        }
    }

    /// Numeric code per SPEC §4 (10001–10006), or 0 for Bridge-side transport errors.
    public var sidecarCode: Int {
        switch self {
        case .notImplemented:    return 10001
        case .capabilityMissing: return 10002
        case .authFailed:        return 10003
        case .sdkError:          return 10004
        case .costCapTripped:    return 10005
        case .timeout:           return 10006
        case .sidecarError(let c, _, _): return c
        default: return 0
        }
    }
}
