// CronHumanizerTests.swift — v1.9.1
// Test coverage for the public CronHumanizer in TheBridgeLib.
// Uses the custom async test harness (not XCTest) — same pattern as the other
// test files in this target.

import Foundation
import TheBridgeLib

func runCronHumanizerTests() async {
    print("\n\u{1F4AC} CronHumanizer Tests (v1.9.1)")

    // Fixtures: (cron expression, expected human output).
    // These are the v1.9.1 spec strings — any output drift is a regression.
    let valid: [(String, String)] = [
        ("* * * * *",       "Every minute"),
        ("*/5 * * * *",     "Every 5 minutes"),
        ("*/15 * * * *",    "Every 15 minutes"),
        ("0 * * * *",       "Every hour"),
        ("0 9 * * *",       "Every day at 9:00 AM"),
        ("0 9 * * 1-5",     "Every weekday at 9:00 AM"),
        ("0 9 * * 1",       "Every Monday at 9:00 AM"),
        ("0 0 * * 0",       "Every Sunday at midnight"),
        ("0 0 1 * *",       "First of every month at midnight"),
        ("30 14 * * 3",     "Every Wednesday at 2:30 PM"),
        ("0 */2 * * *",     "Every 2 hours"),
    ]

    for (expr, expected) in valid {
        await test("CronHumanizer: \"\(expr)\" -> \"\(expected)\"") {
            let actual = CronHumanizer.describe(expr)
            try expect(actual == expected,
                       "expected \"\(expected)\", got \(actual.map { "\"\($0)\"" } ?? "nil")")
        }
    }

    await test("CronHumanizer: invalid input returns nil") {
        let actual = CronHumanizer.describe("invalid garbage")
        try expect(actual == nil, "expected nil, got \(actual ?? "<string>")")
    }

    // Round-trip: for every valid fixture, the raw cron expression must parse
    // cleanly through CronParser AND the humanizer output must be stable
    // (pure function, same result on a second call). This guards against
    // parser/humanizer drift — if CronParser rejects a fixture we claim to
    // describe, the humanizer is out of step with the parser.
    await test("CronHumanizer: round-trip — valid fixtures parse + humanize consistently") {
        for (expr, expected) in valid {
            let intervals = try CronParser.parse(expr)
            try expect(!intervals.isEmpty,
                       "CronParser produced no intervals for \"\(expr)\"")
            let first  = CronHumanizer.describe(expr)
            let second = CronHumanizer.describe(expr)
            try expect(first == expected,
                       "humanizer output drifted for \"\(expr)\": got \(first ?? "nil")")
            try expect(first == second,
                       "humanizer not idempotent for \"\(expr)\"")
        }
    }
}
