// NodeTestModule.swift — U2 owner-bound foreground Node test execution.

import Foundation
import MCP
import Darwin

public struct NodeTestInvocation: Sendable, Equatable {
    public let workingDirectory: String
    public let worktreePath: String
    public let branch: String
    public let stableID: String
    public let testPaths: [String]
    public let resolvedTestPaths: [String]
}

public enum NodeTestContract {
    private static let allowedExtensions: Set<String> = ["js", "mjs", "cjs"]
    private static let maximumTestPaths = 32
    private static let maximumPathBytes = 4_096

    public static func prepare(
        workingDirectory: String,
        testPaths: [String],
        fileManager: FileManager = .default
    ) throws -> NodeTestInvocation {
        guard workingDirectory.hasPrefix("/") else {
            throw WorktreeOwnershipError.invalid("node_test workingDir must be absolute")
        }
        guard (1...maximumTestPaths).contains(testPaths.count) else {
            throw WorktreeOwnershipError.invalid(
                "node_test requires 1...\(maximumTestPaths) test paths"
            )
        }

        let canonicalWorkingDirectory = try WorktreeOwnershipGuard.canonicalPath(
            workingDirectory
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: canonicalWorkingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw WorktreeOwnershipError.invalid(
                "node_test workingDir must be an existing directory"
            )
        }

        let identity = try WorktreeOwnershipGuard.liveIdentity(
            for: canonicalWorkingDirectory
        )
        let canonicalWorktree = URL(fileURLWithPath: identity.worktreePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let canonicalWorking = URL(fileURLWithPath: canonicalWorkingDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard canonicalWorking == canonicalWorktree
                || canonicalWorking.hasPrefix(canonicalWorktree + "/") else {
            throw WorktreeOwnershipError.identityChanged(
                "node_test workingDir resolved outside its live Git worktree"
            )
        }

        var normalized: [String] = []
        var resolved: [String] = []
        for rawPath in testPaths {
            guard !rawPath.isEmpty,
                  rawPath.utf8.count <= maximumPathBytes,
                  !rawPath.hasPrefix("/"),
                  !rawPath.hasPrefix("~"),
                  !rawPath.contains("$"),
                  !rawPath.contains("`"),
                  !rawPath.contains("\n"),
                  !rawPath.contains("\r"),
                  !rawPath.unicodeScalars.contains(where: { $0.value == 0 }),
                  !rawPath.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0 == ".." }) else {
                throw WorktreeOwnershipError.targetUnresolved(
                    "node_test path is not a static relative test path: \(rawPath)"
                )
            }

            let candidate = URL(fileURLWithPath: canonicalWorking)
                .appendingPathComponent(rawPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard candidate.path.hasPrefix(canonicalWorking + "/") else {
                throw WorktreeOwnershipError.targetUnresolved(
                    "node_test path escapes workingDir: \(rawPath)"
                )
            }
            let extensionName = candidate.pathExtension.lowercased()
            guard allowedExtensions.contains(extensionName) else {
                throw WorktreeOwnershipError.invalid(
                    "node_test accepts only .js, .mjs, or .cjs test files"
                )
            }
            var candidateIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &candidateIsDirectory
            ), !candidateIsDirectory.boolValue else {
                throw WorktreeOwnershipError.invalid(
                    "node_test test path must be an existing file: \(rawPath)"
                )
            }
            let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw WorktreeOwnershipError.invalid(
                    "node_test test path must resolve to a regular file: \(rawPath)"
                )
            }
            let relative = String(candidate.path.dropFirst(canonicalWorking.count + 1))
            guard !normalized.contains(relative) else {
                throw WorktreeOwnershipError.invalid(
                    "node_test test paths must be unique"
                )
            }
            normalized.append(relative)
            resolved.append(candidate.path)
        }

        return NodeTestInvocation(
            workingDirectory: canonicalWorking,
            worktreePath: canonicalWorktree,
            branch: identity.branch,
            stableID: identity.stableID,
            testPaths: normalized,
            resolvedTestPaths: resolved
        )
    }

    public static func sanitizedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": base["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": base["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "CI": "1",
            "NO_COLOR": "1",
        ]
    }

    public static func resolveNodeExecutable(
        fileManager: FileManager = .default
    ) throws -> String {
        for candidate in [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ] where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
        }
        throw WorktreeOwnershipError.invalid(
            "node_test requires Node at a fixed trusted system path"
        )
    }
}

private final class NodeTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() { lock.withLock { stored = true } }
    var value: Bool { lock.withLock { stored } }
}

private final class NodeTestOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var wasTruncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ next: Data) {
        lock.withLock {
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(next.prefix(remaining))
            }
            if next.count > remaining {
                wasTruncated = true
            }
        }
    }

    func snapshot() -> (text: String, truncated: Bool, bytes: Int) {
        lock.withLock {
            (
                String(decoding: data, as: UTF8.self),
                wasTruncated,
                data.count
            )
        }
    }
}

