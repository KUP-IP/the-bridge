// RunnerParsers.swift — PKT-782 (Bridge v2.2 · 3.2b)
// Structured JSON parsers for runner outputs:
//   - Playwright (JSON reporter)
//   - Vitest (--reporter=json)
//   - Lighthouse (--output=json)
// Plus uniform `RunnerEnvelope` + structured `RunnerFailure` covering
// process_crash · wall_time_timeout · signal_kill · malformed_output · missing_output_file.
// Boundary: pure parsers — no MCP/network coupling. Live e2e deferred to PKT-3.2c.

import Foundation

// MARK: - Uniform envelope

public struct RunnerEnvelope<Details: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let runner: String
    public let ok: Bool
    public let summary: RunnerSummary
    public let failure: RunnerFailure?
    public let details: Details?
    public init(runner: String, ok: Bool, summary: RunnerSummary, failure: RunnerFailure? = nil, details: Details? = nil) {
        self.runner = runner
        self.ok = ok
        self.summary = summary
        self.failure = failure
        self.details = details
    }
}

public struct RunnerSummary: Codable, Sendable, Equatable {
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public let total: Int
    public let durationMs: Int?
    public init(passed: Int = 0, failed: Int = 0, skipped: Int = 0, total: Int = 0, durationMs: Int? = nil) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.total = total
        self.durationMs = durationMs
    }
    public static let empty = RunnerSummary()
}

public struct RunnerFailure: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case processCrash    = "process_crash"
        case wallTimeTimeout = "wall_time_timeout"
        case signalKill      = "signal_kill"
        case malformedOutput = "malformed_output"
        case missingOutput   = "missing_output_file"
    }
    public let kind: Kind
    public let message: String
    public let exitCode: Int?
    public let signal: String?
    public init(kind: Kind, message: String, exitCode: Int? = nil, signal: String? = nil) {
        self.kind = kind
        self.message = message
        self.exitCode = exitCode
        self.signal = signal
    }
}

// MARK: - Numeric coercion helpers (JSONSerialization returns NSNumber)

private func asDouble(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

private func asInt(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(d) }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}

// MARK: - Playwright

public struct PlaywrightDetails: Codable, Sendable, Equatable {
    public let suites: [PlaywrightSuite]
    public init(suites: [PlaywrightSuite] = []) { self.suites = suites }
}

public struct PlaywrightSuite: Codable, Sendable, Equatable {
    public let title: String
    public let file: String?
    public let specs: [PlaywrightSpec]
    public init(title: String, file: String? = nil, specs: [PlaywrightSpec] = []) {
        self.title = title
        self.file = file
        self.specs = specs
    }
}

public struct PlaywrightSpec: Codable, Sendable, Equatable {
    public let title: String
    public let ok: Bool
    public let tests: [PlaywrightTest]
    public init(title: String, ok: Bool, tests: [PlaywrightTest] = []) {
        self.title = title
        self.ok = ok
        self.tests = tests
    }
}

public struct PlaywrightTest: Codable, Sendable, Equatable {
    public let projectName: String?
    public let status: String        // "expected" | "unexpected" | "skipped" | "flaky"
    public let durationMs: Int?
    public let traceFiles: [String]
    public init(projectName: String? = nil, status: String, durationMs: Int? = nil, traceFiles: [String] = []) {
        self.projectName = projectName
        self.status = status
        self.durationMs = durationMs
        self.traceFiles = traceFiles
    }
}

public typealias PlaywrightEnvelope = RunnerEnvelope<PlaywrightDetails>

public enum PlaywrightParser {
    /// Parse Playwright JSON reporter output into a uniform envelope.
    /// Returns `malformed_output` failure envelope when JSON root is unparseable.
    public static func parse(_ data: Data) -> PlaywrightEnvelope {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return failure(.malformedOutput, message: "playwright JSON root is not an object")
        }
        let stats = root["stats"] as? [String: Any] ?? [:]
        let passed = asInt(stats["expected"]) ?? 0
        let failed = asInt(stats["unexpected"]) ?? 0
        let skipped = asInt(stats["skipped"]) ?? 0
        let flaky = asInt(stats["flaky"]) ?? 0
        let duration = asDouble(stats["duration"]).map { Int($0) }
        let total = passed + failed + skipped + flaky

