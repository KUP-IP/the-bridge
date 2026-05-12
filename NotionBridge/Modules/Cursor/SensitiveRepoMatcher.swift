// SensitiveRepoMatcher.swift — PKT-3.4.3 (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Sensitive-repo allowlist for Cursor agent runs. Repos matching a configured
// glob pattern are forced to runtime=local (cloud disabled) and flagged as
// requiring extra approval before dispatch. Default glob `~/Developer/secure/*`
// covers the canonical "do not send to a third-party cloud" convention.
//
// User-extensible via UserDefaults key
// `com.notionbridge.cursor.sensitiveRepoGlobs` (array of strings). Each entry
// is fnmatch(3)-compatible (POSIX-style; supports `*`, `?`, `[…]`). Glob
// patterns undergo `~`-expansion before matching.
//
// Wave 1 of PKT-3.4.3 (this packet): pure matcher + UserDefaults storage.
// Settings UI section that lets the user manage the list is PKT-3.4.2 /
// 3.4.3.W2 territory. Extra-approval modal surfacing is PKT-3.4.2's new-run
// modal; this module just returns the verdict for it to consume.

import Foundation
import Darwin

public enum SensitiveRepoMatcher {

    // MARK: - UserDefaults

    public static let userDefaultsKey = "com.notionbridge.cursor.sensitiveRepoGlobs"

    public static let defaultGlobs: [String] = [
        "~/Developer/secure/*",
        "~/Developer/secure/**"
    ]

    // MARK: - Verdict

    public struct Verdict: Sendable, Equatable {
        public let isSensitive: Bool
        public let matchedPattern: String?
        public let forceLocal: Bool
        public let requiresExtraApproval: Bool

        public init(isSensitive: Bool, matchedPattern: String?, forceLocal: Bool, requiresExtraApproval: Bool) {
            self.isSensitive = isSensitive
            self.matchedPattern = matchedPattern
            self.forceLocal = forceLocal
            self.requiresExtraApproval = requiresExtraApproval
        }

        public static let notSensitive = Verdict(
            isSensitive: false,
            matchedPattern: nil,
            forceLocal: false,
            requiresExtraApproval: false
        )
    }

    // MARK: - Public API

    public static func evaluate(
        repoPath: String?,
        defaults: UserDefaults = .standard
    ) -> Verdict {
        guard let raw = repoPath, !raw.isEmpty else { return .notSensitive }
        let expandedPath = (raw as NSString).expandingTildeInPath
        let globs = effectiveGlobs(defaults: defaults)
        for glob in globs {
            let expandedGlob = (glob as NSString).expandingTildeInPath
            if matches(path: expandedPath, glob: expandedGlob) {
                return Verdict(
                    isSensitive: true,
                    matchedPattern: glob,
                    forceLocal: true,
                    requiresExtraApproval: true
                )
            }
        }
        return .notSensitive
    }

    public static func effectiveGlobs(defaults: UserDefaults = .standard) -> [String] {
        var globs = defaultGlobs
        if let extra = defaults.stringArray(forKey: userDefaultsKey) {
            for g in extra where !g.isEmpty && !globs.contains(g) {
                globs.append(g)
            }
        }
        return globs
    }

    // MARK: - Glob matching

    static func matches(path: String, glob: String) -> Bool {
        if fnmatchSwift(glob, path, FNM_PATHNAME) { return true }
        if fnmatchSwift(glob, path, 0) { return true }
        let trimmed: String? = {
            if glob.hasSuffix("/**") { return String(glob.dropLast(3)) }
            if glob.hasSuffix("/*")  { return String(glob.dropLast(2)) }
            return nil
        }()
        if let t = trimmed, path == t || path.hasPrefix(t + "/") {
            return true
        }
        return false
    }

    private static func fnmatchSwift(_ pattern: String, _ path: String, _ flags: Int32) -> Bool {
        pattern.withCString { pat in
            path.withCString { p in
                fnmatch(pat, p, flags) == 0
            }
        }
    }
}
