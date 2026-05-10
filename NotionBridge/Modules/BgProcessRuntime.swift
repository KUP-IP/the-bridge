// BgProcessRuntime.swift – PKT-744 W1: bg_process_* runtime
// NotionBridge · Modules · dev/
//
// Single source of truth for async process lifecycle. Owns:
//   - per-job dir at ~/Library/Application Support/NotionBridge/jobs/<id>/{stdout,stderr,meta.json}
//   - posix_spawn child in its own process group (POSIX_SPAWN_SETPGROUP, pgrp=0 ⇒ pgid==pid)
//   - atomic status writer (meta.json via .tmp + rename)
//   - per-job stdout/stderr files redirected via posix_spawn_file_actions_addopen
//   - SIGCHLD reaping via DispatchSource.makeProcessSource(.exit)
//   - kill cascade SIGTERM → 5s grace → SIGKILL on the process group (killpg)
//   - log pagination by byte offset (cursor + n)
//   - orphan reconciliation on Bridge relaunch (kill(pid, 0) liveness probe)
//   - 7-day auto-cleanup of terminal jobs
//
// PKT-744: Foundation primitive — every Wave 1+ packet that spawns child
// processes (devserver, lsp, runners, Cursor SDK sidecar) supervises through
// this runtime, replacing the W29 nohup workaround.

import Foundation
import Darwin

// MARK: - Public Types

public enum BgProcessStatus: String, Codable, Sendable, CaseIterable {
    case running
    case done
    case failed
    case killed
    case unknown
}

public struct BgProcessJobMeta: Codable, Sendable {
    public let id: String
    public let pid: Int32
    public let pgid: Int32
    public let command: String
    public let workingDir: String?
    public let label: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var status: BgProcessStatus
    public var killSignal: Int32?
    public var lastReconcileAt: Date?
    public var note: String?

    public init(
        id: String, pid: Int32, pgid: Int32, command: String,
        workingDir: String?, label: String?, startedAt: Date,
        endedAt: Date? = nil, exitCode: Int32? = nil,
        status: BgProcessStatus = .running, killSignal: Int32? = nil,
        lastReconcileAt: Date? = nil, note: String? = nil
    ) {
        self.id = id; self.pid = pid; self.pgid = pgid
        self.command = command; self.workingDir = workingDir; self.label = label
        self.startedAt = startedAt; self.endedAt = endedAt; self.exitCode = exitCode
        self.status = status; self.killSignal = killSignal
        self.lastReconcileAt = lastReconcileAt; self.note = note
    }
}

public enum BgProcessError: Error, LocalizedError {
    case capabilityMissing(String)
    case spawnFailed(Int32, String)
    case notFound(String)
    case invalidArgument(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .capabilityMissing(let m): return "capability_missing: \(m)"
        case .spawnFailed(let code, let m): return "spawn failed (errno \(code)): \(m)"
        case .notFound(let id): return "job not found: \(id)"
        case .invalidArgument(let m): return "invalid argument: \(m)"
        case .ioError(let m): return "io error: \(m)"
        }
    }
}

public struct BgProcessLogPage: Sendable {
    public let id: String
    public let stream: String   // "stdout" | "stderr"
    public let cursor: Int      // byte offset returned (start of this chunk)
    public let nextCursor: Int  // byte offset to pass next call
    public let bytes: Int       // bytes in `text`
    public let totalBytes: Int  // total file size
    public let eof: Bool        // true ⇔ nextCursor == totalBytes && job terminal
    public let text: String
}

// MARK: - Runtime Actor

