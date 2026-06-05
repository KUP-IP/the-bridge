// SessionPersistenceStore.swift — MCP session durability across restart/install
// NotionBridge · Server
//
// ITEM [session]: The app HOSTS the MCP server in-process, so an app restart /
// `make install` tears down the live `SSEServer.sessions` map. A returning
// client carrying its prior `Mcp-Session-Id` then hit a hard 404 ("Session not
// found or expired") and had to manually reconnect.
//
// This store implements the SERVER-SIDE half of session durability:
//
//   1. PERSIST — active session ids + minimal context (client name/version,
//      created/last-accessed timestamps, protocol version) are snapshotted to
//      a single JSON document on disk as sessions are created / touched / torn
//      down. Atomic-rename writes (Data.write(.atomic)) so a `kill -9`
//      mid-write (force-quit / installer swap) cannot leave a torn file —
//      mirrors SnippetStore's crash-safe posture.
//
//   2. CLEAN-SHUTDOWN MARKER — on a graceful shutdown (app quit / install) the
//      server records a `shutdown` marker { date, reason, cleanlyEnded: true }
//      and flushes. On the next launch this lets the server distinguish a
//      planned restart from a crash, and lets a reconnecting client be told
//      "the host restarted" rather than "your session is corrupt".
//
//   3. RESUME CAPABILITY — on restart the live `sessions` map is empty, but the
//      persisted snapshot still knows the prior session ids. A reconnect
//      carrying a KNOWN-but-expired session id is answered with a structured,
//      machine-readable "re-initialize" response (HTTP 404 + JSON-RPC error
//      carrying a stable `resumable: true` hint + the prior session id) per
//      Streamable-HTTP resumability guidance, instead of the opaque hard-404
//      that gave clients no signal to recover.
//
// SCOPE NOTE (status=partial): full TRANSPARENT transport resume (replaying the
// SDK's per-stream event log so an in-flight request survives a restart without
// a client round-trip) requires SDK-level event-store support that
// StatefulHTTPServerTransport does not expose here. That remainder, and the
// harness-side auto re-initialize, are documented as external asks in
// docs/session-durability.md. This store delivers the contained, safe slice:
// persistence + clean-shutdown marker + a resumable-reconnect signal.
//
// Concurrency: `actor` — every mutation is serialized so concurrent session
// create / touch / remove calls cannot corrupt the snapshot.

import Foundation

// MARK: - Models

/// A persisted snapshot of one MCP session's durable context. Deliberately
/// minimal: it carries identity + provenance, NEVER any tool arguments, bearer
/// material, or transport buffers. Enough to recognise a returning client and
/// answer its reconnect with a resumable signal.
public struct PersistedSession: Codable, Sendable, Equatable {
    /// The `Mcp-Session-Id` issued at initialize.
    public let sessionID: String
    /// MCP `clientInfo.name`, if the client supplied one.
    public var clientName: String?
    /// MCP `clientInfo.version`, if supplied.
    public var clientVersion: String?
    /// Transport that owns this session ("streamable-http" | "legacy-sse").
    public var transport: String
    /// Negotiated MCP protocol version at handshake, if known.
    public var protocolVersion: String?
    /// When the session first initialized.
    public let createdAt: Date
    /// Last request observed on the session (drives staleness).
    public var lastAccessedAt: Date

