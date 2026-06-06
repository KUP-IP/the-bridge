// CredentialHardening.swift — Credential read/list hardening primitives.
// NotionBridge · Security · [credentials] backlog item.
//
// Three PURE, side-effect-free hardening concerns, kept out of CredentialManager
// (which owns Keychain I/O) so they are fully unit-testable with zero Keychain
// access and zero live network:
//
//   1. CredentialAliasNormalizer — accept env-var-style aliases
//      (e.g. `CURSOR_API_KEY`, `STRIPE_API_KEY`, `NOTION_TOKEN`) on the
//      credential_read lookup path and resolve them to the canonical
//      keychain `service` + `account` shape the vault actually stores
//      (`api_key:<provider>` / `<provider>`). Callers that hand us an
//      env-var name no longer silently miss the stored secret.
//
//   2. CredentialSentinelDetector — flag obvious sentinel / placeholder
//      secret values (empty, "changeme", "/dev/stdin", "xxx", "<your key>",
//      etc.) in credential_read / credential_list results so a caller does
//      not deploy a non-secret thinking it's real.
//
//   3. CredentialRetryPolicy — pure decision helper for client-side
//      auto-retry of IDEMPOTENT reads on a transient transport drop. Read /
//      list are safe to retry (no mutation); save / delete are NOT and must
//      never be auto-retried. The policy decides *whether* and *how long to
//      back off*; the actual retry loop lives in CredentialManager.read.
//
// All three are pure value logic — the test suite covers them without an
// .app bundle, Keychain, or network (the truthfulness / no-flake contract).

import Foundation

// MARK: - 1. Alias normalization

/// Resolves env-var-style credential aliases (e.g. `CURSOR_API_KEY`) to the
/// canonical `(service, account)` Keychain shape the vault stores.
///
/// CANONICAL SHAPE (matches CredentialAddSheet.saveApiKey / ConnectionRegistry):
///   • API keys  → service `api_key:<provider>`, account `<provider>`
///   • Notion    → service `com.notionbridge`,   account `notion_api_token`
///   • Stripe    → service `api_key:stripe`,     account `stripe`
///
/// The mapping is intentionally conservative: it only rewrites a lookup when
/// the supplied `service` looks like an env-var alias (ALL-CAPS / underscores
/// and a known `_API_KEY` / `_TOKEN` / `_KEY` / `_SECRET` suffix, or an exact
/// documented alias). An already-canonical `service` (anything containing a
/// lowercase letter or a `:`) is returned UNCHANGED so existing callers and
/// arbitrary user-defined service names are never disturbed.
public enum CredentialAliasNormalizer {

    /// A resolved canonical lookup target.
    public struct Resolved: Equatable, Sendable {
        public let service: String
        public let account: String
        /// `true` when the input was recognized as an alias and rewritten.
        public let wasAlias: Bool

        public init(service: String, account: String, wasAlias: Bool) {
            self.service = service
            self.account = account
            self.wasAlias = wasAlias
        }
    }

    /// Documented canonical alias map (env-var name → provider slug). Extend
    /// here when a new first-class provider is added. Keys are compared
    /// case-insensitively after normalization.
    static let canonicalAliasMap: [String: String] = [
        "STRIPE_API_KEY": "stripe",
        "STRIPE_SECRET_KEY": "stripe",
        "STRIPE_KEY": "stripe",
        "NOTION_API_KEY": "notion",
        "NOTION_TOKEN": "notion",
        "NOTION_API_TOKEN": "notion",
        "OPENAI_API_KEY": "openai",
        "ANTHROPIC_API_KEY": "anthropic",
        "CURSOR_API_KEY": "cursor",
        "GITHUB_TOKEN": "github",
        "GH_TOKEN": "github",
        "GITHUB_API_KEY": "github",
        "LINEAR_API_KEY": "linear",
    ]

    /// Env-var suffixes that mark a value as a secret alias when no exact map
    /// entry exists. `FOO_API_KEY` → provider `foo`.
    private static let aliasSuffixes = ["_API_KEY", "_API_TOKEN", "_SECRET_KEY", "_ACCESS_TOKEN", "_TOKEN", "_SECRET", "_KEY"]

    /// `true` when `service` looks like an env-var-style alias (ALL-CAPS letters,
    /// digits, underscores only — and at least one underscore or a documented
    /// exact match). A value with a lowercase letter or a `:` is NOT an alias.
    public static func looksLikeAlias(_ service: String) -> Bool {
        let trimmed = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if canonicalAliasMap[trimmed.uppercased()] != nil { return true }
        // Must be SCREAMING_SNAKE_CASE: only A-Z, 0-9, underscore; no ':'.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Require an underscore so a bare "STRIPE" or "GITHUB" isn't treated as
        // an alias (those are already valid bare service names).
        guard trimmed.contains("_") else { return false }
        let upper = trimmed.uppercased()
        return aliasSuffixes.contains { upper.hasSuffix($0) }
    }

