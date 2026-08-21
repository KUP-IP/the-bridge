// WorktreeOwnership.swift — C0 runtime ownership ledger and shared mutation guard.
// Claims are durable metadata only. Claim/release/expiry paths never mutate Git or files.

import Foundation
import SQLite3
import MCP
import CryptoKit
import Darwin

private let worktreeSQLiteTransient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

public struct WorktreeClaimTuple: Codable, Sendable, Equatable {
    public let stableID: String
    public let repoRoot: String
    public let worktreePath: String
    public let branch: String
    public let baseSHA: String
    public let ownerSession: String
    public let expiresAt: Date
}

public enum WorktreeReleaseDisposition: String, Codable, Sendable, CaseIterable {
    case cleanReleasable = "clean_releasable"
    case preserveForReview = "preserve_for_review"
    case preserveWithUniqueCommits = "preserve_with_unique_commits"
    case abandonedWithRecoveryNote = "abandoned_with_recovery_note"
}

public struct WorktreeReleaseEvidence: Codable, Sendable, Equatable {
    public let headSHA: String?
    public let isClean: Bool?
    public let uniqueCommitCount: Int?
    public let finalWorktreePath: String?
    public let finalBranch: String?
}

public struct WorktreeClaimRecord: Codable, Sendable, Equatable {
    public let tuple: WorktreeClaimTuple
    public let releasedAt: Date?
    public let disposition: WorktreeReleaseDisposition?
    public let recoveryNote: String?
    public let releaseEvidence: WorktreeReleaseEvidence?

    public func isExpired(at date: Date = Date()) -> Bool {
        releasedAt == nil && tuple.expiresAt <= date
    }
}

public enum WorktreeOwnershipTargetState: String, Codable, Sendable, Equatable {
    case resolved
    case unresolved
}

public enum WorktreeOwnershipOwnerState: String, Codable, Sendable, Equatable {
    case claimedByAnotherSession = "claimed_by_another_session"
    case noActiveClaim = "no_active_claim"
    case claimExpired = "claim_expired"
    case ownerSessionMissing = "owner_session_missing"
    case authorizationInProgress = "authorization_in_progress"
    case identityChanged = "identity_changed"
    case storageUnavailable = "storage_unavailable"
    case notEvaluated = "not_evaluated"
}

/// The operator-facing C0 denial contract. It identifies what was blocked,
/// states ownership without exposing another session identifier, and gives the
/// caller one concrete next action.
public struct WorktreeOwnershipDenialContext: Codable, Sendable, Equatable {
    public let target: String
    public let targetState: WorktreeOwnershipTargetState
    public let ownerState: WorktreeOwnershipOwnerState
    public let remedy: String

    public init(
        target: String,
        targetState: WorktreeOwnershipTargetState,
        ownerState: WorktreeOwnershipOwnerState,
        remedy: String
    ) {
        self.target = target
        self.targetState = targetState
        self.ownerState = ownerState
        self.remedy = remedy
    }
}

/// Preserve the existing error cases and code surface while allowing every C0
/// denial to carry the same target / owner-state / remedy context through
/// direct throws and structured tool results.
public enum WorktreeOwnershipError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)
    case conflict(String)
    case busy(String)
    case ownershipRequired(String)
    case foreignOwnership(String)
    case identityChanged(String)
    case staleRecoveryRequired(String)
    case targetUnresolved(String)
    case backgroundUnsupported(String)
    case storage(String)
    case contextual(code: String, detail: String, context: WorktreeOwnershipDenialContext)

    public var code: String {
        switch self {
        case .identityChanged: return "worktree_identity_changed"
        case .ownershipRequired: return "worktree_ownership_required"
        case .foreignOwnership: return "worktree_foreign_ownership"
        case .staleRecoveryRequired: return "worktree_stale_recovery_required"
        case .targetUnresolved: return "worktree_target_unresolved"
        case .backgroundUnsupported: return "worktree_background_unsupported"
        case .busy: return "worktree_busy"
        case .conflict: return "worktree_claim_conflict"
        case .invalid: return "invalid_arguments"
        case .storage: return "worktree_ownership_storage_failed"
        case .contextual(let code, _, _): return code
        }
    }

    fileprivate var detail: String {
        switch self {
        case .invalid(let value), .conflict(let value), .busy(let value),
             .ownershipRequired(let value), .foreignOwnership(let value),
             .identityChanged(let value), .staleRecoveryRequired(let value),
             .targetUnresolved(let value), .backgroundUnsupported(let value),
             .storage(let value), .contextual(_, let value, _):
            return value
        }
    }

    public var denialContext: WorktreeOwnershipDenialContext? {
        guard case .contextual(_, _, let context) = self else { return nil }
        return context
    }

    public func withDenialContext(_ context: WorktreeOwnershipDenialContext) -> WorktreeOwnershipError {
        .contextual(code: code, detail: detail, context: context)
    }

    public var errorDescription: String? {
        guard let denialContext else { return "\(code): \(detail)" }
        return "\(code): target=\(denialContext.target) (target_state=\(denialContext.targetState.rawValue)); owner_state=\(denialContext.ownerState.rawValue); remedy=\(denialContext.remedy)"
    }
}

public final class WorktreeExecutionAuthorization: @unchecked Sendable {
    private enum Kind { case root, nested }

    private let mutex = NSLock()
    private var released = false
    private let kind: Kind
    public let permit: WorktreeExecutionPermit

    fileprivate static func root(_ permit: WorktreeExecutionPermit) -> WorktreeExecutionAuthorization {
        WorktreeExecutionAuthorization(permit: permit, kind: .root)
    }

    fileprivate static func nested(_ permit: WorktreeExecutionPermit) -> WorktreeExecutionAuthorization {
        WorktreeExecutionAuthorization(permit: permit, kind: .nested)
    }

    private init(permit: WorktreeExecutionPermit, kind: Kind) {
        self.permit = permit
        self.kind = kind
    }

    public func release() {
        mutex.lock()
        guard !released else {
            mutex.unlock()
            return
        }
        released = true
        mutex.unlock()
        switch kind {
        case .root:
            permit.release()
        case .nested:
            permit.releaseNestedAuthorization()
        }
    }

    deinit { release() }
}

public final class WorktreeExecutionPermit: @unchecked Sendable {
    private struct ReleasedResources {
        let descriptors: [Int32]
        let directoryDescriptor: Int32
        let releaseLocalReservation: (() -> Void)?
    }

    private let mutex = NSLock()
    private var descriptors: [Int32]
    private var directoryDescriptor: Int32
    private var releaseLocalReservation: (() -> Void)?
    private var rootReleased = false
    private var nestedAuthorizationCount = 0
    public let stableIDs: Set<String>
    public let ownerSession: String

    fileprivate init(
        stableIDs: [String],
        ownerSession: String,
        descriptors: [Int32],
        directoryDescriptor: Int32,
        releaseLocalReservation: @escaping () -> Void
    ) {
        self.stableIDs = Set(stableIDs)
        self.ownerSession = ownerSession
        self.descriptors = descriptors
        self.directoryDescriptor = directoryDescriptor
        self.releaseLocalReservation = releaseLocalReservation
    }

    fileprivate func acquireNestedAuthorization(
        _ identities: Set<String>,
        ownerSession: String
    ) throws -> WorktreeExecutionAuthorization {
        mutex.lock()
        guard !rootReleased,
              !descriptors.isEmpty,
              self.ownerSession == ownerSession,
              identities.isSubset(of: stableIDs) else {
            mutex.unlock()
            throw WorktreeOwnershipError.busy(
                "nested dispatch cannot extend or reuse a closed worktree permit"
            )
        }
        nestedAuthorizationCount += 1
        mutex.unlock()
        return .nested(self)
    }

    private func takeReleasedResourcesIfReadyLocked() -> ReleasedResources? {
        guard rootReleased,
              nestedAuthorizationCount == 0,
              !descriptors.isEmpty || directoryDescriptor >= 0 || releaseLocalReservation != nil else {
            return nil
        }
        let resources = ReleasedResources(
            descriptors: descriptors,
            directoryDescriptor: directoryDescriptor,
            releaseLocalReservation: releaseLocalReservation
        )
        descriptors.removeAll()
        directoryDescriptor = -1
        releaseLocalReservation = nil
        return resources
    }

    private static func releaseResources(_ resources: ReleasedResources?) {
        guard let resources else { return }
        for descriptor in resources.descriptors.reversed() {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = Darwin.close(descriptor)
        }
        if resources.directoryDescriptor >= 0 {
            _ = Darwin.close(resources.directoryDescriptor)
        }
        resources.releaseLocalReservation?()
    }

    public func release() {
        mutex.lock()
        guard !rootReleased else {
            mutex.unlock()
            return
        }
        rootReleased = true
        let resources = takeReleasedResourcesIfReadyLocked()
        mutex.unlock()
        Self.releaseResources(resources)
    }

    fileprivate func releaseNestedAuthorization() {
        mutex.lock()
        guard nestedAuthorizationCount > 0 else {
            mutex.unlock()
            return
        }
        nestedAuthorizationCount -= 1
        let resources = takeReleasedResourcesIfReadyLocked()
        mutex.unlock()
        Self.releaseResources(resources)
    }

    deinit { release() }
}

private enum WorktreeLockCoordinator {
    private static let localMutex = NSLock()
    nonisolated(unsafe) private static var locallyHeld: Set<String> = []

    private static func reserveLocally(_ stableIDs: [String]) throws {
        localMutex.lock()
        defer { localMutex.unlock() }
        if stableIDs.contains(where: locallyHeld.contains) {
            throw WorktreeOwnershipError.busy(
                "another dispatch in this Bridge process currently holds a requested worktree"
            )
        }
        locallyHeld.formUnion(stableIDs)
    }

    private static func releaseLocally(_ stableIDs: [String]) {
        localMutex.lock()
        locallyHeld.subtract(stableIDs)
        localMutex.unlock()
    }

    private static func secureDirectory(_ directory: URL) throws -> Int32 {
        let path = directory.path
        if Darwin.mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
            throw WorktreeOwnershipError.storage("unable to create lock directory: \(path)")
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw WorktreeOwnershipError.storage(
                "unable to open lock directory without symlink traversal: \(path)"
            )
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else {
            _ = Darwin.close(descriptor)
            throw WorktreeOwnershipError.storage(
                "lock directory is not a private directory owned by this user: \(path)"
            )
        }
        guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
            _ = Darwin.close(descriptor)
            throw WorktreeOwnershipError.storage("unable to secure lock directory: \(path)")
        }
        return descriptor
    }

    private static func lockFileName(stableID: String) -> String {
        let digest = SHA256.hash(data: Data(stableID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".lock"
    }

    static func lockFileURL(stableID: String, directory: URL) -> URL {
        directory.appendingPathComponent(lockFileName(stableID: stableID))
    }

    private static func openLockFile(directoryDescriptor: Int32, fileName: String) throws -> Int32 {
        for _ in 0..<4 {
            let existing = Darwin.openat(
                directoryDescriptor,
                fileName,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
            if existing >= 0 { return existing }
            let existingErrno = errno
            guard existingErrno == ENOENT else {
                let detail = String(cString: strerror(existingErrno))
                throw WorktreeOwnershipError.storage(
                    "unable to open existing worktree lock: \(fileName) (errno=\(existingErrno), \(detail))"
                )
            }

            let created = Darwin.openat(
                directoryDescriptor,
                fileName,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            if created >= 0 { return created }
            let createErrno = errno
            if createErrno == EEXIST { continue }
            let detail = String(cString: strerror(createErrno))
            throw WorktreeOwnershipError.storage(
                "unable to create worktree lock: \(fileName) (errno=\(createErrno), \(detail))"
            )
        }
        throw WorktreeOwnershipError.storage(
            "worktree lock creation did not converge after concurrent first-open: \(fileName)"
        )
    }

    static func acquire(
        stableIDs: [String],
        ownerSession: String,
        directory: URL
    ) throws -> WorktreeExecutionPermit {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryDescriptor = try secureDirectory(directory)
        let sorted = Array(Set(stableIDs)).sorted()
        do {
            try reserveLocally(sorted)
        } catch {
            _ = Darwin.close(directoryDescriptor)
            throw error
        }
        var descriptors: [Int32] = []
        do {
            for stableID in sorted {
                let fileName = lockFileName(stableID: stableID)
                let descriptor = try openLockFile(
                    directoryDescriptor: directoryDescriptor,
                    fileName: fileName
                )
                var metadata = stat()
                guard Darwin.fstat(descriptor, &metadata) == 0,
                      metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_uid == Darwin.geteuid(),
                      metadata.st_nlink == 1,
                      Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                    _ = Darwin.close(descriptor)
                    throw WorktreeOwnershipError.storage("unable to secure worktree lock: \(fileName)")
                }
                guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
                    let lockErrno = errno
                    _ = Darwin.close(descriptor)
                    if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                        throw WorktreeOwnershipError.busy(
                            "another Bridge dispatch currently holds worktree \(stableID)"
                        )
                    }
                    throw WorktreeOwnershipError.storage("unable to acquire worktree lock: \(fileName)")
                }
                descriptors.append(descriptor)
            }
            return WorktreeExecutionPermit(
                stableIDs: sorted,
                ownerSession: ownerSession,
                descriptors: descriptors,
                directoryDescriptor: directoryDescriptor,
                releaseLocalReservation: { releaseLocally(sorted) }
            )
        } catch {
            for descriptor in descriptors.reversed() {
                _ = Darwin.lockf(descriptor, F_ULOCK, 0)
                _ = Darwin.close(descriptor)
            }
            _ = Darwin.close(directoryDescriptor)
            releaseLocally(sorted)
            throw error
        }
    }
}