public enum NodeTestModule {
    public static let moduleName = "dev"
    public static let toolName = "node_test"
    private static let defaultTimeoutSeconds = 120
    private static let maximumTimeoutSeconds = 600
    private static let outputLimitBytes = 2_000_000

    private static func string(_ value: Value?) -> String? {
        if case .string(let value) = value, !value.isEmpty { return value }
        return nil
    }

    private static func integer(_ value: Value?) -> Int? {
        if case .int(let value) = value { return value }
        return nil
    }

    private static func strings(_ value: Value?) -> [String]? {
        guard case .array(let values) = value else { return nil }
        var result: [String] = []
        for value in values {
            guard case .string(let string) = value else { return nil }
            result.append(string)
        }
        return result
    }

    private static func activeClaim(
        store: WorktreeOwnershipStore,
        invocation: NodeTestInvocation,
        ownerSession: String,
        timeoutSeconds: Int,
        now: Date = Date()
    ) async throws -> WorktreeClaimRecord {
        guard let permit = WorktreeOwnershipGuard.currentPermit,
              permit.ownerSession == ownerSession,
              permit.stableIDs.contains(invocation.stableID) else {
            throw WorktreeOwnershipError.ownershipRequired(
                "node_test requires the router-held worktree execution permit"
            )
        }
        guard let record = try await store.record(
            worktreePath: invocation.worktreePath
        ), record.releasedAt == nil else {
            throw WorktreeOwnershipError.ownershipRequired(
                "node_test requires an active worktree claim"
            )
        }
        guard record.tuple.ownerSession == ownerSession else {
            throw WorktreeOwnershipError.foreignOwnership(
                "node_test claim belongs to a different ownerSession"
            )
        }
        guard record.tuple.stableID == invocation.stableID,
              record.tuple.worktreePath == invocation.worktreePath,
              record.tuple.branch == invocation.branch else {
            throw WorktreeOwnershipError.identityChanged(
                "node_test live worktree identity does not match its claim"
            )
        }
        guard record.tuple.expiresAt.timeIntervalSince(now)
                > TimeInterval(timeoutSeconds + 2) else {
            throw WorktreeOwnershipError.staleRecoveryRequired(
                "node_test claim must outlive the requested timeout"
            )
        }
        return record
    }

    private static func revalidate(
        store: WorktreeOwnershipStore,
        invocation: NodeTestInvocation,
        ownerSession: String,
        now: Date = Date()
    ) async throws {
        let live = try WorktreeOwnershipGuard.liveIdentity(
            for: invocation.workingDirectory
        )
        guard live.stableID == invocation.stableID,
              live.worktreePath == invocation.worktreePath,
              live.branch == invocation.branch else {
            throw WorktreeOwnershipError.identityChanged(
                "node_test worktree identity changed during process execution"
            )
        }
        guard let record = try await store.record(
            worktreePath: invocation.worktreePath
        ), record.releasedAt == nil,
           record.tuple.ownerSession == ownerSession,
           record.tuple.expiresAt > now else {
            throw WorktreeOwnershipError.staleRecoveryRequired(
                "node_test claim expired or was released during process execution"
            )
        }
    }

