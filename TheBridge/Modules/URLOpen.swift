// URLOpen.swift — first-class http(s)/notion URL open (#312)
// TheBridge · Modules
//
// Remote fleets cannot `shell_exec open <url>`: C0 treats `open` as an opaque
// executable (`worktree_target_unresolved`). This policy is the lease-free
// alternative — same effective behavior as AppleScript `open location`.
// It never opens file paths or other schemes, so it is not a C0 bypass.

import Foundation

/// Pure allowlist + shell-command detector for `url_open` and the
/// `shell_exec open <http(s)>` denial remedy. Foundation-only so C0 tests
/// can cover the contract without AppKit.
public enum URLOpenPolicy {

    /// Schemes `url_open` will hand to the Mac. `file:` and everything else
    /// stay rejected — local paths remain worktree-gated via `shell_exec`.
    public static let allowedSchemes: Set<String> = ["http", "https", "notion"]

    /// Client-facing remedy when `shell_exec`/`bg_run` `open <http(s)|notion>`
    /// fails closed as `worktree_target_unresolved`. Names the first-class
    /// tool first so fleets stop retrying shell open.
    public static let shellOpenRemoteURLRemedy =
        "Do not retry shell_exec open. Use url_open with the http(s) or notion URL, or applescript_exec with open location \"{url}\"."

    public enum ParseError: Error, Equatable, LocalizedError, Sendable {
        case missing
        case invalid
        case disallowedScheme(String)

        public var errorDescription: String? {
            switch self {
            case .missing:
                return "missing required 'url' parameter"
            case .invalid:
                return "url must be an absolute http(s) or notion URL"
            case .disallowedScheme(let scheme):
                return "url scheme '\(scheme)' is not allowed; use http, https, or notion (not file or local paths)"
            }
        }
    }

    /// Parse and allowlist a caller-supplied URL string.
    public static func parse(_ raw: String) -> Result<URL, ParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missing) }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else {
            return .failure(.invalid)
        }
        guard allowedSchemes.contains(scheme) else {
            return .failure(.disallowedScheme(scheme))
        }
        if url.user != nil || url.password != nil {
            return .failure(.invalid)
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return .failure(.invalid) }
        }
        return .success(url)
    }

    /// True when a shell command is `open` (or `/usr/bin/open`) of an
    /// http(s)/notion URL — the #312 fleet workaround case. File opens
    /// (`open .`, `open /tmp/x`) stay false so C0 copy is unchanged.
    public static func shellCommandOpensRemoteURL(_ command: String) -> Bool {
        let separators = CharacterSet(charactersIn: ";&|\n")
        return command.components(separatedBy: separators).contains { openSegmentHasRemoteURL($0) }
    }

    private static func openSegmentHasRemoteURL(_ segment: String) -> Bool {
        let tokens = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return false }
        let executable = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        guard executable == "open" else { return false }
        return tokens.dropFirst().contains { isRemoteOpenURLToken($0) }
    }

    private static func isRemoteOpenURLToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        switch parse(trimmed) {
        case .success: return true
        case .failure: return false
        }
    }
}