public actor WorktreeOwnershipStore {
    public static let shared = WorktreeOwnershipStore()

    private let databaseURLOverride: URL?
    private let beforeClaimReprobeForTesting: (@Sendable () throws -> Void)?
    private var opened = false
    private var db: OpaquePointer?

    public init(
        databaseURL: URL? = nil,
        beforeClaimReprobeForTesting: (@Sendable () throws -> Void)? = nil
    ) {
        self.databaseURLOverride = databaseURL
        self.beforeClaimReprobeForTesting = beforeClaimReprobeForTesting
    }

    private func databaseURL() throws -> URL {
        if let databaseURLOverride {
            try FileManager.default.createDirectory(
                at: databaseURLOverride.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return databaseURLOverride
        }
        return try BridgePaths.ensureApplicationSupport(.worktreeOwnership)
            .appendingPathComponent("claims.sqlite")
    }

    private func lockDirectoryURL() throws -> URL {
        try databaseURL().deletingLastPathComponent().appendingPathComponent("locks", isDirectory: true)
    }

    public func lockDirectoryPath() throws -> String { try lockDirectoryURL().path }

    public func lockFileURL(worktreePath: String) throws -> URL {
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: worktreePath)
        return WorktreeLockCoordinator.lockFileURL(
            stableID: identity.stableID,
            directory: try lockDirectoryURL()
        )
    }

    private func open() throws {
        guard !opened else { return }
        let path = try databaseURL().path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw WorktreeOwnershipError.storage("unable to open \(path)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=FULL;")
        // C0 was never installed. Keep any earlier development table untouched and
        // use an identity-keyed v2 table so path/branch semantics cannot leak forward.
        try exec("""
        CREATE TABLE IF NOT EXISTS worktree_claims_v2 (
          stable_id TEXT PRIMARY KEY,
          worktree_path TEXT NOT NULL,
          repo_root TEXT NOT NULL,
          branch TEXT NOT NULL,
          base_sha TEXT NOT NULL,
          owner_session TEXT NOT NULL,
          expires_at REAL NOT NULL,
          released_at REAL,
          disposition TEXT,
          recovery_note TEXT,
          release_head_sha TEXT,
          release_is_clean INTEGER,
          release_unique_commit_count INTEGER,
          release_worktree_path TEXT,
          release_branch TEXT
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_worktree_claim_v2_owner ON worktree_claims_v2(owner_session, released_at);")
        try exec("CREATE INDEX IF NOT EXISTS idx_worktree_claim_v2_path ON worktree_claims_v2(worktree_path);")
        try exec("""
        CREATE TABLE IF NOT EXISTS worktree_release_history_v2 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          stable_id TEXT NOT NULL,
          worktree_path TEXT NOT NULL,
          repo_root TEXT NOT NULL,
          branch TEXT NOT NULL,
          base_sha TEXT NOT NULL,
          owner_session TEXT NOT NULL,
          expires_at REAL NOT NULL,
          released_at REAL NOT NULL,
          disposition TEXT NOT NULL,
          recovery_note TEXT,
          release_head_sha TEXT,
          release_is_clean INTEGER,
          release_unique_commit_count INTEGER,
          release_worktree_path TEXT,
          release_branch TEXT
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_worktree_release_history_v2_identity ON worktree_release_history_v2(stable_id, released_at);")
        try exec("CREATE INDEX IF NOT EXISTS idx_worktree_release_history_v2_path ON worktree_release_history_v2(worktree_path, released_at);")
        opened = true
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw WorktreeOwnershipError.storage("database unavailable") }
        let deadline = Date().addingTimeInterval(5)
        while true {
            var error: UnsafeMutablePointer<Int8>?
            let result = sqlite3_exec(db, sql, nil, nil, &error)
            if result == SQLITE_OK { return }
            let text = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            if (result == SQLITE_BUSY || result == SQLITE_LOCKED), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.025)
                continue
            }
            throw WorktreeOwnershipError.storage(text)
        }
    }

    private func begin() throws { try exec("BEGIN IMMEDIATE;") }
    private func rollback() { try? exec("ROLLBACK;") }

    public func claim(
        repoRoot: String,
        worktreePath: String,
        branch: String,
        baseSHA: String,
        ownerSession: String,
        ttlSeconds: Int,
        now: Date = Date()
    ) throws -> WorktreeClaimTuple {
        guard !ownerSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !branch.isEmpty,
              !baseSHA.isEmpty,
              (60...86_400).contains(ttlSeconds) else {
            throw WorktreeOwnershipError.invalid(
                "ownerSession, branch, baseSHA, and ttlSeconds (60...86400) are required"
            )
        }

        let requestedRepo = try WorktreeOwnershipGuard.canonicalPath(repoRoot)
        let requestedWorktree = try WorktreeOwnershipGuard.canonicalPath(worktreePath)
        let live = try WorktreeOwnershipGuard.liveIdentity(for: requestedWorktree)
        guard live.repoRoot == requestedRepo,
              live.worktreePath == requestedWorktree,
              live.branch == branch else {
            throw WorktreeOwnershipError.identityChanged(
                "claim provenance does not match the live repo/worktree/branch"
            )
        }

        let permit = try WorktreeLockCoordinator.acquire(
            stableIDs: [live.stableID],
            ownerSession: ownerSession,
            directory: try lockDirectoryURL()
        )
        defer { permit.release() }

        try beforeClaimReprobeForTesting?()
        let reprobed = try WorktreeOwnershipGuard.liveIdentity(for: requestedWorktree)
        guard reprobed.stableID == live.stableID,
              reprobed.repoRoot == requestedRepo,
              reprobed.worktreePath == requestedWorktree,
              reprobed.branch == branch else {
            throw WorktreeOwnershipError.identityChanged(
                "worktree repo, path, branch, or stable identity changed during claim"
            )
        }

        let normalizedExpiry = Date(
            timeIntervalSince1970: floor(now.timeIntervalSince1970) + TimeInterval(ttlSeconds)
        )
        let tuple = WorktreeClaimTuple(
            stableID: reprobed.stableID,
            repoRoot: reprobed.repoRoot,
            worktreePath: reprobed.worktreePath,
            branch: reprobed.branch,
            baseSHA: baseSHA,
            ownerSession: ownerSession,
            expiresAt: normalizedExpiry
        )

        try open()
        try begin()
        defer { rollback() }

        if let existing = try row(stableID: live.stableID), existing.releasedAt == nil {
            if existing.tuple.expiresAt <= now {
                throw WorktreeOwnershipError.staleRecoveryRequired(
                    "expired claim remains durable until its owner explicitly releases it with abandoned_with_recovery_note"
                )
            }
            guard existing.tuple.ownerSession == ownerSession else {
                throw WorktreeOwnershipError.conflict(
                    "stable worktree identity is already owned by another active ownerSession"
                )
            }
            guard existing.tuple.repoRoot == tuple.repoRoot,
                  existing.tuple.branch == tuple.branch,
                  existing.tuple.baseSHA == tuple.baseSHA else {
                throw WorktreeOwnershipError.identityChanged(
                    "same-owner claim retry changed the recorded claim-time provenance"
                )
            }
            try exec("COMMIT;")
            return existing.tuple
        }

        guard reprobed.headSHA == baseSHA else {
            throw WorktreeOwnershipError.identityChanged(
                "first claim requires baseSHA to equal the locked live worktree HEAD"
            )
        }

        try bind(
            """
            INSERT INTO worktree_claims_v2(
              stable_id, worktree_path, repo_root, branch, base_sha, owner_session, expires_at,
              released_at, disposition, recovery_note, release_head_sha,
              release_is_clean, release_unique_commit_count, release_worktree_path, release_branch
            ) VALUES(?,?,?,?,?,?,?,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)
            ON CONFLICT(stable_id) DO UPDATE SET
              worktree_path=excluded.worktree_path,
              repo_root=excluded.repo_root,
              branch=excluded.branch,
              base_sha=excluded.base_sha,
              owner_session=excluded.owner_session,
              expires_at=excluded.expires_at,
              released_at=NULL,
              disposition=NULL,
              recovery_note=NULL,
              release_head_sha=NULL,
              release_is_clean=NULL,
              release_unique_commit_count=NULL,
              release_worktree_path=NULL,
              release_branch=NULL;
            """,
            values: [
                tuple.stableID, tuple.worktreePath, tuple.repoRoot, tuple.branch,
                tuple.baseSHA, tuple.ownerSession, String(tuple.expiresAt.timeIntervalSince1970)
            ]
        )
        try exec("COMMIT;")
        return tuple
    }

    @discardableResult
    public func release(
        worktreePath: String,
        ownerSession: String,
        disposition: WorktreeReleaseDisposition,
        recoveryNote: String?,
        now: Date = Date()
    ) throws -> WorktreeReleaseEvidence {
        let path = try WorktreeOwnershipGuard.canonicalPath(worktreePath)
        let note = recoveryNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        try open()

        let live = try? WorktreeOwnershipGuard.liveIdentity(for: path)
        let preliminary = try live.flatMap { try row(stableID: $0.stableID) } ?? row(path: path)
        guard let preliminary else {
            throw WorktreeOwnershipError.ownershipRequired("no claim exists for \(path)")
        }
        let permit = try WorktreeLockCoordinator.acquire(
            stableIDs: [preliminary.tuple.stableID],
            ownerSession: ownerSession,
            directory: try lockDirectoryURL()
        )
        defer { permit.release() }

        try begin()
        defer { rollback() }
        guard let existing = try row(stableID: preliminary.tuple.stableID) else {
            throw WorktreeOwnershipError.ownershipRequired("claim disappeared before release")
        }
        guard existing.tuple.ownerSession == ownerSession else {
            throw WorktreeOwnershipError.foreignOwnership("claim belongs to a different ownerSession")
        }
        if existing.releasedAt != nil {
            guard existing.disposition == disposition,
                  existing.recoveryNote == note,
                  let evidence = existing.releaseEvidence else {
                throw WorktreeOwnershipError.invalid(
                    "release retry does not match the recorded disposition or recovery note"
                )
            }
            try exec("COMMIT;")
            return evidence
        }

        let isExpired = existing.tuple.expiresAt <= now
        if isExpired && disposition != .abandonedWithRecoveryNote {
            throw WorktreeOwnershipError.staleRecoveryRequired(
                "an expired claim may only be closed explicitly as abandoned_with_recovery_note"
            )
        }
        if disposition == .abandonedWithRecoveryNote, note?.isEmpty != false {
            throw WorktreeOwnershipError.invalid(
                "abandoned_with_recovery_note requires a substantive recoveryNote"
            )
        }

        let evidence: WorktreeReleaseEvidence
        do {
            let current = try WorktreeOwnershipGuard.liveIdentity(for: path)
            guard current.stableID == existing.tuple.stableID else {
                throw WorktreeOwnershipError.identityChanged(
                    "the supplied path now refers to a different Git worktree identity"
                )
            }
            evidence = try WorktreeOwnershipGuard.releaseEvidence(
                baseSHA: existing.tuple.baseSHA,
                worktreePath: current.worktreePath,
                finalBranch: current.branch
            )
        } catch {
            guard disposition == .abandonedWithRecoveryNote else { throw error }
            evidence = WorktreeReleaseEvidence(
                headSHA: nil,
                isClean: nil,
                uniqueCommitCount: nil,
                finalWorktreePath: nil,
                finalBranch: nil
            )
        }

        switch disposition {
        case .cleanReleasable:
            guard evidence.isClean == true, evidence.uniqueCommitCount == 0 else {
                throw WorktreeOwnershipError.invalid(
                    "clean_releasable requires a clean worktree with zero commits unique to the recorded base"
                )
            }
        case .preserveWithUniqueCommits:
            guard (evidence.uniqueCommitCount ?? 0) > 0 else {
                throw WorktreeOwnershipError.invalid(
                    "preserve_with_unique_commits requires at least one commit unique to the recorded base"
                )
            }
        case .preserveForReview, .abandonedWithRecoveryNote:
            break
        }

        let releasedAt = String(now.timeIntervalSince1970)
        let values: [String?] = [
            existing.tuple.stableID,
            existing.tuple.worktreePath,
            existing.tuple.repoRoot,
            existing.tuple.branch,
            existing.tuple.baseSHA,
            existing.tuple.ownerSession,
            String(existing.tuple.expiresAt.timeIntervalSince1970),
            releasedAt,
            disposition.rawValue,
            note,
            evidence.headSHA,
            evidence.isClean.map { $0 ? "1" : "0" },
            evidence.uniqueCommitCount.map(String.init),
            evidence.finalWorktreePath,
            evidence.finalBranch
        ]
        try bind(
            """
            INSERT INTO worktree_release_history_v2(
              stable_id, worktree_path, repo_root, branch, base_sha, owner_session, expires_at,
              released_at, disposition, recovery_note, release_head_sha,
              release_is_clean, release_unique_commit_count, release_worktree_path, release_branch
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """,
            values: values
        )
        try bind(
            """
            UPDATE worktree_claims_v2 SET
              released_at=?, disposition=?, recovery_note=?, release_head_sha=?,
              release_is_clean=?, release_unique_commit_count=?,
              release_worktree_path=?, release_branch=?
            WHERE stable_id=?;
            """,
            values: [
                releasedAt,
                disposition.rawValue,
                note,
                evidence.headSHA,
                evidence.isClean.map { $0 ? "1" : "0" },
                evidence.uniqueCommitCount.map(String.init),
                evidence.finalWorktreePath,
                evidence.finalBranch,
                existing.tuple.stableID
            ]
        )
        try exec("COMMIT;")
        return evidence
    }

    public func authorize(
        path: String,
        ownerSession: String?,
        now: Date = Date()
    ) throws {
        guard let ownerSession, !ownerSession.isEmpty else {
            throw WorktreeOwnershipError.ownershipRequired(
                "protected mutation requires ownerSession"
            )
        }
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: path)
        let permit = try executionPermit(
            identities: [identity],
            ownerSession: ownerSession,
            now: now
        )
        permit.release()
    }

    public func executionPermit(
        identities: [WorktreeOwnershipGuard.LiveIdentity],
        ownerSession: String,
        now: Date = Date()
    ) throws -> WorktreeExecutionPermit {
        guard !ownerSession.isEmpty else {
            throw WorktreeOwnershipError.ownershipRequired("protected mutation requires ownerSession")
        }
        let stableIDs = identities.map(\.stableID)
        let permit = try WorktreeLockCoordinator.acquire(
            stableIDs: stableIDs,
            ownerSession: ownerSession,
            directory: try lockDirectoryURL()
        )
        do {
            try open()
            for initial in identities {
                let current = try WorktreeOwnershipGuard.liveIdentity(for: initial.worktreePath)
                guard current.stableID == initial.stableID else {
                    throw WorktreeOwnershipError.identityChanged(
                        "worktree identity changed between analysis and permit acquisition"
                    )
                }
                try validateClaim(stableID: current.stableID, ownerSession: ownerSession, now: now)
            }
            return permit
        } catch {
            permit.release()
            throw error
        }
    }

    private func validateClaim(stableID: String, ownerSession: String, now: Date) throws {
        guard let existing = try row(stableID: stableID), existing.releasedAt == nil else {
            throw WorktreeOwnershipError.ownershipRequired(
                "no active claim exists for stable worktree identity \(stableID)"
            )
        }
        guard existing.tuple.ownerSession == ownerSession else {
            throw WorktreeOwnershipError.foreignOwnership(
                "stable worktree identity is owned by another session"
            )
        }
        guard existing.tuple.expiresAt > now else {
            throw WorktreeOwnershipError.staleRecoveryRequired(
                "claim expired and must be explicitly recovered; no new mutation was admitted"
            )
        }
    }

    public func record(worktreePath: String) throws -> WorktreeClaimRecord? {
        let path = try WorktreeOwnershipGuard.canonicalPath(worktreePath)
        try open()
        if let identity = try? WorktreeOwnershipGuard.liveIdentity(for: path),
           let record = try row(stableID: identity.stableID) {
            return record
        }
        return try row(path: path)
    }

    public func releaseHistory(worktreePath: String) throws -> [WorktreeClaimRecord] {
        let path = try WorktreeOwnershipGuard.canonicalPath(worktreePath)
        try open()
        let stableID = try? WorktreeOwnershipGuard.liveIdentity(for: path).stableID
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql: String
        if stableID != nil {
            sql = """
            SELECT stable_id, worktree_path, repo_root, branch, base_sha, owner_session, expires_at,
                   released_at, disposition, recovery_note, release_head_sha,
                   release_is_clean, release_unique_commit_count, release_worktree_path, release_branch
            FROM worktree_release_history_v2
            WHERE stable_id=?
            ORDER BY released_at ASC, id ASC;
            """
        } else {
            sql = """
            SELECT stable_id, worktree_path, repo_root, branch, base_sha, owner_session, expires_at,
                   released_at, disposition, recovery_note, release_head_sha,
                   release_is_clean, release_unique_commit_count, release_worktree_path, release_branch
            FROM worktree_release_history_v2
            WHERE worktree_path=? OR release_worktree_path=?
            ORDER BY released_at ASC, id ASC;
            """
        }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorktreeOwnershipError.storage("prepare release history")
        }
        if let stableID {
            sqlite3_bind_text(statement, 1, stableID, -1, worktreeSQLiteTransient)
        } else {
            sqlite3_bind_text(statement, 1, path, -1, worktreeSQLiteTransient)
            sqlite3_bind_text(statement, 2, path, -1, worktreeSQLiteTransient)
        }
        var result: [WorktreeClaimRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(decodeRow(statement))
        }
        return result
    }

    private func row(stableID: String) throws -> WorktreeClaimRecord? {
        try row(sql: """
        SELECT stable_id, worktree_path, repo_root, branch, base_sha, owner_session, expires_at,
               released_at, disposition, recovery_note, release_head_sha,
               release_is_clean, release_unique_commit_count, release_worktree_path, release_branch
        FROM worktree_claims_v2 WHERE stable_id=?;
        """, values: [stableID])
    }

    private func row(path: String) throws -> WorktreeClaimRecord? {
        try row(sql: """
        SELECT stable_id, worktree_path, repo_root, branch, base_sha, owner_session, expires_at,
               released_at, disposition, recovery_note, release_head_sha,
               release_is_clean, release_unique_commit_count, release_worktree_path, release_branch
        FROM worktree_claims_v2
        WHERE worktree_path=? OR release_worktree_path=?
        ORDER BY released_at IS NULL DESC LIMIT 1;
        """, values: [path, path])
    }

    private func row(sql: String, values: [String]) throws -> WorktreeClaimRecord? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorktreeOwnershipError.storage("prepare claim row")
        }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, worktreeSQLiteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeRow(statement)
    }

    private func decodeRow(_ statement: OpaquePointer?) -> WorktreeClaimRecord {
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }
        let expiry = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        let releasedAt = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let disposition = text(8).flatMap(WorktreeReleaseDisposition.init(rawValue:))
        let isClean: Bool? = sqlite3_column_type(statement, 11) == SQLITE_NULL
            ? nil
            : sqlite3_column_int(statement, 11) != 0
        let uniqueCount: Int? = sqlite3_column_type(statement, 12) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 12))
        let evidence: WorktreeReleaseEvidence? = releasedAt == nil
            ? nil
            : WorktreeReleaseEvidence(
                headSHA: text(10),
                isClean: isClean,
                uniqueCommitCount: uniqueCount,
                finalWorktreePath: text(13),
                finalBranch: text(14)
            )
        return WorktreeClaimRecord(
            tuple: WorktreeClaimTuple(
                stableID: text(0) ?? "",
                repoRoot: text(2) ?? "",
                worktreePath: text(1) ?? "",
                branch: text(3) ?? "",
                baseSHA: text(4) ?? "",
                ownerSession: text(5) ?? "",
                expiresAt: expiry
            ),
            releasedAt: releasedAt,
            disposition: disposition,
            recoveryNote: text(9),
            releaseEvidence: evidence
        )
    }

    private func bind(_ sql: String, values: [String?]) throws {
        guard let db else { throw WorktreeOwnershipError.storage("database unavailable") }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorktreeOwnershipError.storage("prepare write")
        }
        for (index, value) in values.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, worktreeSQLiteTransient)
            } else {
                sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(db))
            throw WorktreeOwnershipError.storage(message)
        }
    }
}

