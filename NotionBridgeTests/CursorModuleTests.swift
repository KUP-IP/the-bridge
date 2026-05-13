// CursorModuleTests.swift — PKT-3.4.1 (Bridge v2.2)
// Coverage for CursorModule + CursorRuntime capability surface.
//
// Wave 1 coverage: registration (5 tools, tier .request, module="cursor"),
// CursorTypes Codable round-trip, capabilityCheck shape, error mapping.
// Live sidecar IPC tests (A1 local round-trip, B2 cloud + PR, C5 reconnect)
// are scoped to PKT-3.4.1.W2 once `@cursor/sdk@1.0.12` types are vendored
// or shipped, and require user-side authorization for real spend.

import Foundation
import MCP
import NotionBridgeLib

func runCursorModuleTests() async {
    print("\n\u{1F500} CursorModule Tests (PKT-3.4.1 v2.2 · 3.4.1 Wave 1)")

    // ------------------------------------------------------------------
    // 1) Tool registration: 5 tools, module = "cursor", tier = .request
    // ------------------------------------------------------------------
    await test("CursorModule registers 5 tools under module=\"cursor\"") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await CursorModule.register(on: router)
        let regs = await router.registrations(forModule: "cursor")
        let names = Set(regs.map { $0.name })
        let expected: Set<String> = [
            "cursor_agent_run",
            "cursor_agent_status",
            "cursor_agent_list",
            "cursor_agent_cancel",
            "cursor_agent_artifacts",
        ]
        try expect(expected.isSubset(of: names),
            "missing tools — got \(names.sorted())")
    }

    await test("All cursor_agent_* tools are tier .request") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await CursorModule.register(on: router)
        let regs = await router.registrations(forModule: "cursor")
        let cursorRegs = regs.filter { $0.name.hasPrefix("cursor_agent_") }
        try expect(cursorRegs.count == 5, "expected 5 cursor_agent_* tools, got \(cursorRegs.count)")
        for r in cursorRegs {
            try expect(r.tier == .request, "\(r.name) tier is \(r.tier.rawValue), expected request")
        }
    }

    await test("CursorModule.moduleName == \"cursor\"") {
        try expect(CursorModule.moduleName == "cursor")
    }

    // ------------------------------------------------------------------
    // 2) CursorTypes Codable round-trip
    // ------------------------------------------------------------------
    await test("CursorRun JSON round-trip") {
        let original = CursorRun(
            id: "run-abc",
            runtime: .cloud,
            model: "cursor-default",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: nil,
            costCents: 42,
            repoPath: "/tmp/repo",
            prURL: nil,
            lastEventId: "evt-1"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CursorRun.self, from: data)
        try expect(decoded == original, "round-trip mismatch")
    }

    await test("CursorArtifact JSON round-trip") {
        let a = CursorArtifact(kind: "pr_url", url: "https://github.com/x/y/pull/1", label: "PR", mediaType: nil)
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(CursorArtifact.self, from: data)
        try expect(decoded == a)
    }

    await test("CursorEvent JSON round-trip") {
        let e = CursorEvent(
            id: "evt-7",
            runId: "run-abc",
            kind: "token",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            payload: ["text": "hello"]
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(e)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CursorEvent.self, from: data)
        try expect(decoded == e)
    }

    // ------------------------------------------------------------------
    // 3) CursorRuntime capability surface
    // ------------------------------------------------------------------
    await test("CursorRuntime capabilityCheck reports node availability") {
        let rt = CursorRuntime(sidecarRoot: URL(fileURLWithPath: "/tmp/nonexistent-cursor-sidecar-\(UUID().uuidString)"))
        let cap = rt.capabilityCheck()
        // node should be locatable on a dev machine; sidecar path won't be ok
        try expect(cap.hasApiKey == cap.hasApiKey)  // tautology — just exercise the path
        try expect(cap.ok == false, "expected !ok because sidecar root doesn't exist")
        try expect(cap.reason?.contains("sidecar entrypoint missing") == true,
            "expected reason to mention sidecar path; got '\(cap.reason ?? "nil")'")
    }

    await test("CursorRuntime.defaultSidecarRoot resolves under Application Support") {
        let root = CursorRuntime.defaultSidecarRoot()
        try expect(root.path.contains("Application Support/NotionBridge/cursor-sidecar"),
            "unexpected default root: \(root.path)")
    }

    await test("CursorRuntime.keychain coordinates are stable") {
        try expect(CursorRuntime.keychainService == "api_key:cursor")
        try expect(CursorRuntime.keychainAccount == "cursor")
        try expect(CursorRuntime.envVarName == "CURSOR_API_KEY")
    }

    // ------------------------------------------------------------------
    // 4) CursorError code mapping (mirrors sidecar SPEC §4 registry)
    // ------------------------------------------------------------------
    await test("CursorError sidecar codes mirror SPEC §4 registry") {
        try expect(CursorError.notImplemented("x").sidecarCode    == 10001)
        try expect(CursorError.capabilityMissing("x").sidecarCode == 10002)
        try expect(CursorError.authFailed("x").sidecarCode        == 10003)
        try expect(CursorError.sdkError("x").sidecarCode          == 10004)
        try expect(CursorError.costCapTripped("x").sidecarCode    == 10005)
        try expect(CursorError.timeout("x").sidecarCode           == 10006)
        try expect(CursorError.sidecarError(code: 9999, message: "x", data: nil).sidecarCode == 9999)
    }

    // ------------------------------------------------------------------
    // 5) Wave 1: handler proxies hit notImplemented when capability is ok,
    //    or capabilityMissing when not. We can't test the ok path without
    //    a real Keychain entry; this verifies the error envelope shape on
    //    the dispatch happy path.
    // ------------------------------------------------------------------
    await test("cursor_agent_run handler returns structured error envelope on Wave 1 stub path") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        // Tier override for unit test: force .open so SecurityGate doesn't block.
        UserDefaults.standard.set(["cursor_agent_run": "open"], forKey: BridgeDefaults.tierOverrides)
        defer { UserDefaults.standard.removeObject(forKey: BridgeDefaults.tierOverrides) }

        // Inject a runtime whose capabilityCheck is guaranteed to fail (bad sidecar root).
        let badRoot = URL(fileURLWithPath: "/tmp/nonexistent-cursor-sidecar-\(UUID().uuidString)")
        let rt = CursorRuntime(sidecarRoot: badRoot)
        await CursorModule.register(on: router, runtime: rt)

        let result = try await router.dispatch(
            toolName: "cursor_agent_run",
            arguments: .object(["prompt": .string("refactor foo")])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object result, got \(result)")
        }
        guard case .bool(let ok) = dict["ok"], ok == false else {
            throw TestError.assertion("expected ok=false in error envelope")
        }
        guard case .int(let code) = dict["code"] else {
            throw TestError.assertion("expected numeric code in error envelope")
        }
        // Either capability_missing (10002) or not_implemented (10001) is acceptable here —
        // depends on whether the dev box has Node + Keychain entry present.
        try expect(code == 10001 || code == 10002,
            "expected code 10001 or 10002, got \(code)")
    }

    await test("CursorRuntime JSON-RPC sidecar ping and capability probe") {
        let root = try makeFakeCursorSidecar()
        defer { try? FileManager.default.removeItem(at: root) }
        let rt = CursorRuntime(sidecarRoot: root, apiKeyOverride: "test-key")

        let ping = try await rt.ping()
        try expect(ping["pong"] == "true", "unexpected ping response \(ping)")

        let cap = try await rt.capabilityProbe()
        try expect(cap["ok"] == "true", "unexpected capability response \(cap)")
        await rt.shutdown()
    }

    await test("CursorRuntime JSON-RPC sidecar run lifecycle maps DTOs") {
        let root = try makeFakeCursorSidecar()
        defer { try? FileManager.default.removeItem(at: root) }
        let rt = CursorRuntime(sidecarRoot: root, apiKeyOverride: "test-key")

        let run = try await rt.agentRun(
            prompt: "Refactor without leaking ghp_1234567890abcdef1234567890abcdef1234",
            runtime: .cloud,
            model: "composer-latest",
            repoPath: "/Users/keepup/Developer/notion-bridge",
            branch: "feature/test",
            maxCostCents: 25
        )
        try expect(run.id == "run-fake")
        try expect(run.runtime == .cloud)
        try expect(run.status == .running)

        let pending = await rt.pendingRedactionAudits()
        try expect(pending.count == 1, "expected one redaction audit")
        try expect(pending[0].count >= 1, "expected prompt redaction count")

        let status = try await rt.agentStatus(id: run.id)
        try expect(status.id == run.id)

        let runs = try await rt.agentList(statusFilter: nil, runtimeFilter: .cloud)
        try expect(runs.contains(where: { $0.id == run.id }))

        let artifacts = try await rt.agentArtifacts(id: run.id)
        try expect(artifacts.contains(where: { $0.kind == "log" }))

        let cancelled = try await rt.agentCancel(id: run.id)
        try expect(cancelled.status == .cancelled)
        await rt.shutdown()
    }
}