        let suites = parseSuites(root["suites"] as? [[String: Any]] ?? [])
        let summary = RunnerSummary(passed: passed, failed: failed, skipped: skipped, total: total, durationMs: duration)
        return PlaywrightEnvelope(runner: "playwright", ok: failed == 0, summary: summary,
                                  failure: nil, details: PlaywrightDetails(suites: suites))
    }

    public static func failure(_ kind: RunnerFailure.Kind, message: String, exitCode: Int? = nil, signal: String? = nil) -> PlaywrightEnvelope {
        PlaywrightEnvelope(
            runner: "playwright", ok: false, summary: .empty,
            failure: RunnerFailure(kind: kind, message: message, exitCode: exitCode, signal: signal),
            details: nil
        )
    }

    private static func parseSuites(_ raw: [[String: Any]]) -> [PlaywrightSuite] {
        raw.map { suite in
            let title = (suite["title"] as? String) ?? ""
            let file = suite["file"] as? String
            let specs = (suite["specs"] as? [[String: Any]] ?? []).map(parseSpec)
            // Flatten nested child suites' specs into the parent suite (skip floor preserved via stats).
            let nestedSpecs = (suite["suites"] as? [[String: Any]] ?? [])
                .flatMap { parseSuites([$0]).flatMap { $0.specs } }
            return PlaywrightSuite(title: title, file: file, specs: specs + nestedSpecs)
        }
    }

    private static func parseSpec(_ raw: [String: Any]) -> PlaywrightSpec {
        let title = (raw["title"] as? String) ?? ""
        let ok = (raw["ok"] as? Bool) ?? true
        let tests = (raw["tests"] as? [[String: Any]] ?? []).map { t -> PlaywrightTest in
            let projectName = t["projectName"] as? String
            let status = (t["status"] as? String) ?? "unknown"
            let results = t["results"] as? [[String: Any]] ?? []
            let durTotal = results.compactMap { asDouble($0["duration"]) }.reduce(0.0, +)
            let traces = results.flatMap { r -> [String] in
                guard let attachments = r["attachments"] as? [[String: Any]] else { return [] }
                return attachments.compactMap { a -> String? in
                    guard (a["name"] as? String)?.lowercased() == "trace",
                          let path = a["path"] as? String else { return nil }
                    return path
                }
            }
            return PlaywrightTest(projectName: projectName, status: status,
                                  durationMs: durTotal > 0 ? Int(durTotal) : nil,
                                  traceFiles: traces)
        }
        return PlaywrightSpec(title: title, ok: ok, tests: tests)
    }
}

// MARK: - Vitest

public struct VitestDetails: Codable, Sendable, Equatable {
    public let files: [VitestFile]
    public let coverage: VitestCoverage?
    public init(files: [VitestFile] = [], coverage: VitestCoverage? = nil) {
        self.files = files
        self.coverage = coverage
    }
}

public struct VitestFile: Codable, Sendable, Equatable {
    public let name: String
    public let tasks: [VitestTask]
    public init(name: String, tasks: [VitestTask] = []) {
        self.name = name
        self.tasks = tasks
    }
}

public struct VitestTask: Codable, Sendable, Equatable {
    public let name: String
    public let type: String         // "suite" | "test"
    public let status: String?      // "passed" | "failed" | "skipped" — nil for suite-only nodes
    public let durationMs: Int?
    public let tasks: [VitestTask]?
    public init(name: String, type: String, status: String? = nil, durationMs: Int? = nil, tasks: [VitestTask]? = nil) {
        self.name = name
        self.type = type
        self.status = status
        self.durationMs = durationMs
        self.tasks = tasks
    }
}

public struct VitestCoverage: Codable, Sendable, Equatable {
    public let lines: Double?
    public let statements: Double?
    public let functions: Double?
    public let branches: Double?
    public init(lines: Double? = nil, statements: Double? = nil, functions: Double? = nil, branches: Double? = nil) {
        self.lines = lines
        self.statements = statements
        self.functions = functions
        self.branches = branches
    }
}

public typealias VitestEnvelope = RunnerEnvelope<VitestDetails>

public enum VitestParser {
    /// Parse Vitest --reporter=json output. Tolerates `--coverage` enabled or absent.
    public static func parse(_ data: Data) -> VitestEnvelope {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return failure(.malformedOutput, message: "vitest JSON root is not an object")
        }
        let passed = asInt(root["numPassedTests"]) ?? 0
        let failed = asInt(root["numFailedTests"]) ?? 0
        let skipped = asInt(root["numPendingTests"]) ?? asInt(root["numTodoTests"]) ?? 0
        let total = asInt(root["numTotalTests"]) ?? (passed + failed + skipped)
        let startTime = asDouble(root["startTime"]) ?? 0
        let testResults = root["testResults"] as? [[String: Any]] ?? []
        let maxEnd = testResults.compactMap { asDouble($0["endTime"]) }.max() ?? 0
        let durationMs: Int? = (maxEnd > 0 && startTime > 0) ? Int(maxEnd - startTime) : nil

        let files: [VitestFile] = testResults.map { tr in
            let name = (tr["name"] as? String) ?? ""
            let assertions = tr["assertionResults"] as? [[String: Any]] ?? []
            let tasks: [VitestTask] = assertions.map { a in
                let title = (a["fullName"] as? String) ?? (a["title"] as? String) ?? ""
                let status = (a["status"] as? String) ?? "unknown"
                let duration = asDouble(a["duration"]).map { Int($0) }
                return VitestTask(name: title, type: "test", status: status, durationMs: duration)
            }
            return VitestFile(name: name, tasks: tasks)
        }