public enum WorktreeOwnershipGuard {
    private static let directMutationTools: Set<String> = [
        "git_apply_patch", "git_create_branch", "node_test",
        "file_edit", "file_write", "file_append", "file_move", "file_rename",
        "file_copy", "dir_create", "file_zip", "file_unzip", "run_script"
    ]

    public struct LiveIdentity: Sendable, Equatable {
        public let stableID: String
        public let repoRoot: String
        public let worktreePath: String
        public let commonGitDirectory: String
        public let worktreeGitDirectory: String
        public let branch: String
        public let headSHA: String
    }

    @TaskLocal public static var currentPermit: WorktreeExecutionPermit?

    /// One shared enforcement seam called by ToolRouter after security approval
    /// but immediately before a handler can perform a consequential mutation.
    @discardableResult
    public static func authorizeToolMutation(
        toolName: String,
        arguments: Value,
        store: WorktreeOwnershipStore = .shared
    ) async throws -> WorktreeExecutionAuthorization? {
        do {
            return try await authorizeToolMutationImpl(
                toolName: toolName,
                arguments: arguments,
                store: store
            )
        } catch let error as WorktreeOwnershipError {
            guard error.denialContext == nil else { throw error }
            throw error.withDenialContext(
                denialContext(for: error, toolName: toolName, arguments: arguments)
            )
        }
    }

    private static func authorizeToolMutationImpl(
        toolName: String,
        arguments: Value,
        store: WorktreeOwnershipStore
    ) async throws -> WorktreeExecutionAuthorization? {
        guard directMutationTools.contains(toolName)
                || toolName == "shell_exec"
                || toolName == "bg_run"
                || toolName == "worktree_command_run" else { return nil }
        guard case .object(let args) = arguments else { return nil }

        if toolName == "git_apply_patch",
           bool(args["check"]),
           !bool(args["index"]),
           !bool(args["commit"]) {
            return nil
        }
        if toolName == "file_edit", bool(args["preview"]) { return nil }
        if toolName == "run_script" {
            throw WorktreeOwnershipError.targetUnresolved(
                "run_script has opaque mutation semantics and cannot prove its complete worktree target set; use shell_exec with an explicit command and workingDir"
            )
        }

        // C0 promises that read-only Git stays available without a lease.
        // This narrow parser accepts only statically recognizable Git reads;
        // a mixed command, redirect, dynamic configuration, or unknown Git
        // verb falls through to the normal ownership/deny path below.
        if toolName == "shell_exec",
           let command = string(args["command"]),
           args["env"] == nil,
           isReadOnlyGitShellCommand(
                command,
                relativeTo: string(args["workingDir"])
                    ?? FileManager.default.currentDirectoryPath
           ) {
            return nil
        }

        let ownerSession = string(args["ownerSession"])
        let paths: [String]
        let repositoryRequired: Bool

        if toolName == "worktree_command_run" {
            guard let worktreePath = string(args["worktreePath"]) else {
                throw WorktreeOwnershipError.targetUnresolved(
                    "worktree_command_run requires an explicit worktreePath"
                )
            }
            paths = [worktreePath]
            repositoryRequired = true
        } else if toolName == "shell_exec" || toolName == "bg_run" {
            guard let command = string(args["command"]) else { return nil }
            let workingDirectory = string(args["workingDir"])
                ?? FileManager.default.currentDirectoryPath
            var analysis = analyzeCommand(command, relativeTo: workingDirectory)
            analysis.merge(analyzeToolEnvironment(
                args["env"],
                relativeTo: workingDirectory
            ))
            if !analysis.unresolved.isEmpty {
                throw WorktreeOwnershipError.targetUnresolved(
                    analysis.unresolved.joined(separator: "; ")
                )
            }
            paths = analysis.directories
            repositoryRequired = false
        } else {
            (paths, repositoryRequired) = mutationTargets(
                toolName: toolName,
                arguments: args
            )
        }

        var identities: [String: LiveIdentity] = [:]
        for rawPath in paths {
            let path = rawPath.hasPrefix("/")
                ? rawPath
                : resolveCommandPath(rawPath, relativeTo: FileManager.default.currentDirectoryPath)
            do {
                let identity = try liveIdentity(for: path)
                identities[identity.stableID] = identity
            } catch {
                if pathIsInGitRepository(path) { throw error }
            }
        }
        if repositoryRequired && identities.isEmpty {
            throw WorktreeOwnershipError.ownershipRequired(
                "protected mutation did not resolve to an authorized Git worktree"
            )
        }
        guard !identities.isEmpty else { return nil }
        if toolName == "bg_run" {
            throw WorktreeOwnershipError.backgroundUnsupported(
                "detached background execution is not supported for governed Git worktrees; use foreground shell_exec"
            )
        }
        guard let ownerSession, !ownerSession.isEmpty else {
            throw WorktreeOwnershipError.ownershipRequired(
                "protected mutation requires ownerSession"
            )
        }
        let requestedStableIDs = Set(identities.keys)
        if let currentPermit {
            return try currentPermit.acquireNestedAuthorization(
                requestedStableIDs,
                ownerSession: ownerSession
            )
        }
        let permit = try await store.executionPermit(
            identities: identities.values.sorted(by: { $0.stableID < $1.stableID }),
            ownerSession: ownerSession
        )
        return .root(permit)
    }

