// CronHumanizer.swift — v1.9.1
// Moved from TheBridge/UI/JobsView.swift so it lives in TheBridgeLib and can
// be unit-tested from the TheBridgeTests executable target.
//
// Describes a 5-field cron expression in plain English. Returns nil if the
// expression fails to parse or falls outside the supported pattern set.

import Foundation

public enum CronHumanizer {
    /// Describe a 5-field cron expression in plain English.
    /// - Returns: A human-readable string, or `nil` if the expression is invalid
    ///   or its shape isn't one the humanizer recognizes.
    public static func describe(_ expr: String) -> String? {
        let parts = expr.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5 else { return nil }
        // Validate via the authoritative parser first. Anything the parser rejects
        // (bad numbers, malformed steps/ranges) is surfaced as nil so callers can
        // render a raw fallback.
        guard (try? CronParser.parse(expr)) != nil else { return nil }

        let minF = parts[0], hrF = parts[1], domF = parts[2], monF = parts[3], dowF = parts[4]

        // Every minute.
        if minF == "*" && hrF == "*" && domF == "*" && monF == "*" && dowF == "*" {
            return "Every minute"
        }
        // Every N minutes.
        if minF.hasPrefix("*/"), let n = Int(minF.dropFirst(2)), n > 0,
           hrF == "*", domF == "*", monF == "*", dowF == "*" {
            return "Every \(n) minutes"
        }
        // Every hour (:00 of every hour, all days).
        if minF == "0", hrF == "*", domF == "*", monF == "*", dowF == "*" {
            return "Every hour"
        }
        // Every N hours.
        if minF == "0", hrF.hasPrefix("*/"), let n = Int(hrF.dropFirst(2)), n > 0,
           domF == "*", monF == "*", dowF == "*" {
            return "Every \(n) hours"
        }
        // First of every month at <time>.
        if let m = Int(minF), let h = Int(hrF),
           domF == "1", monF == "*", dowF == "*",
           (0...59).contains(m), (0...23).contains(h) {
            return "First of every month at \(timeWord(hour: h, minute: m))"
        }
        // Every weekday at <time> (Mon–Fri).
        if let m = Int(minF), let h = Int(hrF),
           domF == "*", monF == "*", dowF == "1-5",
           (0...59).contains(m), (0...23).contains(h) {
            return "Every weekday at \(timeWord(hour: h, minute: m))"
        }
        // Every <Day> at <time> (single weekday; accept 0..7 with 7==Sun).
        if let m = Int(minF), let h = Int(hrF),
           domF == "*", monF == "*", let d = Int(dowF), (0...7).contains(d),
           (0...59).contains(m), (0...23).contains(h) {
            let normalized = d == 7 ? 0 : d
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            return "Every \(names[normalized]) at \(timeWord(hour: h, minute: m))"
        }
        // Every day at <time>.
        if let m = Int(minF), let h = Int(hrF),
           domF == "*", monF == "*", dowF == "*",
           (0...59).contains(m), (0...23).contains(h) {
            return "Every day at \(timeWord(hour: h, minute: m))"
        }
        return nil
    }

    /// Format an (hour, minute) pair in 12-hour clock language with
    /// "midnight" and "noon" special cases.
    private static func timeWord(hour: Int, minute: Int) -> String {
        if hour == 0 && minute == 0 { return "midnight" }
        if hour == 12 && minute == 0 { return "noon" }
        let period = hour < 12 ? "AM" : "PM"
        var h12 = hour % 12
        if h12 == 0 { h12 = 12 }
        return String(format: "%d:%02d %@", h12, minute, period)
    }
}
