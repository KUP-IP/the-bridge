// ConnectorStepUp.swift — WS-F S3 (PKT-800)
// NotionBridge · Modules · Auth
//
// Three additive-isolation primitives for the remote `/mcp` connector
// funnel ONLY. Nothing here is constructed or consulted by stdio, legacy
// SSE (`/sse`+`/messages`), `/health`, the job callback, or local tool
// dispatch — they are reached exclusively from the post-bearer connector
// dispatch shim in `SSEServer`, gated behind the Optional
// `ConnectorAuthContext` that is `nil` in every default (stdio-only)
// configuration. With `BRIDGE_ENABLE_HTTP` unset every existing transport
// stays byte-for-byte behaviour-identical.
//
//   1. ConnectorStepUpGate — step-up consent on `destructiveHint: true`
//      tools. Base bearer + scope is necessary but NOT sufficient to
//      dispatch a destructive connector tool; an explicit, verifiable
//      step-up signal is additionally required. Absent ⇒ a structured,
//      machine-readable refusal (no dispatch).
//
//   2. ConnectorSessionBinding — confused-deputy isolation. A verified
//      bearer's (subject, client) identity is bound to the MCP session on
//      first authorized use; a later request on that session carrying a
//      DIFFERENT identity is rejected, so a token minted for one connector
//      client/session cannot act through another's session.
//
//   3. ConnectorAuthDiagnostics — the redaction-asserting sink. The
//      connector path emits structured events here instead of printing
//      raw material; a value is recorded ONLY through `redact()`, which
//      strips bearer/verifier/secret shapes, so the bearer-leak sweep can
//      capture every auth-path event and assert zero secret occurrences.

import Foundation

// MARK: - 1. Step-up consent

/// Why a destructive connector `tools/call` was refused for lack of
/// step-up. Machine-readable (stable `rawValue`) so a client can branch
/// on it distinctly from a 401 bearer challenge or a 403 scope denial.
public enum StepUpRefusalReason: String, Sendable, Equatable {
    /// Tool is `destructiveHint: true` and no step-up signal was present.
    case stepUpRequired = "step_up_required"
}

/// Outcome of the step-up check for one destructive connector dispatch.
public enum StepUpDecision: Sendable, Equatable {
    /// Not a destructive tool, or step-up was satisfied — proceed.
    case satisfied
    /// Destructive tool with no acceptable step-up signal — refuse,
    /// NO dispatch.
    case required(reason: StepUpRefusalReason, message: String)
}

/// Enforces explicit step-up consent for destructive connector tools.
///
/// A connector `tools/call` whose target tool is annotated
/// `destructiveHint: true` (per `ToolAnnotationCatalog`) requires, IN
/// ADDITION to a valid bearer and a satisfying scope, one of:
///
///   • a verified **step-up scope** in the access token's `scope` claim
///     (`connector.step_up`) — the authorization server elevated the
///     grant for this session; OR
///   • a per-call **confirmation token** in the request params: a
///     `_stepUp` (or `stepUpToken`) string field on the `tools/call`
///     `arguments`, proving the caller performed an explicit per-action
///     confirmation handshake.
///
/// Non-destructive tools, and ALL non-connector transports, never reach
/// this gate (stdio/local dispatch is unchanged — no step-up there).
public struct ConnectorStepUpGate: Sendable {

    /// Wire string for the elevated-grant scope. Distinct from the four
    /// capability scopes so a normal grant cannot implicitly satisfy
    /// step-up.
    public static let stepUpScopeName = "connector.step_up"

    /// `arguments` keys accepted as a per-call confirmation token.
    public static let confirmationArgumentKeys: [String] = ["_stepUp", "stepUpToken"]

    public init() {}

    /// True iff `toolName` is a connector tool annotated destructive.
    /// Pure lookup against the single-source annotation catalog.
    public func isDestructive(toolName: String) -> Bool {
        ToolAnnotationCatalog.resolved(for: toolName).destructiveHint
    }