    private static func mutationTargets(
        toolName: String,
        arguments: [String: Value]
    ) -> ([String], Bool) {
        switch toolName {
        case "git_apply_patch", "git_create_branch":
            return ([string(arguments["cwd"])
                ?? FileManager.default.currentDirectoryPath], true)
        case "file_edit", "file_write", "file_append", "dir_create":
            return (compact([string(arguments["path"])]), false)
        case "file_rename":
            let source = string(arguments["path"])
            let destination = source.flatMap { path in
                string(arguments["newName"]).map { newName in
                    URL(fileURLWithPath: path)
                        .deletingLastPathComponent()
                        .appendingPathComponent(newName)
                        .path
                }
            }
            return (compact([source, destination]), false)
        case "file_move":
            return (compact([
                string(arguments["sourcePath"]),
                string(arguments["destinationPath"])
            ]), false)
        case "file_copy":
            return (compact([string(arguments["destinationPath"])]), false)
        case "file_zip":
            return (compact([string(arguments["archivePath"])]), false)
        case "file_unzip":
            return (compact([string(arguments["destinationPath"])]), false)
        case "node_test":
            return (compact([string(arguments["workingDir"])]), true)
        default:
            return ([], false)
        }
    }

    private static func denialContext(
        for error: WorktreeOwnershipError,
        toolName: String,
        arguments: Value
    ) -> WorktreeOwnershipDenialContext {
        let targets: [String]
        if error.code == "worktree_target_unresolved" {
            targets = []
        } else {
            targets = diagnosticTargets(toolName: toolName, arguments: arguments)
        }
        let targetState: WorktreeOwnershipTargetState = targets.isEmpty ? .unresolved : .resolved
        let target = targets.isEmpty ? "unresolved" : targets.joined(separator: ", ")
        let ownerState: WorktreeOwnershipOwnerState
        let remedy: String

        switch error.code {
        case "worktree_claim_conflict", "worktree_foreign_ownership":
            ownerState = .claimedByAnotherSession
            remedy = "Use a different claimed worktree, or ask the current owner to release this claim."
        case "worktree_ownership_required":
            if error.detail.localizedCaseInsensitiveContains("ownerSession") {
                ownerState = .ownerSessionMissing
                remedy = "Provide the ownerSession for the session that owns this worktree, then retry."
            } else {
                ownerState = .noActiveClaim
                remedy = "Claim this worktree with worktree_claim before mutating it."
            }
        case "worktree_stale_recovery_required":
            ownerState = .claimExpired
            remedy = "Release the expired claim with abandoned_with_recovery_note before retrying."
        case "worktree_target_unresolved":
            ownerState = .notEvaluated
            remedy = toolName == "run_script"
                ? "Use shell_exec with an explicit command and workingDir."
                : "Use a supported command with an explicit, statically resolvable worktree target."
        case "worktree_background_unsupported":
            ownerState = .notEvaluated
            remedy = "Use foreground shell_exec with an explicit command and workingDir."
        case "worktree_identity_changed":
            ownerState = .identityChanged
            remedy = "Re-read the live worktree path, branch, and base SHA, then submit a matching claim."
        case "worktree_busy":
            ownerState = .authorizationInProgress
            remedy = "Wait for the active worktree authorization to finish, then retry."
        case "worktree_ownership_storage_failed":
            ownerState = .storageUnavailable
            remedy = "Stop and preserve worktree state; restore ownership storage before retrying."
        default:
            ownerState = .notEvaluated
            remedy = "Correct the required arguments and retry."
        }

        return WorktreeOwnershipDenialContext(
            target: target,
            targetState: targetState,
            ownerState: ownerState,
            remedy: remedy
        )
    }

    private static func diagnosticTargets(toolName: String, arguments: Value) -> [String] {
        guard case .object(let object) = arguments else { return [] }
        let rawTargets: [String]
        switch toolName {
        case "worktree_claim", "worktree_release":
            rawTargets = compact([string(object["worktreePath"])])
        case "worktree_command_run":
            rawTargets = compact([string(object["worktreePath"])])
        case "shell_exec", "bg_run":
            let workingDirectory = string(object["workingDir"])
                ?? FileManager.default.currentDirectoryPath
            if let command = string(object["command"]) {
                let analysis = analyzeCommand(command, relativeTo: workingDirectory)
                rawTargets = analysis.directories.isEmpty ? [workingDirectory] : analysis.directories
            } else {
                rawTargets = [workingDirectory]
            }
        case "node_test":
            rawTargets = compact([string(object["workingDir"])])
        case "run_script":
            rawTargets = []
        default:
            rawTargets = mutationTargets(toolName: toolName, arguments: object).0
        }

        var targets: [String] = []
        for rawTarget in rawTargets {
            let absoluteTarget = rawTarget.hasPrefix("/")
                ? rawTarget
                : resolveCommandPath(rawTarget, relativeTo: FileManager.default.currentDirectoryPath)
            let target = (try? liveIdentity(for: absoluteTarget).worktreePath)
                ?? (try? canonicalPath(absoluteTarget))
                ?? absoluteTarget
            if !targets.contains(target) { targets.append(target) }
        }
        return targets.sorted()
    }

    private static func compact(_ values: [String?]) -> [String] {
        values.compactMap { $0 }
    }

    private static func string(_ value: Value?) -> String? {
        if case .string(let value) = value, !value.isEmpty { return value }
        return nil
    }

    private static func bool(_ value: Value?) -> Bool {
        if case .bool(let value) = value { return value }
        return false
    }

    private static let gitAlwaysReadOnlyVerbs: Set<String> = [
        "status", "diff", "log", "show", "blame", "rev-parse", "ls-files",
        "ls-tree", "cat-file", "grep", "describe", "name-rev", "shortlog",
        "for-each-ref", "show-ref", "check-ignore", "check-attr", "merge-base",
        "count-objects", "help", "version"
    ]

    private static let gitWorktreeMutationVerbs: Set<String> = [
        "add", "remove", "move", "prune", "lock", "unlock", "repair"
    ]

    /// An unknown Git subcommand can resolve through a configured alias or an
    /// external `git-<name>` executable. Both can write outside the claimed
    /// worktree, so only recognized built-ins reach the ownership path.
    private static let knownGitVerbs: Set<String> = [
        "add", "am", "annotate", "apply", "archive", "bisect", "blame",
        "branch", "bundle", "cat-file", "check-attr", "check-ignore",
        "check-mailmap", "check-ref-format", "checkout", "cherry", "cherry-pick",
        "clean", "clone", "commit", "config", "count-objects", "describe",
        "diff", "difftool", "fetch", "for-each-ref", "fsck", "gc", "grep",
        "help", "init", "interpret-trailers", "log", "maintenance", "merge",
        "merge-base", "mergetool", "mktag", "mv", "name-rev", "notes",
        "pack-objects", "pack-refs", "patch-id", "prune", "pull", "push",
        "range-diff", "read-tree", "rebase", "reflog", "remote", "repack",
        "replace", "request-pull", "reset", "restore", "revert", "rev-list",
        "rev-parse", "rm", "send-email", "shortlog", "show", "show-branch",
        "show-index", "show-ref", "sparse-checkout", "stash", "status", "submodule",
        "switch", "symbolic-ref", "tag", "unpack-objects", "update-index",
        "update-ref", "verify-commit", "verify-pack", "verify-tag", "version",
        "whatchanged", "worktree", "write-tree"
    ]

    private static let promotionTargets: Set<String> = [
        "install", "install-copy", "install-agent-safe", "release", "dmg",
        "notarize", "sign", "appcast", "promote", "promotion", "deploy"
    ]

    /// Commands whose write targets are parsed by `analyzeOrdinaryMutation`.
    /// Everything else that is executable code is opaque: a claim for the
    /// launch directory cannot prove where that code will write.
    private static let staticallyResolvedShellMutators: Set<String> = [
        "rm", "mkdir", "touch", "tee", "mv", "cp", "ln"
    ]

    /// These commands have no mutation semantics on their own. Redirections
    /// are still independently analyzed above the command dispatcher.
    private static let knownReadOnlyShellCommands: Set<String> = [
        "pwd", "echo", "printf", "true", "false", "test", "["
    ]

    private struct CommandAnalysis {
        var directories: [String] = []
        var unresolved: [String] = []

        mutating func add(_ path: String) {
            if !directories.contains(path) { directories.append(path) }
        }

        mutating func reject(_ reason: String) {
            if !unresolved.contains(reason) { unresolved.append(reason) }
        }

        mutating func merge(_ other: CommandAnalysis) {
            for path in other.directories { add(path) }
            for reason in other.unresolved { reject(reason) }
        }
    }

    private enum ExecutableResolution {
        case resolved(index: Int, directory: String)
        case none
        case unresolved(String)
    }

    public static func isConsequentialCommand(_ command: String) -> Bool {
        let analysis = analyzeCommand(
            command,
            relativeTo: FileManager.default.currentDirectoryPath
        )
        return !analysis.directories.isEmpty || !analysis.unresolved.isEmpty
    }

    public static func commandCandidateDirectories(
        _ command: String,
        relativeTo workingDirectory: String
    ) -> [String] {
        analyzeCommand(command, relativeTo: workingDirectory).directories
    }

