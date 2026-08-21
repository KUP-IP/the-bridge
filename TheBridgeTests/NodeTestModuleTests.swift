// NodeTestModuleTests.swift — U2 governed foreground Node test execution

import Foundation
import MCP
import TheBridgeLib

private struct NodeTestFixture {
    let root: URL
    let repo: URL
    let store: WorktreeOwnershipStore
    let ownerSession: String
    let headSHA: String
}

private func nodeTestRun(
    _ executable: String,
    _ arguments: [String],
    cwd: URL
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let error = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw TestError.assertion(
            String(decoding: error, as: UTF8.self)
        )
    }
    return String(decoding: output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func makeNodeTestFixture(
    testSource: String = """
    import test from 'node:test'
    import assert from 'node:assert/strict'
    test('governed', () => assert.equal(2 + 2, 4))
    """
) async throws -> NodeTestFixture {
    let fixtureBase = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/node-test-fixtures", isDirectory: true)
    let root = fixtureBase
        .appendingPathComponent("bridge-node-test-\(UUID().uuidString)", isDirectory: true)
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repo,
        withIntermediateDirectories: true
    )
    _ = try nodeTestRun("/usr/bin/git", ["init", "-b", "main"], cwd: repo)
    _ = try nodeTestRun("/usr/bin/git", ["config", "user.email", "node-test@example.invalid"], cwd: repo)
    _ = try nodeTestRun("/usr/bin/git", ["config", "user.name", "Node Test"], cwd: repo)
    try testSource.write(
        to: repo.appendingPathComponent("sample.test.mjs"),
        atomically: true,
        encoding: .utf8
    )
    _ = try nodeTestRun("/usr/bin/git", ["add", "sample.test.mjs"], cwd: repo)
    _ = try nodeTestRun(
        "/usr/bin/git",
        ["-c", "commit.gpgsign=false", "commit", "-m", "fixture"],
        cwd: repo
    )
    let head = try nodeTestRun("/usr/bin/git", ["rev-parse", "HEAD"], cwd: repo)
    let store = WorktreeOwnershipStore(
        databaseURL: root.appendingPathComponent("claims.sqlite")
    )
    let owner = "node-test-\(UUID().uuidString)"
    _ = try await store.claim(
        repoRoot: repo.path,
        worktreePath: repo.path,
        branch: "main",
        baseSHA: head,
        ownerSession: owner,
        ttlSeconds: 300
    )
    return NodeTestFixture(
        root: root,
        repo: repo,
        store: store,
        ownerSession: owner,
        headSHA: head
    )
}

private func nodeTestOwnershipCode(
    _ operation: () async throws -> Void
) async -> String? {
    do {
        try await operation()
        return nil
    } catch let error as WorktreeOwnershipError {
        return error.code
    } catch {
        return nil
    }
}