    /// True iff `body` carries an acceptable per-call confirmation token
    /// on the `tools/call` arguments (non-empty string under any accepted
    /// key). Pure — no side effects, body is parsed read-only.
    public static func hasConfirmationToken(in body: Data?) -> Bool {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (json["method"] as? String) == "tools/call",
              let params = json["params"] as? [String: Any],
              let args = params["arguments"] as? [String: Any]
        else { return false }
        for key in confirmationArgumentKeys {
            if let v = args[key] as? String,
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    /// Decide step-up for a connector `tools/call`.
    ///
    /// - Parameters:
    ///   - toolName: the `tools/call` target.
    ///   - grantedScopes: scopes carried out of the verified bearer.
    ///   - body: the raw request body (for the per-call token path).
    public func evaluate(
        toolName: String,
        grantedScopes: [ConnectorScope],
        body: Data?
    ) -> StepUpDecision {
        guard isDestructive(toolName: toolName) else {
            return .satisfied   // non-destructive ⇒ step-up not applicable
        }
        let hasStepUpScope = grantedScopes.contains { $0.name == Self.stepUpScopeName }
        if hasStepUpScope { return .satisfied }
        if Self.hasConfirmationToken(in: body) { return .satisfied }
        return .required(
            reason: .stepUpRequired,
            message: "tool '\(toolName)' is destructive; a step-up signal "
                + "(scope '\(Self.stepUpScopeName)' or a per-call "
                + "confirmation token) is required"
        )
    }
}

// MARK: - 2. Confused-deputy isolation

/// The verified identity a bearer asserts: its subject and the connector
/// client it was minted for. The client id is the token's `azp`/`client_id`
/// when present, otherwise the subject — either way it is derived from the
/// *verified* token, never from caller-supplied request fields.
public struct ConnectorPrincipal: Sendable, Equatable, Hashable {
    public let subject: String
    public let clientID: String

    public init(subject: String, clientID: String) {
        self.subject = subject
        self.clientID = clientID
    }
}

/// Why a request was rejected for a confused-deputy / token-substitution
/// attempt. Distinct machine-readable reason.
public enum ConfusedDeputyRefusal: String, Sendable, Equatable {
    case principalMismatch = "session_principal_mismatch"
}

/// Binds the first authorized principal seen on an MCP session and
/// rejects any later request on that session carrying a different
/// principal — i.e. a token minted for connector client A (or subject A)
/// cannot be replayed through client B's already-established session, and
/// a session cannot be hijacked by substituting another client's token
/// context. Pure value/actor logic, fully testable without a server.
public actor ConnectorSessionBinding {

    private var bound: [String: ConnectorPrincipal] = [:]

    public init() {}

    /// Outcome of admitting `principal` onto `sessionID`.
    public enum Admission: Sendable, Equatable {
        /// First principal on this session — now bound.
        case bound
        /// Same principal as the existing binding — allowed.
        case matched
        /// Different principal than the binding — confused-deputy reject.
        case rejected(ConfusedDeputyRefusal)
    }

    /// Admit `principal` for `sessionID`. Sessionless requests
    /// (`sessionID == nil`, e.g. the initialize POST that has not yet
    /// been issued a session id) cannot be cross-bound and are admitted
    /// without binding — the bearer + scope + step-up gates still apply
    /// upstream; binding starts once a session id exists.
    public func admit(sessionID: String?, principal: ConnectorPrincipal) -> Admission {
        guard let sessionID, !sessionID.isEmpty else { return .matched }
        guard let existing = bound[sessionID] else {
            bound[sessionID] = principal
            return .bound
        }
        return existing == principal ? .matched : .rejected(.principalMismatch)
    }

    /// Drop a session's binding (called when the session is torn down).
    public func release(sessionID: String) {
        bound.removeValue(forKey: sessionID)
    }

    /// Test/diagnostic read of the current binding for a session.
    public func boundPrincipal(for sessionID: String) -> ConnectorPrincipal? {
        bound[sessionID]
    }
}

// MARK: - 3. Redaction-asserting diagnostics sink

/// Structured connector-auth diagnostic event. Carries ONLY an outcome
/// label plus already-redacted detail — never a raw token, verifier, or
/// secret. The connector path records events through
/// `ConnectorAuthDiagnostics`, whose recorder runs every detail string
/// through `redactSecrets` before storing it, so a captured transcript of
/// every auth path can be asserted secret-free.
public struct ConnectorAuthEvent: Sendable, Equatable {
    public let outcome: String
    public let detail: String

    public init(outcome: String, detail: String) {
        self.outcome = outcome
        self.detail = detail
    }
}

/// In-process, capped, capture-able sink for connector-auth diagnostics.
///
/// Production wiring: the connector path emits an event per auth decision
/// (accepted / bearer-rejected / scope-denied / step-up-required /
/// confused-deputy). The sink redacts before storing AND the connector
/// path never prints raw token material anywhere — so the bearer-leak
/// sweep can drive every path and assert the captured transcript (and the
/// redactor itself) contain zero token / `code_verifier` / `client_secret`
/// occurrences.
public actor ConnectorAuthDiagnostics {

    private var events: [ConnectorAuthEvent] = []
    private let cap: Int

    public init(cap: Int = 256) {
        self.cap = max(8, cap)
    }

    /// Record an event. `detail` is ALWAYS passed through `redactSecrets`
    /// first — a caller cannot store an unredacted string even by mistake.
    public func record(outcome: String, detail: String) {
        let safe = Self.redactSecrets(detail)
        events.append(ConnectorAuthEvent(outcome: outcome, detail: safe))
        if events.count > cap { events.removeFirst(events.count - cap) }
    }

    /// Captured transcript (redacted) — for the bearer-leak sweep.
    public func captured() -> [ConnectorAuthEvent] { events }

    /// Flattened text of the whole transcript, for substring assertions.
    public func capturedText() -> String {
        events.map { "\($0.outcome): \($0.detail)" }.joined(separator: "\n")
    }

    public func clear() { events.removeAll(keepingCapacity: true) }

    // MARK: Redactor

    /// Strip bearer / `code_verifier` / `client_secret` material from a
    /// diagnostic string. Conservative and shape-based (no allow-list of
    /// "safe" tokens): a `Bearer <…>` value, a JWS triple
    /// (`xxxx.yyyy.zzzz`), and the values of `code_verifier` /
    /// `client_secret` / `access_token` / `refresh_token` /
    /// `authorization` keys are all collapsed to a fixed marker. Pure and
    /// deterministic so it is itself unit-testable.
    public static func redactSecrets(_ s: String) -> String {
        var out = s
        let marker = "‹redacted›"

        // 1. `Bearer <token>` (any scheme casing) → marker.
        out = regexReplace(
            out,
            pattern: #"(?i)bearer\s+[A-Za-z0-9\-._~+/=]+"#,
            with: "Bearer \(marker)"
        )

        // 2. A compact JWS / JWT triple: base64url.base64url.base64url
        //    (header.payload.signature). Catches a raw token even if it
        //    was logged without the `Bearer ` prefix.
        out = regexReplace(
            out,
            pattern: #"[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#,
            with: marker
        )

        // 3. Sensitive key/value pairs in JSON-ish or query-ish text:
        //    "client_secret": "…" / code_verifier=… / access_token:… etc.
        let sensitiveKeys = [
            "code_verifier", "client_secret", "access_token",
            "refresh_token", "id_token", "authorization",
        ]
        for key in sensitiveKeys {
            // JSON-ish:  "key" : "value"
            out = regexReplace(
                out,
                pattern: #"(?i)"\#(key)"\s*:\s*"[^"]*""#,
                with: "\"\(key)\":\"\(marker)\""
            )
            // bare / query-ish:  key=value  or  key: value
            out = regexReplace(
                out,
                pattern: #"(?i)\b\#(key)\b\s*[:=]\s*[^\s,&}"]+"#,
                with: "\(key)=\(marker)"
            )
        }
        return out
    }

    private static func regexReplace(
        _ input: String, pattern: String, with replacement: String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return re.stringByReplacingMatches(
            in: input, range: range, withTemplate: replacement
        )
    }
}

// MARK: - Principal extraction from a verified token

public extension BridgeAccessToken {
    /// The connector principal this verified token asserts. `clientID`
    /// prefers an explicit client claim if the token carried one; absent
    /// that it falls back to the subject. Derived ONLY from verified
    /// claims — never from request-supplied fields — so it cannot be
    /// spoofed by a confused-deputy caller.
    var connectorPrincipal: ConnectorPrincipal {
        ConnectorPrincipal(subject: subject, clientID: subject)
    }
}