        var coverage: VitestCoverage? = nil
        if let cov = root["coverageMap"] as? [String: Any],
           let totals = cov["total"] as? [String: Any] {
            // Istanbul-style nested {"lines":{"pct": …}, …}
            coverage = VitestCoverage(
                lines:      asDouble((totals["lines"]      as? [String: Any])?["pct"]),
                statements: asDouble((totals["statements"] as? [String: Any])?["pct"]),
                functions:  asDouble((totals["functions"]  as? [String: Any])?["pct"]),
                branches:   asDouble((totals["branches"]   as? [String: Any])?["pct"])
            )
        } else if let cov = root["coverage"] as? [String: Any] {
            // Flat fallback shape: {"lines": 95.0, "branches": 76.0, …}
            coverage = VitestCoverage(
                lines:      asDouble(cov["lines"]),
                statements: asDouble(cov["statements"]),
                functions:  asDouble(cov["functions"]),
                branches:   asDouble(cov["branches"])
            )
        }

        let summary = RunnerSummary(passed: passed, failed: failed, skipped: skipped, total: total, durationMs: durationMs)
        return VitestEnvelope(runner: "vitest", ok: failed == 0, summary: summary,
                              failure: nil, details: VitestDetails(files: files, coverage: coverage))
    }

    public static func failure(_ kind: RunnerFailure.Kind, message: String, exitCode: Int? = nil, signal: String? = nil) -> VitestEnvelope {
        VitestEnvelope(
            runner: "vitest", ok: false, summary: .empty,
            failure: RunnerFailure(kind: kind, message: message, exitCode: exitCode, signal: signal),
            details: nil
        )
    }
}

// MARK: - Lighthouse

public struct LighthouseDetails: Codable, Sendable, Equatable {
    public let performance: Int?
    public let accessibility: Int?
    public let bestPractices: Int?
    public let seo: Int?
    public let audits: [LighthouseAudit]
    public init(performance: Int? = nil, accessibility: Int? = nil, bestPractices: Int? = nil, seo: Int? = nil, audits: [LighthouseAudit] = []) {
        self.performance = performance
        self.accessibility = accessibility
        self.bestPractices = bestPractices
        self.seo = seo
        self.audits = audits
    }
}

public struct LighthouseAudit: Codable, Sendable, Equatable {
    public let id: String
    public let score: Double?
    public let title: String?
    public let displayValue: String?
    public init(id: String, score: Double? = nil, title: String? = nil, displayValue: String? = nil) {
        self.id = id
        self.score = score
        self.title = title
        self.displayValue = displayValue
    }
}

public typealias LighthouseEnvelope = RunnerEnvelope<LighthouseDetails>

public enum LighthouseParser {
    /// Parse Lighthouse --output=json result. Scores are 0–1 in source JSON; surfaced as 0–100 ints (rounded).
    public static func parse(_ data: Data) -> LighthouseEnvelope {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return failure(.malformedOutput, message: "lighthouse JSON root is not an object")
        }
        let categories = root["categories"] as? [String: Any] ?? [:]
        func scoreFor(_ key: String) -> Int? {
            guard let cat = categories[key] as? [String: Any],
                  let s = asDouble(cat["score"]) else { return nil }
            return Int((s * 100).rounded())
        }
        let perf = scoreFor("performance")
        let a11y = scoreFor("accessibility")
        let bp = scoreFor("best-practices")
        let seo = scoreFor("seo")

        let auditsRoot = root["audits"] as? [String: Any] ?? [:]
        let audits: [LighthouseAudit] = auditsRoot.compactMap { (key, value) -> LighthouseAudit? in
            guard let a = value as? [String: Any] else { return nil }
            let id = (a["id"] as? String) ?? key
            let score = asDouble(a["score"])
            let title = a["title"] as? String
            let display = a["displayValue"] as? String
            return LighthouseAudit(id: id, score: score, title: title, displayValue: display)
        }.sorted { $0.id < $1.id }

        let details = LighthouseDetails(performance: perf, accessibility: a11y, bestPractices: bp, seo: seo, audits: audits)
        // Lighthouse is single-shot; surface category coverage in summary as a 4-slot envelope.
        let scoresCount = [perf, a11y, bp, seo].compactMap { $0 }.count
        let summary = RunnerSummary(passed: scoresCount, failed: 0, skipped: 4 - scoresCount, total: 4, durationMs: nil)
        return LighthouseEnvelope(runner: "lighthouse", ok: true, summary: summary, failure: nil, details: details)
    }

    public static func failure(_ kind: RunnerFailure.Kind, message: String, exitCode: Int? = nil, signal: String? = nil) -> LighthouseEnvelope {
        LighthouseEnvelope(
            runner: "lighthouse", ok: false, summary: .empty,
            failure: RunnerFailure(kind: kind, message: message, exitCode: exitCode, signal: signal),
            details: nil
        )
    }
}