    public static func register(
        on router: ToolRouter,
        store: WorktreeOwnershipStore = .shared
    ) async {
        await router.register(ToolRegistration(
            name: toolName,
            module: moduleName,
            tier: .request,
            neverAutoApprove: true,
            description: "Run 1...32 trusted Node test files through the built-in node:test API in one live claimed Git worktree. The executable and argument shape are fixed: node --permission plus one --import per existing relative .js/.mjs/.cjs path. Requires the exact ownerSession, a claim that outlives the bounded foreground process, sanitized environment, and post-run identity revalidation. Network, child-process, worker, native-addon, inspector, WASI, and FFI permissions remain denied; filesystem access is bounded to the worktree. Returns process id, exact executable/arguments, exit code, duration, stdout, stderr, and timeout evidence. It accepts no shell text, arbitrary flags, environment overrides, package scripts, redirection, command substitution, or detached execution.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "workingDir": .object([
                        "type": .string("string"),
                        "description": .string("Absolute directory inside the live claimed Git worktree.")
                    ]),
                    "testPaths": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "minItems": .int(1),
                        "maxItems": .int(32),
                        "description": .string("Static relative existing .js/.mjs/.cjs test paths under workingDir.")
                    ]),
                    "ownerSession": .object([
                        "type": .string("string"),
                        "description": .string("Exact active ownerSession for the claimed worktree.")
                    ]),
                    "timeoutSeconds": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(maximumTimeoutSeconds),
                        "description": .string("Foreground timeout, 1...600 seconds; default 120.")
                    ])
                ]),
                "required": .array([
                    .string("workingDir"),
                    .string("testPaths"),
                    .string("ownerSession"),
                ])
            ]),
            metadata: ToolMetadata(
                title: "Governed Node Test",
                whenToUse: [
                    "Run explicit trusted node:test files inside a claimed development worktree.",
                    "Obtain a fresh-process exit code and bounded stdout/stderr without shell execution.",
                ],
                whenNotToUse: [
                    "Do not use for untrusted code, package scripts, builds, arbitrary Node programs, environment overrides, or detached work.",
                    "Do not use outside a live claimed Git worktree.",
                ],
                relatedTools: ["worktree_claim", "worktree_release", "git_status"]
            ),
            handler: { arguments in
                guard case .object(let object) = arguments,
                      let workingDirectory = string(object["workingDir"]),
                      let testPaths = strings(object["testPaths"]),
                      let ownerSession = string(object["ownerSession"]) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: toolName,
                        reason: "workingDir, testPaths, and ownerSession are required"
                    )
                }
                let timeout = integer(object["timeoutSeconds"])
                    ?? defaultTimeoutSeconds
                guard (1...maximumTimeoutSeconds).contains(timeout) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: toolName,
                        reason: "timeoutSeconds must be 1...\(maximumTimeoutSeconds)"
                    )
                }

                let invocation = try NodeTestContract.prepare(
                    workingDirectory: workingDirectory,
                    testPaths: testPaths
                )
                let claim = try await activeClaim(
                    store: store,
                    invocation: invocation,
                    ownerSession: ownerSession,
                    timeoutSeconds: timeout
                )
                let nodeExecutable = try NodeTestContract.resolveNodeExecutable()

                let process = Process()
                process.executableURL = URL(fileURLWithPath: nodeExecutable)
                let nodeArguments = [
                    "--permission",
                    "--allow-fs-read=\(invocation.worktreePath)",
                    "--allow-fs-write=\(invocation.worktreePath)",
                    "--eval",
                    "",
                ] + invocation.resolvedTestPaths.map { "--import=\($0)" }
                process.arguments = nodeArguments
                process.currentDirectoryURL = URL(
                    fileURLWithPath: invocation.workingDirectory
                )
                process.environment = NodeTestContract.sanitizedEnvironment()

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                let stdout = NodeTestOutput(limit: outputLimitBytes)
                let stderr = NodeTestOutput(limit: outputLimitBytes)
                let timedOut = NodeTestFlag()
                let readers = DispatchGroup()

                let start = ContinuousClock.now
                try process.run()
                let processID = Int(process.processIdentifier)

                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    let handle = stdoutPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        stdout.append(data)
                    }
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    let handle = stderrPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        stderr.append(data)
                    }
                    readers.leave()
                }

                let timeoutItem = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.set()
                    let pid = process.processIdentifier
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning {
                            _ = Darwin.kill(pid, SIGKILL)
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(timeout),
                    execute: timeoutItem
                )

                process.waitUntilExit()
                timeoutItem.cancel()
                await withCheckedContinuation { continuation in
                    readers.notify(queue: .global(qos: .utility)) {
                        continuation.resume()
                    }
                }

                try await revalidate(
                    store: store,
                    invocation: invocation,
                    ownerSession: ownerSession
                )

                let elapsed = ContinuousClock.now - start
                let duration = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds)
                    / 1_000_000_000_000_000_000.0
                let stdoutSnapshot = stdout.snapshot()
                let stderrSnapshot = stderr.snapshot()
                let exitCode = Int(process.terminationStatus)
                let didTimeout = timedOut.value
                let success = exitCode == 0 && !didTimeout
                let terminationReason = didTimeout
                    ? "timeout_killed"
                    : (success ? "exited" : "non_zero_exit")

                return .object([
                    "ok": .bool(success),
                    "success": .bool(success),
                    "status": .string(
                        success ? "success" : (didTimeout ? "timed_out" : "failed")
                    ),
                    "commandIdentity": .string("node node:test imports"),
                    "nodeExecutable": .string(nodeExecutable),
                    "arguments": .array(nodeArguments.map(Value.string)),
                    "workingDir": .string(invocation.workingDirectory),
                    "worktreePath": .string(invocation.worktreePath),
                    "branch": .string(invocation.branch),
                    "testPaths": .array(invocation.testPaths.map(Value.string)),
                    "processId": .int(processID),
                    "exitCode": .int(exitCode),
                    "duration": .double(duration),
                    "stdout": .string(stdoutSnapshot.text),
                    "stderr": .string(stderrSnapshot.text),
                    "stdoutBytes": .int(stdoutSnapshot.bytes),
                    "stderrBytes": .int(stderrSnapshot.bytes),
                    "stdoutTruncated": .bool(stdoutSnapshot.truncated),
                    "stderrTruncated": .bool(stderrSnapshot.truncated),
                    "timedOut": .bool(didTimeout),
                    "timeoutSeconds": .int(timeout),
                    "terminationReason": .string(terminationReason),
                    "claimExpiresAt": .string(
                        ISO8601DateFormatter().string(from: claim.tuple.expiresAt)
                    ),
                ])
            }
        ))
    }
}