    private static let unsupportedShellControlWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until",
        "do", "done", "case", "esac", "select", "function", "{", "}", "!"
    ]

    private static func unsupportedShellSyntaxReason(_ command: String) -> String? {
        let characters = Array(command)
        var quote: Character?
        var escaped = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                index += 1
                continue
            }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if quote != "'", character == "`" {
                return "backtick command substitution is not statically resolvable"
            }
            if quote != "'", character == "$", next == "(" {
                return "command substitution is not statically resolvable"
            }
            if quote == nil,
               (character == "<" || character == ">"), next == "(" {
                return "process substitution is not statically resolvable"
            }
            if quote == nil, character == "(" || character == ")" {
                return "shell grouping and subshell syntax is not statically resolvable"
            }
            index += 1
        }
        return nil
    }

    private static func analyzeCommand(
        _ command: String,
        relativeTo workingDirectory: String
    ) -> CommandAnalysis {
        var analysis = CommandAnalysis()
        if let reason = unsupportedShellSyntaxReason(command) {
            analysis.reject(reason)
            return analysis
        }
        var currentDirectory = workingDirectory

        for segment in shellSegments(command) {
            let tokens = shellWords(segment)
            guard !tokens.isEmpty else { continue }
            if unsupportedShellControlWords.contains(tokens[0].lowercased()) {
                analysis.reject("unsupported shell control syntax: \(tokens[0])")
                continue
            }

            do {
                for target in try outputRedirectionTargets(
                    segment,
                    relativeTo: currentDirectory
                ) {
                    analysis.add(target)
                }
            } catch let error as WorktreeOwnershipError {
                analysis.reject(error.localizedDescription)
            } catch {
                analysis.reject(error.localizedDescription)
            }

            let resolution = resolveExecutable(tokens, relativeTo: currentDirectory)
            let executableIndex: Int
            let executionDirectory: String
            switch resolution {
            case .resolved(let index, let directory):
                executableIndex = index
                executionDirectory = directory
            case .none:
                continue
            case .unresolved(let reason):
                analysis.reject(reason)
                continue
            }

            let executable = URL(fileURLWithPath: tokens[executableIndex]).lastPathComponent
            let executableName = executable.lowercased()

            if executableName == "cd" {
                let operands = Array(tokens.dropFirst(executableIndex + 1))
                var target: String?
                var operandIndex = 0
                while operandIndex < operands.count {
                    let operand = operands[operandIndex]
                    if operand == "--" {
                        operandIndex += 1
                        continue
                    }
                    if operand.hasPrefix("-") {
                        analysis.reject("unsupported cd option or dynamic target: \(operand)")
                        break
                    }
                    target = operand
                    break
                }
                guard let target else {
                    analysis.reject("cd is missing a statically resolvable directory operand")
                    continue
                }
                do {
                    currentDirectory = try resolveStaticCommandPath(
                        target,
                        relativeTo: executionDirectory
                    )
                } catch {
                    analysis.reject(error.localizedDescription)
                }
            } else if ["pushd", "popd", "source", ".", "eval"].contains(executableName) {
                analysis.reject("shell state mutation is not statically resolvable: \(executableName)")
            } else if ["bash", "sh", "zsh"].contains(executableName) {
                analysis.merge(analyzeShellInterpreter(
                    tokens,
                    segment: segment,
                    executableIndex: executableIndex,
                    relativeTo: executionDirectory
                ))
            } else if executableName == "git" {
                analysis.merge(analyzeGitEnvironment(
                    tokens,
                    executableIndex: executableIndex,
                    relativeTo: executionDirectory
                ))
                analysis.merge(analyzeGit(
                    Array(tokens[executableIndex...]),
                    relativeTo: executionDirectory
                ))
            } else if executableName == "make" || executableName == "just" {
                analysis.merge(analyzeBuildTool(
                    Array(tokens[executableIndex...]),
                    relativeTo: executionDirectory
                ))
                analysis.reject(
                    "\(executableName) has opaque recipe semantics and cannot prove its complete worktree target set; use an explicit Bridge mutation tool or a reviewed target contract"
                )
            } else if executableName == "swift" {
                analysis.merge(analyzeSwiftPackageTool(
                    Array(tokens[executableIndex...]),
                    relativeTo: executionDirectory
                ))
                analysis.reject(
                    "swift package execution has opaque plugin and build-script semantics and cannot prove its complete worktree target set; use an explicit Bridge mutation tool or a reviewed target contract"
                )
            } else {
                analysis.add(executionDirectory)
                let executableToken = tokens[executableIndex]
                if executableToken.contains("/") {
                    do {
                        analysis.add(try resolveStaticCommandPath(
                            executableToken,
                            relativeTo: executionDirectory
                        ))
                    } catch {
                        analysis.reject("executable path: \(error.localizedDescription)")
                    }
                }
                if staticallyResolvedShellMutators.contains(executableName) {
                    analysis.merge(analyzeOrdinaryMutation(
                        executable: executableName,
                        tokens: Array(tokens.dropFirst(executableIndex + 1)),
                        relativeTo: executionDirectory
                    ))
                } else if !knownReadOnlyShellCommands.contains(executableName) {
                    analysis.reject(
                        "\(executableName) has opaque execution semantics and cannot prove its complete worktree target set; use an explicit Bridge mutation tool or a statically supported command"
                    )
                }
            }

            if promotionTargets.contains(where: { executableName.contains($0) }) {
                analysis.add(executionDirectory)
            }
        }
        return analysis
    }

    private static let gitEnvironmentPathVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY"
    ]

    private static func gitAdministrativeWorktreeTarget(_ path: String) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized.hasSuffix("/.git") {
            return URL(fileURLWithPath: standardized).deletingLastPathComponent().path
        }
        if let range = standardized.range(of: "/.git/worktrees/") {
            let suffix = standardized[range.upperBound...]
            guard let name = suffix.split(separator: "/").first else { return nil }
            let adminRoot = String(standardized[..<range.upperBound]) + String(name)
            return commandDirectoryForGitDir(adminRoot, relativeTo: "/")
        }
        if let range = standardized.range(of: "/.git/") {
            return String(standardized[..<range.lowerBound])
        }
        return nil
    }

    private static func addGitEnvironmentPath(
        name: String,
        value: String,
        relativeTo workingDirectory: String,
        analysis: inout CommandAnalysis
    ) {
        do {
            let resolved = try resolveStaticCommandPath(value, relativeTo: workingDirectory)
            switch name {
            case "GIT_DIR", "GIT_COMMON_DIR":
                analysis.add(commandDirectoryForGitDir(resolved, relativeTo: workingDirectory))
            default:
                if let worktreeTarget = gitAdministrativeWorktreeTarget(resolved) {
                    analysis.add(worktreeTarget)
                } else {
                    analysis.add(resolved)
                }
            }
        } catch {
            analysis.reject("\(name): \(error.localizedDescription)")
        }
    }

    private static func analyzeToolEnvironment(
        _ value: Value?,
        relativeTo workingDirectory: String
    ) -> CommandAnalysis {
        var analysis = CommandAnalysis()
        guard let value else { return analysis }
        guard case .object(let environment) = value else {
            analysis.reject("shell environment must be an object of static string values")
            return analysis
        }
        for name in gitEnvironmentPathVariables.sorted() {
            guard let rawValue = environment[name] else { continue }
            guard case .string(let path) = rawValue, !path.isEmpty else {
                analysis.reject("\(name) must be a non-empty static string")
                continue
            }
            addGitEnvironmentPath(
                name: name,
                value: path,
                relativeTo: workingDirectory,
                analysis: &analysis
            )
        }
        return analysis
    }

    private static func analyzeGitEnvironment(
        _ tokens: [String],
        executableIndex: Int,
        relativeTo workingDirectory: String
    ) -> CommandAnalysis {
        var analysis = CommandAnalysis()
        for token in tokens.prefix(executableIndex) {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let name = String(token[..<separator])
            guard gitEnvironmentPathVariables.contains(name) else { continue }
            let value = String(token[token.index(after: separator)...])
            addGitEnvironmentPath(
                name: name,
                value: value,
                relativeTo: workingDirectory,
                analysis: &analysis
            )
        }
        return analysis
    }

    private static func analyzeGit(
        _ tokens: [String],
        relativeTo workingDirectory: String
    ) -> CommandAnalysis {
        var analysis = CommandAnalysis()
        var commandDirectory = workingDirectory
        var gitTargets = [workingDirectory]
        var index = 1

        func addTarget(_ path: String) {
            if !gitTargets.contains(path) { gitTargets.append(path) }
        }

        func resolveTarget(_ raw: String, label: String) -> String? {
            do {
                return try resolveStaticCommandPath(raw, relativeTo: commandDirectory)
            } catch {
                analysis.reject("\(label): \(error.localizedDescription)")
                return nil
            }
        }

        while index < tokens.count {
            let token = tokens[index]
            if token == "-C" {
                guard index + 1 < tokens.count else {
                    analysis.reject("git -C is missing its directory operand")
                    break
                }
                guard let resolved = resolveTarget(tokens[index + 1], label: "git -C") else {
                    break
                }
                commandDirectory = resolved
                gitTargets[0] = commandDirectory
                index += 2
                continue
            }
            if token.hasPrefix("-C"), token.count > 2 {
                guard let resolved = resolveTarget(
                    String(token.dropFirst(2)),
                    label: "git -C"
                ) else { break }
                commandDirectory = resolved
                gitTargets[0] = commandDirectory
                index += 1
                continue
            }
            if token == "--work-tree" {
                guard index + 1 < tokens.count else {
                    analysis.reject("git --work-tree is missing its directory operand")
                    break
                }
                if let resolved = resolveTarget(tokens[index + 1], label: "git --work-tree") {
                    addTarget(resolved)
                }
                index += 2
                continue
            }
            if token.hasPrefix("--work-tree=") {
                if let resolved = resolveTarget(
                    String(token.dropFirst("--work-tree=".count)),
                    label: "git --work-tree"
                ) {
                    addTarget(resolved)
                }
                index += 1
                continue
            }
            if token == "--git-dir" {
                guard index + 1 < tokens.count else {
                    analysis.reject("git --git-dir is missing its directory operand")
                    break
                }
                if let resolved = resolveTarget(tokens[index + 1], label: "git --git-dir") {
                    addTarget(commandDirectoryForGitDir(
                        resolved,
                        relativeTo: commandDirectory
                    ))
                }
                index += 2
                continue
            }
            if token.hasPrefix("--git-dir=") {
                if let resolved = resolveTarget(
                    String(token.dropFirst("--git-dir=".count)),
                    label: "git --git-dir"
                ) {
                    addTarget(commandDirectoryForGitDir(
                        resolved,
                        relativeTo: commandDirectory
                    ))
                }
                index += 1
                continue
            }
            if token == "-c" {
                guard index + 1 < tokens.count else {
                    analysis.reject("git -c is missing its config assignment")
                    break
                }
                let assignment = tokens[index + 1]
                let lower = assignment.lowercased()
                guard lower.hasPrefix("core.worktree=") else {
                    analysis.reject("git -c configuration has opaque execution semantics and cannot prove its complete worktree target set")
                    break
                }
                let value = String(assignment.dropFirst("core.worktree=".count))
                guard value.hasPrefix("/") else {
                    analysis.reject("git -c core.worktree requires an absolute static path")
                    break
                }
                if let resolved = resolveTarget(value, label: "git -c core.worktree") {
                    addTarget(resolved)
                }
                index += 2
                continue
            }
            if token.hasPrefix("-c"), token.count > 2 {
                let assignment = String(token.dropFirst(2))
                let lower = assignment.lowercased()
                guard lower.hasPrefix("core.worktree=") else {
                    analysis.reject("git -c configuration has opaque execution semantics and cannot prove its complete worktree target set")
                    break
                }
                let value = String(assignment.dropFirst("core.worktree=".count))
                guard value.hasPrefix("/") else {
                    analysis.reject("git -c core.worktree requires an absolute static path")
                    break
                }
                if let resolved = resolveTarget(value, label: "git -c core.worktree") {
                    addTarget(resolved)
                }
                index += 1
                continue
            }
            if token == "--config-env" {
                analysis.reject("git --config-env has opaque configuration semantics and cannot prove its complete worktree target set")
                break
            }
            if token.hasPrefix("--config-env=") {
                analysis.reject("git --config-env has opaque configuration semantics and cannot prove its complete worktree target set")
                break
            }
            if token == "--namespace" || token == "--exec-path"
                || token.hasPrefix("--namespace=") || token.hasPrefix("--exec-path=") {
                analysis.reject("git namespace or executable-path selection has opaque execution semantics and cannot prove its complete worktree target set")
                break
            }
            if token.hasPrefix("-") {
                analysis.reject("unsupported git global option: \(token)")
                break
            }
            break
        }

        for target in gitTargets { analysis.add(target) }
        guard index < tokens.count else { return analysis }
        let verb = tokens[index].lowercased()
        let verbArguments = Array(tokens.dropFirst(index + 1))

        guard knownGitVerbs.contains(verb) else {
            analysis.reject(
                "git subcommand \(verb) is opaque because it may resolve through an alias or external executable; use a recognized Git command or a reviewed target contract"
            )
            return analysis
        }

        if verb == "worktree" {
            var operationIndex = index + 1
            while operationIndex < tokens.count, tokens[operationIndex].hasPrefix("-") {
                operationIndex += 1
            }
            guard operationIndex < tokens.count else { return analysis }
            let operation = tokens[operationIndex].lowercased()
            if operation == "list" { return analysis }

            if gitWorktreeMutationVerbs.contains(operation) {
                let operands = worktreeOperands(
                    Array(tokens.dropFirst(operationIndex + 1)),
                    operation: operation
                )
                for operand in operands {
                    do {
                        analysis.add(try resolveStaticCommandPath(
                            operand,
                            relativeTo: commandDirectory
                        ))
                    } catch {
                        analysis.reject("git worktree operand: \(error.localizedDescription)")
                    }
                }
            }
            return analysis
        }

        if isReadOnlyGitInvocation(verb: verb, arguments: verbArguments) {
            return analysis
        }

        // Generic shell Git is ownership-gated even when the verb is read-only.
        // Mutation-specific operand extraction above adds any additional targets.
        return analysis
    }

    private static func isReadOnlyGitInvocation(
        verb: String,
        arguments: [String]
    ) -> Bool {
        if gitAlwaysReadOnlyVerbs.contains(verb) { return true }
        if arguments.contains("--help") || arguments.contains("-h") { return true }
        switch verb {
        case "branch":
            return branchInvocationIsReadOnly(arguments)
        case "tag":
            return tagInvocationIsReadOnly(arguments)
        case "stash":
            guard let operation = arguments.first(where: { !$0.hasPrefix("-") }) else {
                return false
            }
            return operation == "list" || operation == "show"
        default:
            return false
        }
    }

    /// Classifies only the conservative read-only subset that C0 promises to
    /// leave lease-free. It intentionally refuses command redirection,
    /// `env`/`GIT_*` wrapper state, dynamic config, mixed shell chains, and
    /// unknown Git verbs so they stay on the governed fail-closed path.
    private static func isReadOnlyGitShellCommand(
        _ command: String,
        relativeTo workingDirectory: String
    ) -> Bool {
        guard unsupportedShellSyntaxReason(command) == nil else { return false }
        var sawGit = false

        for segment in shellSegments(command) {
            let tokens = shellWords(segment)
            guard !tokens.isEmpty else { continue }
            guard (try? outputRedirectionTargets(
                segment,
                relativeTo: workingDirectory
            ))?.isEmpty == true,
            (try? inputRedirectionTargets(
                segment,
                relativeTo: workingDirectory
            ))?.isEmpty == true else {
                return false
            }

            let resolution = resolveExecutable(tokens, relativeTo: workingDirectory)
            guard case .resolved(let executableIndex, _) = resolution else {
                return false
            }
            let executable = URL(fileURLWithPath: tokens[executableIndex])
                .lastPathComponent.lowercased()
            guard executable == "git" else { return false }

            let wrappers = tokens[..<executableIndex]
            guard !wrappers.contains(where: { token in
                let name = URL(fileURLWithPath: token).lastPathComponent.lowercased()
                return name == "env" || token.uppercased().hasPrefix("GIT_")
            }) else {
                return false
            }
            guard gitTokensAreReadOnly(
                Array(tokens[executableIndex...]),
                relativeTo: workingDirectory
            ) else {
                return false
            }
            sawGit = true
        }
        return sawGit
    }

    private static func gitTokensAreReadOnly(
        _ tokens: [String],
        relativeTo workingDirectory: String
    ) -> Bool {
        guard tokens.count > 1 else { return false }
        var index = 1

        func hasStaticPath(_ raw: String, requiresAbsolutePath: Bool = false) -> Bool {
            guard !requiresAbsolutePath || raw.hasPrefix("/") else { return false }
            return (try? resolveStaticCommandPath(
                raw,
                relativeTo: workingDirectory
            )) != nil
        }

        while index < tokens.count {
            let token = tokens[index]
            if token == "-C" || token == "--work-tree" || token == "--git-dir" {
                guard index + 1 < tokens.count else { return false }
                guard hasStaticPath(tokens[index + 1]) else { return false }
                index += 2
                continue
            }
            if (token.hasPrefix("-C") && token.count > 2)
                || token.hasPrefix("--work-tree=")
                || token.hasPrefix("--git-dir=") {
                let raw: String
                if token.hasPrefix("-C") {
                    raw = String(token.dropFirst(2))
                } else if token.hasPrefix("--work-tree=") {
                    raw = String(token.dropFirst("--work-tree=".count))
                } else {
                    raw = String(token.dropFirst("--git-dir=".count))
                }
                guard hasStaticPath(raw) else { return false }
                index += 1
                continue
            }
            if token == "-c" {
                guard index + 1 < tokens.count else { return false }
                let assignment = tokens[index + 1]
                guard assignment.lowercased().hasPrefix("core.worktree=") else {
                    return false
                }
                let raw = String(assignment.dropFirst("core.worktree=".count))
                guard hasStaticPath(raw, requiresAbsolutePath: true) else {
                    return false
                }
                index += 2
                continue
            }
            if token.hasPrefix("-c") && token.count > 2 {
                let assignment = String(token.dropFirst(2))
                guard assignment.lowercased().hasPrefix("core.worktree=") else {
                    return false
                }
                let raw = String(assignment.dropFirst("core.worktree=".count))
                guard hasStaticPath(raw, requiresAbsolutePath: true) else {
                    return false
                }
                index += 1
                continue
            }
            if token == "--config-env" || token.hasPrefix("--config-env=") {
                return false
            }
            if token.hasPrefix("-") { return false }
            break
        }

        guard index < tokens.count else { return false }
        let verb = tokens[index].lowercased()
        let arguments = Array(tokens.dropFirst(index + 1))
        if verb == "worktree" {
            guard let operation = arguments.first(where: { !$0.hasPrefix("-") }) else {
                return false
            }
            return operation.lowercased() == "list"
        }
        return isReadOnlyGitInvocation(verb: verb, arguments: arguments)
    }

    private static func branchInvocationIsReadOnly(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return true }
        let mutationOptions: Set<String> = [
            "-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy",
            "--edit-description", "--set-upstream-to", "--unset-upstream", "--track",
            "--no-track", "--recurse-submodules", "--create-reflog"
        ]
        let readOptionsWithValues: Set<String> = [
            "--contains", "--no-contains", "--merged", "--no-merged", "--points-at",
            "--sort", "--format", "--column", "--color", "--abbrev"
        ]
        let readFlags: Set<String> = [
            "-a", "--all", "-r", "--remotes", "-v", "-vv", "--list", "-l",
            "--show-current", "--ignore-case", "--omit-empty", "--no-column",
            "--no-color", "--no-abbrev"
        ]
        var listMode = false
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if mutationOptions.contains(token) || token.hasPrefix("--set-upstream-to=") {
                return false
            }
            if token == "--" { return listMode }
            if readOptionsWithValues.contains(token) {
                guard index + 1 < arguments.count else { return false }
                listMode = true
                index += 2
                continue
            }
            if readOptionsWithValues.contains(where: { token.hasPrefix($0 + "=") }) || readFlags.contains(token) {
                listMode = true
                index += 1
                continue
            }
            if token.hasPrefix("-") { return false }
            if !listMode { return false }
            index += 1
        }
        return true
    }

    private static func tagInvocationIsReadOnly(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return true }
        let mutationOptions: Set<String> = [
            "-a", "--annotate", "-s", "--sign", "-u", "--local-user", "-f", "--force",
            "-d", "--delete", "--create-reflog", "--cleanup", "-m", "--message",
            "-F", "--file", "-e", "--edit"
        ]
        let readOptionsWithValues: Set<String> = [
            "--contains", "--no-contains", "--merged", "--no-merged", "--points-at",
            "--sort", "--format", "--color", "--column"
        ]
        let readFlags: Set<String> = [
            "-l", "--list", "--ignore-case", "--no-column", "--no-color",
            "-v", "--verify"
        ]
        var readMode = false
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if mutationOptions.contains(token) || mutationOptions.contains(where: { token.hasPrefix($0 + "=") }) {
                return false
            }
            if token == "--" { return readMode }
            if readOptionsWithValues.contains(token) {
                guard index + 1 < arguments.count else { return false }
                readMode = true
                index += 2
                continue
            }
            if readOptionsWithValues.contains(where: { token.hasPrefix($0 + "=") }) || readFlags.contains(token) || token.hasPrefix("-n") {
                readMode = true
                index += 1
                continue
            }
            if token.hasPrefix("-") { return false }
            if !readMode { return false }
            index += 1
        }
        return true
    }

    private static func commandDirectoryForGitDir(
        _ raw: String,
        relativeTo base: String
    ) -> String {
        let resolved = URL(fileURLWithPath: resolveCommandPath(raw, relativeTo: base)).standardizedFileURL
        if resolved.lastPathComponent == ".git" {
            return resolved.deletingLastPathComponent().path
        }
        if resolved.path.contains("/.git/worktrees/") {
            let marker = resolved.appendingPathComponent("gitdir")
            if let value = try? String(contentsOf: marker, encoding: .utf8) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return URL(fileURLWithPath: resolveCommandPath(trimmed, relativeTo: resolved.path))
                        .deletingLastPathComponent().path
                }
            }
        }
        return resolved.path
    }

    private static func analyzeSwiftPackageTool(
        _ tokens: [String],
        relativeTo workingDirectory: String
    ) -> CommandAnalysis {
        var analysis = CommandAnalysis()
        var packageDirectory = workingDirectory
        let packageOptions: Set<String> = ["--package-path"]
        let outputOptions: Set<String> = [
            "--scratch-path", "--build-path", "--cache-path", "--config-path", "--security-path"
        ]
        let attachedPrefixes = (packageOptions.union(outputOptions)).map { $0 + "=" }
        var index = 1

        func addPath(_ raw: String, option: String, changesPackageDirectory: Bool) -> Bool {
            do {
                let resolved = try resolveStaticCommandPath(raw, relativeTo: workingDirectory)
                analysis.add(resolved)
                if changesPackageDirectory {
                    packageDirectory = resolved
                } else if !raw.hasPrefix("/"), packageDirectory != workingDirectory {
                    analysis.add(try resolveStaticCommandPath(raw, relativeTo: packageDirectory))
                }
                return true
            } catch {
                analysis.reject("swift \(option): \(error.localizedDescription)")
                return false
            }
        }

        while index < tokens.count {
            let token = tokens[index]
            if packageOptions.contains(token) || outputOptions.contains(token) {
                guard index + 1 < tokens.count else {
                    analysis.reject("swift \(token) is missing its path operand")
                    break
                }
                guard addPath(
                    tokens[index + 1],
                    option: token,
                    changesPackageDirectory: packageOptions.contains(token)
                ) else { break }
                index += 2
                continue
            }
            if let prefix = attachedPrefixes.first(where: { token.hasPrefix($0) }) {
                let option = String(prefix.dropLast())
                guard addPath(
                    String(token.dropFirst(prefix.count)),
                    option: option,
                    changesPackageDirectory: packageOptions.contains(option)
                ) else { break }
                index += 1
                continue
            }
            index += 1
        }

        analysis.add(packageDirectory)
        return analysis
    }

    private static func analyzeBuildTool(
        _ tokens: [String],
        relativeTo workingDirectory: String
    ) -> CommandAnalysis {
        var analysis = CommandAnalysis()
        var buildDirectory = workingDirectory
        var makefileOperands: [(raw: String, label: String)] = []
        let executable = URL(fileURLWithPath: tokens.first ?? "").lastPathComponent.lowercased()
        var index = 1

        func updateDirectory(_ raw: String, label: String) -> Bool {
            do {
                buildDirectory = try resolveStaticCommandPath(
                    raw,
                    relativeTo: buildDirectory
                )
                return true
            } catch {
                analysis.reject("\(label): \(error.localizedDescription)")
                return false
            }
        }

        while index < tokens.count {
            let token = tokens[index]
            let splitDirectoryOptions: Set<String> = executable == "just"
                ? ["-d", "--working-directory"]
                : ["-C", "--directory"]
            let attachedDirectoryPrefixes = executable == "just"
                ? ["--working-directory="]
                : ["--directory="]

            if splitDirectoryOptions.contains(token) {
                guard index + 1 < tokens.count else {
                    analysis.reject("\(executable) \(token) is missing its directory operand")
                    break
                }
                guard updateDirectory(tokens[index + 1], label: "\(executable) \(token)") else {
                    break
                }
                index += 2
                continue
            }
            if executable == "make", token.hasPrefix("-C"), token.count > 2 {
                guard updateDirectory(
                    String(token.dropFirst(2)),
                    label: "make -C"
                ) else { break }
                index += 1
                continue
            }
            if let prefix = attachedDirectoryPrefixes.first(where: { token.hasPrefix($0) }) {
                guard updateDirectory(
                    String(token.dropFirst(prefix.count)),
                    label: "\(executable) \(prefix.dropLast())"
                ) else { break }
                index += 1
                continue
            }
            if executable == "just",
               ["-f", "--justfile"].contains(token)
                    || token.hasPrefix("--justfile=") {
                analysis.reject("justfile directory semantics are not supported by this analyzer")
                break
            }
            if executable == "make", ["-f", "--file", "--makefile"].contains(token) {
                guard index + 1 < tokens.count else {
                    analysis.reject("make \(token) is missing its Makefile operand")
                    break
                }
                makefileOperands.append((tokens[index + 1], "make \(token)"))
                index += 2
                continue
            }
            if executable == "make" {
                let attachedMakefilePrefixes = ["--file=", "--makefile="]
                if let prefix = attachedMakefilePrefixes.first(where: { token.hasPrefix($0) }) {
                    makefileOperands.append((
                        String(token.dropFirst(prefix.count)),
                        "make \(prefix.dropLast())"
                    ))
                    index += 1
                    continue
                }
                if token.hasPrefix("-f"), token.count > 2 {
                    makefileOperands.append((String(token.dropFirst(2)), "make -f"))
                    index += 1
                    continue
                }
            }
            if token.hasPrefix("-") || token.contains("=") {
                index += 1
                continue
            }
            index += 1
        }

        if executable == "make", analysis.unresolved.isEmpty {
            for operand in makefileOperands {
                do {
                    analysis.add(try resolveStaticCommandPath(
                        operand.raw,
                        relativeTo: buildDirectory
                    ))
                } catch {
                    analysis.reject("\(operand.label): \(error.localizedDescription)")
                    break
                }
            }
        }
        analysis.add(buildDirectory)
        return analysis
    }

    private static func analyzeOrdinaryMutation(
        executable: String,
        tokens: [String],
        relativeTo workingDirectory: String
    ) -> CommandAnalysis {
        var analysis = CommandAnalysis()
        let optionsWithValues: Set<String>
        switch executable {
        case "mkdir":
            optionsWithValues = ["-m"]
        case "touch":
            optionsWithValues = ["-A", "-d", "-r", "-t"]
        case "cp", "mv":
            optionsWithValues = ["-S", "--suffix", "-t", "--target-directory"]
        default:
            optionsWithValues = []
        }
        let positionals = commandPositionals(
            tokens,
            optionsWithValues: optionsWithValues
        )
        let targetDirectory: String?
        if executable == "cp" || executable == "mv" {
            switch targetDirectoryOperand(tokens) {
            case .success(let value):
                targetDirectory = value
            case .failure(let error):
                analysis.reject(error.localizedDescription)
                return analysis
            }
        } else {
            targetDirectory = nil
        }
        let mutationOperands: [String]
        switch executable {
        case "rm", "mkdir", "touch", "tee":
            mutationOperands = positionals
        case "mv":
            mutationOperands = targetDirectory.map { positionals + [$0] } ?? positionals
        case "cp":
            mutationOperands = targetDirectory.map { [$0] }
                ?? (positionals.last.map { [$0] } ?? [])
        case "ln":
            if positionals.count >= 2 {
                mutationOperands = [positionals[positionals.count - 1]]
            } else if let source = positionals.first {
                mutationOperands = [URL(fileURLWithPath: workingDirectory)
                    .appendingPathComponent(URL(fileURLWithPath: source).lastPathComponent)
                    .path]
            } else {
                mutationOperands = []
            }
        default:
            return analysis
        }

        for operand in mutationOperands {
            do {
                analysis.add(try resolveStaticCommandPath(
                    operand,
                    relativeTo: workingDirectory
                ))
            } catch {
                analysis.reject(error.localizedDescription)
            }
        }
        return analysis
    }

    private static func targetDirectoryOperand(
        _ tokens: [String]
    ) -> Result<String?, WorktreeOwnershipError> {
        var target: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" { break }
            if token == "-t" || token == "--target-directory" {
                guard index + 1 < tokens.count, !tokens[index + 1].isEmpty else {
                    return .failure(.targetUnresolved("\(token) is missing its target directory"))
                }
                target = tokens[index + 1]
                index += 2
                continue
            }
            if token.hasPrefix("--target-directory=") {
                let value = String(token.dropFirst("--target-directory=".count))
                guard !value.isEmpty else {
                    return .failure(.targetUnresolved("--target-directory is missing its target directory"))
                }
                target = value
                index += 1
                continue
            }
            if token.hasPrefix("-t"), !token.hasPrefix("--"), token.count > 2 {
                let value = String(token.dropFirst(2))
                guard !value.isEmpty else {
                    return .failure(.targetUnresolved("-t is missing its target directory"))
                }
                target = value
                index += 1
                continue
            }
            index += 1
        }
        return .success(target)
    }

    private static func commandPositionals(
        _ tokens: [String],
        optionsWithValues: Set<String>
    ) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                result.append(contentsOf: tokens.dropFirst(index + 1))
                break
            }
            if optionsWithValues.contains(token) {
                index += min(2, tokens.count - index)
                continue
            }
            if optionsWithValues.contains(where: { token.hasPrefix($0 + "=") })
                || token.hasPrefix("-") {
                index += 1
                continue
            }
            result.append(token)
            index += 1
        }
        return result
    }

    private static func resolveStaticCommandPath(
        _ raw: String,
        relativeTo workingDirectory: String
    ) throws -> String {
        guard !raw.isEmpty,
              !raw.contains("$"),
              !raw.contains("`") else {
            throw WorktreeOwnershipError.targetUnresolved(
                "dynamic mutation target cannot be resolved safely: \(raw)"
            )
        }
        return resolveCommandPath(raw, relativeTo: workingDirectory)
    }

    private static func outputRedirectionTargets(
        _ segment: String,
        relativeTo workingDirectory: String
    ) throws -> [String] {
        let characters = Array(segment)
        var targets: [String] = []
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                index += 1
                continue
            }
            guard quote == nil, character == ">" else {
                index += 1
                continue
            }

            var cursor = index + 1
            if cursor < characters.count,
               characters[cursor] == ">" || characters[cursor] == "|" {
                cursor += 1
            }
            while cursor < characters.count, characters[cursor].isWhitespace {
                cursor += 1
            }
            guard cursor < characters.count else {
                throw WorktreeOwnershipError.targetUnresolved(
                    "output redirection is missing its destination"
                )
            }
            var ampersandRedirection = false
            if characters[cursor] == "&" {
                ampersandRedirection = true
                cursor += 1
                while cursor < characters.count, characters[cursor].isWhitespace {
                    cursor += 1
                }
                guard cursor < characters.count else {
                    throw WorktreeOwnershipError.targetUnresolved(
                        "ampersand redirection is missing its destination"
                    )
                }
            }

            var raw = ""
            var targetQuote: Character?
            var targetEscaped = false
            while cursor < characters.count {
                let value = characters[cursor]
                if targetEscaped {
                    raw.append(value)
                    targetEscaped = false
                    cursor += 1
                    continue
                }
                if value == "\\", targetQuote != "'" {
                    targetEscaped = true
                    cursor += 1
                    continue
                }
                if value == "'" || value == "\"" {
                    if targetQuote == value { targetQuote = nil }
                    else if targetQuote == nil { targetQuote = value }
                    else { raw.append(value) }
                    cursor += 1
                    continue
                }
                if targetQuote == nil,
                   value.isWhitespace || ";&|<>".contains(value) {
                    break
                }
                raw.append(value)
                cursor += 1
            }
            guard targetQuote == nil, !raw.isEmpty else {
                throw WorktreeOwnershipError.targetUnresolved(
                    "output redirection destination is malformed"
                )
            }
            if ampersandRedirection, raw == "-" || Int(raw) != nil {
                index = cursor
                continue
            }
            targets.append(try resolveStaticCommandPath(
                raw,
                relativeTo: workingDirectory
            ))
            index = cursor
        }
        return targets
    }

    private static func inputRedirectionTargets(
        _ segment: String,
        relativeTo workingDirectory: String
    ) throws -> [String] {
        let characters = Array(segment)
        var targets: [String] = []
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                index += 1
                continue
            }
            guard quote == nil, character == "<" else {
                index += 1
                continue
            }

            var cursor = index + 1
            if cursor < characters.count,
               ["<", ">", "&"].contains(characters[cursor]) {
                throw WorktreeOwnershipError.targetUnresolved(
                    "shell stdin redirection form is not statically supported"
                )
            }
            while cursor < characters.count, characters[cursor].isWhitespace {
                cursor += 1
            }
            guard cursor < characters.count else {
                throw WorktreeOwnershipError.targetUnresolved(
                    "input redirection is missing its source"
                )
            }

            var raw = ""
            var targetQuote: Character?
            var targetEscaped = false
            while cursor < characters.count {
                let value = characters[cursor]
                if targetEscaped {
                    raw.append(value)
                    targetEscaped = false
                    cursor += 1
                    continue
                }
                if value == "\\", targetQuote != "'" {
                    targetEscaped = true
                    cursor += 1
                    continue
                }
                if value == "'" || value == "\"" {
                    if targetQuote == value { targetQuote = nil }
                    else if targetQuote == nil { targetQuote = value }
                    else { raw.append(value) }
                    cursor += 1
                    continue
                }
                if targetQuote == nil,
                   value.isWhitespace || ";&|<>".contains(value) {
                    break
                }
                raw.append(value)
                cursor += 1
            }
            guard targetQuote == nil, !raw.isEmpty else {
                throw WorktreeOwnershipError.targetUnresolved(
                    "input redirection source is malformed"
                )
            }
            targets.append(try resolveStaticCommandPath(
                raw,
                relativeTo: workingDirectory
            ))
            index = cursor
        }
        return targets
    }

    private static func worktreeOperands(_ tokens: [String], operation: String) -> [String] {
        var positionals: [String] = []
        var index = 0
        let optionsWithValues: Set<String> = [
            "-b", "-B", "--reason", "--expire"
        ]
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                positionals.append(contentsOf: tokens.dropFirst(index + 1))
                break
            }
            if optionsWithValues.contains(token), index + 1 < tokens.count {
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            positionals.append(token)
            index += 1
        }
        switch operation {
        case "remove", "lock", "unlock", "add":
            return Array(positionals.prefix(1))
        case "move":
            return Array(positionals.prefix(2))
        case "repair":
            return positionals
        default:
            return []
        }
    }

    private static func analyzeShellInterpreter(
        _ tokens: [String],
        segment: String,
        executableIndex: Int,
        relativeTo executionDirectory: String
    ) -> CommandAnalysis {
        var analysis = CommandAnalysis()
        analysis.add(executionDirectory)
        var index = executableIndex + 1
        let optionsWithValues: Set<String> = [
            "-o", "+o", "-O", "+O", "--rcfile", "--init-file"
        ]

        func rejectFileBackedScript(_ form: String) {
            do {
                let targets = try inputRedirectionTargets(
                    segment,
                    relativeTo: executionDirectory
                )
                guard !targets.isEmpty else {
                    analysis.reject(
                        "\(form) has opaque file-backed script semantics and cannot prove its complete worktree target set"
                    )
                    return
                }
                for target in targets { analysis.add(target) }
                analysis.reject(
                    "\(form) has opaque file-backed script semantics and cannot prove its complete worktree target set"
                )
            } catch {
                analysis.reject("\(form) source: \(error.localizedDescription)")
            }
        }

        while index < tokens.count {
            let option = tokens[index]
            if option == "--" {
                index += 1
                break
            }
            if option == "-" {
                rejectFileBackedScript("shell stdin execution")
                return analysis
            }
            if optionsWithValues.contains(option) {
                guard index + 1 < tokens.count else {
                    analysis.reject("shell option \(option) is missing its operand")
                    return analysis
                }
                index += 2
                continue
            }
            if option.hasPrefix("-") && !option.hasPrefix("--") {
                let flags = option.dropFirst()
                if flags.contains("c") {
                    guard index + 1 < tokens.count else {
                        analysis.reject("shell -c is missing its command string")
                        return analysis
                    }
                    analysis.merge(analyzeCommand(
                        tokens[index + 1],
                        relativeTo: executionDirectory
                    ))
                    return analysis
                }
                if flags.contains("s") {
                    rejectFileBackedScript("shell stdin execution")
                    return analysis
                }
            }
            guard option.hasPrefix("-") || option.hasPrefix("+") else { break }
            index += 1
        }

        if index >= tokens.count || tokens[index].hasPrefix("<") {
            rejectFileBackedScript("shell stdin execution")
            return analysis
        }
        do {
            analysis.add(try resolveStaticCommandPath(
                tokens[index],
                relativeTo: executionDirectory
            ))
            analysis.reject(
                "shell script-file execution has opaque mutation semantics and cannot prove its complete worktree target set; use shell -c with a static command"
            )
        } catch {
            analysis.reject("shell script path: \(error.localizedDescription)")
        }
        return analysis
    }

    private static func resolveExecutable(
        _ tokens: [String],
        relativeTo workingDirectory: String
    ) -> ExecutableResolution {
        var index = 0
        var executionDirectory = workingDirectory

        func resolveDirectory(_ raw: String, label: String) -> ExecutableResolution? {
            do {
                executionDirectory = try resolveStaticCommandPath(
                    raw,
                    relativeTo: executionDirectory
                )
                return nil
            } catch {
                return .unresolved("\(label): \(error.localizedDescription)")
            }
        }

        while index < tokens.count {
            let token = tokens[index]
            if token.contains("=") && !token.hasPrefix("/") && !token.hasPrefix("-") {
                index += 1
                continue
            }
            let wrapper = URL(fileURLWithPath: token).lastPathComponent.lowercased()
            switch wrapper {
            case "command", "builtin", "nohup", "exec":
                index += 1
                while index < tokens.count, tokens[index].hasPrefix("-") { index += 1 }

            case "env":
                index += 1
                while index < tokens.count {
                    let value = tokens[index]
                    if value == "-C" {
                        guard index + 1 < tokens.count else {
                            return .unresolved("env -C is missing its directory operand")
                        }
                        if let failure = resolveDirectory(tokens[index + 1], label: "env -C") {
                            return failure
                        }
                        index += 2
                    } else if value == "--chdir" || value.hasPrefix("--chdir=") {
                        return .unresolved(
                            "env --chdir is unsupported by the installed BSD env; use env -C"
                        )
                    } else if value == "-S" || value == "--split-string" {
                        return .unresolved("env -S split-string execution is unsupported")
                    } else if value.hasPrefix("-S") && value.count > 2
                                || value.hasPrefix("--split-string=") {
                        return .unresolved("env -S split-string execution is unsupported")
                    } else if ["-u", "--unset", "-P"].contains(value) {
                        guard index + 1 < tokens.count else {
                            return .unresolved("env option \(value) is missing its operand")
                        }
                        index += 2
                    } else if value.hasPrefix("-") || value.contains("=") {
                        index += 1
                    } else {
                        break
                    }
                }

            case "sudo":
                index += 1
                let optionsWithValues: Set<String> = [
                    "-u", "--user", "-g", "--group", "-h", "--host", "-p",
                    "--prompt", "-C", "--close-from", "-R", "--chroot", "-r",
                    "--role", "-t", "--type", "-T", "--command-timeout"
                ]
                while index < tokens.count {
                    let value = tokens[index]
                    if value == "-D" {
                        guard index + 1 < tokens.count else {
                            return .unresolved("sudo -D is missing its directory operand")
                        }
                        if let failure = resolveDirectory(tokens[index + 1], label: "sudo -D") {
                            return failure
                        }
                        index += 2
                    } else if value.hasPrefix("-D"), value.count > 2 {
                        if let failure = resolveDirectory(
                            String(value.dropFirst(2)),
                            label: "sudo -D"
                        ) {
                            return failure
                        }
                        index += 1
                    } else if value == "--chdir" {
                        return .unresolved(
                            "sudo --chdir requires the installed --chdir=directory form"
                        )
                    } else if value.hasPrefix("--chdir=") {
                        let raw = String(value.dropFirst("--chdir=".count))
                        guard !raw.isEmpty else {
                            return .unresolved("sudo --chdir is missing its directory operand")
                        }
                        if let failure = resolveDirectory(raw, label: "sudo --chdir") {
                            return failure
                        }
                        index += 1
                    } else if optionsWithValues.contains(value) {
                        guard index + 1 < tokens.count else {
                            return .unresolved("sudo option \(value) is missing its operand")
                        }
                        index += 2
                    } else if value.hasPrefix("-") {
                        index += 1
                    } else {
                        break
                    }
                }

            case "time":
                index += 1
                let optionsWithValues: Set<String> = ["-f", "--format", "-o", "--output"]
                while index < tokens.count {
                    let value = tokens[index]
                    if optionsWithValues.contains(value) {
                        guard index + 1 < tokens.count else {
                            return .unresolved("time option \(value) is missing its operand")
                        }
                        index += 2
                    } else if value.hasPrefix("-") {
                        index += 1
                    } else {
                        break
                    }
                }

            case "nice":
                index += 1
                if index < tokens.count, ["-n", "--adjustment"].contains(tokens[index]) {
                    guard index + 1 < tokens.count else {
                        return .unresolved("nice adjustment option is missing its operand")
                    }
                    index += 2
                } else if index < tokens.count,
                          tokens[index].hasPrefix("--adjustment=") {
                    index += 1
                }

            case "timeout", "gtimeout":
                index += 1
                let optionsWithValues: Set<String> = ["-k", "--kill-after", "-s", "--signal"]
                while index < tokens.count {
                    let value = tokens[index]
                    if optionsWithValues.contains(value) {
                        guard index + 1 < tokens.count else {
                            return .unresolved("timeout option \(value) is missing its operand")
                        }
                        index += 2
                    } else if value.hasPrefix("-") {
                        index += 1
                    } else {
                        break
                    }
                }
                guard index < tokens.count else {
                    return .unresolved("timeout is missing its duration")
                }
                index += 1

            case "xcrun":
                index += 1
                let optionsWithValues: Set<String> = ["--sdk", "--toolchain", "--log"]
                while index < tokens.count {
                    let value = tokens[index]
                    if optionsWithValues.contains(value) {
                        guard index + 1 < tokens.count else {
                            return .unresolved("xcrun option \(value) is missing its operand")
                        }
                        index += 2
                    } else if value.hasPrefix("-") {
                        index += 1
                    } else {
                        break
                    }
                }

            default:
                if token.contains("$") || token.contains("`") {
                    return .unresolved("dynamic executable cannot be resolved safely: \(token)")
                }
                return .resolved(index: index, directory: executionDirectory)
            }
        }
        return .none
    }

    private static func shellSegments(_ command: String) -> [String] {
        let characters = Array(command)
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if escaped {
                current.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\", quote != "'" {
                current.append(character)
                escaped = true
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                current.append(character)
                index += 1
                continue
            }

            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let isRedirectionAmpersand = character == "&"
                && (previous == ">" || previous == "<" || next == ">" || next == "<")
            if quote == nil,
               character == ";" || character == "|" || character == "\n"
                    || (character == "&" && !isRedirectionAmpersand) {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(current)
                }
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(current)
        }
        return segments
    }

    private static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        func flush() {
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }

        for character in command {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if character == "'" || character == "\"" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                else { current.append(character) }
                continue
            }
            if quote == nil, character.isWhitespace {
                flush()
                continue
            }
            if quote == nil, character == "(" || character == ")" {
                flush()
                continue
            }
            current.append(character)
        }
        flush()
        return words
    }

    private static func resolveCommandPath(_ raw: String, relativeTo base: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: base).appendingPathComponent(expanded).path
    }

    public static func canonicalPath(_ raw: String) throws -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw WorktreeOwnershipError.invalid("path must be absolute: \(raw)")
        }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        var cursor = standardized
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: cursor.path) {
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { break }
            missingComponents.append(cursor.lastPathComponent)
            cursor = parent
        }
        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    private static func probeDirectory(for rawPath: String) throws -> String {
        let canonical = try canonicalPath(rawPath)
        var url = URL(fileURLWithPath: canonical)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            url.deleteLastPathComponent()
        }
        while !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                || !isDirectory.boolValue {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else {
                throw WorktreeOwnershipError.ownershipRequired(
                    "no existing directory could be resolved for \(rawPath)"
                )
            }
            url = parent
        }
        return url.path
    }

    private static func pathIsInGitRepository(_ path: String) -> Bool {
        guard let probe = try? probeDirectory(for: path) else { return false }
        return (try? runGitChecked(["rev-parse", "--git-dir"], cwd: probe)) != nil
    }

    private static func filesystemIdentity(_ path: String) throws -> String {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0 else {
            throw WorktreeOwnershipError.identityChanged(
                "unable to stat Git administrative identity: \(path)"
            )
        }
        let birth = metadata.st_birthtimespec
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_gen):\(birth.tv_sec):\(birth.tv_nsec)"
    }

    public static func liveIdentity(for path: String) throws -> LiveIdentity {
        let probe = try probeDirectory(for: path)
        let worktree = try canonicalPath(
            try runGitChecked(["rev-parse", "--show-toplevel"], cwd: probe)
        )
        let rawCommon = try runGitChecked(["rev-parse", "--git-common-dir"], cwd: probe)
        let commonURL = rawCommon.hasPrefix("/")
            ? URL(fileURLWithPath: rawCommon)
            : URL(fileURLWithPath: probe).appendingPathComponent(rawCommon)
        let common = try canonicalPath(commonURL.path)
        guard URL(fileURLWithPath: common).lastPathComponent == ".git" else {
            throw WorktreeOwnershipError.ownershipRequired(
                "bare repositories are not supported by worktree ownership"
            )
        }
        let worktreeGitDirectory = try canonicalPath(
            try runGitChecked(["rev-parse", "--absolute-git-dir"], cwd: probe)
        )
        let repoRoot = try canonicalPath(
            URL(fileURLWithPath: common).deletingLastPathComponent().path
        )
        let branch = runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: probe)
        let head = try runGitChecked(["rev-parse", "HEAD"], cwd: probe)
        let role = common == worktreeGitDirectory ? "main" : "linked"
        let stableID = [
            "git-worktree-v3",
            role,
            try filesystemIdentity(common),
            try filesystemIdentity(worktreeGitDirectory)
        ].joined(separator: ":")
        return LiveIdentity(
            stableID: stableID,
            repoRoot: repoRoot,
            worktreePath: worktree,
            commonGitDirectory: common,
            worktreeGitDirectory: worktreeGitDirectory,
            branch: branch.isEmpty ? "(detached)" : branch,
            headSHA: head
        )
    }

    public static func baseStillMatches(_ baseSHA: String, worktreePath: String) -> Bool {
        do {
            _ = try runGitChecked(["rev-parse", "--verify", "\(baseSHA)^{commit}"], cwd: worktreePath)
            _ = try runGitChecked(["merge-base", "--is-ancestor", baseSHA, "HEAD"], cwd: worktreePath)
            return true
        } catch {
            return false
        }
    }

    public static func releaseEvidence(
        baseSHA: String,
        worktreePath: String,
        finalBranch: String
    ) throws -> WorktreeReleaseEvidence {
        let currentPath = try canonicalPath(worktreePath)
        let head = try runGitChecked(["rev-parse", "HEAD"], cwd: currentPath)
        let status = try runGitChecked(["status", "--porcelain"], cwd: currentPath)
        let countText = try runGitChecked(
            ["rev-list", "--count", "\(baseSHA)..HEAD"],
            cwd: currentPath
        )
        guard let count = Int(countText) else {
            throw WorktreeOwnershipError.storage("unable to parse unique commit count")
        }
        return WorktreeReleaseEvidence(
            headSHA: head,
            isClean: status.isEmpty,
            uniqueCommitCount: count,
            finalWorktreePath: currentPath,
            finalBranch: finalBranch
        )
    }

    private static func runGit(_ arguments: [String], cwd: String) -> String {
        (try? runGitChecked(arguments, cwd: cwd)) ?? ""
    }

    private static func runGitChecked(_ arguments: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let error = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: error, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw WorktreeOwnershipError.ownershipRequired(
                    detail.isEmpty ? "git identity probe failed" : detail
                )
            }
            return String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as WorktreeOwnershipError {
            throw error
        } catch {
            throw WorktreeOwnershipError.ownershipRequired(error.localizedDescription)
        }
    }

    public static func errorValue(
        tool: String,
        error: Error,
        arguments: Value? = nil
    ) -> Value {
        let ownershipError = error as? WorktreeOwnershipError
        let context = ownershipError?.denialContext ?? ownershipError.map {
            denialContext(for: $0, toolName: tool, arguments: arguments ?? .object([:]))
        }
        let renderedError = ownershipError.flatMap { ownershipError in
            context.map(ownershipError.withDenialContext)
        }
        var value: [String: Value] = [
            "ok": .bool(false),
            "tool": .string(tool),
            "status": .string(renderedError?.code ?? "worktree_ownership_failed"),
            "error": .string(renderedError?.localizedDescription ?? error.localizedDescription)
        ]
        if let context {
            value["target"] = .string(context.target)
            value["targetState"] = .string(context.targetState.rawValue)
            value["ownerState"] = .string(context.ownerState.rawValue)
            value["remedy"] = .string(context.remedy)
        }
        return .object(value)
    }
}

