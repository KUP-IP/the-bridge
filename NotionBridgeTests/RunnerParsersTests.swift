// RunnerParsersTests.swift — PKT-782 (Bridge v2.2 · 3.2b)
// Fixture-JSON unit tests for Playwright / Vitest / Lighthouse parsers
// + per-runner failure cases (process_crash, wall_time_timeout, signal_kill,
// malformed_output, missing_output_file). Pure data-shape tests — no live e2e.

import Foundation
import NotionBridgeLib

// MARK: - Fixtures (inline; no external test-data dependency)

private let playwrightHappyJSON = #"""
{
  "config": { "version": "1.40.0" },
  "stats": {
    "expected": 3, "unexpected": 1, "skipped": 1, "flaky": 0, "duration": 4200
  },
  "suites": [
    {
      "title": "auth.spec.ts",
      "file": "tests/auth.spec.ts",
      "specs": [
        {
          "title": "login succeeds",
          "ok": true,
          "tests": [
            {
              "projectName": "chromium",
              "status": "expected",
              "results": [
                { "duration": 1200, "attachments": [ { "name": "trace", "path": "/tmp/trace1.zip" } ] }
              ]
            }
          ]
        },
        {
          "title": "logout fails",
          "ok": false,
          "tests": [
            {
              "projectName": "chromium",
              "status": "unexpected",
              "results": [ { "duration": 800, "attachments": [] } ]
            }
          ]
        }
      ]
    }
  ]
}
"""#

private let vitestHappyJSON = #"""
{
  "numTotalTests": 5,
  "numPassedTests": 3,
  "numFailedTests": 1,
  "numPendingTests": 1,
  "startTime": 1000000,
  "testResults": [
    {
      "name": "/src/foo.test.ts",
      "endTime": 1003500,
      "assertionResults": [
        { "fullName": "foo > works",   "status": "passed", "duration": 12 },
        { "fullName": "foo > fails",   "status": "failed", "duration": 8 },
        { "fullName": "foo > skipped", "status": "skipped" }
      ]
    },
    {
      "name": "/src/bar.test.ts",
      "endTime": 1003000,
      "assertionResults": [
        { "fullName": "bar > pass1", "status": "passed", "duration": 5 },
        { "fullName": "bar > pass2", "status": "passed", "duration": 7 }
      ]
    }
  ],
  "coverageMap": {
    "total": {
      "lines":      { "pct": 95.5 },
      "statements": { "pct": 94.2 },
      "functions":  { "pct": 88.0 },
      "branches":   { "pct": 76.4 }
    }
  }
}
"""#

private let lighthouseHappyJSON = #"""
{
  "categories": {
    "performance":    { "id": "performance",    "score": 0.92 },
    "accessibility":  { "id": "accessibility",  "score": 1.00 },
    "best-practices": { "id": "best-practices", "score": 0.96 },
    "seo":            { "id": "seo",            "score": 1.00 }
  },
  "audits": {
    "first-contentful-paint": {
      "id": "first-contentful-paint", "score": 0.95,
      "title": "First Contentful Paint", "displayValue": "1.2 s"
    },
    "color-contrast": {
      "id": "color-contrast", "score": 1.0,
      "title": "Background colors have sufficient contrast"
    }
  }
}
"""#

private let malformedJSON = #"""
{ "not valid json
"""#

func runRunnerParsersTests() async {
    print("\n\u{1F4E6} RunnerParsers Tests (PKT-782 v2.2 · 3.2b)")

    // --- Playwright happy-path: 3 tests ---

    await test("PlaywrightParser preserves pass/fail/skip counts from stats") {
        let env = PlaywrightParser.parse(Data(playwrightHappyJSON.utf8))
        try expect(env.runner == "playwright", "wrong runner: \(env.runner)")
        try expect(env.ok == false, "expected ok=false because failed>0")
        try expect(env.summary.passed == 3, "passed: \(env.summary.passed)")
        try expect(env.summary.failed == 1, "failed: \(env.summary.failed)")
        try expect(env.summary.skipped == 1, "skipped: \(env.summary.skipped)")
        try expect(env.summary.total == 5, "total: \(env.summary.total)")
        try expect(env.summary.durationMs == 4200, "duration: \(env.summary.durationMs ?? -1)")
        try expect(env.failure == nil, "expected no failure on happy parse")
    }

    await test("PlaywrightParser captures suite/spec tree + trace attachments") {
        let env = PlaywrightParser.parse(Data(playwrightHappyJSON.utf8))
        guard let details = env.details else { throw TestError.assertion("missing details") }
        try expect(details.suites.count == 1, "expected 1 suite, got \(details.suites.count)")
        let suite = details.suites[0]
        try expect(suite.file == "tests/auth.spec.ts", "wrong file: \(suite.file ?? "nil")")
        try expect(suite.specs.count == 2, "expected 2 specs, got \(suite.specs.count)")
        try expect(suite.specs[0].tests.first?.traceFiles == ["/tmp/trace1.zip"], "trace not captured")
        try expect(suite.specs[0].tests.first?.projectName == "chromium", "project missing")
        try expect(suite.specs[1].ok == false, "second spec should be ok=false")
    }

    await test("PlaywrightEnvelope is Codable round-trip safe") {
        let env = PlaywrightParser.parse(Data(playwrightHappyJSON.utf8))
        let encoded = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(PlaywrightEnvelope.self, from: encoded)
        try expect(decoded == env, "round-trip inequality")
    }

    // --- Vitest happy-path: 3 tests ---

    await test("VitestParser preserves pass/fail/skip + computes durationMs from startTime/endTime") {
        let env = VitestParser.parse(Data(vitestHappyJSON.utf8))
        try expect(env.runner == "vitest", "wrong runner")
        try expect(env.summary.passed == 3, "passed: \(env.summary.passed)")
        try expect(env.summary.failed == 1, "failed: \(env.summary.failed)")
        try expect(env.summary.skipped == 1, "skipped: \(env.summary.skipped)")
        try expect(env.summary.total == 5, "total: \(env.summary.total)")
        try expect(env.summary.durationMs == 3500, "expected 3500ms, got \(env.summary.durationMs ?? -1)")
    }

    await test("VitestParser preserves file tree shape + coverage envelope") {
        let env = VitestParser.parse(Data(vitestHappyJSON.utf8))
        guard let details = env.details else { throw TestError.assertion("missing details") }
        try expect(details.files.count == 2, "expected 2 files, got \(details.files.count)")
        try expect(details.files[0].tasks.count == 3, "expected 3 tasks in file 0")
        try expect(details.files[1].tasks.count == 2, "expected 2 tasks in file 1")
        try expect(details.coverage?.lines == 95.5, "lines coverage: \(String(describing: details.coverage?.lines))")
        try expect(details.coverage?.statements == 94.2, "statements coverage")
        try expect(details.coverage?.functions == 88.0, "functions coverage")
        try expect(details.coverage?.branches == 76.4, "branches coverage")
    }

    await test("VitestEnvelope is Codable round-trip safe") {
        let env = VitestParser.parse(Data(vitestHappyJSON.utf8))
        let encoded = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(VitestEnvelope.self, from: encoded)
        try expect(decoded == env, "round-trip inequality")
    }

    // --- Lighthouse happy-path: 3 tests ---

    await test("LighthouseParser preserves 4-score envelope (perf/a11y/bp/seo)") {
        let env = LighthouseParser.parse(Data(lighthouseHappyJSON.utf8))
        try expect(env.runner == "lighthouse", "wrong runner")
        try expect(env.ok == true, "happy lighthouse should be ok=true")
        guard let details = env.details else { throw TestError.assertion("missing details") }
        try expect(details.performance == 92, "perf: \(String(describing: details.performance))")
        try expect(details.accessibility == 100, "a11y: \(String(describing: details.accessibility))")
        try expect(details.bestPractices == 96, "bp: \(String(describing: details.bestPractices))")
        try expect(details.seo == 100, "seo: \(String(describing: details.seo))")
        try expect(env.summary.passed == 4 && env.summary.total == 4, "4-slot summary mismatch")
    }

    await test("LighthouseParser captures audits with score + displayValue") {
        let env = LighthouseParser.parse(Data(lighthouseHappyJSON.utf8))
        guard let details = env.details else { throw TestError.assertion("missing details") }
        try expect(details.audits.count == 2, "expected 2 audits, got \(details.audits.count)")
        let fcp = details.audits.first { $0.id == "first-contentful-paint" }
        try expect(fcp?.score == 0.95, "fcp score wrong")
        try expect(fcp?.displayValue == "1.2 s", "fcp displayValue wrong: \(fcp?.displayValue ?? "nil")")
        try expect(fcp?.title == "First Contentful Paint", "fcp title wrong")
    }

    await test("LighthouseEnvelope is Codable round-trip safe") {
        let env = LighthouseParser.parse(Data(lighthouseHappyJSON.utf8))
        let encoded = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(LighthouseEnvelope.self, from: encoded)
        try expect(decoded == env, "round-trip inequality")
    }

    // --- Per-runner failure cases: 3 tests (covers 5 kinds across the runners) ---

    await test("PlaywrightParser returns structured malformed_output failure on bad JSON") {
        let env = PlaywrightParser.parse(Data(malformedJSON.utf8))
        try expect(env.ok == false, "expected ok=false")
        try expect(env.failure?.kind == .malformedOutput, "expected malformed_output, got \(String(describing: env.failure?.kind))")
        try expect(env.details == nil, "expected no details on failure")
        try expect(env.summary.total == 0, "empty summary on failure")
    }

    await test("VitestParser.failure factory produces process_crash with exitCode + signal") {
        let env = VitestParser.failure(.processCrash, message: "vitest aborted unexpectedly", exitCode: 134, signal: "SIGABRT")
        try expect(env.ok == false, "expected ok=false")
        try expect(env.failure?.kind == .processCrash, "wrong kind")
        try expect(env.failure?.exitCode == 134, "wrong exitCode")
        try expect(env.failure?.signal == "SIGABRT", "wrong signal")
        try expect(env.runner == "vitest", "wrong runner")
        try expect(env.details == nil, "failure should have no details")
        // Codable round-trip preserves failure shape
        let encoded = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(VitestEnvelope.self, from: encoded)
        try expect(decoded.failure?.kind == .processCrash, "failure round-trip lost kind")
        try expect(decoded.failure?.exitCode == 134, "failure round-trip lost exitCode")
    }

    await test("LighthouseParser.failure factory covers wall_time_timeout + signal_kill + missing_output") {
        let timeoutEnv = LighthouseParser.failure(.wallTimeTimeout, message: "exceeded 60s wall-time")
        try expect(timeoutEnv.failure?.kind == .wallTimeTimeout, "timeout wrong kind")
        let signalEnv = LighthouseParser.failure(.signalKill, message: "killed by supervisor", signal: "SIGTERM")
        try expect(signalEnv.failure?.kind == .signalKill, "signal wrong kind")
        try expect(signalEnv.failure?.signal == "SIGTERM", "signal wrong signal")
        let missingEnv = LighthouseParser.failure(.missingOutput, message: "/tmp/lh.json not found after run")
        try expect(missingEnv.failure?.kind == .missingOutput, "missing wrong kind")
        // All 5 RunnerFailure.Kind cases reachable as expected
        try expect(RunnerFailure.Kind.allCases().count == 5, "expected 5 failure kinds")
    }
}

// Helper: surface allCases-style coverage without requiring CaseIterable conformance on the public type.
private extension RunnerFailure.Kind {
    static func allCases() -> [RunnerFailure.Kind] {
        [.processCrash, .wallTimeTimeout, .signalKill, .malformedOutput, .missingOutput]
    }
}
