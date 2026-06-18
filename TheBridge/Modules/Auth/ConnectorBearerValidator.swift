// ConnectorBearerValidator.swift — WS-F S2 (PKT-800)
// TheBridge · Modules · Auth
//
// RFC 6750 Bearer-token validation for the remote-MCP *connector* path
// (`/mcp` Streamable HTTP) ONLY. This is the additive-isolation core:
// nothing here is invoked from stdio, legacy SSE (`/sse`+`/messages`),
// `/health`, the job callback, or local tool dispatch — the SSE NIO
// handler reaches this code exclusively on the `.mcpEndpoint` route, so
// every existing transport stays byte-for-byte behaviour-identical.
//
// Crypto is NOT rolled here: JWS signature verification + JWKS handling
// are delegated to JWTKit (vapor/jwt-kit 5.5.0, swift-crypto backed).
// `iss` / `aud` / `exp` / `nbf` are validated in `BridgeAccessToken`'s
// `JWTPayload.verify`. Keys come from an injectable `JWTKeyCollection`
// (tests add a synthetic ES256 public key directly — no network) or, in
// production, from a JWKS document resolved out of `BRIDGE_OAUTH_JWKS`
// (inline JSON or a local file path — still no network).

import Foundation
import JWTKit

// MARK: - Verified access-token payload

/// The subset of RFC 9068 / OAuth 2.1 access-token claims the connector
/// enforces. `verify(using:)` is where `iss` / `aud` / `exp` / `nbf` are
/// checked — JWTKit has already verified the JWS signature against the
/// resolved key before this runs.
public struct BridgeAccessToken: JWTPayload, Sendable, Equatable {
    public let iss: IssuerClaim
    public let aud: AudienceClaim
    public let sub: SubjectClaim?
    public let exp: ExpirationClaim
    public let nbf: NotBeforeClaim?
    /// Space-delimited OAuth scope string (RFC 8693 §4.2 `scope`).
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case iss, aud, sub, exp, nbf, scope
    }

    /// Carried out of token validation into the connector dispatch path:
    /// the resolved subject and the parsed connector scopes.
    public var subject: String { sub?.value ?? "" }

    /// Parsed, de-duplicated connector scopes from the `scope` claim.
    public var connectorScopes: [ConnectorScope] {
        guard let scope, !scope.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [ConnectorScope] = []
        for raw in scope.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            let name = String(raw)
            if seen.insert(name).inserted { out.append(ConnectorScope(name: name)) }
        }
        return out
    }

    public init(
        iss: IssuerClaim,
        aud: AudienceClaim,
        sub: SubjectClaim?,
        exp: ExpirationClaim,
        nbf: NotBeforeClaim?,
        scope: String?
    ) {
        self.iss = iss
        self.aud = aud
        self.sub = sub
        self.exp = exp
        self.nbf = nbf
        self.scope = scope
    }

    /// Expected issuer / audience are injected via the JWTKit verification
    /// context so this stays a pure claim check (JWTKit verifies the JWS
    /// signature before calling this).
    public func verify(using _: some JWTAlgorithm) async throws {
        // `exp` / `nbf` are time-window checks (clock-skew tolerant via
        // JWTKit defaults). `iss` / `aud` are bound to the configured
        // values by `ConnectorBearerValidator` (it constructs the validator
        // with the expected issuer + resource and re-checks here through
        // the static expectation set just before verify()).
        do {
            try exp.verifyNotExpired()
        } catch {
            throw BearerValidationError.expired
        }
        if let nbf {
            do {
                try nbf.verifyNotBefore()
            } catch {
                throw BearerValidationError.notYetValid
            }
        }

        guard let expected = BridgeAccessToken.expectation else {
            // No expectation configured ⇒ refuse rather than accept an
            // unbound token (fail-closed).
            throw BearerValidationError.misconfigured
        }
        guard iss.value == expected.issuer else {
            throw BearerValidationError.issuerMismatch(
                expected: expected.issuer, got: iss.value
            )
        }
        do {
            try aud.verifyIntendedAudience(includes: expected.audience)
        } catch {
            throw BearerValidationError.audienceMismatch(
                expected: expected.audience, got: aud.value
            )
        }
    }

    // MARK: Expectation binding

    /// Issuer + audience the current verification must match. Set by
    /// `ConnectorBearerValidator.validate` immediately before `verify()` and
    /// task-local so concurrent validations cannot cross-contaminate.
    @TaskLocal static var expectation: Expectation?

    struct Expectation: Sendable {
        let issuer: String
        let audience: String
    }
}

// MARK: - Errors

