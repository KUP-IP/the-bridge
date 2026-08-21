import Darwin
import Foundation
import MCP
import TheBridgeLib

private struct C0CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

@discardableResult
private func c0Run(
    _ executable: String,
    _ arguments: [String],
    cwd: URL? = nil,
    expectSuccess: Bool = true
) throws -> C0CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let result = C0CommandResult(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines),
        stderr: String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    if expectSuccess, result.status != 0 {
        throw TestError.assertion(
            "command failed: \(executable) \(arguments.joined(separator: " ")) — \(result.stderr)"
        )
    }
    return result
}

private final class C0GitFixture: @unchecked Sendable {
    let root: URL
    let repo: URL
    let linked: URL
    let baseSHA: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-c0-git-\(UUID().uuidString)", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try c0Run("/usr/bin/git", ["init", "-b", "main"], cwd: repo)
        try c0Run("/usr/bin/git", ["config", "user.name", "C0 Test"], cwd: repo)
        try c0Run("/usr/bin/git", ["config", "user.email", "c0@example.invalid"], cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try c0Run("/usr/bin/git", ["add", "README.md"], cwd: repo)
        try c0Run("/usr/bin/git", ["commit", "-m", "base"], cwd: repo)
        baseSHA = try c0Run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: repo).stdout
        try c0Run(
            "/usr/bin/git",
            ["worktree", "add", "-b", "packet/c0-linked", linked.path, baseSHA],
            cwd: repo
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func databaseURL(_ name: String = UUID().uuidString) -> URL {
        root.appendingPathComponent("db-\(name)/claims.sqlite")
    }

    func commitUniqueFile(in worktree: URL, name: String = "unique.txt") throws {
        try "unique\n".write(
            to: worktree.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
        try c0Run("/usr/bin/git", ["add", name], cwd: worktree)
        try c0Run("/usr/bin/git", ["commit", "-m", "unique \(name)"], cwd: worktree)
    }
}

private actor C0InvocationProbe {
    private var count = 0
    func mark() { count += 1 }
    func value() -> Int { count }
}

private func c0Claim(
    _ store: WorktreeOwnershipStore,
    fixture: C0GitFixture,
    worktree: URL,
    branch: String,
    owner: String,
    ttl: Int = 300,
    now: Date = Date()
) async throws -> WorktreeClaimTuple {
    try await store.claim(
        repoRoot: fixture.repo.path,
        worktreePath: worktree.path,
        branch: branch,
        baseSHA: fixture.baseSHA,
        ownerSession: owner,
        ttlSeconds: ttl,
        now: now
    )
}

private func c0ErrorCode(_ operation: () async throws -> Void) async -> String? {
    do {
        try await operation()
        return nil
    } catch let error as WorktreeOwnershipError {
        return error.code
    } catch {
        return "unexpected:\(error)"
    }
}

private func c0SchemaHasOwnerSession(_ registration: ToolRegistration) -> Bool {
    guard case .object(let schema) = registration.inputSchema,
          case .object(let properties)? = schema["properties"] else { return false }
    return properties["ownerSession"] != nil
}

private final class C0ProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32 = 3

    func set(_ value: Int32) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func worktreeOwnershipProcessProbeExitCodeIfRequested() -> Int32? {
    let arguments = CommandLine.arguments

    if let index = arguments.firstIndex(of: "--worktree-ownership-permit-probe"),
       arguments.count >= index + 6 {
        let databaseURL = URL(fileURLWithPath: arguments[index + 1])
        let ownerSession = arguments[index + 2]
        let readyPath = arguments[index + 3]
        let releasePath = arguments[index + 4]
        let worktreePaths = Array(arguments[(index + 5)...])
        let semaphore = DispatchSemaphore(value: 0)
        let result = C0ProbeResult()
        Task.detached {
            do {
                let store = WorktreeOwnershipStore(databaseURL: databaseURL)
                let identities = try worktreePaths.map {
                    try WorktreeOwnershipGuard.liveIdentity(for: $0)
                }
                let permit = try await store.executionPermit(
                    identities: identities,
                    ownerSession: ownerSession
                )
                try Data().write(to: URL(fileURLWithPath: readyPath), options: .atomic)
                let deadline = Date().addingTimeInterval(15)
                while !FileManager.default.fileExists(atPath: releasePath), Date() < deadline {
                    usleep(10_000)
                }
                guard FileManager.default.fileExists(atPath: releasePath) else {
                    permit.release()
                    result.set(4)
                    semaphore.signal()
                    return
                }
                permit.release()
                result.set(0)
            } catch let error as WorktreeOwnershipError
                where error.code == "worktree_busy" {
                result.set(42)
            } catch {
                fputs("worktree permit probe failed: \(error)\n", stderr)
                result.set(3)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result.get()
    }

    guard let index = arguments.firstIndex(of: "--worktree-ownership-claim-probe"),
          arguments.count >= index + 8 else { return nil }
    let databaseURL = URL(fileURLWithPath: arguments[index + 1])
    let repoRoot = arguments[index + 2]
    let worktreePath = arguments[index + 3]
    let branch = arguments[index + 4]
    let baseSHA = arguments[index + 5]
    let ownerSession = arguments[index + 6]
    let gatePath = arguments[index + 7]
    let semaphore = DispatchSemaphore(value: 0)
    let result = C0ProbeResult()

    Task.detached {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: gatePath), Date() < deadline {
            usleep(10_000)
        }
        guard FileManager.default.fileExists(atPath: gatePath) else {
            result.set(4)
            semaphore.signal()
            return
        }
        do {
            let store = WorktreeOwnershipStore(databaseURL: databaseURL)
            _ = try await store.claim(
                repoRoot: repoRoot,
                worktreePath: worktreePath,
                branch: branch,
                baseSHA: baseSHA,
                ownerSession: ownerSession,
                ttlSeconds: 300
            )
            result.set(0)
        } catch let error as WorktreeOwnershipError
            where error.code == "worktree_claim_conflict" || error.code == "worktree_busy" {
            result.set(42)
        } catch {
            fputs("worktree ownership probe failed: \(error)\n", stderr)
            result.set(3)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return result.get()
}

private func c0WaitForChildProcess(
    _ process: Process,
    label: String,
    timeout: TimeInterval = 15
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    process.terminate()
    try await Task.sleep(nanoseconds: 250_000_000)
    if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
    throw TestError.assertion("\(label) exceeded \(Int(timeout))s (pid=\(pid))")
}

func runWorktreeOwnershipTests() async {
    print("\n🧷 Worktree ownership tests (C0)")

    await test("C0 live identity distinguishes primary repo root from linked worktree path") {
        let fixture = try C0GitFixture()
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        try expect(identity.repoRoot == fixture.repo.path)
        try expect(identity.worktreePath == fixture.linked.path)
        try expect(identity.branch == "packet/c0-linked")
        try expect(identity.headSHA == fixture.baseSHA)
    }

    await test("C0 first claim validates live tuple and same-owner retry is idempotent") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let first = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        let retry = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        try expect(first == retry, "idempotent retry must not extend expiry")
    }

    await test("C0 same-owner claim retry remains idempotent after legitimate commits") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let first = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        try fixture.commitUniqueFile(in: fixture.linked, name: "after-claim.txt")
        let retry = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        try expect(first == retry, "commits must not rotate or extend the stored claim")
        try await store.authorize(path: fixture.linked.path, ownerSession: "owner-a")
    }

    await test("C0 claim fails closed on branch, repo-root, or base mismatch") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let wrongBranch = await c0ErrorCode {
            _ = try await store.claim(
                repoRoot: fixture.repo.path,
                worktreePath: fixture.linked.path,
                branch: "wrong",
                baseSHA: fixture.baseSHA,
                ownerSession: "owner",
                ttlSeconds: 300
            )
        }
        try expect(wrongBranch == "worktree_identity_changed")
        let wrongRepo = await c0ErrorCode {
            _ = try await store.claim(
                repoRoot: fixture.linked.path,
                worktreePath: fixture.linked.path,
                branch: "packet/c0-linked",
                baseSHA: fixture.baseSHA,
                ownerSession: "owner",
                ttlSeconds: 300
            )
        }
        try expect(wrongRepo == "worktree_identity_changed")
        let wrongBase = await c0ErrorCode {
            _ = try await store.claim(
                repoRoot: fixture.repo.path,
                worktreePath: fixture.linked.path,
                branch: "packet/c0-linked",
                baseSHA: String(repeating: "0", count: 40),
                ownerSession: "owner",
                ttlSeconds: 300
            )
        }
        try expect(wrongBase == "worktree_identity_changed")
        try fixture.commitUniqueFile(in: fixture.linked, name: "before-claim.txt")
        let ancestorButNotHead = await c0ErrorCode {
            _ = try await store.claim(
                repoRoot: fixture.repo.path,
                worktreePath: fixture.linked.path,
                branch: "packet/c0-linked",
                baseSHA: fixture.baseSHA,
                ownerSession: "owner",
                ttlSeconds: 300
            )
        }
        try expect(ancestorButNotHead == "worktree_identity_changed")

        let branchDriftFixture = try C0GitFixture()
        let branchDriftStore = WorktreeOwnershipStore(
            databaseURL: branchDriftFixture.databaseURL("claim-branch-drift"),
            beforeClaimReprobeForTesting: {
                _ = try c0Run(
                    "/usr/bin/git",
                    ["switch", "-c", "claim-interleaved-branch"],
                    cwd: branchDriftFixture.linked
                )
            }
        )
        let branchDrift = await c0ErrorCode {
            _ = try await branchDriftStore.claim(
                repoRoot: branchDriftFixture.repo.path,
                worktreePath: branchDriftFixture.linked.path,
                branch: "packet/c0-linked",
                baseSHA: branchDriftFixture.baseSHA,
                ownerSession: "owner",
                ttlSeconds: 300
            )
        }
        try expect(branchDrift == "worktree_identity_changed")
        try expect(try await branchDriftStore.record(
            worktreePath: branchDriftFixture.linked.path
        ) == nil, "branch drift must persist no claim")

        let headDriftFixture = try C0GitFixture()
        let headDriftStore = WorktreeOwnershipStore(
            databaseURL: headDriftFixture.databaseURL("claim-head-drift"),
            beforeClaimReprobeForTesting: {
                try headDriftFixture.commitUniqueFile(
                    in: headDriftFixture.linked,
                    name: "claim-interleaved-head.txt"
                )
            }
        )
        let headDrift = await c0ErrorCode {
            _ = try await headDriftStore.claim(
                repoRoot: headDriftFixture.repo.path,
                worktreePath: headDriftFixture.linked.path,
                branch: "packet/c0-linked",
                baseSHA: headDriftFixture.baseSHA,
                ownerSession: "owner",
                ttlSeconds: 300
            )
        }
        try expect(headDrift == "worktree_identity_changed")
        try expect(try await headDriftStore.record(
            worktreePath: headDriftFixture.linked.path
        ) == nil, "HEAD drift must persist no claim")
    }

    await test("C0 detached HEAD claims with branch (detached) and baseSHA equal to HEAD") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("detached-claim"))
        _ = try c0Run("/usr/bin/git", ["switch", "--detach", "HEAD"], cwd: fixture.linked)
        let liveBranch = try c0Run(
            "/usr/bin/git",
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            cwd: fixture.linked,
            expectSuccess: false
        )
        try expect(liveBranch.status != 0, "symbolic-ref must fail on detached HEAD")
        let head = try c0Run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: fixture.linked).stdout
        try expect(head == fixture.baseSHA)
        let claim = try await store.claim(
            repoRoot: fixture.repo.path,
            worktreePath: fixture.linked.path,
            branch: "(detached)",
            baseSHA: head,
            ownerSession: "sign-tree",
            ttlSeconds: 300
        )
        try expect(claim.branch == "(detached)")
        try expect(claim.baseSHA == head)
        try expect(claim.ownerSession == "sign-tree")
    }

    await test("C0 named-branch claim on detached HEAD fails worktree_identity_changed") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("detached-named"))
        _ = try c0Run("/usr/bin/git", ["switch", "--detach", "HEAD"], cwd: fixture.linked)
        let named = await c0ErrorCode {
            _ = try await store.claim(
                repoRoot: fixture.repo.path,
                worktreePath: fixture.linked.path,
                branch: "packet/c0-linked",
                baseSHA: fixture.baseSHA,
                ownerSession: "sign-tree",
                ttlSeconds: 300
            )
        }
        try expect(named == "worktree_identity_changed")
        try expect(
            try await store.record(worktreePath: fixture.linked.path) == nil,
            "named-branch claim on detached HEAD must persist no claim"
        )
        let wrongBase = await c0ErrorCode {
            _ = try await store.claim(
                repoRoot: fixture.repo.path,
                worktreePath: fixture.linked.path,
                branch: "(detached)",
                baseSHA: String(repeating: "0", count: 40),
                ownerSession: "sign-tree",
                ttlSeconds: 300
            )
        }
        try expect(wrongBase == "worktree_identity_changed")
    }

    await test("C0 same-path race across independent SQLite connections elects one owner") {
        let fixture = try C0GitFixture()
        let databaseURL = fixture.databaseURL("race")
        let firstStore = WorktreeOwnershipStore(databaseURL: databaseURL)
        let secondStore = WorktreeOwnershipStore(databaseURL: databaseURL)
        _ = try await firstStore.record(worktreePath: fixture.linked.path)
        _ = try await secondStore.record(worktreePath: fixture.linked.path)
        async let first: Bool = {
            do {
                _ = try await c0Claim(
                    firstStore,
                    fixture: fixture,
                    worktree: fixture.linked,
                    branch: "packet/c0-linked",
                    owner: "owner-a"
                )
                return true
            } catch { return false }
        }()
        async let second: Bool = {
            do {
                _ = try await c0Claim(
                    secondStore,
                    fixture: fixture,
                    worktree: fixture.linked,
                    branch: "packet/c0-linked",
                    owner: "owner-b"
                )
                return true
            } catch { return false }
        }()
        let results = await [first, second]
        try expect(results.filter { $0 }.count == 1, "exactly one connection must acquire")
    }

    await test("C0 same-path race across child processes elects one owner") {
        let fixture = try C0GitFixture()
        let databaseURL = fixture.databaseURL("process-race")
        let gate = fixture.root.appendingPathComponent("claim-race-start")
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let commonArguments = [
            "--worktree-ownership-claim-probe",
            databaseURL.path,
            fixture.repo.path,
            fixture.linked.path,
            "packet/c0-linked",
            fixture.baseSHA
        ]
        let first = Process()
        first.executableURL = binary
        first.arguments = commonArguments + ["process-owner-a", gate.path]
        let second = Process()
        second.executableURL = binary
        second.arguments = commonArguments + ["process-owner-b", gate.path]
        try first.run()
        try second.run()
        try Data().write(to: gate, options: .atomic)
        try await c0WaitForChildProcess(first, label: "C0 first claim child")
        try await c0WaitForChildProcess(second, label: "C0 second claim child")
        let statuses = [first.terminationStatus, second.terminationStatus].sorted()
        try expect(statuses == [0, 42], "expected one owner and one conflict, got \(statuses)")
    }

    await test("C0 symlink aliases collide on one canonical worktree path") {
        let fixture = try C0GitFixture()
        let alias = fixture.root.appendingPathComponent("linked-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.linked)
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        let code = await c0ErrorCode {
            _ = try await store.claim(
                repoRoot: fixture.repo.path,
                worktreePath: alias.path,
                branch: "packet/c0-linked",
                baseSHA: fixture.baseSHA,
                ownerSession: "owner-b",
                ttlSeconds: 300
            )
        }
        try expect(code == "worktree_claim_conflict")
    }

    await test("C0 distinct worktrees under one repository are concurrently claimable") {
        let fixture = try C0GitFixture()
        let databaseURL = fixture.databaseURL("distinct")
        let firstStore = WorktreeOwnershipStore(databaseURL: databaseURL)
        let secondStore = WorktreeOwnershipStore(databaseURL: databaseURL)
        async let primary = c0Claim(
            firstStore,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "primary-owner"
        )
        async let linked = c0Claim(
            secondStore,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "linked-owner"
        )
        let claims = try await [primary, linked]
        try expect(Set(claims.map(\.worktreePath)).count == 2)
    }

    await test("C0 stable identity is alias-invariant and distinct across main and linked worktrees") {
        let fixture = try C0GitFixture()
        let alias = fixture.root.appendingPathComponent("identity-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.linked)
        let linked = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let aliased = try WorktreeOwnershipGuard.liveIdentity(for: alias.path)
        let main = try WorktreeOwnershipGuard.liveIdentity(for: fixture.repo.path)
        try expect(linked.stableID == aliased.stableID)
        try expect(linked.stableID != main.stableID)
        try expect(linked.stableID.hasPrefix("git-worktree-v3:"))
        try expect(linked.stableID.split(separator: ":").count == 12)
        try expect(linked.commonGitDirectory == main.commonGitDirectory)
        try expect(linked.worktreeGitDirectory != main.worktreeGitDirectory)
    }

    await test("C0 remove and recreate at the same path produces a new stable identity") {
        let fixture = try C0GitFixture()
        let original = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        try c0Run("/usr/bin/git", ["worktree", "remove", "--force", fixture.linked.path], cwd: fixture.repo)
        try c0Run(
            "/usr/bin/git",
            ["worktree", "add", "-b", "packet/c0-recreated", fixture.linked.path, fixture.baseSHA],
            cwd: fixture.repo
        )
        let recreated = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        try expect(original.stableID != recreated.stableID)
    }

    await test("C0 held permit blocks a second process and permits acquisition after release") {
        let fixture = try C0GitFixture()
        let databaseURL = fixture.databaseURL("permit-process")
        let store = WorktreeOwnershipStore(databaseURL: databaseURL)
        _ = try await c0Claim(
            store, fixture: fixture, worktree: fixture.linked,
            branch: "packet/c0-linked", owner: "owner"
        )
        let ready = fixture.root.appendingPathComponent("permit-ready")
        let release = fixture.root.appendingPathComponent("permit-release")
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let holder = Process()
        holder.executableURL = binary
        holder.arguments = [
            "--worktree-ownership-permit-probe", databaseURL.path, "owner",
            ready.path, release.path, fixture.linked.path
        ]
        try holder.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(FileManager.default.fileExists(atPath: ready.path), "holder never acquired permit")
        let busy = await c0ErrorCode {
            let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
            _ = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        }
        try expect(busy == "worktree_busy")
        try Data().write(to: release, options: .atomic)
        try await c0WaitForChildProcess(holder, label: "C0 permit holder")
        try expect(holder.terminationStatus == 0)
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let reacquired = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        reacquired.release()
    }

    await test("C0 different worktrees hold permits concurrently across processes") {
        let fixture = try C0GitFixture()
        let databaseURL = fixture.databaseURL("permit-distinct")
        let store = WorktreeOwnershipStore(databaseURL: databaseURL)
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.repo, branch: "main", owner: "owner")
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let readyA = fixture.root.appendingPathComponent("ready-a")
        let readyB = fixture.root.appendingPathComponent("ready-b")
        let release = fixture.root.appendingPathComponent("release-both")
        let first = Process()
        first.executableURL = binary
        first.arguments = ["--worktree-ownership-permit-probe", databaseURL.path, "owner", readyA.path, release.path, fixture.repo.path]
        let second = Process()
        second.executableURL = binary
        second.arguments = ["--worktree-ownership-permit-probe", databaseURL.path, "owner", readyB.path, release.path, fixture.linked.path]
        try first.run()
        try second.run()
        let deadline = Date().addingTimeInterval(10)
        while (!FileManager.default.fileExists(atPath: readyA.path)
               || !FileManager.default.fileExists(atPath: readyB.path)), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(FileManager.default.fileExists(atPath: readyA.path))
        try expect(FileManager.default.fileExists(atPath: readyB.path))
        try Data().write(to: release, options: .atomic)
        try await c0WaitForChildProcess(first, label: "C0 distinct permit A")
        try await c0WaitForChildProcess(second, label: "C0 distinct permit B")
        try expect(first.terminationStatus == 0 && second.terminationStatus == 0)
    }

    await test("C0 deterministic multi-lock ordering fails fast and releases partial acquisitions") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("multi-lock"))
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.repo, branch: "main", owner: "owner")
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        let main = try WorktreeOwnershipGuard.liveIdentity(for: fixture.repo.path)
        let linked = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let first = try await store.executionPermit(identities: [main, linked], ownerSession: "owner")
        let busy = await c0ErrorCode {
            _ = try await store.executionPermit(identities: [linked, main], ownerSession: "owner")
        }
        try expect(busy == "worktree_busy")
        first.release()
        let second = try await store.executionPermit(identities: [linked, main], ownerSession: "owner")
        second.release()
    }

    await test("C0 claim and release contend with an active execution permit") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("claim-release-lock"))
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let permit = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        let releaseBusy = await c0ErrorCode {
            _ = try await store.release(
                worktreePath: fixture.linked.path,
                ownerSession: "owner",
                disposition: .cleanReleasable,
                recoveryNote: nil
            )
        }
        try expect(releaseBusy == "worktree_busy")
        let claimBusy = await c0ErrorCode {
            _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        }
        try expect(claimBusy == "worktree_busy")
        permit.release()
    }

    await test("C0 issued permit survives claim expiry but new permits do not") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("expiry-permit"))
        let claimNow = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await c0Claim(
            store, fixture: fixture, worktree: fixture.linked,
            branch: "packet/c0-linked", owner: "owner", ttl: 60, now: claimNow
        )
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let permit = try await store.executionPermit(
            identities: [identity], ownerSession: "owner", now: claimNow.addingTimeInterval(30)
        )
        try expect(permit.stableIDs.contains(identity.stableID))
        permit.release()
        let stale = await c0ErrorCode {
            _ = try await store.executionPermit(
                identities: [identity], ownerSession: "owner", now: claimNow.addingTimeInterval(61)
            )
        }
        try expect(stale == "worktree_stale_recovery_required")
    }

    await test("C0 task-local permit supports nested same-target authorization only") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("nested"))
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let permit = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        try await WorktreeOwnershipGuard.$currentPermit.withValue(permit) {
            let nested = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "file_write",
                arguments: .object([
                    "path": .string(fixture.linked.appendingPathComponent("nested.txt").path),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
            try expect(nested != nil)
            let extensionCode = await c0ErrorCode {
                _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "file_move",
                    arguments: .object([
                        "sourcePath": .string(fixture.linked.appendingPathComponent("a").path),
                        "destinationPath": .string(fixture.repo.appendingPathComponent("b").path),
                        "ownerSession": .string("owner")
                    ]),
                    store: store
                )
            }
            try expect(extensionCode == "worktree_busy")
            nested?.release()
        }
        permit.release()
    }

    await test("C0 nested authorization retains exclusion until its handler finishes") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("nested-lease"))
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let rootPermit = try await store.executionPermit(
            identities: [identity],
            ownerSession: "owner"
        )
        let nestedAuthorization = try await WorktreeOwnershipGuard.$currentPermit.withValue(rootPermit) {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "file_write",
                arguments: .object([
                    "path": .string(fixture.linked.appendingPathComponent("nested-race.txt").path),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
        }
        try expect(nestedAuthorization != nil)
        rootPermit.release()

        let stillBusy = await c0ErrorCode {
            _ = try await store.executionPermit(
                identities: [identity],
                ownerSession: "owner"
            )
        }
        try expect(stillBusy == "worktree_busy")

        nestedAuthorization?.release()
        let afterNestedCompletion = try await store.executionPermit(
            identities: [identity],
            ownerSession: "owner"
        )
        afterNestedCompletion.release()
    }

    await test("C0 released task-local permit cannot escape into a child task") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("escaped-permit"))
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let permit = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        try await WorktreeOwnershipGuard.$currentPermit.withValue(permit) {
            let child = Task {
                try await Task.sleep(nanoseconds: 75_000_000)
                return await c0ErrorCode {
                    _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                        toolName: "file_write",
                        arguments: .object([
                            "path": .string(fixture.linked.appendingPathComponent("escaped.txt").path),
                            "ownerSession": .string("owner")
                        ]),
                        store: store
                    )
                }
            }
            permit.release()
            let code = try await child.value
            try expect(code == "worktree_busy")
        }
    }

    await test("C0 lock storage is private, rejects symlinks, and tolerates stale files") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("lock-security"))
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let first = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        let lockFile = try await store.lockFileURL(worktreePath: fixture.linked.path)
        let lockDirectory = URL(fileURLWithPath: try await store.lockDirectoryPath())
        var directoryStat = stat()
        var fileStat = stat()
        try expect(Darwin.lstat(lockDirectory.path, &directoryStat) == 0)
        try expect(Darwin.lstat(lockFile.path, &fileStat) == 0)
        try expect((directoryStat.st_mode & 0o777) == 0o700)
        try expect((fileStat.st_mode & 0o777) == 0o600)
        first.release()
        let staleFilePermit = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        staleFilePermit.release()
        let hardLink = lockDirectory.appendingPathComponent("hardlink-alias.lock")
        try FileManager.default.linkItem(at: lockFile, to: hardLink)
        let hardLinkCode = await c0ErrorCode {
            _ = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        }
        try expect(hardLinkCode == "worktree_ownership_storage_failed")
        try FileManager.default.removeItem(at: hardLink)
        try FileManager.default.removeItem(at: lockFile)
        try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: fixture.repo.appendingPathComponent("README.md"))
        let symlinkCode = await c0ErrorCode {
            _ = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        }
        try expect(symlinkCode == "worktree_ownership_storage_failed")
    }

    await test("C0 lock directory replacement with a symlink fails closed") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("lock-dir-symlink"))
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let lockDirectory = URL(fileURLWithPath: try await store.lockDirectoryPath())
        try FileManager.default.removeItem(at: lockDirectory)
        let redirect = fixture.root.appendingPathComponent("redirected-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: redirect, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lockDirectory, withDestinationURL: redirect)
        let code = await c0ErrorCode {
            _ = try await store.executionPermit(identities: [identity], ownerSession: "owner")
        }
        try expect(code == "worktree_ownership_storage_failed")
        try expect((try FileManager.default.contentsOfDirectory(atPath: redirect.path)).isEmpty)
    }

    await test("C0 missing and foreign ownership fail before mutation") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let missing = await c0ErrorCode {
            try await store.authorize(path: fixture.linked.path, ownerSession: "owner-a")
        }
        try expect(missing == "worktree_ownership_required")
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        let foreign = await c0ErrorCode {
            try await store.authorize(path: fixture.linked.path, ownerSession: "owner-b")
        }
        try expect(foreign == "worktree_foreign_ownership")
    }

    await test("C0 owner remains authorized after an intentional branch switch") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        try c0Run("/usr/bin/git", ["switch", "-c", "drifted"], cwd: fixture.linked)
        try await store.authorize(path: fixture.linked.path, ownerSession: "owner-a")
        let foreign = await c0ErrorCode {
            try await store.authorize(path: fixture.linked.path, ownerSession: "owner-b")
        }
        try expect(foreign == "worktree_foreign_ownership")
    }

    await test("C0 stable identity and ownership survive git worktree move") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let before = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        let moved = fixture.root.appendingPathComponent("linked-moved", isDirectory: true)
        try c0Run(
            "/usr/bin/git",
            ["worktree", "move", fixture.linked.path, moved.path],
            cwd: fixture.repo
        )
        let after = try WorktreeOwnershipGuard.liveIdentity(for: moved.path)
        try expect(before.stableID == after.stableID)
        try await store.authorize(path: moved.path, ownerSession: "owner-a")
        let record = try await store.record(worktreePath: moved.path)
        try expect(record?.tuple.worktreePath == fixture.linked.path, "claim-time path remains provenance")
    }

    await test("C0 expired claim remains stale metadata and recovery mutates no Git or files") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let oldNow = Date(timeIntervalSinceNow: -180)
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a",
            ttl: 60,
            now: oldNow
        )
        let headBefore = try c0Run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: fixture.linked).stdout
        let statusBefore = try c0Run("/usr/bin/git", ["status", "--porcelain"], cwd: fixture.linked).stdout
        let stale = await c0ErrorCode {
            try await store.authorize(path: fixture.linked.path, ownerSession: "owner-a")
        }
        try expect(stale == "worktree_stale_recovery_required")
        let reClaim = await c0ErrorCode {
            _ = try await c0Claim(
                store,
                fixture: fixture,
                worktree: fixture.linked,
                branch: "packet/c0-linked",
                owner: "owner-b"
            )
        }
        try expect(reClaim == "worktree_stale_recovery_required")
        _ = try await store.release(
            worktreePath: fixture.linked.path,
            ownerSession: "owner-a",
            disposition: .abandonedWithRecoveryNote,
            recoveryNote: "Expired owner closed explicitly; preserve the worktree for inspection."
        )
        let headAfter = try c0Run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: fixture.linked).stdout
        let statusAfter = try c0Run("/usr/bin/git", ["status", "--porcelain"], cwd: fixture.linked).stdout
        try expect(headAfter == headBefore)
        try expect(statusAfter == statusBefore)
        let record = try await store.record(worktreePath: fixture.linked.path)
        try expect(record?.disposition == .abandonedWithRecoveryNote)
        try expect(record?.recoveryNote?.contains("preserve") == true)
    }

    await test("C0 release dispositions are evidence-backed and fail closed") {
        let cleanFixture = try C0GitFixture()
        let cleanStore = WorktreeOwnershipStore(databaseURL: cleanFixture.databaseURL())
        _ = try await c0Claim(
            cleanStore,
            fixture: cleanFixture,
            worktree: cleanFixture.linked,
            branch: "packet/c0-linked",
            owner: "clean-owner"
        )
        let cleanEvidence = try await cleanStore.release(
            worktreePath: cleanFixture.linked.path,
            ownerSession: "clean-owner",
            disposition: .cleanReleasable,
            recoveryNote: nil
        )
        try expect(cleanEvidence.isClean == true)
        try expect(cleanEvidence.uniqueCommitCount == 0)

        let uniqueFixture = try C0GitFixture()
        let uniqueStore = WorktreeOwnershipStore(databaseURL: uniqueFixture.databaseURL())
        _ = try await c0Claim(
            uniqueStore,
            fixture: uniqueFixture,
            worktree: uniqueFixture.linked,
            branch: "packet/c0-linked",
            owner: "unique-owner"
        )
        try uniqueFixture.commitUniqueFile(in: uniqueFixture.linked)
        let wrongDisposition = await c0ErrorCode {
            _ = try await uniqueStore.release(
                worktreePath: uniqueFixture.linked.path,
                ownerSession: "unique-owner",
                disposition: .cleanReleasable,
                recoveryNote: nil
            )
        }
        try expect(wrongDisposition == "invalid_arguments")
        let uniqueEvidence = try await uniqueStore.release(
            worktreePath: uniqueFixture.linked.path,
            ownerSession: "unique-owner",
            disposition: .preserveWithUniqueCommits,
            recoveryNote: nil
        )
        try expect((uniqueEvidence.uniqueCommitCount ?? 0) > 0)

        let reviewFixture = try C0GitFixture()
        let reviewStore = WorktreeOwnershipStore(databaseURL: reviewFixture.databaseURL())
        _ = try await c0Claim(
            reviewStore,
            fixture: reviewFixture,
            worktree: reviewFixture.linked,
            branch: "packet/c0-linked",
            owner: "review-owner"
        )
        try "dirty".write(
            to: reviewFixture.linked.appendingPathComponent("dirty.txt"),
            atomically: true,
            encoding: .utf8
        )
        let reviewEvidence = try await reviewStore.release(
            worktreePath: reviewFixture.linked.path,
            ownerSession: "review-owner",
            disposition: .preserveForReview,
            recoveryNote: nil
        )
        try expect(reviewEvidence.isClean == false)
    }

    await test("C0 exact same-owner release retry is idempotent and preserves one history row") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        let first = try await store.release(
            worktreePath: fixture.linked.path,
            ownerSession: "owner-a",
            disposition: .cleanReleasable,
            recoveryNote: nil
        )
        let retry = try await store.release(
            worktreePath: fixture.linked.path,
            ownerSession: "owner-a",
            disposition: .cleanReleasable,
            recoveryNote: nil
        )
        try expect(first == retry)
        let history = try await store.releaseHistory(worktreePath: fixture.linked.path)
        try expect(history.count == 1, "release retry must not append duplicate history")
        let mismatched = await c0ErrorCode {
            _ = try await store.release(
                worktreePath: fixture.linked.path,
                ownerSession: "owner-a",
                disposition: .preserveForReview,
                recoveryNote: nil
            )
        }
        try expect(mismatched == "invalid_arguments")
    }

    await test("C0 release history survives a later claim on the same path") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "first-owner"
        )
        _ = try await store.release(
            worktreePath: fixture.linked.path,
            ownerSession: "first-owner",
            disposition: .cleanReleasable,
            recoveryNote: nil
        )
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "second-owner"
        )
        let history = try await store.releaseHistory(worktreePath: fixture.linked.path)
        try expect(history.count == 1)
        try expect(history[0].tuple.ownerSession == "first-owner")
        try expect(history[0].disposition == .cleanReleasable)
        try expect(history[0].releaseEvidence?.uniqueCommitCount == 0)
    }

    await test("C0 read-only Git and dry-run patch bypass ownership") {
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "git_status",
            arguments: .object([:])
        )
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "git_apply_patch",
            arguments: .object([
                "cwd": .string("/not/a/repository"),
                "check": .bool(true),
                "index": .bool(false),
                "commit": .bool(false)
            ])
        )
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "file_edit",
            arguments: .object([
                "path": .string("/not/a/repository/file"),
                "preview": .bool(true)
            ])
        )
    }

    await test("C0 guard authorizes every current direct mutation target") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        let file = fixture.linked.appendingPathComponent("nested/new.txt").path
        let direct: [(String, [String: Value])] = [
            ("git_apply_patch", ["cwd": .string(fixture.linked.path), "ownerSession": .string("owner")]),
            ("git_create_branch", ["cwd": .string(fixture.linked.path), "ownerSession": .string("owner")]),
            ("file_edit", ["path": .string(file), "ownerSession": .string("owner")]),
            ("file_write", ["path": .string(file), "ownerSession": .string("owner")]),
            ("file_append", ["path": .string(file), "ownerSession": .string("owner")]),
            ("file_rename", ["path": .string(file), "ownerSession": .string("owner")]),
            ("file_copy", ["destinationPath": .string(file), "ownerSession": .string("owner")]),
            ("dir_create", ["path": .string(fixture.linked.appendingPathComponent("new-dir").path), "ownerSession": .string("owner")]),
            ("file_zip", ["archivePath": .string(fixture.linked.appendingPathComponent("archive.zip").path), "ownerSession": .string("owner")]),
            ("file_unzip", ["destinationPath": .string(fixture.linked.appendingPathComponent("unzipped").path), "ownerSession": .string("owner")])
        ]
        for (tool, arguments) in direct {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: tool,
                arguments: .object(arguments),
                store: store
            )
        }
    }

    await test("C0 move across worktrees requires ownership of both paths") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        let arguments: Value = .object([
            "sourcePath": .string(fixture.linked.appendingPathComponent("source.txt").path),
            "destinationPath": .string(fixture.repo.appendingPathComponent("dest.txt").path),
            "ownerSession": .string("owner")
        ])
        let missingSecond = await c0ErrorCode {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "file_move",
                arguments: arguments,
                store: store
            )
        }
        try expect(missingSecond == "worktree_ownership_required")
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "owner"
        )
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "file_move",
            arguments: arguments,
            store: store
        )
    }

    await test("C0 file_rename authorizes source and computed destination worktrees") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        let source = fixture.linked.appendingPathComponent("nested/source.txt").path
        let arguments: Value = .object([
            "path": .string(source),
            "newName": .string("../../repo/destination.txt"),
            "ownerSession": .string("owner")
        ])
        let missingDestinationClaim = await c0ErrorCode {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "file_rename",
                arguments: arguments,
                store: store
            )
        }
        try expect(missingDestinationClaim == "worktree_ownership_required")
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "owner"
        )
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "file_rename",
            arguments: arguments,
            store: store
        )
    }

    await test("C0 copy and archive authorize mutated outputs, not read-only sources") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("direct-policy"))
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.repo, branch: "main", owner: "owner")
        let source = fixture.linked.appendingPathComponent("README.md").path
        for (tool, arguments) in [
            ("file_copy", Value.object([
                "sourcePath": .string(source),
                "destinationPath": .string(fixture.repo.appendingPathComponent("copy.txt").path),
                "ownerSession": .string("owner")
            ])),
            ("file_zip", Value.object([
                "sourcePath": .string(source),
                "archivePath": .string(fixture.repo.appendingPathComponent("archive.zip").path),
                "ownerSession": .string("owner")
            ]))
        ] {
            let permit = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: tool, arguments: arguments, store: store
            )
            permit?.release()
        }
    }

    await test("C0 shell Git reads remain lease-free, including -C") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let command = "git -C '\(fixture.linked.path)' status --porcelain"
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "shell_exec",
            arguments: .object([
                "workingDir": .string(fixture.repo.path),
                "command": .string(command)
            ]),
            store: store
        )
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "shell_exec",
            arguments: .object([
                "workingDir": .string(fixture.repo.path),
                "command": .string("git -C '\(fixture.linked.path)' worktree list")
            ]),
            store: store
        )
    }

    await test("C0 Git worktree mutations authorize the effective worktree, not the launch directory") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "owner-a"
        )
        let command = "git -C '\(fixture.linked.path)' switch --detach"
        let wrongOwnerArguments: Value = .object([
            "workingDir": .string(fixture.repo.path),
            "command": .string(command),
            "ownerSession": .string("owner-a")
        ])
        let missingEffectiveClaim = await c0ErrorCode {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: wrongOwnerArguments,
                store: store
            )
        }
        try expect(missingEffectiveClaim == "worktree_ownership_required")

        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-b"
        )
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "shell_exec",
            arguments: .object([
                "workingDir": .string(fixture.repo.path),
                "command": .string(command),
                "ownerSession": .string("owner-b")
            ]),
            store: store
        )
    }

    await test("C0 Git worktree mutations authorize every existing operand worktree") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "owner"
        )
        let removeArguments: Value = .object([
            "workingDir": .string(fixture.repo.path),
            "command": .string("git worktree remove '\(fixture.linked.path)'"),
            "ownerSession": .string("owner")
        ])
        let missingLinkedClaim = await c0ErrorCode {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: removeArguments,
                store: store
            )
        }
        try expect(missingLinkedClaim == "worktree_ownership_required")
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "shell_exec",
            arguments: removeArguments,
            store: store
        )
        let moveTargets = WorktreeOwnershipGuard.commandCandidateDirectories(
            "git -C '\(fixture.repo.path)' worktree move '\(fixture.linked.path)' '\(fixture.root.appendingPathComponent("moved").path)'",
            relativeTo: fixture.root.path
        )
        try expect(moveTargets.contains(fixture.repo.path))
        try expect(moveTargets.contains(fixture.linked.path))
    }

    await test("C0 shell guard fails closed for a bare --git-dir target") {
        let fixture = try C0GitFixture()
        let bare = fixture.root.appendingPathComponent("bare.git", isDirectory: true)
        try c0Run("/usr/bin/git", ["init", "--bare", bare.path], cwd: fixture.root)
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "owner"
        )
        let arguments: Value = .object([
            "workingDir": .string(fixture.repo.path),
            "command": .string("git --git-dir '\(bare.path)' config --local core.bare true"),
            "ownerSession": .string("owner")
        ])
        let code = await c0ErrorCode {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: arguments,
                store: store
            )
        }
        try expect(code == "worktree_ownership_required")
    }

    await test("C0 shell analysis returns the complete affected-directory set") {
        let base = "/tmp/base"
        func expectNormalizedCandidates(_ actual: [String], equal expected: [String]) throws {
            let normalize: (String) -> String = {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
            try expect(actual.count == expected.count)
            try expect(actual.map(normalize).sorted() == expected.map(normalize).sorted())
        }
        let genericCommands = [
            "pwd",
            "git status --porcelain",
            "swift build -c debug",
            "echo harmless"
        ]
        for command in genericCommands {
            try expect(
                WorktreeOwnershipGuard.commandCandidateDirectories(
                    command,
                    relativeTo: base
                ) == [base],
                "expected generic shell execution directory for \(command)"
            )
            try expect(WorktreeOwnershipGuard.isConsequentialCommand(command))
        }
        try expectNormalizedCandidates(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "./scripts/update-fixture.sh",
                relativeTo: base
            ),
            equal: [base, "/tmp/base/scripts/update-fixture.sh"]
        )
        try expect(WorktreeOwnershipGuard.isConsequentialCommand("./scripts/update-fixture.sh"))
        try expectNormalizedCandidates(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "bash ./scripts/update-fixture.sh",
                relativeTo: base
            ),
            equal: [base, "/tmp/base/scripts/update-fixture.sh"]
        )
        try expectNormalizedCandidates(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "env -C /tmp/other sh ./scripts/promote.sh",
                relativeTo: base
            ),
            equal: ["/tmp/other", "/tmp/other/scripts/promote.sh"]
        )

        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "env -C /tmp/two pwd",
                relativeTo: base
            ) == ["/tmp/two"]
        )
        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "sudo -D /tmp/two pwd",
                relativeTo: base
            ) == ["/tmp/two"]
        )
        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "sudo --chdir=/tmp/two pwd",
                relativeTo: base
            ) == ["/tmp/two"]
        )
        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "pwd && env -C /tmp/two pwd",
                relativeTo: base
            ) == [base, "/tmp/two"]
        )
        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "git -C /tmp/two status --porcelain",
                relativeTo: base
            ) == ["/tmp/two"]
        )
        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "printf x > /tmp/two/output.txt",
                relativeTo: base
            ) == ["/tmp/two/output.txt", base]
        )
        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "printf x >& /tmp/two/output.txt",
                relativeTo: base
            ) == ["/tmp/two/output.txt", base]
        )
        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "command cd /tmp/two && pwd",
                relativeTo: base
            ) == ["/tmp/two"]
        )
        try expect(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "cd /tmp/two > /tmp/base/cd.log && pwd",
                relativeTo: base
            ) == ["/tmp/base/cd.log", "/tmp/two"]
        )
        let candidates = WorktreeOwnershipGuard.commandCandidateDirectories(
            "cd '/tmp/one' && git commit -m x; make -C /tmp/two release",
            relativeTo: base
        )
        try expect(candidates == ["/tmp/one", "/tmp/two"])
        let gitDirTargets = WorktreeOwnershipGuard.commandCandidateDirectories(
            "git --git-dir '/tmp/repo/.git' config --local user.name test",
            relativeTo: base
        )
        try expect(gitDirTargets == [base, "/tmp/repo"])
        let splitGitTargets = WorktreeOwnershipGuard.commandCandidateDirectories(
            "git --git-dir '/tmp/repo/.git' --work-tree '/tmp/other' config --local user.name test",
            relativeTo: base
        )
        try expect(splitGitTargets == [base, "/tmp/repo", "/tmp/other"])
        let gitEnvironmentTargets = WorktreeOwnershipGuard.commandCandidateDirectories(
            "GIT_DIR='/tmp/repo/.git' GIT_WORK_TREE='/tmp/other' git status --porcelain",
            relativeTo: base
        )
        try expect(gitEnvironmentTargets == ["/tmp/repo", "/tmp/other", base])
        let coreWorktreeTargets = WorktreeOwnershipGuard.commandCandidateDirectories(
            "git -c core.worktree=/tmp/other status --porcelain",
            relativeTo: base
        )
        try expect(coreWorktreeTargets == [base, "/tmp/other"])
        let swiftTargets = WorktreeOwnershipGuard.commandCandidateDirectories(
            "swift build --package-path /tmp/package --scratch-path /tmp/output",
            relativeTo: base
        )
        try expect(swiftTargets == ["/tmp/package", "/tmp/output"])
        let externalScriptTargets = WorktreeOwnershipGuard.commandCandidateDirectories(
            "/tmp/claimed/scripts/promote.sh --candidate /tmp/out",
            relativeTo: base
        )
        try expectNormalizedCandidates(
            externalScriptTargets,
            equal: [base, "/tmp/claimed/scripts/promote.sh"]
        )
        let stdinScriptCases = [
            "bash - < /tmp/claimed/scripts/stdin.sh",
            "sh -s < /tmp/claimed/scripts/stdin.sh",
            "zsh < /tmp/claimed/scripts/stdin.sh",
            "command bash - < /tmp/claimed/scripts/stdin.sh"
        ]
        for command in stdinScriptCases {
            try expectNormalizedCandidates(
                WorktreeOwnershipGuard.commandCandidateDirectories(command, relativeTo: base),
                equal: [base, "/tmp/claimed/scripts/stdin.sh"]
            )
        }

        let absoluteMakefileCases = [
            "make -f /tmp/claimed/Makefile install",
            "make --file /tmp/claimed/Makefile install",
            "make --makefile /tmp/claimed/Makefile install",
            "make -f/tmp/claimed/Makefile install",
            "make --file=/tmp/claimed/Makefile install",
            "make --makefile=/tmp/claimed/Makefile install"
        ]
        for command in absoluteMakefileCases {
            try expectNormalizedCandidates(
                WorktreeOwnershipGuard.commandCandidateDirectories(command, relativeTo: base),
                equal: [base, "/tmp/claimed/Makefile"]
            )
        }

        let orderedMakefileCases = [
            "make -C /tmp/project/build -f ../Makefile install",
            "make -f ../Makefile -C /tmp/project/build install",
            "make -C/tmp/project/build -f../Makefile install",
            "make -f../Makefile -C/tmp/project/build install",
            "make --directory /tmp/project/build --file ../Makefile install",
            "make --file ../Makefile --directory /tmp/project/build install",
            "make --directory=/tmp/project/build --file=../Makefile install",
            "make --file=../Makefile --directory=/tmp/project/build install",
            "make -C /tmp/project/build --makefile ../Makefile install",
            "make --makefile=../Makefile -C /tmp/project/build install"
        ]
        for command in orderedMakefileCases {
            try expectNormalizedCandidates(
                WorktreeOwnershipGuard.commandCandidateDirectories(command, relativeTo: base),
                equal: ["/tmp/project/build", "/tmp/project/Makefile"]
            )
        }

        try expectNormalizedCandidates(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "make -f ../Makefile -C /tmp/project -C build install",
                relativeTo: base
            ),
            equal: ["/tmp/project/build", "/tmp/project/Makefile"]
        )
        try expectNormalizedCandidates(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "make -f ../Makefile -C /tmp/project --directory=build install",
                relativeTo: base
            ),
            equal: ["/tmp/project/build", "/tmp/project/Makefile"]
        )
        try expectNormalizedCandidates(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "make -f ../Makefile --file ../config/Release.mk -C /tmp/project/build install",
                relativeTo: base
            ),
            equal: ["/tmp/project/build", "/tmp/project/Makefile", "/tmp/project/config/Release.mk"]
        )
        try expectNormalizedCandidates(
            WorktreeOwnershipGuard.commandCandidateDirectories(
                "make -f '../Release Makefile' -C '/tmp/project/build space' install",
                relativeTo: base
            ),
            equal: ["/tmp/project/build space", "/tmp/project/Release Makefile"]
        )
    }

    await test("C0 Git environment path controls require ownership of their target worktree") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("git-env"))
        let command = "GIT_WORK_TREE='\(fixture.linked.path)' git status --porcelain"
        let missing = await c0ErrorCode {
            _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.root.path),
                    "command": .string(command)
                ]),
                store: store
            )
        }
        try expect(missing == "worktree_ownership_required")
        _ = try await c0Claim(store, fixture: fixture, worktree: fixture.linked, branch: "packet/c0-linked", owner: "owner")
        let permit = try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "shell_exec",
            arguments: .object([
                "workingDir": .string(fixture.root.path),
                "command": .string(command),
                "ownerSession": .string("owner")
            ]),
            store: store
        )
        permit?.release()
    }

    await test("C0 shell_exec env Git path controls are governed") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("tool-env"))
        let identity = try WorktreeOwnershipGuard.liveIdentity(for: fixture.linked.path)
        let indexPath = URL(fileURLWithPath: identity.worktreeGitDirectory)
            .appendingPathComponent("index").path
        let arguments: Value = .object([
            "workingDir": .string(fixture.root.path),
            "command": .string("git status --porcelain"),
            "env": .object([
                "GIT_WORK_TREE": .string(fixture.linked.path),
                "GIT_INDEX_FILE": .string(indexPath)
            ])
        ])
        let missing = await c0ErrorCode {
            _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: arguments,
                store: store
            )
        }
        try expect(missing == "worktree_ownership_required")

        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        guard case .object(var ownedArguments) = arguments else {
            throw TestError.assertion("expected shell arguments object")
        }
        ownedArguments["ownerSession"] = .string("owner")
        let authorization = try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "shell_exec",
            arguments: .object(ownedArguments),
            store: store
        )
        authorization?.release()

        let dynamic = await c0ErrorCode {
            _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.root.path),
                    "command": .string("git status --porcelain"),
                    "env": .object(["GIT_WORK_TREE": .int(1)]),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
        }
        try expect(dynamic == "worktree_target_unresolved")
    }

    await test("C0 static Git configuration is lease-free only for core.worktree reads") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("core-worktree"))
        let commands = [
            "git -c core.worktree='\(fixture.linked.path)' status --porcelain",
            "git -ccore.worktree='\(fixture.linked.path)' status --porcelain"
        ]
        for command in commands {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.root.path),
                    "command": .string(command)
                ]),
                store: store
            )
        }

        for command in [
            "git -c core.worktree=relative status --porcelain",
            "git --config-env=core.worktree=TARGET status --porcelain"
        ] {
            let unresolved = await c0ErrorCode {
                _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "shell_exec",
                    arguments: .object([
                        "workingDir": .string(fixture.root.path),
                        "command": .string(command),
                        "ownerSession": .string("owner")
                    ]),
                    store: store
                )
            }
            try expect(unresolved == "worktree_target_unresolved")
        }

        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        for command in [
            "git -c alias.c0-opaque='!touch /tmp/c0-foreign-target' c0-opaque",
            "git c0-opaque"
        ] {
            let aliasEscape = await c0ErrorCode {
                _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "shell_exec",
                    arguments: .object([
                        "workingDir": .string(fixture.linked.path),
                        "command": .string(command),
                        "ownerSession": .string("owner")
                    ]),
                    store: store
                )
            }
            try expect(aliasEscape == "worktree_target_unresolved")
        }
    }

    await test("C0 Swift package commands fail closed even when every visible worktree is claimed") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("swiftpm-paths"))
        let output = fixture.repo.appendingPathComponent(".build-c0").path
        let command = "swift build --package-path '\(fixture.linked.path)' --scratch-path '\(output)'"

        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        let unowned = await c0ErrorCode {
            _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.root.path),
                    "command": .string(command),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
        }
        try expect(unowned == "worktree_target_unresolved")

        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "owner"
        )
        let owned = await c0ErrorCode {
            _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.root.path),
                    "command": .string(command),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
        }
        try expect(owned == "worktree_target_unresolved")

        let dynamic = await c0ErrorCode {
            _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.root.path),
                    "command": .string("swift build --package-path $PACKAGE_PATH"),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
        }
        try expect(dynamic == "worktree_target_unresolved")
    }

    await test("C0 admits statically analyzable shell mutations under ownership") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let commands = [
            "rm README.md",
            "cp source.txt copied.txt",
            "printf x > redirected.txt",
            "bash -c 'printf x > inline-interpreter.txt'"
        ]
        for command in commands {
            let missing = await c0ErrorCode {
                try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "shell_exec",
                    arguments: .object([
                        "workingDir": .string(fixture.linked.path),
                        "command": .string(command)
                    ]),
                    store: store
                )
            }
            try expect(
                missing == "worktree_ownership_required",
                "expected ownership denial for \(command), got \(missing ?? "nil")"
            )
        }

        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        for command in commands {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.linked.path),
                    "command": .string(command),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
        }

        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "shell_exec",
            arguments: .object([
                "workingDir": .string(fixture.linked.path),
                "command": .string("git status --porcelain")
            ]),
            store: store
        )

        let scriptDirectory = fixture.linked.appendingPathComponent("scripts", isDirectory: true)
        let buildDirectory = fixture.linked.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        let directScript = scriptDirectory.appendingPathComponent("direct.sh").path
        let interpretedScript = scriptDirectory.appendingPathComponent("interpreted.sh").path
        let makefile = fixture.linked.appendingPathComponent("Makefile").path
        let nestedBuildDirectory = buildDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedBuildDirectory, withIntermediateDirectories: true)
        let opaqueTargetCommands = [
            directScript,
            "python3 -c 'print(\"opaque\")'",
            "npm run build",
            "bash '\(interpretedScript)'",
            "sh '\(interpretedScript)'",
            "command bash '\(interpretedScript)'",
            "env -C '\(fixture.linked.path)' zsh ./scripts/interpreted.sh",
            "bash - < '\(interpretedScript)'",
            "sh -s < '\(interpretedScript)'",
            "zsh < '\(interpretedScript)'",
            "command bash - < '\(interpretedScript)'",
            "make -f '\(makefile)' install",
            "make --file '\(makefile)' install",
            "make --makefile '\(makefile)' install",
            "make -f'\(makefile)' install",
            "make --file='\(makefile)' install",
            "make --makefile='\(makefile)' install",
            "make -C '\(buildDirectory.path)' -f ../Makefile install",
            "make -f ../Makefile -C '\(buildDirectory.path)' install",
            "make -C'\(buildDirectory.path)' -f../Makefile install",
            "make -f../Makefile -C'\(buildDirectory.path)' install",
            "make --directory '\(buildDirectory.path)' --file ../Makefile install",
            "make --file ../Makefile --directory '\(buildDirectory.path)' install",
            "make --directory='\(buildDirectory.path)' --file=../Makefile install",
            "make --file=../Makefile --directory='\(buildDirectory.path)' install",
            "make --makefile=../Makefile -C '\(buildDirectory.path)' install",
            "make -f ../../Makefile -C '\(buildDirectory.path)' -C nested install",
            "make -f ../../Makefile -C '\(buildDirectory.path)' --directory=nested install",
            "make -f ../../Makefile --file ../../Release.mk -C '\(nestedBuildDirectory.path)' install"
        ]
        let targetStore = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("script-and-make-targets"))
        for command in opaqueTargetCommands {
            let code = await c0ErrorCode {
                _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "shell_exec",
                    arguments: .object([
                        "workingDir": .string(fixture.root.path),
                        "command": .string(command)
                    ]),
                    store: targetStore
                )
            }
            try expect(
                code == "worktree_target_unresolved",
                "expected opaque target denial for \(command), got \(code ?? "nil")"
            )
        }
        _ = try await c0Claim(
            targetStore,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "target-owner"
        )
        for command in opaqueTargetCommands {
            let code = await c0ErrorCode {
                _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "shell_exec",
                    arguments: .object([
                        "workingDir": .string(fixture.root.path),
                        "command": .string(command),
                        "ownerSession": .string("target-owner")
                    ]),
                    store: targetStore
                )
            }
            try expect(
                code == "worktree_target_unresolved",
                "owned opaque command was admitted: \(command) (\(code ?? "nil"))"
            )
        }
    }

    await test("C0 shell guard resolves ordinary mutation destinations from outside Git") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let destination = fixture.linked.appendingPathComponent("target.txt").path
        let targetDirectory = fixture.linked.path
        let commands = [
            "rm '\(destination)'",
            "cp source.txt '\(destination)'",
            "cp -t '\(targetDirectory)' source.txt",
            "cp -t'\(targetDirectory)' source.txt",
            "cp --target-directory='\(targetDirectory)' source.txt",
            "mv source.txt '\(destination)'",
            "mv -t '\(targetDirectory)' source.txt",
            "mv -t'\(targetDirectory)' source.txt",
            "mv --target-directory='\(targetDirectory)' source.txt",
            "mkdir '\(fixture.linked.appendingPathComponent("new-dir").path)'",
            "touch '\(destination)'",
            "ln source.txt '\(destination)'",
            "tee '\(destination)'",
            "printf x > '\(destination)'"
        ]
        for command in commands {
            let missing = await c0ErrorCode {
                try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "shell_exec",
                    arguments: .object([
                        "workingDir": .string(fixture.root.path),
                        "command": .string(command)
                    ]),
                    store: store
                )
            }
            try expect(
                missing == "worktree_ownership_required",
                "expected explicit target denial for \(command), got \(missing ?? "nil")"
            )
        }

        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        for command in commands {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.root.path),
                    "command": .string(command),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
        }
    }

    await test("C0 env and sudo directory wrappers authorize their effective worktree") {
        let fixture = try C0GitFixture()
        let firstStore = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("wrapper-a"))
        _ = try await c0Claim(
            firstStore,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "owner-a"
        )
        for command in [
            "env -C '\(fixture.linked.path)' pwd",
            "sudo -D '\(fixture.linked.path)' pwd",
            "sudo --chdir='\(fixture.linked.path)' pwd"
        ] {
            let code = await c0ErrorCode {
                try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "shell_exec",
                    arguments: .object([
                        "workingDir": .string(fixture.repo.path),
                        "command": .string(command),
                        "ownerSession": .string("owner-a")
                    ]),
                    store: firstStore
                )
            }
            try expect(code == "worktree_ownership_required")
        }

        let secondStore = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("wrapper-b"))
        _ = try await c0Claim(
            secondStore,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-b"
        )
        for command in [
            "env -C '\(fixture.linked.path)' pwd",
            "sudo -D '\(fixture.linked.path)' pwd",
            "sudo --chdir='\(fixture.linked.path)' pwd"
        ] {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.repo.path),
                    "command": .string(command),
                    "ownerSession": .string("owner-b")
                ]),
                store: secondStore
            )
        }
    }

    await test("C0 unsupported or dynamic shell targets fail as worktree_target_unresolved") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let commands = [
            "env --chdir='\(fixture.linked.path)' pwd",
            "env -S \"pwd\"",
            "env -Spwd",
            "env --split-string \"pwd\"",
            "env --split-string=pwd",
            "env -C '\(fixture.linked.path)' -S \"pwd\"",
            "sudo --chdir '\(fixture.linked.path)' pwd",
            "printf x > $OUTPUT_PATH",
            "cd $TARGET && pwd",
            "git -C $TARGET status --porcelain",
            "GIT_WORK_TREE=$TARGET git status --porcelain",
            "make -C $TARGET test",
            "make -f $MAKEFILE -C /tmp/build test",
            "make -f",
            "make --file=",
            "make -C",
            "make --directory= test",
            "cp -t",
            "mv --target-directory= source.txt",
            "if true; then cd '\(fixture.linked.path)'; fi",
            "eval '$COMMAND'",
            "source ./directory-changing-script.sh && pwd",
            "bash -c '$COMMAND'",
            "bash -",
            "sh -s",
            "zsh < $SCRIPT_PATH",
            "bash - <<EOF",
            "cat <(printf hidden)"
        ]
        for command in commands {
            let code = await c0ErrorCode {
                try await WorktreeOwnershipGuard.authorizeToolMutation(
                    toolName: "shell_exec",
                    arguments: .object([
                        "workingDir": .string(fixture.root.path),
                        "command": .string(command)
                    ]),
                    store: store
                )
            }
            try expect(
                code == "worktree_target_unresolved",
                "expected unresolved target for \(command), got \(code ?? "nil")"
            )
        }
    }

    await test("C0 mixed shell chains authorize the union before any segment starts") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.repo,
            branch: "main",
            owner: "owner"
        )
        let arguments: Value = .object([
            "workingDir": .string(fixture.repo.path),
            "command": .string("pwd && env -C '\(fixture.linked.path)' pwd"),
            "ownerSession": .string("owner")
        ])
        let missingLinked = await c0ErrorCode {
            try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "shell_exec",
                arguments: arguments,
                store: store
            )
        }
        try expect(missingLinked == "worktree_ownership_required")
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "shell_exec",
            arguments: arguments,
            store: store
        )
    }

    await test("C0 disabled router preserves mutation dispatch without opening the claim database") {
        let fixture = try C0GitFixture()
        let databaseURL = fixture.databaseURL("disabled-router")
        let store = WorktreeOwnershipStore(databaseURL: databaseURL)
        let probe = C0InvocationProbe()
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: store,
            worktreeOwnershipEnabled: false,
            licenseStatusProvider: { .grandfathered }
        )
        await router.register(
            ToolRegistration(
                name: "file_write",
                module: "dev",
                tier: .open,
                description: "C0 disabled-path test probe",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ) { _ in
                await probe.mark()
                return .object(["ok": .bool(true)])
            }
        )

        _ = try await router.dispatch(
            toolName: "file_write",
            arguments: .object(["path": .string(fixture.linked.appendingPathComponent("probe.txt").path)])
        )

        try await expect(probe.value() == 1)
        try expect(
            !FileManager.default.fileExists(atPath: databaseURL.path),
            "disabled C0 dispatch created the claim database"
        )
    }

    await test("C0 actual shell denial starts no handler mutation") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let target = fixture.linked.appendingPathComponent("shell-blocked.txt")
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: store,
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await ShellModule.register(on: router)
        let code = await c0ErrorCode {
            _ = try await router.dispatch(
                toolName: "shell_exec",
                arguments: .object([
                    "workingDir": .string(fixture.linked.path),
                    "command": .string("printf blocked > '\(target.path)'")
                ])
            )
        }
        try expect(code == "worktree_ownership_required")
        try expect(!FileManager.default.fileExists(atPath: target.path))
    }

    await test("C0 denied bg_run creates no process artifacts or target mutation") {
        let fixture = try C0GitFixture()
        let fakeHome = fixture.root.appendingPathComponent("bg-home", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(fakeHome)
        defer { BridgePaths.overrideHomeForTesting(nil) }

        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let target = fixture.linked.appendingPathComponent("bg-blocked.txt")
        let bgDirectory = BridgePaths.applicationSupport(.bgProcess)
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: store,
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await BgProcessModule.register(on: router)
        let code = await c0ErrorCode {
            _ = try await router.dispatch(
                toolName: "bg_run",
                arguments: .object([
                    "workingDir": .string(fixture.linked.path),
                    "command": .string("printf blocked > '\(target.path)'")
                ])
            )
        }
        try expect(code == "worktree_background_unsupported")
        try expect(!FileManager.default.fileExists(atPath: target.path))
        if FileManager.default.fileExists(atPath: bgDirectory.path) {
            let artifacts = try FileManager.default.contentsOfDirectory(atPath: bgDirectory.path)
            try expect(artifacts.isEmpty, "denied bg_run created artifacts: \(artifacts)")
        }
    }

    await test("C0 ToolRouter blocks protected handler before invocation and audits through normal pipeline") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        let probe = C0InvocationProbe()
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: store,
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await router.register(ToolRegistration(
            name: "run_script",
            module: "shell",
            tier: .open,
            description: "C0 opaque script guard probe",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in
                await probe.mark()
                return .object(["ok": .bool(true)])
            }
        ))
        let opaqueScript = await c0ErrorCode {
            _ = try await router.dispatch(
                toolName: "run_script",
                arguments: .object(["scriptName": .string("approved.sh")])
            )
        }
        try expect(opaqueScript == "worktree_target_unresolved")
        try expect(await probe.value() == 0)

        await router.register(ToolRegistration(
            name: "file_write",
            module: "dev",
            tier: .open,
            description: "C0 guard probe",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in
                await probe.mark()
                return .object(["ok": .bool(true)])
            }
        ))
        let missing = await c0ErrorCode {
            _ = try await router.dispatch(
                toolName: "file_write",
                arguments: .object([
                    "path": .string(fixture.linked.appendingPathComponent("blocked.txt").path)
                ])
            )
        }
        try expect(missing == "worktree_ownership_required")
        try expect(await probe.value() == 0)
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        _ = try await router.dispatch(
            toolName: "file_write",
            arguments: .object([
                "path": .string(fixture.linked.appendingPathComponent("allowed.txt").path),
                "ownerSession": .string("owner")
            ])
        )
        try expect(await probe.value() == 1)
    }

    await test("C0 formatted foreign mutation denial identifies target, owner state, and remedy") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: store,
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await router.register(ToolRegistration(
            name: "file_write",
            module: "dev",
            tier: .open,
            description: "C0 formatted denial probe",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .object(["ok": .bool(true)]) }
        ))

        let denied = await router.dispatchFormatted(
            toolName: "file_write",
            arguments: .object([
                "path": .string(fixture.linked.appendingPathComponent("blocked.txt").path),
                "ownerSession": .string("owner-b")
            ])
        )

        try expect(denied.isError)
        try expect(denied.text.contains("worktree_foreign_ownership"))
        try expect(denied.text.contains("target=\(fixture.linked.path)"))
        try expect(denied.text.contains("target_state=resolved"))
        try expect(denied.text.contains("owner_state=claimed_by_another_session"))
        try expect(denied.text.contains("remedy=Use a different claimed worktree"))
        try expect(!denied.text.contains("owner-a"), "denial must not disclose another ownerSession")
    }

    await test("C0 claim and release denial results carry the same structured context") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL())
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner-a"
        )
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: store,
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await WorktreeOwnershipModule.register(on: router, store: store)
        let claimResult = try await router.dispatch(
            toolName: "worktree_claim",
            arguments: .object([
                "repoRoot": .string(fixture.repo.path),
                "worktreePath": .string(fixture.linked.path),
                "branch": .string("packet/c0-linked"),
                "baseSHA": .string(fixture.baseSHA),
                "ownerSession": .string("owner-b"),
                "ttlSeconds": .int(300)
            ])
        )
        guard case .object(let claim) = claimResult,
              case .string(let status)? = claim["status"],
              case .string(let target)? = claim["target"],
              case .string(let targetState)? = claim["targetState"],
              case .string(let ownerState)? = claim["ownerState"],
              case .string(let remedy)? = claim["remedy"],
              case .string(let errorText)? = claim["error"] else {
            throw TestError.assertion("claim conflict must return a structured C0 denial")
        }
        try expect(status == "worktree_claim_conflict")
        try expect(target == fixture.linked.path)
        try expect(targetState == "resolved")
        try expect(ownerState == "claimed_by_another_session")
        try expect(remedy.contains("different claimed worktree"))
        try expect(!errorText.contains("owner-a"), "claim denial must not disclose another ownerSession")

        let releaseResult = try await router.dispatch(
            toolName: "worktree_release",
            arguments: .object([
                "worktreePath": .string(fixture.linked.path),
                "ownerSession": .string("owner-b"),
                "disposition": .string(WorktreeReleaseDisposition.preserveForReview.rawValue)
            ])
        )
        guard case .object(let release) = releaseResult,
              case .string(let releaseTarget)? = release["target"],
              case .string(let releaseOwnerState)? = release["ownerState"],
              case .string(let releaseError)? = release["error"] else {
            throw TestError.assertion("release denial must return a structured C0 denial")
        }
        try expect(releaseTarget == fixture.linked.path)
        try expect(releaseOwnerState == "claimed_by_another_session")
        try expect(!releaseError.contains("owner-a"), "release denial must redact another ownerSession")
    }

    await test("C0 unresolved run_script denial identifies unresolved target and remedy") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await router.register(ToolRegistration(
            name: "run_script",
            module: "shell",
            tier: .open,
            description: "C0 unresolved denial probe",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .object(["ok": .bool(true)]) }
        ))

        let denied = await router.dispatchFormatted(
            toolName: "run_script",
            arguments: .object(["scriptName": .string("opaque.sh")])
        )
        try expect(denied.isError)
        try expect(denied.text.contains("worktree_target_unresolved"))
        try expect(denied.text.contains("target=unresolved"))
        try expect(denied.text.contains("target_state=unresolved"))
        try expect(denied.text.contains("owner_state=not_evaluated"))
        try expect(denied.text.contains("remedy=Use shell_exec with an explicit command and workingDir"))
    }

    await test("WU0 command contract accepts only reviewed argv build/test families and bounded roots") {
        let fixture = try C0GitFixture()
        let accepted = try WorktreeCommandContract.validate(.init(
            worktreePath: fixture.linked.path,
            ownerSession: "owner",
            expectedBranch: "packet/c0-linked",
            expectedHead: fixture.baseSHA,
            executable: "/usr/bin/make",
            argv: ["test"],
            declaredWriteRoots: [".build"],
            timeoutSeconds: 60
        ))
        try expect(accepted.argv == ["test"])
        try expect(accepted.declaredWriteRoots == [fixture.linked.appendingPathComponent(".build").path])

        for (executable, argv) in [
            ("/bin/bash", ["-c", "make test"]),
            ("/usr/bin/git", ["push", "origin", "main"]),
            ("/usr/bin/make", ["install-copy"]),
            ("/usr/bin/make", ["release"]),
        ] {
            do {
                _ = try WorktreeCommandContract.validate(.init(
                    worktreePath: fixture.linked.path,
                    ownerSession: "owner",
                    expectedBranch: "packet/c0-linked",
                    expectedHead: fixture.baseSHA,
                    executable: executable,
                    argv: argv,
                    declaredWriteRoots: [".build"],
                    timeoutSeconds: 60
                ))
                throw TestError.assertion("unexpectedly admitted \(executable) \(argv)")
            } catch is WorktreeCommandError {
                // expected
            }
        }

        for root in [".", "../escaped"] {
            do {
                _ = try WorktreeCommandContract.validate(.init(
                    worktreePath: fixture.linked.path,
                    ownerSession: "owner",
                    expectedBranch: "packet/c0-linked",
                    expectedHead: fixture.baseSHA,
                    executable: "/usr/bin/make",
                    argv: ["debug"],
                    declaredWriteRoots: [root],
                    timeoutSeconds: 60
                ))
                throw TestError.assertion("unexpectedly admitted write root \(root)")
            } catch is WorktreeCommandError {
                // expected
            }
        }
    }

    await test("WU0 command runner requires the claimed owner before process launch") {
        let fixture = try C0GitFixture()
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("wu0-owner"))
        let missing = await c0ErrorCode {
            _ = try await WorktreeOwnershipGuard.authorizeToolMutation(
                toolName: "worktree_command_run",
                arguments: .object([
                    "worktreePath": .string(fixture.linked.path),
                    "ownerSession": .string("owner")
                ]),
                store: store
            )
        }
        try expect(missing == "worktree_ownership_required")
        _ = try await c0Claim(
            store,
            fixture: fixture,
            worktree: fixture.linked,
            branch: "packet/c0-linked",
            owner: "owner"
        )
        let authorization = try await WorktreeOwnershipGuard.authorizeToolMutation(
            toolName: "worktree_command_run",
            arguments: .object([
                "worktreePath": .string(fixture.linked.path),
                "ownerSession": .string("owner")
            ]),
            store: store
        )
        try expect(authorization != nil)
        authorization?.release()
    }

    await test("WU0 command runner executes argv directly and returns branch, HEAD, and digest evidence") {
        let fixture = try C0GitFixture()
        let makefile = "debug:\n\t@mkdir -p .build\n\t@printf 'runner-ok\\n' > .build/wu0-marker\n\t@printf 'wu0-stdout\\n'\n"
        try makefile.write(
            to: fixture.linked.appendingPathComponent("Makefile"),
            atomically: true,
            encoding: .utf8
        )
        try c0Run("/usr/bin/git", ["add", "Makefile"], cwd: fixture.linked)
        try c0Run("/usr/bin/git", ["commit", "-m", "add runner fixture"], cwd: fixture.linked)
        let expectedHead = try c0Run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: fixture.linked).stdout
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("wu0-live"))
        _ = try await store.claim(
            repoRoot: fixture.repo.path,
            worktreePath: fixture.linked.path,
            branch: "packet/c0-linked",
            baseSHA: expectedHead,
            ownerSession: "wu0-live",
            ttlSeconds: 300
        )
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: store,
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await WorktreeOwnershipModule.register(on: router, store: store)
        let value = try await router.dispatch(
            toolName: "worktree_command_run",
            arguments: .object([
                "worktreePath": .string(fixture.linked.path),
                "ownerSession": .string("wu0-live"),
                "expectedBranch": .string("packet/c0-linked"),
                "expectedHead": .string(expectedHead),
                "executable": .string("/usr/bin/make"),
                "argv": .array([.string("debug")]),
                "declaredWriteRoots": .array([.string(".build")]),
                "timeoutSeconds": .int(30)
            ])
        )
        guard case .object(let object) = value else {
            throw TestError.assertion("expected worktree command object")
        }
        try expect(object["ok"] == .bool(true), "runner failed: \(value)")
        try expect(object["headSHA"] == .string(expectedHead))
        try expect(object["branch"] == .string("packet/c0-linked"))
        try expect(object["stdout"] == .string("wu0-stdout\n"))
        guard case .string(let commandDigest) = object["commandSHA256"] else {
            throw TestError.assertion("missing command digest")
        }
        try expect(commandDigest.count == 64)
        let marker = try String(
            contentsOf: fixture.linked.appendingPathComponent(".build/wu0-marker"),
            encoding: .utf8
        )
        try expect(marker == "runner-ok\n")
    }

    await test("WU0 command runner detects writes outside the declared roots") {
        let fixture = try C0GitFixture()
        let makefile = "debug:\n\t@printf 'outside\\n' > outside.txt\n"
        try makefile.write(
            to: fixture.linked.appendingPathComponent("Makefile"),
            atomically: true,
            encoding: .utf8
        )
        try c0Run("/usr/bin/git", ["add", "Makefile"], cwd: fixture.linked)
        try c0Run("/usr/bin/git", ["commit", "-m", "add scope fixture"], cwd: fixture.linked)
        let expectedHead = try c0Run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: fixture.linked).stdout
        let store = WorktreeOwnershipStore(databaseURL: fixture.databaseURL("wu0-scope"))
        _ = try await store.claim(
            repoRoot: fixture.repo.path,
            worktreePath: fixture.linked.path,
            branch: "packet/c0-linked",
            baseSHA: expectedHead,
            ownerSession: "wu0-scope",
            ttlSeconds: 300
        )
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: store,
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await WorktreeOwnershipModule.register(on: router, store: store)
        let value = try await router.dispatch(
            toolName: "worktree_command_run",
            arguments: .object([
                "worktreePath": .string(fixture.linked.path),
                "ownerSession": .string("wu0-scope"),
                "expectedBranch": .string("packet/c0-linked"),
                "expectedHead": .string(expectedHead),
                "executable": .string("/usr/bin/make"),
                "argv": .array([.string("debug")]),
                "declaredWriteRoots": .array([.string(".build")]),
                "timeoutSeconds": .int(30)
            ])
        )
        guard case .object(let object) = value else {
            throw TestError.assertion("expected worktree command object")
        }
        try expect(object["ok"] == .bool(false))
        try expect(object["status"] == .string("write_scope_violation"))
        try expect(object["outsideDeclaredWriteRoots"] == .array([.string("outside.txt")]))
        try expect(object["headSHA"] == .string(expectedHead))
    }

    await test("C0 guarded public schemas expose ownerSession and tools are annotated") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipEnabled: true,
            licenseStatusProvider: { .grandfathered }
        )
        await ShellModule.register(on: router)
        await BgProcessModule.register(on: router)
        await FileModule.register(on: router)
        await CodeEditModule.register(on: router)
        await ArtifactModule.register(on: router)
        await GitModule.registerWave2(on: router)
        await GitModule.registerWave3(on: router, runtime: GitRuntime.shared)
        await WorktreeOwnershipModule.register(on: router)
        await NodeTestModule.register(on: router)
        let registrations = await router.allRegistrations()
        let guarded = Set([
            "shell_exec", "run_script", "bg_run", "worktree_command_run", "file_edit", "file_write", "file_append",
            "file_move", "file_rename", "file_copy", "dir_create", "file_zip",
            "file_unzip", "git_apply_patch", "git_create_branch", "node_test"
        ])
        let byName = Dictionary(uniqueKeysWithValues: registrations.map { ($0.name, $0) })
        for name in guarded {
            guard let registration = byName[name] else {
                throw TestError.assertion("missing registration \(name)")
            }
            try expect(c0SchemaHasOwnerSession(registration), "\(name) lacks ownerSession schema")
        }
        try expect(byName["worktree_claim"] != nil)
        try expect(byName["worktree_release"] != nil)
        try expect(
            byName["worktree_claim"]?.description.contains("(detached)") == true,
            "worktree_claim description must document detached HEAD claims"
        )
        let claimAnnotation = ToolAnnotationCatalog.annotations(for: "worktree_claim")
        let releaseAnnotation = ToolAnnotationCatalog.annotations(for: "worktree_release")
        let commandAnnotation = ToolAnnotationCatalog.annotations(for: "worktree_command_run")
        try expect(claimAnnotation?.idempotentHint == true)
        try expect(releaseAnnotation?.idempotentHint == false)
        try expect(commandAnnotation?.requiresConfirmation == true)
        try expect(BridgeConstants.staticFeatureModuleToolCount == 224)
    }
}