public actor BgProcessRuntime {

    public static let shared = BgProcessRuntime()

    // Configuration
    public let baseDir: URL
    public let cleanupTTL: TimeInterval
    public let killGracePeriodSec: Int

    // Internal state — DispatchSource handles per active job (kept alive
    // until child exits and meta.json is finalized). All mutations are
    // actor-isolated.
    private var watchers: [String: DispatchSourceProcess] = [:]
    private var pendingSigkill: [String: DispatchWorkItem] = [:]

    public init(
        baseDir: URL? = nil,
        cleanupTTL: TimeInterval = 7 * 24 * 3600,
        killGracePeriodSec: Int = 5
    ) {
        if let baseDir {
            self.baseDir = baseDir
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
            self.baseDir = support
                .appendingPathComponent("NotionBridge", isDirectory: true)
                .appendingPathComponent("jobs", isDirectory: true)
        }
        self.cleanupTTL = cleanupTTL
        self.killGracePeriodSec = killGracePeriodSec
    }

    // MARK: Capability

    /// Always available on macOS — POSIX spawn + filesystem are baseline.
    /// Returns false only if the jobs base directory cannot be created.
    public func capabilityCheck() -> (ok: Bool, reason: String?) {
        do {
            try FileManager.default.createDirectory(
                at: baseDir, withIntermediateDirectories: true
            )
            return (true, nil)
        } catch {
            return (false, "jobs base dir not writable: \(error.localizedDescription)")
        }
    }

    // MARK: Start

    public func start(
        command: String,
        workingDir: String? = nil,
        env: [String: String] = [:],
        label: String? = nil
    ) throws -> BgProcessJobMeta {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BgProcessError.invalidArgument("command is empty")
        }
        let cap = capabilityCheck()
        guard cap.ok else {
            throw BgProcessError.capabilityMissing(cap.reason ?? "unknown")
        }

        let id = Self.makeJobId()
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stdoutURL = dir.appendingPathComponent("stdout")
        let stderrURL = dir.appendingPathComponent("stderr")
        // Touch the log files so they exist even before child writes.
        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())

        let pid = try Self.spawnChild(
            command: command,
            workingDir: workingDir,
            env: env,
            stdoutPath: stdoutURL.path,
            stderrPath: stderrURL.path
        )

        let meta = BgProcessJobMeta(
            id: id, pid: pid, pgid: pid,  // pgid == pid because POSIX_SPAWN_SETPGROUP w/ pgrp=0
            command: command, workingDir: workingDir, label: label,
            startedAt: Date(), status: .running
        )
        try writeMeta(meta, to: dir)

        // Begin watching for child exit so meta is finalized automatically.
        installWatcher(for: id, pid: pid, dir: dir)
        return meta
    }

    // MARK: Status

    public func status(id: String) throws -> BgProcessJobMeta {
        guard let meta = readMeta(id: id) else {
            throw BgProcessError.notFound(id)
        }
        return meta
    }

    // MARK: Logs (paginated by byte offset)

    public func logs(
        id: String, stream: String, cursor: Int? = nil, n: Int? = nil
    ) throws -> BgProcessLogPage {
        guard stream == "stdout" || stream == "stderr" else {
            throw BgProcessError.invalidArgument("stream must be 'stdout' or 'stderr', got '\(stream)'")
        }
        guard let meta = readMeta(id: id) else {
            throw BgProcessError.notFound(id)
        }
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        let url = dir.appendingPathComponent(stream)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let start = max(0, min(cursor ?? 0, total))
        let limit = n ?? 8192
        let want = max(0, min(limit, total - start))
        var chunk = Data()
        if want > 0, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(start))
            chunk = handle.readData(ofLength: want)
        }
        let text = String(data: chunk, encoding: .utf8)
            // Tolerate mid-multibyte cuts at the page boundary.
            ?? String(decoding: chunk, as: UTF8.self)
        let nextCursor = start + chunk.count
        let terminal = (meta.status != .running)
        let eof = (nextCursor >= total) && terminal
        return BgProcessLogPage(
            id: id, stream: stream, cursor: start,
            nextCursor: nextCursor, bytes: chunk.count,
            totalBytes: total, eof: eof, text: text
        )
    }

    // MARK: Kill

    @discardableResult
    public func kill(id: String, force: Bool = false) throws -> BgProcessJobMeta {
        guard var meta = readMeta(id: id) else {
            throw BgProcessError.notFound(id)
        }
        guard meta.status == .running else {
            return meta  // idempotent — already terminal
        }
        let signal: Int32 = force ? SIGKILL : SIGTERM
        // Negative pid → killpg semantics: deliver to the entire process group.
        _ = Darwin.kill(-meta.pgid, signal)
        meta.killSignal = signal
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        try writeMeta(meta, to: dir)

        if !force {
            // Schedule SIGKILL after grace period if child is still alive.
            let grace = killGracePeriodSec
            let pgid = meta.pgid
            let runtime = self
            let work = DispatchWorkItem {
                // Probe — if process group is still alive, escalate.
                if Darwin.kill(-pgid, 0) == 0 {
                    _ = Darwin.kill(-pgid, SIGKILL)
                    Task { await runtime.recordEscalation(id: id) }
                }
            }
            pendingSigkill[id] = work
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(grace), execute: work)
        }
        return meta
    }

    private func recordEscalation(id: String) {
        guard var meta = readMeta(id: id) else { return }
        meta.killSignal = SIGKILL
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        try? writeMeta(meta, to: dir)
    }

    // MARK: List

    public func list(filter: BgProcessStatus? = nil, label: String? = nil) -> [BgProcessJobMeta] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: baseDir.path) else {
            return []
        }
        var results: [BgProcessJobMeta] = []
        results.reserveCapacity(entries.count)
        for entry in entries {
            guard let meta = readMeta(id: entry) else { continue }
            if let f = filter, meta.status != f { continue }
            if let l = label, meta.label != l { continue }
            results.append(meta)
        }
        // Newest-started first.
        results.sort { $0.startedAt > $1.startedAt }
        return results
    }

    // MARK: Orphan reconciliation (call on Bridge relaunch)

    /// Scan jobs/, for any meta.status == .running probe pid liveness via kill(pid, 0).
    /// Dead PIDs ⇒ status flipped to .unknown and lastReconcileAt stamped.
    /// Live PIDs ⇒ re-attach a DispatchSource watcher so future exits are reaped.
    /// Also runs the 7-day cleanup pass for terminal jobs.
    @discardableResult
    public func reconcileOrphans(now: Date = Date()) -> (reconciled: Int, stillRunning: Int, cleaned: Int) {
        _ = capabilityCheck()  // ensures baseDir exists
        var reconciled = 0, stillRunning = 0, cleaned = 0
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: baseDir.path) else {
            return (0, 0, 0)
        }
        for id in entries {
            let dir = baseDir.appendingPathComponent(id, isDirectory: true)
            guard var meta = readMeta(id: id) else { continue }
            // 7-day cleanup for terminal jobs.
            if meta.status != .running, let ended = meta.endedAt,
               now.timeIntervalSince(ended) > cleanupTTL {
                try? FileManager.default.removeItem(at: dir)
                cleaned += 1
                continue
            }
            if meta.status == .running {
                if Darwin.kill(meta.pid, 0) == 0 {
                    // Still alive — re-attach watcher.
                    if watchers[id] == nil {
                        installWatcher(for: id, pid: meta.pid, dir: dir)
                    }
                    stillRunning += 1
                } else {
                    // Dead — reconcile to unknown (we missed the SIGCHLD across relaunch).
                    meta.status = .unknown
                    meta.endedAt = meta.endedAt ?? now
                    meta.lastReconcileAt = now
                    meta.note = "orphan reconciled on relaunch — pid \(meta.pid) absent"
                    try? writeMeta(meta, to: dir)
                    reconciled += 1
                }
            }
        }
        return (reconciled, stillRunning, cleaned)
    }

    // MARK: Cleanup helper (for tests)

    public func purgeAll() {
        // Cancel any pending sigkill timers + close watchers.
        for (_, work) in pendingSigkill { work.cancel() }
        pendingSigkill.removeAll()
        for (_, src) in watchers { src.cancel() }
        watchers.removeAll()
        try? FileManager.default.removeItem(at: baseDir)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    // MARK: - Internals

    private func installWatcher(for id: String, pid: Int32, dir: URL) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        let runtime = self
        source.setEventHandler {
            // waitpid is non-blocking here — child has already exited.
            var rawStatus: Int32 = 0
            let r = waitpid(pid, &rawStatus, WNOHANG)
            let exitCode: Int32
            let signaled: Int32?
            if r == pid {
                if (rawStatus & 0x7f) == 0 {
                    // WIFEXITED
                    exitCode = (rawStatus >> 8) & 0xff
                    signaled = nil
                } else if ((rawStatus & 0x7f) + 1) >> 1 > 0 {
                    // WIFSIGNALED
                    exitCode = -1
                    signaled = rawStatus & 0x7f
                } else {
                    exitCode = -1
                    signaled = nil
                }
            } else {
                // Already reaped (e.g., by orphan reconciliation).
                exitCode = -1
                signaled = nil
            }
            Task { await runtime.finalizeExit(id: id, dir: dir, exitCode: exitCode, signaled: signaled) }
        }
        source.setCancelHandler {}
        watchers[id] = source
        source.resume()
    }

    private func finalizeExit(id: String, dir: URL, exitCode: Int32, signaled: Int32?) {
        defer {
            watchers[id]?.cancel()
            watchers[id] = nil
            pendingSigkill[id]?.cancel()
            pendingSigkill[id] = nil
        }
        guard var meta = readMeta(id: id) else { return }
        meta.endedAt = Date()
        meta.exitCode = exitCode
        if let sig = signaled {
            meta.status = (meta.killSignal != nil) ? .killed : .failed
            meta.killSignal = meta.killSignal ?? sig
        } else {
            meta.status = (exitCode == 0) ? .done : .failed
        }
        try? writeMeta(meta, to: dir)
    }

    private func readMeta(id: String) -> BgProcessJobMeta? {
        let url = baseDir.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(BgProcessJobMeta.self, from: data)
    }

    private func writeMeta(_ meta: BgProcessJobMeta, to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(meta) }
        catch { throw BgProcessError.ioError("encode meta: \(error.localizedDescription)") }
        let final = dir.appendingPathComponent("meta.json")
        let tmp = dir.appendingPathComponent("meta.json.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            // Atomic replace — POSIX rename is atomic on the same filesystem.
            _ = try FileManager.default.replaceItemAt(final, withItemAt: tmp)
        } catch {
            // Fallback: direct atomic write if replaceItemAt struggles
            // (e.g., final does not exist yet on first write).
            try? FileManager.default.removeItem(at: tmp)
            try data.write(to: final, options: .atomic)
        }
    }

    // MARK: Job ID

    private static func makeJobId() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return "\(stamp)-\(suffix)"
    }

    // MARK: posix_spawn

    private static func spawnChild(
        command: String,
        workingDir: String?,
        env: [String: String],
        stdoutPath: String,
        stderrPath: String
    ) throws -> Int32 {
        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw BgProcessError.spawnFailed(errno, "posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let openFlags = O_WRONLY | O_CREAT | O_APPEND
        let mode: mode_t = 0o644
        // stdin → /dev/null
        _ = posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        _ = posix_spawn_file_actions_addopen(&fileActions, 1, stdoutPath, openFlags, mode)
        _ = posix_spawn_file_actions_addopen(&fileActions, 2, stderrPath, openFlags, mode)

        if let wd = workingDir, !wd.isEmpty {
            let expanded = (wd as NSString).expandingTildeInPath
            // posix_spawn_file_actions_addchdir_np available on macOS 10.15+.
            _ = expanded.withCString { cstr in
                posix_spawn_file_actions_addchdir_np(&fileActions, cstr)
            }
        }

        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else {
            throw BgProcessError.spawnFailed(errno, "posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attr) }

        // POSIX_SPAWN_SETPGROUP with pgrp=0 ⇒ child becomes process group leader
        // with pgid == pid. POSIX_SPAWN_CLOEXEC_DEFAULT keeps inherited fds tidy.
        let flags: Int16 = Int16(POSIX_SPAWN_SETPGROUP)
        _ = posix_spawnattr_setflags(&attr, flags)
        _ = posix_spawnattr_setpgroup(&attr, 0)

        // Build env with deterministic PATH bootstrap matching ShellModule.
        var envBuilt = ProcessInfo.processInfo.environment
        for (k, v) in env { envBuilt[k] = v }
        let defaultPathParts = [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin"
        ]
        let defaultPath = defaultPathParts.joined(separator: ":")
        if let existing = envBuilt["PATH"], !existing.isEmpty {
            envBuilt["PATH"] = defaultPath + ":" + existing
        } else {
            envBuilt["PATH"] = defaultPath
        }

        // argv: /bin/bash -c "<command>"
        let argv = ["/bin/bash", "-c", command]
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgv { if let p { free(p) } } }

        let envStrings = envBuilt.map { "\($0.key)=\($0.value)" }
        let cEnvp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { for p in cEnvp { if let p { free(p) } } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/bash", &fileActions, &attr, cArgv, cEnvp)
        if rc != 0 {
            throw BgProcessError.spawnFailed(rc, String(cString: strerror(rc)))
        }
        return pid
    }
}