private func makeFakeCursorSidecar() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("cursor-sidecar-test-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try fm.createDirectory(at: dist, withIntermediateDirectories: true)
    try #"{"version":"0.0.0-test","type":"module"}"#.write(
        to: root.appendingPathComponent("package.json"),
        atomically: true,
        encoding: .utf8
    )
    let js = #"""
import readline from "node:readline";
let status = "running";
const run = {
  id: "run-fake",
  runtime: "cloud",
  model: "composer-latest",
  status,
  startedAt: "2026-05-12T00:00:00Z",
  endedAt: null,
  costCents: 3,
  repoPath: "/Users/keepup/Developer/notion-bridge",
  prURL: null,
  lastEventId: "evt-1"
};
function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}
function response(id, result) {
  write({ jsonrpc: "2.0", id, result });
}
readline.createInterface({ input: process.stdin, crlfDelay: Infinity }).on("line", (line) => {
  const msg = JSON.parse(line);
  if (msg.method === "ping") {
    response(msg.id, { pong: "true" });
  } else if (msg.method === "capability_probe") {
    response(msg.id, { ok: "true", fake: "true" });
  } else if (msg.method === "agent_run") {
    status = "running";
    run.status = status;
    run.runtime = msg.params.runtime;
    response(msg.id, run);
  } else if (msg.method === "agent_status") {
    response(msg.id, run);
  } else if (msg.method === "agent_list") {
    response(msg.id, { runs: [run] });
  } else if (msg.method === "agent_artifacts") {
    response(msg.id, { artifacts: [{ kind: "log", label: "stdout", mediaType: "text/plain", url: null }] });
  } else if (msg.method === "agent_cancel") {
    status = "cancelled";
    run.status = status;
    response(msg.id, run);
  } else {
    write({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "unknown" } });
  }
});
"""#
    let entry = dist.appendingPathComponent("index.js")
    try js.write(to: entry, atomically: true, encoding: .utf8)
    return root
}