public enum WorktreeOwnershipModule {
    public static let moduleName = "dev"

    private static func schema(_ properties: [String: Value], _ required: [String]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string))
        ])
    }

    private static func stringProperty(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerProperty(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func enumProperty(_ values: [String], _ description: String) -> Value {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(Value.string)),
            "description": .string(description)
        ])
    }

    private static func argument(_ object: [String: Value], _ key: String) -> String? {
        if case .string(let value) = object[key], !value.isEmpty { return value }
        return nil
    }

    public static func register(
        on router: ToolRouter,
        store: WorktreeOwnershipStore = .shared
    ) async {
        await WorktreeCommandModule.register(on: router)
        await router.register(ToolRegistration(
            name: "worktree_claim",
            module: moduleName,
            tier: .request,
            description: "Claim one live canonical Git worktree for an ownerSession. The requested repo root, worktree path, branch, and base SHA are verified before the durable SQLite/WAL claim is written. Same-owner exact retries are idempotent; expired claims require explicit evidence-preserving recovery. On a detached HEAD, pass branch exactly \"(detached)\" and baseSHA equal to that HEAD. A named branch on a detached tree fails worktree_identity_changed; the identity tuple is never rewritten to match.",
            inputSchema: schema([
                "repoRoot": stringProperty("Canonical primary repository root."),
                "worktreePath": stringProperty("Canonical live worktree path."),
                "branch": stringProperty("Expected current branch, or exactly \"(detached)\" when HEAD is detached."),
                "baseSHA": stringProperty("Expected commit ancestor that defines the worktree base. First claim requires this equal to live HEAD."),
                "ownerSession": stringProperty("Unique active owner session."),
                "ttlSeconds": integerProperty("Bounded expiry, 60...86400 seconds.")
            ], ["repoRoot", "worktreePath", "branch", "baseSHA", "ownerSession", "ttlSeconds"]),
            handler: { args in
                guard case .object(let object) = args,
                      let repoRoot = argument(object, "repoRoot"),
                      let worktreePath = argument(object, "worktreePath"),
                      let branch = argument(object, "branch"),
                      let baseSHA = argument(object, "baseSHA"),
                      let ownerSession = argument(object, "ownerSession"),
                      case .int(let ttlSeconds) = object["ttlSeconds"] else {
                    return WorktreeOwnershipGuard.errorValue(
                        tool: "worktree_claim",
                        error: WorktreeOwnershipError.invalid("required claim tuple is incomplete"),
                        arguments: args
                    )
                }
                do {
                    let claim = try await store.claim(
                        repoRoot: repoRoot,
                        worktreePath: worktreePath,
                        branch: branch,
                        baseSHA: baseSHA,
                        ownerSession: ownerSession,
                        ttlSeconds: ttlSeconds
                    )
                    return .object([
                        "ok": .bool(true),
                        "repoRoot": .string(claim.repoRoot),
                        "worktreePath": .string(claim.worktreePath),
                        "branch": .string(claim.branch),
                        "baseSHA": .string(claim.baseSHA),
                        "ownerSession": .string(claim.ownerSession),
                        "expiresAt": .string(ISO8601DateFormatter().string(from: claim.expiresAt))
                    ])
                } catch {
                    return WorktreeOwnershipGuard.errorValue(
                        tool: "worktree_claim",
                        error: error,
                        arguments: args
                    )
                }
            }
        ))

        await router.register(ToolRegistration(
            name: "worktree_release",
            module: moduleName,
            tier: .request,
            description: "Release a worktree claim as metadata only. Records a preservation disposition plus read-only Git evidence and never resets, cleans, stashes, switches, deletes, or edits the worktree. Expired or inaccessible claims require abandoned_with_recovery_note.",
            inputSchema: schema([
                "worktreePath": stringProperty("Claimed canonical worktree path."),
                "ownerSession": stringProperty("Current claim owner."),
                "disposition": enumProperty(
                    WorktreeReleaseDisposition.allCases.map(\.rawValue),
                    "Evidence-preserving release disposition."
                ),
                "recoveryNote": stringProperty("Required for abandoned_with_recovery_note.")
            ], ["worktreePath", "ownerSession", "disposition"]),
            handler: { args in
                guard case .object(let object) = args,
                      let worktreePath = argument(object, "worktreePath"),
                      let ownerSession = argument(object, "ownerSession"),
                      let rawDisposition = argument(object, "disposition"),
                      let disposition = WorktreeReleaseDisposition(rawValue: rawDisposition) else {
                    return WorktreeOwnershipGuard.errorValue(
                        tool: "worktree_release",
                        error: WorktreeOwnershipError.invalid("required release tuple is incomplete"),
                        arguments: args
                    )
                }
                do {
                    let evidence = try await store.release(
                        worktreePath: worktreePath,
                        ownerSession: ownerSession,
                        disposition: disposition,
                        recoveryNote: argument(object, "recoveryNote")
                    )
                    var result: [String: Value] = [
                        "ok": .bool(true),
                        "disposition": .string(disposition.rawValue)
                    ]
                    if let headSHA = evidence.headSHA { result["headSHA"] = .string(headSHA) }
                    if let isClean = evidence.isClean { result["isClean"] = .bool(isClean) }
                    if let count = evidence.uniqueCommitCount { result["uniqueCommitCount"] = .int(count) }
                    return .object(result)
                } catch {
                    return WorktreeOwnershipGuard.errorValue(
                        tool: "worktree_release",
                        error: error,
                        arguments: args
                    )
                }
            }
        ))
    }
}
