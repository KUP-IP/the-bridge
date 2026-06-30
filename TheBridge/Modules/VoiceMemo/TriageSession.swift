// TriageSession.swift — Operator triage session (PKT-MEM-122)
// TheBridge · Modules · VoiceMemo
//
// MCP agent ↔ UI handoff: `voice_memo_triage_open` / `voice_memo_triage_await`.
// HTTP/SSE opener only (stdio excluded via MCPClientPresence). Events queue durably
// when no waiter is attached; drain on the next `await`.

import Foundation
import MCP

public enum TriageSessionError: Error, Sendable, Equatable {
    case stdioOnlyOpener
    case sessionAlreadyOpen(memoId: String)
    case sessionNotFound
    case sessionEnded
}

public struct TriageEventPayload: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case committed
        case sessionEnded
        case timeout
    }

    public let kind: Kind
    public let memoId: String
    public let receiptHash: String?
    public let detail: String?

    public init(kind: Kind, memoId: String, receiptHash: String? = nil, detail: String? = nil) {
        self.kind = kind
        self.memoId = memoId
        self.receiptHash = receiptHash
        self.detail = detail
    }
}

/// Actor-backed triage session store (one active session per memo).
public actor TriageSessionStore {

    public static let shared = TriageSessionStore()

    private struct Session: Sendable {
        let sessionId: String
        let memoId: String
        let openerClientId: String
        var ended: Bool
    }

    private struct QueuedEnvelope: Codable {
        let sessionId: String
        let event: TriageEventPayload
    }

    private var sessions: [String: Session] = [:]
    private var memoToSession: [String: String] = [:]
    private var pendingBySession: [String: [TriageEventPayload]] = [:]
    private var waiters: [String: CheckedContinuation<TriageEventPayload?, Never>] = [:]

    /// Hermetic override — when set, skips MCPClientPresence gate.
    nonisolated(unsafe) public static var testAllowWithoutHTTPClient = false
    /// Hermetic override — pretend this HTTP client name is the opener.
    nonisolated(unsafe) public static var testOpenerClientId: String?

    public init() {}

    // MARK: - Open / await / end

    public func open(memoId: String) async throws -> (sessionId: String, openerClientId: String) {
        let trimmed = memoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TriageSessionError.sessionNotFound }

        let openerId: String?
        if let testId = Self.testOpenerClientId {
            openerId = testId
        } else if Self.testAllowWithoutHTTPClient {
            openerId = "test-http-client"
        } else {
            let present = await MCPClientPresence.shared.hasConnectedClient
            guard present else { throw TriageSessionError.stdioOnlyOpener }
            openerId = await MCPClientPresence.shared.primaryClientName
        }
        guard let openerClientId = openerId, !openerClientId.isEmpty else {
            throw TriageSessionError.stdioOnlyOpener
        }

        if let existingId = memoToSession[trimmed], let existing = sessions[existingId], !existing.ended {
            throw TriageSessionError.sessionAlreadyOpen(memoId: trimmed)
        }

        let sessionId = UUID().uuidString
        let session = Session(sessionId: sessionId, memoId: trimmed, openerClientId: openerClientId, ended: false)
        sessions[sessionId] = session
        memoToSession[trimmed] = sessionId
        pendingBySession[sessionId] = loadDurableQueue(sessionId: sessionId)
        return (sessionId, openerClientId)
    }

    public func awaitEvent(sessionId: String, timeoutSeconds: Int) async -> TriageEventPayload {
        let capped = min(max(timeoutSeconds, 1), 1800)
        guard let session = sessions[sessionId], !session.ended else {
            return TriageEventPayload(kind: .sessionEnded, memoId: "", detail: "session not found or already ended")
        }

        if let queued = drainNextPending(sessionId: sessionId) {
            return queued
        }

        return await withTaskGroup(of: TriageEventPayload.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<TriageEventPayload?, Never>) in
                    Task { await self.registerWaiter(sessionId: sessionId, continuation: cont) }
                } ?? TriageEventPayload(kind: .sessionEnded, memoId: session.memoId, detail: "session ended while waiting")
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(capped) * 1_000_000_000)
                return TriageEventPayload(kind: .timeout, memoId: session.memoId, detail: "await timed out after \(capped)s")
            }
            let first = await group.next()!
            group.cancelAll()
            if first.kind == .timeout {
                await self.cancelWaiter(sessionId: sessionId)
            }
            return first
        }
    }

    public func emitCommitted(memoId: String, receiptHash: String, detail: String) {
        guard let sessionId = memoToSession[memoId], var session = sessions[sessionId], !session.ended else { return }
        let event = TriageEventPayload(kind: .committed, memoId: memoId, receiptHash: receiptHash, detail: detail)
        deliver(event, sessionId: sessionId, session: &session)
        sessions[sessionId] = session
        endSession(sessionId: sessionId, reason: "committed")
    }

    public func invalidateForMemo(memoId: String) {
        guard let sessionId = memoToSession[memoId] else { return }
        endSession(sessionId: sessionId, reason: "invalidated")
    }

    public func endSession(sessionId: String, reason: String) {
        guard var session = sessions[sessionId], !session.ended else { return }
        session.ended = true
        sessions[sessionId] = session
        memoToSession.removeValue(forKey: session.memoId)
        let event = TriageEventPayload(kind: .sessionEnded, memoId: session.memoId, detail: reason)
        deliver(event, sessionId: sessionId, session: &session)
        sessions[sessionId] = session
        cancelWaiter(sessionId: sessionId)
        pendingBySession.removeValue(forKey: sessionId)
        removeDurableQueue(sessionId: sessionId)
    }

    public func activeSession(forMemoId memoId: String) -> String? {
        guard let sid = memoToSession[memoId], let s = sessions[sid], !s.ended else { return nil }
        return sid
    }

    public func resetForTesting() {
        for (_, cont) in waiters { cont.resume(returning: nil) }
        waiters.removeAll()
        sessions.removeAll()
        memoToSession.removeAll()
        pendingBySession.removeAll()
    }

    // MARK: - Internals

    private func registerWaiter(sessionId: String, continuation: CheckedContinuation<TriageEventPayload?, Never>) {
        if let existing = waiters[sessionId] {
            existing.resume(returning: nil)
        }
        waiters[sessionId] = continuation
        if let queued = drainNextPending(sessionId: sessionId) {
            waiters.removeValue(forKey: sessionId)?.resume(returning: queued)
        }
    }

    private func cancelWaiter(sessionId: String) {
        waiters.removeValue(forKey: sessionId)?.resume(returning: nil)
    }

    private func deliver(_ event: TriageEventPayload, sessionId: String, session: inout Session) {
        if let cont = waiters.removeValue(forKey: sessionId) {
            cont.resume(returning: event)
        } else {
            var queue = pendingBySession[sessionId] ?? []
            queue.append(event)
            pendingBySession[sessionId] = queue
            persistDurableQueue(sessionId: sessionId, events: queue)
        }
        _ = session
    }

    private func drainNextPending(sessionId: String) -> TriageEventPayload? {
        guard var queue = pendingBySession[sessionId], !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        pendingBySession[sessionId] = queue.isEmpty ? nil : queue
        if queue.isEmpty {
            removeDurableQueue(sessionId: sessionId)
        } else {
            persistDurableQueue(sessionId: sessionId, events: queue)
        }
        return next
    }

    private func queueFile(sessionId: String) -> URL {
        BridgePaths.applicationSupport(.memoryHub)
            .appendingPathComponent("triage-queue-\(sessionId).json")
    }

    private func loadDurableQueue(sessionId: String) -> [TriageEventPayload] {
        let url = queueFile(sessionId: sessionId)
        guard let data = try? Data(contentsOf: url),
              let envelopes = try? JSONDecoder().decode([QueuedEnvelope].self, from: data) else { return [] }
        return envelopes.map(\.event)
    }

    private func persistDurableQueue(sessionId: String, events: [TriageEventPayload]) {
        let url = queueFile(sessionId: sessionId)
        let envelopes = events.map { QueuedEnvelope(sessionId: sessionId, event: $0) }
        guard let data = try? JSONEncoder().encode(envelopes) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func removeDurableQueue(sessionId: String) {
        try? FileManager.default.removeItem(at: queueFile(sessionId: sessionId))
    }
}

// MARK: - MCP value helpers

public enum TriageSessionMCP {

    public static func eventValue(_ event: TriageEventPayload) -> Value {
        var obj: [String: Value] = [
            "kind": .string(event.kind.rawValue),
            "memoId": .string(event.memoId),
        ]
        if let receiptHash = event.receiptHash { obj["receiptHash"] = .string(receiptHash) }
        if let detail = event.detail { obj["detail"] = .string(detail) }
        return .object(obj)
    }
}