    /// Map an env-var alias to its provider slug (e.g. `CURSOR_API_KEY` →
    /// `cursor`). Returns `nil` when `service` is not alias-shaped.
    public static func providerSlug(forAlias service: String) -> String? {
        let trimmed = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if let mapped = canonicalAliasMap[upper] { return mapped }
        guard looksLikeAlias(trimmed) else { return nil }
        // Strip the longest matching suffix, then lowercase the remainder.
        for suffix in aliasSuffixes where upper.hasSuffix(suffix) {
            let base = String(upper.dropLast(suffix.count))
            guard !base.isEmpty else { return nil }
            return base.lowercased()
        }
        return nil
    }

    /// Resolve a `(service, account)` lookup, rewriting an env-var alias to the
    /// canonical Keychain shape. Non-alias inputs are returned unchanged
    /// (`wasAlias == false`). Used by credential_read before hitting Keychain.
    ///
    /// - Parameters:
    ///   - service: the caller-supplied service / alias.
    ///   - account: the caller-supplied account. When the input is an alias and
    ///     the account is empty, it defaults to the provider slug (matching how
    ///     the vault stores API keys: account == provider).
    public static func resolve(service: String, account: String) -> Resolved {
        let trimmedService = service.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let provider = providerSlug(forAlias: trimmedService) else {
            return Resolved(service: service, account: account, wasAlias: false)
        }

        // Notion is stored under the bare `notion` service (account = workspace);
        // everything else uses the `api_key:<provider>` shape.
        let canonicalService: String
        let canonicalAccount: String
        if provider == "notion" {
            // Notion's token is stored by KeychainManager under the infrastructure
            // service `com.notionbridge` / account `notion_api_token` (NOT an
            // api_key:<provider> row); credential_read surfaces com.notionbridge
            // infrastructure keys via its fallback path.
            canonicalService = "com.notionbridge"
            canonicalAccount = trimmedAccount.isEmpty ? "notion_api_token" : trimmedAccount
        } else {
            canonicalService = "api_key:\(provider)"
            canonicalAccount = trimmedAccount.isEmpty ? provider : trimmedAccount
        }
        return Resolved(service: canonicalService, account: canonicalAccount, wasAlias: true)
    }
}

// MARK: - 2. Sentinel / placeholder detection

/// Flags obvious sentinel / placeholder secret values so a caller does not
/// deploy a non-secret. PURE — operates on the already-read value string; the
/// secret itself is never logged or persisted by this type.
public enum CredentialSentinelDetector {

    /// Why a value was flagged as a non-secret. Returned to the caller so the
    /// tool surface can attach a human-readable warning without re-deriving it.
    public enum Reason: String, Equatable, Sendable {
        case empty                 // "" or whitespace-only
        case knownPlaceholder      // "changeme", "password", "todo", …
        case devicePath            // "/dev/stdin", "/dev/null", "/dev/tty"
        case templateMarker        // "<your key>", "${SECRET}", "xxx…"
        case tooShort              // < 4 non-whitespace chars (not a real key)

        /// Short, caller-facing message for the warning field.
        public var message: String {
            switch self {
            case .empty:            return "value is empty — this is not a real secret"
            case .knownPlaceholder: return "value is a known placeholder, not a real secret"
            case .devicePath:       return "value is a device path, not a real secret"
            case .templateMarker:   return "value looks like an unfilled template placeholder"
            case .tooShort:         return "value is too short to be a real secret"
            }
        }
    }

    /// Exact (case-insensitive) placeholder tokens that are never real secrets.
    static let knownPlaceholders: Set<String> = [
        "changeme", "change-me", "change_me",
        "password", "passw0rd", "secret", "secrets",
        "todo", "tbd", "fixme", "placeholder", "example",
        "your-key-here", "your_key_here", "yourkeyhere",
        "none", "null", "nil", "undefined", "unset", "empty",
        "test", "testing", "dummy", "fake", "sample",
        "xxx", "xxxx", "xxxxx", "redacted", "n/a", "na",
    ]

    /// Device / pipe paths that show up when a secret was meant to be piped in
    /// but the literal path got stored instead.
    static let devicePaths: Set<String> = [
        "/dev/stdin", "/dev/stdout", "/dev/null", "/dev/tty", "/dev/zero", "-",
    ]

