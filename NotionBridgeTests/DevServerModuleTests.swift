// DevServerModuleTests.swift — PKT-741 (Bridge v2.2 · 1.3)
// Coverage for DevServerRuntime + DevServerModule (port_inspect, devserver_*).
//
// Hermetic: each test allocates a fresh BgProcessRuntime under a UUID-named
// temp baseDir and dynamic free-port allocation. python3 -m http.server is
// the canonical happy-path workload (skipped if python3 is unavailable).
//
// Failure-mode coverage (per packet DoD): timeout, port_in_use, command-not-found.

import Foundation
import MCP
import Darwin
import NotionBridgeLib

// MARK: - Helpers

private func makeTempBaseDir(_ tag: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NotionBridgeTests-devserver-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func makeTestSupervisor(_ tag: String) -> BgProcessRuntime {
    return BgProcessRuntime(baseDir: makeTempBaseDir(tag))
}

/// Reserve an ephemeral port via bind(0) and immediately close. The OS won't
/// re-issue this port for a short window, so it's safe to expect it free in
/// the immediately-following test step (modulo unrelated host activity).
private func findFreePort() -> Int {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    if s < 0 { return 0 }
    defer { close(s) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = in_addr_t(0)  // 0.0.0.0
    let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
            bind(s, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bound != 0 { return 0 }
    var got = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let res = withUnsafeMutablePointer(to: &got) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
            getsockname(s, sptr, &len)
        }
    }
    if res != 0 { return 0 }
    return Int(UInt16(bigEndian: got.sin_port))
}

private func resolvedPython3() -> String? {
    for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

func runDevServerModuleTests() async {
    print("\n\u{1F6F0}  DevServerModule Tests (PKT-741 v2.2 · 1.3)")

    // 1) Tool registration: 4 tools under module=dev
    await test("DevServerModule registers 4 tools under module=\"dev\"") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        let runtime = DevServerRuntime(supervisor: makeTestSupervisor("reg"))
        await DevServerModule.register(on: router, runtime: runtime)
        let regs = await router.registrations(forModule: "dev")
        let names = Set(regs.map { $0.name })
        let expected: Set<String> = [
            "port_inspect", "devserver_start", "devserver_stop", "devserver_health"
        ]
        try expect(expected.isSubset(of: names),
            "missing devserver tools — got \(names.sorted())")
    }

    // 2) All 4 tools tier .request
    await test("All port_inspect + devserver_* tools are tier .request") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        let runtime = DevServerRuntime(supervisor: makeTestSupervisor("tier"))
        await DevServerModule.register(on: router, runtime: runtime)
        let regs = await router.registrations(forModule: "dev")
        let ours = regs.filter {
            ["port_inspect", "devserver_start", "devserver_stop", "devserver_health"].contains($0.name)
        }
        try expect(ours.count == 4, "expected 4 of our tools, got \(ours.count)")
        for r in ours {
            try expect(r.tier == .request, "\(r.name) tier=\(r.tier) (expected .request)")
        }
    }

    // 3) Capability check: lsof discoverable
    await test("capabilityCheck returns ok with lsof discoverable") {
        let runtime = DevServerRuntime()
        let cap = runtime.capabilityCheck()
        try expect(cap.ok, "lsof not discoverable: \(cap.reason ?? "nil")")
    }

    // 4) port_inspect on a free port: empty occupants
    await test("port_inspect returns empty occupants for a free port") {
        let runtime = DevServerRuntime(supervisor: makeTestSupervisor("free"))
        let port = findFreePort()
        try expect(port > 0, "could not find a free port")
        let r = try await runtime.portInspect(port: port)
        try expect(r.port == port, "result port mismatch")
        try expect(r.listening.isEmpty, "expected no LISTENers, got \(r.listening.map { $0.command })")
    }

    // 5) Happy path: python3 http.server end-to-end (start → health → stop)
    await test("devserver lifecycle (happy path) with python3 http.server") {
        guard let py = resolvedPython3() else {
            print("    [skip] python3 not found")
            return
        }
        let supervisor = makeTestSupervisor("happy")
        let runtime = DevServerRuntime(supervisor: supervisor)
        let port = findFreePort()
        try expect(port > 0, "could not find a free port")
        let cmd = "\(py) -m http.server \(port) --bind 127.0.0.1"
        let started = try await runtime.devserverStart(
            cmd: cmd, cwd: nil, port: port,
            label: "happy-test", env: [:], timeoutSec: 15
        )
        try expect(started.port == port, "port mismatch")
        try expect(started.occupant.listenState == "LISTEN",
            "expected LISTEN, got \(started.occupant.listenState ?? "nil")")

        let h = await runtime.devserverHealth(
            port: port, httpPath: "/", expectedStatus: 200, timeoutSec: 5
        )
        try expect(h.ok, "health failed: listening=\(h.listening) httpStatus=\(h.httpStatus ?? -1) err=\(h.httpError ?? "nil")")
        try expect(h.listening, "health: not listening")
        try expect(h.httpStatus == 200, "expected 200, got \(h.httpStatus ?? -1)")

        // Note: python3 -m http.server ignores SIGTERM, so we use force=true
        // to verify the SIGKILL path within test timeframe. Real dev servers
        // (vite, wrangler, next) honor SIGTERM; force=false works for them.
        let stopped = try await runtime.devserverStop(
            id: started.job.id, port: port, force: true
        )
        try expect(stopped.portFree, "port still occupied after stop: \(stopped.occupants.map { $0.command })")
    }

    // 6) Failure: port collision — second devserver_start on same port
    await test("devserver_start fails with portInUse when port already LISTEN") {
        guard let py = resolvedPython3() else {
            print("    [skip] python3 not found")
            return
        }
        let supervisor = makeTestSupervisor("collision")
        let runtime = DevServerRuntime(supervisor: supervisor)
        let port = findFreePort()
        try expect(port > 0, "no free port")
        let cmd = "\(py) -m http.server \(port) --bind 127.0.0.1"
        let first = try await runtime.devserverStart(
            cmd: cmd, port: port, label: "collision-occupier", timeoutSec: 15
        )
        var caught: DevServerError? = nil
        do {
            _ = try await runtime.devserverStart(
                cmd: cmd, port: port, label: "collision-victim", timeoutSec: 5
            )
        } catch let e as DevServerError {
            caught = e
        }
        // Cleanup the occupier regardless of test outcome
        _ = try? await runtime.devserverStop(id: first.job.id, port: port, force: true)

        if case .portInUse(let p, let occ) = caught {
            try expect(p == port, "port mismatch in error")
            try expect(!occ.isEmpty, "expected at least 1 occupant in error")
        } else {
            try expect(false, "expected DevServerError.portInUse, got \(String(describing: caught))")
        }
    }

    // 7) Failure: cmd not found — bash exec failure surfaces as spawnFailed
    await test("devserver_start fails with spawnFailed for unknown command") {
        let supervisor = makeTestSupervisor("notfound")
        let runtime = DevServerRuntime(supervisor: supervisor)
        let port = findFreePort()
        try expect(port > 0, "no free port")
        let bogus = "/nonexistent-bridge-test-\(UUID().uuidString)"
        var caught: DevServerError? = nil
        do {
            _ = try await runtime.devserverStart(
                cmd: bogus, port: port, label: "bogus", timeoutSec: 5
            )
        } catch let e as DevServerError {
            caught = e
        }
        if case .spawnFailed = caught {
            // ok
        } else {
            try expect(false, "expected DevServerError.spawnFailed, got \(String(describing: caught))")
        }
    }

    // 8) Failure: timeout — process running but never opens the port
    await test("devserver_start fails with timeout when port never opens") {
        let supervisor = makeTestSupervisor("timeout")
        let runtime = DevServerRuntime(supervisor: supervisor)
        let port = findFreePort()
        try expect(port > 0, "no free port")
        var caught: DevServerError? = nil
        do {
            _ = try await runtime.devserverStart(
                cmd: "sleep 30", port: port, label: "sleeper",
                timeoutSec: 1.0, pollIntervalMs: 100
            )
        } catch let e as DevServerError {
            caught = e
        }
        if case .timeout(let s, let p) = caught {
            try expect(p == port, "port mismatch in timeout error")
            try expect(s == 1.0, "timeoutSec mismatch")
        } else {
            try expect(false, "expected DevServerError.timeout, got \(String(describing: caught))")
        }
    }

    // 9) devserver_health on dead port → ok=false, listening=false
    await test("devserver_health reports not-listening on a free port") {
        let runtime = DevServerRuntime(supervisor: makeTestSupervisor("dead"))
        let port = findFreePort()
        try expect(port > 0, "no free port")
        let h = await runtime.devserverHealth(port: port)
        try expect(!h.listening, "expected not-listening on free port")
        try expect(!h.ok, "expected ok=false")
    }

    // 10) devserver_stop is idempotent
    await test("devserver_stop is idempotent on already-killed job") {
        guard let py = resolvedPython3() else {
            print("    [skip] python3 not found")
            return
        }
        let supervisor = makeTestSupervisor("idempotent")
        let runtime = DevServerRuntime(supervisor: supervisor)
        let port = findFreePort()
        try expect(port > 0, "no free port")
        let cmd = "\(py) -m http.server \(port) --bind 127.0.0.1"
        let started = try await runtime.devserverStart(
            cmd: cmd, port: port, label: "idem", timeoutSec: 15
        )
        let r1 = try await runtime.devserverStop(id: started.job.id, port: port, force: true)
        try expect(r1.portFree, "port not free after first stop")
        let r2 = try await runtime.devserverStop(id: started.job.id, port: port, force: true)
        try expect(r2.job.id == started.job.id, "id mismatch on second stop")
    }
}