public enum BearerValidationError: Error, Equatable, Sendable {
    /// No `Authorization: Bearer …` header on a connector request.
    case missingBearer
    /// Header present but not a well-formed `Bearer <token>`.
    case malformedAuthorizationHeader
    /// JWS signature did not verify against the configured key set.
    case signatureInvalid
    case issuerMismatch(expected: String, got: String)
    case audienceMismatch(expected: String, got: [String])
    case expired
    case notYetValid
    /// Validator has no keys / no issuer expectation (fail-closed).
    case misconfigured
    /// JWTKit rejected the token for any other structural reason.
    case malformedToken(String)

    /// RFC 6750 §3 `error` code for the `WWW-Authenticate` challenge.
    public var wwwAuthenticateError: String {
        switch self {
        case .missingBearer:
            return "invalid_request"
        default:
            return "invalid_token"
        }
    }
}

// MARK: - Validator

/// Validates connector bearer tokens against an injectable key set.
///
/// Constructed either with an explicit `JWTKeyCollection` (tests inject a
/// synthetic ES256 public key — no network) or from the environment
/// (`BRIDGE_OAUTH_JWKS` → inline JWKS JSON or a local file path — still no
/// network; absence ⇒ a key-less validator that fail-closed-rejects every
/// token, so enabling the connector without configuring keys cannot
/// silently accept traffic).
public struct ConnectorBearerValidator: Sendable {

    /// Env var holding either an inline JWKS JSON document or a local
    /// filesystem path to one. Never fetched over the network.
    public static let jwksEnvKey = "BRIDGE_OAUTH_JWKS"

    private let keys: JWTKeyCollection
    private let expectedIssuer: String
    private let expectedAudience: String
    private let hasKeys: Bool

    /// Designated initializer — explicit key collection (test seam).
    public init(
        keys: JWTKeyCollection,
        hasKeys: Bool,
        expectedIssuer: String,
        expectedAudience: String
    ) {
        self.keys = keys
        self.hasKeys = hasKeys
        self.expectedIssuer = expectedIssuer
        self.expectedAudience = expectedAudience
    }

    /// Production initializer — resolves the key set from
    /// `BRIDGE_OAUTH_JWKS` (inline JSON or local file). Any failure to
    /// load keys yields a fail-closed (key-less) validator.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        expectedIssuer: String,
        expectedAudience: String
    ) async -> ConnectorBearerValidator {
        let collection = JWTKeyCollection()
        var loaded = false

        if let raw = environment[jwksEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            let jwksJSON: String?
            if raw.hasPrefix("{") {
                jwksJSON = raw
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: raw)),
                      let text = String(data: data, encoding: .utf8) {
                jwksJSON = text
            } else {
                jwksJSON = nil
            }
            if let jwksJSON {
                do {
                    _ = try await collection.add(jwksJSON: jwksJSON)
                    loaded = true
                } catch {
                    loaded = false
                }
            }
        }

        return ConnectorBearerValidator(
            keys: collection,
            hasKeys: loaded,
            expectedIssuer: expectedIssuer,
            expectedAudience: expectedAudience
        )
    }

    // MARK: Header extraction

    /// Extracts a bearer token from an `Authorization` header value.
    /// Returns `nil` if absent / not a `Bearer` scheme / empty token.
    public static func bearerToken(fromAuthorizationHeader header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame
        else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    // MARK: Validate

    /// Validates the raw `Authorization` header value. On success returns
    /// the verified token (subject + scopes ready for dispatch). On any
    /// failure throws a typed `BearerValidationError`.
    public func validate(authorizationHeader: String?) async throws -> BridgeAccessToken {
        guard hasKeys else { throw BearerValidationError.misconfigured }
        guard let token = Self.bearerToken(fromAuthorizationHeader: authorizationHeader) else {
            // Distinguish "no header at all" from "garbled header".
            if authorizationHeader == nil
                || authorizationHeader?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                throw BearerValidationError.missingBearer
            }
            throw BearerValidationError.malformedAuthorizationHeader
        }

        let expectation = BridgeAccessToken.Expectation(
            issuer: expectedIssuer,
            audience: expectedAudience
        )

        do {
            return try await BridgeAccessToken.$expectation.withValue(expectation) {
                try await keys.verify(token, as: BridgeAccessToken.self, iteratingKeys: true)
            }
        } catch let e as BearerValidationError {
            throw e
        } catch let e as JWTError {
            // Map JWTKit's structured failures onto our typed surface.
            // `JWTError.ErrorType` is a struct (not a Swift enum), so this
            // is `==` dispatch, not pattern matching.
            if e.errorType == .signatureVerificationFailed {
                throw BearerValidationError.signatureInvalid
            }
            // claimVerificationFailure / malformedToken / unknownKID /
            // noKeyProvided etc. — the claim layer already threw a typed
            // BearerValidationError where it could (iss/aud/exp/nbf);
            // anything reaching here is a structural rejection.
            throw BearerValidationError.malformedToken(String(describing: e.errorType))
        } catch {
            throw BearerValidationError.malformedToken("\(error)")
        }
    }
}