func runNodeTestModuleTests() async {
    print("\n🧪 NodeTestModule Tests")

    await test("node_test registers one non-downgradable request-tier dev tool") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await NodeTestModule.register(on: router)
        let tools = await router.registrations(forModule: "dev")
            .filter { $0.name == "node_test" }
        try expect(tools.count == 1)
        try expect(tools[0].tier == .request)
        try expect(tools[0].neverAutoApprove)
    }

    await test("node_test environment is fixed and drops inherited execution controls") {
        let environment = NodeTestContract.sanitizedEnvironment(base: [
            "HOME": "/Users/tester",
            "TMPDIR": "/private/tmp/custom",
            "NODE_OPTIONS": "--require=/tmp/escape.cjs",
            "NODE_PATH": "/tmp/modules",
            "GIT_DIR": "/tmp/other.git",
            "PATH": "/tmp/attacker",
            "SECRET_TOKEN": "do-not-copy",
        ])
        try expect(environment["HOME"] == "/Users/tester")
        try expect(environment["TMPDIR"] == "/private/tmp/custom")
        try expect(environment["CI"] == "1")
        try expect(environment["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        for rejected in ["NODE_OPTIONS", "NODE_PATH", "GIT_DIR", "SECRET_TOKEN"] {
            try expect(environment[rejected] == nil, "Unexpected inherited \(rejected)")
        }
    }

    await test("node_test rejects absolute, dynamic, and parent-escape test paths") {
        let fixture = try await makeNodeTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for invalid in [
            "/tmp/escape.test.mjs",
            "../escape.test.mjs",
            "$DYNAMIC.test.mjs",
            "`whoami`.test.mjs",
            "sample.txt",
        ] {
            do {
                _ = try NodeTestContract.prepare(
                    workingDirectory: fixture.repo.path,
                    testPaths: [invalid]
                )
                throw TestError.assertion("Expected rejection for \(invalid)")
            } catch is WorktreeOwnershipError {
                // Expected fail-closed contract error.
            }
        }
    }

    await test("node_test rejects a symlink that escapes the claimed working directory") {
        let fixture = try await makeNodeTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside.test.mjs")
        try "throw new Error('outside')".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.repo.appendingPathComponent("linked.test.mjs"),
            withDestinationURL: outside
        )
        do {
            _ = try NodeTestContract.prepare(
                workingDirectory: fixture.repo.path,
                testPaths: ["linked.test.mjs"]
            )
            throw TestError.assertion("Expected symlink escape rejection")
        } catch is WorktreeOwnershipError {
            // Expected.
        }
    }

    await test("node_test requires the exact active worktree owner") {
        let fixture = try await makeNodeTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: fixture.store,
            worktreeOwnershipEnabled: true
        )
        await NodeTestModule.register(on: router, store: fixture.store)

        let missing = await nodeTestOwnershipCode {
            _ = try await router.dispatch(
                toolName: "node_test",
                arguments: .object([
                    "workingDir": .string(fixture.repo.path),
                    "testPaths": .array([.string("sample.test.mjs")]),
                    "timeoutSeconds": .int(30),
                ])
            )
        }
        try expect(missing == "worktree_ownership_required")

        let foreign = await nodeTestOwnershipCode {
            _ = try await router.dispatch(
                toolName: "node_test",
                arguments: .object([
                    "workingDir": .string(fixture.repo.path),
                    "testPaths": .array([.string("sample.test.mjs")]),
                    "ownerSession": .string("foreign-owner"),
                    "timeoutSeconds": .int(30),
                ])
            )
        }
        try expect(foreign == "worktree_foreign_ownership")
    }

    await test("node_test runs a fresh foreground process and returns authoritative evidence") {
        let fixture = try await makeNodeTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: fixture.store,
            worktreeOwnershipEnabled: true
        )
        await NodeTestModule.register(on: router, store: fixture.store)
        let result = try await router.dispatch(
            toolName: "node_test",
            arguments: .object([
                "workingDir": .string(fixture.repo.path),
                "testPaths": .array([.string("sample.test.mjs")]),
                "ownerSession": .string(fixture.ownerSession),
                "timeoutSeconds": .int(30),
            ])
        )
        guard case .object(let object) = result,
              case .bool(let success) = object["success"],
              case .int(let exitCode) = object["exitCode"],
              case .int(let processID) = object["processId"],
              case .string(let stdout) = object["stdout"],
              case .string(let commandIdentity) = object["commandIdentity"],
              case .string(let workingDirectory) = object["workingDir"],
              case .array(let rawArguments) = object["arguments"] else {
            throw TestError.assertion("Unexpected node_test result shape")
        }
        try expect(success, "node_test failed: \(result)")
        try expect(exitCode == 0)
        try expect(processID > 0)
        try expect(stdout.contains("pass") || stdout.contains("governed"))
        try expect(commandIdentity == "node node:test imports")
        let arguments = rawArguments.compactMap { value -> String? in
            if case .string(let string) = value { return string }
            return nil
        }
        try expect(arguments.contains("--permission"))
        try expect(arguments.contains(where: { $0.hasPrefix("--import=") }))
        try expect(arguments.contains(where: { $0.hasPrefix("--allow-fs-read=") }))
        try expect(arguments.contains(where: { $0.hasPrefix("--allow-fs-write=") }))
        try expect(!arguments.contains("--test"))
        try expect(!arguments.contains("--allow-child-process"))
        try expect(!arguments.contains(where: { $0.hasPrefix("--allow-net") }))
        try expect(
            workingDirectory == (try WorktreeOwnershipGuard.canonicalPath(fixture.repo.path))
        )
    }

    await test("node_test reports a real nonzero test result without converting it to a transport error") {
        let source = """
        import test from 'node:test'
        import assert from 'node:assert/strict'
        test('fails', () => assert.equal(1, 2))
        """
        let fixture = try await makeNodeTestFixture(testSource: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: fixture.store,
            worktreeOwnershipEnabled: true
        )
        await NodeTestModule.register(on: router, store: fixture.store)
        let result = try await router.dispatch(
            toolName: "node_test",
            arguments: .object([
                "workingDir": .string(fixture.repo.path),
                "testPaths": .array([.string("sample.test.mjs")]),
                "ownerSession": .string(fixture.ownerSession),
                "timeoutSeconds": .int(30),
            ])
        )
        guard case .object(let object) = result,
              case .bool(let success) = object["success"],
              case .int(let exitCode) = object["exitCode"],
              case .string(let status) = object["status"] else {
            throw TestError.assertion("Unexpected node_test failure shape")
        }
        try expect(!success)
        try expect(exitCode != 0)
        try expect(status == "failed")
    }

    await test("node_test terminates at its bounded timeout and reports timeout evidence") {
        let source = """
        import test from 'node:test'
        test('slow', async () => {
          await new Promise(resolve => setTimeout(resolve, 10_000))
        })
        """
        let fixture = try await makeNodeTestFixture(testSource: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog(),
            worktreeOwnershipStore: fixture.store,
            worktreeOwnershipEnabled: true
        )
        await NodeTestModule.register(on: router, store: fixture.store)
        let result = try await router.dispatch(
            toolName: "node_test",
            arguments: .object([
                "workingDir": .string(fixture.repo.path),
                "testPaths": .array([.string("sample.test.mjs")]),
                "ownerSession": .string(fixture.ownerSession),
                "timeoutSeconds": .int(1),
            ])
        )
        guard case .object(let object) = result,
              case .bool(let success) = object["success"],
              case .bool(let timedOut) = object["timedOut"],
              case .string(let reason) = object["terminationReason"] else {
            throw TestError.assertion("Unexpected node_test timeout shape")
        }
        try expect(!success)
        try expect(timedOut, "node_test timeout did not fire: \(result)")
        try expect(reason == "timeout_killed")
    }
}