    /// Inspect a (possibly nil) secret value. Returns the first matching
    /// sentinel reason, or `nil` when the value appears to be a real secret.
    public static func inspect(_ value: String?) -> Reason? {
        guard let raw = value else { return .empty }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty { return .empty }

        let lower = trimmed.lowercased()

        if devicePaths.contains(lower) { return .devicePath }
        if knownPlaceholders.contains(lower) { return .knownPlaceholder }

        // Template markers: <...>, ${...}, {{...}}, or all-x runs.
        if isTemplateMarker(trimmed) { return .templateMarker }

        // Repeated single-char runs of x / * / 0 are masking placeholders.
        if isAllSameMaskChar(lower) { return .templateMarker }

        // A real API key is essentially never under 4 chars.
        if trimmed.count < 4 { return .tooShort }

        return nil
    }

    /// `true` when the value is flagged as a non-secret. Convenience over `inspect`.
    public static func isSentinel(_ value: String?) -> Bool {
        inspect(value) != nil
    }

    private static func isTemplateMarker(_ s: String) -> Bool {
        // <your key>, <YOUR_KEY>, etc.
        if s.hasPrefix("<") && s.hasSuffix(">") { return true }
        // ${SECRET}, $SECRET (shell var that never got expanded)
        if s.hasPrefix("${") && s.hasSuffix("}") { return true }
        if s.hasPrefix("$") && s.dropFirst().allSatisfy({ $0.isUppercase || $0 == "_" }) && s.count > 1 { return true }
        // {{secret}} (template engine)
        if s.hasPrefix("{{") && s.hasSuffix("}}") { return true }
        return false
    }

    private static func isAllSameMaskChar(_ lower: String) -> Bool {
        guard lower.count >= 3 else { return false }
        let maskChars: Set<Character> = ["x", "*", "0", "."]
        guard let first = lower.first, maskChars.contains(first) else { return false }
        return lower.allSatisfy { $0 == first }
    }
}

// MARK: - 3. Idempotent-read retry policy

/// PURE decision helper for client-side auto-retry of IDEMPOTENT reads on a
/// transient transport drop. Read / list are safe to retry (no state change);
/// save / delete are NOT and must never auto-retry. The actual sleep + re-issue
/// loop lives in CredentialManager.read; this type owns only the policy.
public enum CredentialRetryPolicy {

    /// Default: up to 2 retries (3 total attempts) with short exponential
    /// backoff. Tuned for a transport hiccup, not a sustained outage.
    public static let defaultMaxRetries = 2
    public static let baseBackoff: TimeInterval = 0.05   // 50ms, then 100ms

    /// Keychain `OSStatus` values that indicate a TRANSIENT failure worth
    /// retrying for an idempotent read. `errSecItemNotFound` and auth/ACL
    /// errors are DEFINITIVE — retrying them only wastes time and (for auth)
    /// risks lockout, so they are excluded.
    ///   • errSecNotAvailable (-25291): no keychain available (locked / mid-unlock).
    ///   • errSecInteractionNotAllowed (-25308): keychain locked during a UI-less call.
    ///   • errSecAuthFailed is INTENTIONALLY excluded (don't hammer auth).
    public static let transientKeychainStatuses: Set<OSStatus> = [
        -25291,  // errSecNotAvailable
        -25308,  // errSecInteractionNotAllowed
        -25299,  // errSecDuplicateItem (race during a concurrent rewrite) — read can retry
    ]

    /// Whether a given Keychain `OSStatus` should be retried on a read.
    public static func shouldRetry(status: OSStatus) -> Bool {
        transientKeychainStatuses.contains(status)
    }

    /// Backoff (seconds) before the Nth retry attempt (1-based). Exponential:
    /// attempt 1 → base, attempt 2 → 2×base, … capped so it can't run away.
    public static func backoff(forAttempt attempt: Int, base: TimeInterval = baseBackoff) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        let factor = pow(2.0, Double(attempt - 1))
        return min(base * factor, 1.0)
    }

    /// Whether another attempt is allowed given the number already made and the
    /// retryability of the last status. `attemptsMade` counts ALL attempts
    /// (including the first), so the first failure has `attemptsMade == 1`.
    public static func allowsAnotherAttempt(
        attemptsMade: Int,
        lastStatus: OSStatus,
        maxRetries: Int = defaultMaxRetries
    ) -> Bool {
        guard shouldRetry(status: lastStatus) else { return false }
        return attemptsMade <= maxRetries
    }
}