    public init(
        sessionID: String,
        clientName: String? = nil,
        clientVersion: String? = nil,
        transport: String,
        protocolVersion: String? = nil,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.transport = transport
        self.protocolVersion = protocolVersion
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

/// Records HOW the server last stopped, so the next launch can distinguish a
/// planned restart from a crash.
public struct ShutdownMarker: Codable, Sendable, Equatable {
    public let date: Date
    public let reason: String
    /// `true` when the server stopped via the graceful path (app quit /
    /// install). `false`/absent ⇒ the prior run ended unexpectedly (crash /
    /// force-quit) — the marker was never written.
    public let cleanlyEnded: Bool
    /// Number of sessions that were active at clean shutdown.
    public let activeSessionsAtShutdown: Int

    public init(date: Date = Date(), reason: String, cleanlyEnded: Bool, activeSessionsAtShutdown: Int) {
        self.date = date
        self.reason = reason
        self.cleanlyEnded = cleanlyEnded
        self.activeSessionsAtShutdown = activeSessionsAtShutdown
    }
}

/// The outcome of looking up a reconnecting session id against the persisted
/// snapshot. Pure value so the reconnect decision is unit-testable without a
/// live transport.
public enum SessionResumeLookup: Sendable, Equatable {
    /// The id was never known (truly unknown / forged) — caller should fall
    /// back to the existing "missing/unknown session" handling.
    case unknown
    /// The id IS known from a prior run but has no live transport — the host
    /// restarted. Caller should answer with a resumable re-initialize signal.
    case resumable(PersistedSession, cleanShutdown: Bool)
}

// MARK: - Store

public actor SessionPersistenceStore {

    /// Process-wide store used by the live server. Tests construct their own
    /// instance over a temp URL (never the real on-disk store).
    public static let shared = SessionPersistenceStore()

    private struct Document: Codable {
        var schemaVersion: Int
        var sessions: [PersistedSession]
        var lastShutdown: ShutdownMarker?
        /// Set true at the FIRST session write of a run, cleared by a clean
        /// shutdown marker. If a launch reads `dirtyRun == true` with no fresh
        /// clean marker, the prior run ended uncleanly.
        var dirtyRun: Bool
    }

    private static let currentSchemaVersion = 1
    private let storeURL: URL
    private var doc: Document

    public init(storeURL: URL = SessionPersistenceStore.defaultStoreURL()) {
        self.storeURL = storeURL
        self.doc = SessionPersistenceStore.loadOrRecover(url: storeURL)
    }

    public nonisolated static func defaultStoreURL() -> URL {
        BridgePaths.applicationSupport(.sessions)
            .appendingPathComponent("active-sessions.json", isDirectory: false)
    }

    // MARK: Load / persist

    private nonisolated static func loadOrRecover(url: URL) -> Document {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return Document(
                schemaVersion: currentSchemaVersion,
                sessions: [],
                lastShutdown: nil,
                dirtyRun: false
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let d = try? decoder.decode(Document.self, from: data) {
            return d
        }
        // Corrupt file — preserve it for forensics, start fresh rather than
        // throw. A torn snapshot must never block server startup.
        let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: backup)
        return Document(
            schemaVersion: currentSchemaVersion,
            sessions: [],
            lastShutdown: nil,
            dirtyRun: false
        )
    }

    private func persist() {
        let dir = storeURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(doc) else { return }
        try? data.write(to: storeURL, options: [.atomic])  // temp + atomic rename
    }

    // MARK: - Launch introspection

    /// Whether the PRIOR run ended cleanly (its shutdown marker was written).
    /// Read once at launch to decide how to phrase a reconnect ("host
    /// restarted" vs "host recovered from an unexpected stop").
    public func priorRunEndedCleanly() -> Bool {
        // A clean shutdown writes `cleanlyEnded: true` AND clears dirtyRun.
        // A crash leaves dirtyRun == true and the prior marker (if any) stale.
        guard let marker = doc.lastShutdown else { return !doc.dirtyRun }
        return marker.cleanlyEnded && !doc.dirtyRun
    }

    /// The persisted shutdown marker from the prior run, if any.
    public func lastShutdownMarker() -> ShutdownMarker? { doc.lastShutdown }

    /// Snapshot of the sessions persisted from the prior run (before any are
    /// touched this run). Used at launch to seed the resume lookup.
    public func persistedSessions() -> [PersistedSession] { doc.sessions }

    /// Number of currently-tracked persisted sessions.
    public var count: Int { doc.sessions.count }

    // MARK: - Mutation (called from the live transport)

    /// Record (or refresh) a session as active. Marks the run dirty on the
    /// first write so an unclean stop is detectable next launch. Idempotent by
    /// `sessionID`.
    public func upsert(_ session: PersistedSession) {
        if !doc.dirtyRun {
            doc.dirtyRun = true
            // A fresh run supersedes the prior shutdown marker for liveness
            // purposes; keep it readable until a new clean shutdown overwrites
            // it, but liveness is now governed by dirtyRun.
        }
        if let idx = doc.sessions.firstIndex(where: { $0.sessionID == session.sessionID }) {
            doc.sessions[idx] = session
        } else {
            doc.sessions.append(session)
        }
        persist()
    }

    /// Update only the last-accessed timestamp for a live session. No-op if the
    /// id isn't tracked (e.g. a resumed-but-not-yet-reinitialized id).
    public func touch(sessionID: String, at date: Date = Date()) {
        guard let idx = doc.sessions.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        doc.sessions[idx].lastAccessedAt = date
        persist()
    }

    /// Remove a session from the active snapshot (explicit DELETE, expiry,
    /// eviction, teardown).
    public func remove(sessionID: String) {
        let before = doc.sessions.count
        doc.sessions.removeAll { $0.sessionID == sessionID }
        if doc.sessions.count != before { persist() }
    }

    /// Resume lookup: does this reconnecting id match a session persisted from
    /// a prior run? Pure decision over the current snapshot.
    public func resumeLookup(sessionID: String) -> SessionResumeLookup {
        guard let match = doc.sessions.first(where: { $0.sessionID == sessionID }) else {
            return .unknown
        }
        let clean: Bool = {
            guard let marker = doc.lastShutdown else { return false }
            return marker.cleanlyEnded
        }()
        return .resumable(match, cleanShutdown: clean)
    }

    // MARK: - Clean shutdown

    /// Write the clean-shutdown marker + flush. Called from the graceful
    /// shutdown path (`SSEServer.stop()` ← `applicationWillTerminate`). After
    /// this, `priorRunEndedCleanly()` reports `true` on the next launch.
    ///
    /// The active-session rows are RETAINED (not cleared) so a client that
    /// reconnects after a clean restart still resolves to `.resumable` and gets
    /// the re-initialize signal — the marker just records that the stop was
    /// planned. They are pruned lazily as sessions are removed, or overwritten
    /// when re-created.
    public func recordCleanShutdown(reason: String) {
        doc.lastShutdown = ShutdownMarker(
            reason: reason,
            cleanlyEnded: true,
            activeSessionsAtShutdown: doc.sessions.count
        )
        doc.dirtyRun = false
        persist()
    }

    /// Test/diagnostic seam: clear all persisted sessions (e.g. a config reset
    /// that invalidates every session).
    public func clearAllSessions() {
        guard !doc.sessions.isEmpty else { return }
        doc.sessions.removeAll()
        persist()
    }

    // MARK: - Synchronous clean-shutdown fallback

    /// SYNCHRONOUS, best-effort clean-shutdown marker write for the
    /// `applicationWillTerminate` path, which is synchronous and cannot reliably
    /// `await` the actor before the process exits (the same constraint the
    /// signal-flush handler works under). This reads the current snapshot off
    /// disk, stamps the clean marker + clears `dirtyRun`, and atomic-writes it
    /// back — preserving the active-session rows so a returning client still
    /// resumes after the restart. Safe to call even if the async `stop()` path
    /// also ran (idempotent: writing a clean marker twice is harmless).
    ///
    /// `nonisolated` so it does not cross the actor boundary; it touches ONLY
    /// the file (never `self.doc`), so it cannot race the actor's in-memory
    /// state in a way that corrupts the file (atomic rename guarantees a whole
    /// document is written).
    public nonisolated static func recordCleanShutdownSync(
        reason: String,
        url: URL = SessionPersistenceStore.defaultStoreURL()
    ) {
        var document = loadOrRecover(url: url)
        document.lastShutdown = ShutdownMarker(
            reason: reason,
            cleanlyEnded: true,
            activeSessionsAtShutdown: document.sessions.count
        )
        document.dirtyRun = false
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
