// CursorAILogsWriterTests.swift — PKT-3.4.1-RESCUE Phase 3
// Unit coverage for the AI LOGS writer's pure mappers (no network).

import Foundation
import NotionBridgeLib

func runCursorAILogsWriterTests() async {
    print("\n\u{1F4DD} CursorAILogsWriter Tests (PKT-3.4.1-RESCUE)")

    await test("outcome map: succeeded → Success") {
        try expect(CursorAILogsWriter.outcome(for: .succeeded) == "Success")
    }
    await test("outcome map: failed → Failure") {
        try expect(CursorAILogsWriter.outcome(for: .failed) == "Failure")
    }
    await test("outcome map: cancelled → Abandoned") {
        try expect(CursorAILogsWriter.outcome(for: .cancelled) == "Abandoned")
    }
    await test("outcome map: running → Partial") {
        try expect(CursorAILogsWriter.outcome(for: .running) == "Partial")
    }

    await test("confidence map") {
        try expect(CursorAILogsWriter.confidence(for: .succeeded) == 1.0)
        try expect(CursorAILogsWriter.confidence(for: .cancelled) == 0.5)
        try expect(CursorAILogsWriter.confidence(for: .failed) == 0.0)
    }

    await test("durationSeconds returns nil when endedAt missing") {
        let run = CursorRun(
            id: "r1", runtime: .local, model: "auto", status: .running,
            startedAt: Date(), endedAt: nil
        )
        try expect(CursorAILogsWriter.durationSeconds(run: run) == nil)
    }

    await test("durationSeconds computes wall time correctly") {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_000_042)
        let run = CursorRun(
            id: "r2", runtime: .cloud, model: "cursor-default", status: .succeeded,
            startedAt: start, endedAt: end
        )
        try expect(CursorAILogsWriter.durationSeconds(run: run) == 42.0)
    }

    await test("sessionContextJSON includes promptHash from first audit") {
        let run = CursorRun(
            id: "r3", runtime: .local, model: "auto", status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let audit = RedactionAuditEntry(
            runId: nil,
            count: 2,
            ruleIds: ["aws-key", "gh-pat"],
            promptHash: String(repeating: "a", count: 64),
            repoPath: "/tmp/x",
            sensitiveRepoMatched: nil,
            forcedLocal: false,
            redactedAt: Date()
        )
        let json = CursorAILogsWriter.sessionContextJSON(run: run, audits: [audit])
        try expect(json.contains("\"promptHash\":\"" + String(repeating: "a", count: 64) + "\""),
                   "sessionContext JSON missing promptHash; got: \(json)")
        try expect(!json.contains("\"prompt\":"),
                   "sessionContext must NOT contain raw 'prompt' field; got: \(json)")
    }

    await test("sessionContextJSON omits optional fields when nil") {
        let run = CursorRun(
            id: "r4", runtime: .cloud, model: "x", status: .running,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let json = CursorAILogsWriter.sessionContextJSON(run: run, audits: [])
        try expect(!json.contains("\"repoPath\":"))
        try expect(!json.contains("\"prURL\":"))
        try expect(!json.contains("\"promptHash\":"))
    }

    await test("artifactsJSON serializes artifact list") {
        let artifacts = [
            CursorArtifact(kind: "pr_url", url: "https://github.com/x/y/pull/1", label: "PR"),
            CursorArtifact(kind: "file", label: "out.txt")
        ]
        let json = CursorAILogsWriter.artifactsJSON(artifacts)
        try expect(json.contains("\"kind\":\"pr_url\""))
        // JSONSerialization escapes forward slashes; assert against the host
        // substring rather than the full URL literal.
        try expect(json.contains("github.com"), "expected URL in JSON; got: \(json)")
        try expect(json.contains("pull"), "expected URL path in JSON; got: \(json)")
        try expect(json.contains("\"kind\":\"file\""))
    }

    await test("artifactsJSON returns [] for empty list") {
        try expect(CursorAILogsWriter.artifactsJSON([]) == "[]")
    }

    await test("frictionSignalsText returns 'none' for empty audits") {
        try expect(CursorAILogsWriter.frictionSignalsText([]) == "none")
    }

    await test("frictionSignalsText dedupes and sorts rule ids") {
        let a1 = RedactionAuditEntry(
            runId: nil, count: 1, ruleIds: ["b-rule", "a-rule"],
            promptHash: "x", repoPath: nil, sensitiveRepoMatched: nil,
            forcedLocal: false, redactedAt: Date()
        )
        let a2 = RedactionAuditEntry(
            runId: nil, count: 1, ruleIds: ["a-rule", "c-rule"],
            promptHash: "x", repoPath: nil, sensitiveRepoMatched: nil,
            forcedLocal: false, redactedAt: Date()
        )
        let text = CursorAILogsWriter.frictionSignalsText([a1, a2])
        try expect(text == "a-rule, b-rule, c-rule", "got: \(text)")
    }

    await test("buildProperties shape: required fields present") {
        let writer = CursorAILogsWriter()
        let run = CursorRun(
            id: "r5", runtime: .cloud, model: "auto", status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            costCents: 42, repoPath: nil,
            prURL: "https://github.com/x/y/pull/9", lastEventId: "evt-1"
        )
        let props = await writer.buildProperties(run: run, audits: [], artifacts: [])
        try expect(props["Log Name"] != nil, "missing Log Name")
        try expect(props["Log Type"] != nil, "missing Log Type")
        try expect(props["Platform"] != nil, "missing Platform")
        try expect(props["Outcome"] != nil, "missing Outcome")
        try expect(props["Session Context"] != nil, "missing Session Context")
        try expect(props["Artifacts Created"] != nil, "missing Artifacts Created")
        try expect(props["Friction Signals"] != nil, "missing Friction Signals")
        try expect(props["Duration"] != nil, "missing Duration")
        try expect(props["Confidence"] != nil, "missing Confidence")
    }
}
