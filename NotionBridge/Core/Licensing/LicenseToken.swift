// LicenseToken.swift — PKT-909 (Sell/Distribute v3 · 1) W1
// NotionBridge · Core · Licensing
//
// Ed25519-signed license token format. The token a customer receives is a
// single line of text — `<base64url(payload)>.<base64url(signature)>` —
// inspired by JWT but flat (no alg header; the app's bundled public key
// is the only verification key, so an `alg` field would be either a
// no-op or an attacker-controllable downgrade vector).
//
// PAYLOAD shape (signed JSON object, canonical key order):
//   {
//     "v":   1,                            // schema version
//     "id":  "ord_…",                      // opaque order/license id
//     "sub": "buyer@example.com",          // subject (display only)
//     "kind":"paid"|"grandfather",         // license class
//     "iat": 1748390400,                   // issued-at (unix seconds)
//     "exp": null | 1779926400             // optional expiry
//   }
//
// VERIFY contract:
//   - `verify(_:publicKey:)` is pure — given the same token + key the
//     answer is deterministic and offline.
//   - Tampering ANY payload byte invalidates the signature.
//   - A correct signature with a payload that fails schema validation
//     (unknown version, missing field, malformed) is REJECTED — schema
//     mismatch is treated as forgery, not "partial".
//   - Expiry is NOT consulted here; this verifies authenticity only. The
//     LicenseManager applies expiry in the consumer layer so a "valid
//     signature but expired" token is still distinguishable from "junk".
//
// We avoid base64 (NOT url-safe) on purpose: the token is going to end up
// pasted into a TextField, possibly URL-encoded for "License://activate"
// links, or sent over HTTP. base64url ([A-Za-z0-9_-], no padding) is
// safe in every transport and idempotent across copy-paste.

import Foundation
import CryptoKit

// MARK: - Token payload

/// The signed inner payload of a license token. The wire form is the
/// canonical JSON encoding (sorted keys, no extra whitespace) so a
/// recipient who re-encodes can verify byte-for-byte.
public struct LicenseTokenPayload: Codable, Equatable, Sendable {
    /// Current schema version. v1 is the only accepted value.
    public static let currentVersion = 1

    public let v: Int
    public let id: String
    public let sub: String
    public let kind: String          // "paid" | "grandfather"
    public let iat: Int64            // unix seconds
    public let exp: Int64?           // unix seconds; nil = no expiry

    public init(v: Int = LicenseTokenPayload.currentVersion,
                id: String,
                sub: String,
                kind: String,
                iat: Int64,
                exp: Int64?) {
        self.v = v
        self.id = id
        self.sub = sub
        self.kind = kind
        self.iat = iat
        self.exp = exp
    }

    /// Encode to canonical bytes for signing or verification. Keys are
    /// always emitted in `.sortedKeys` order so two callers who reconstruct
    /// the payload from the same fields produce the same byte sequence.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Schema validation — surfaced as part of verify so a forged-but-
    /// mal-shaped payload is rejected as forgery, not "partial".
    public func validate() throws {
        guard v == LicenseTokenPayload.currentVersion else {
            throw LicenseVerifyError.unsupportedVersion(v)
        }
        guard !id.isEmpty else {
            throw LicenseVerifyError.malformed("id is empty")
        }
        guard !sub.isEmpty else {
            throw LicenseVerifyError.malformed("sub is empty")
        }
        guard kind == "paid" || kind == "grandfather" else {
            throw LicenseVerifyError.malformed("kind must be 'paid' or 'grandfather'")
        }
        guard iat > 0 else {
            throw LicenseVerifyError.malformed("iat must be > 0")
        }
        if let exp = exp {
            guard exp >= iat else {
                throw LicenseVerifyError.malformed("exp must be >= iat")
            }
        }
    }
}

// MARK: - Verify errors

public enum LicenseVerifyError: Error, Equatable, LocalizedError {
    case malformed(String)
    case unsupportedVersion(Int)
    case badSignature
    case invalidBase64
    case invalidPublicKey

    public var errorDescription: String? {
        switch self {
        case .malformed(let why):       return "License token malformed: \(why)"
        case .unsupportedVersion(let v): return "License token version \(v) is not supported."
        case .badSignature:              return "License token signature is invalid."
        case .invalidBase64:             return "License token is not valid base64url."
        case .invalidPublicKey:          return "Bundled license public key is unreadable."
        }
    }
}

// MARK: - LicenseToken (verify-only API)

/// Verify-only API. Signing happens off-device (Cloudflare worker / build
/// script), so this app never needs the Ed25519 private key.
public enum LicenseToken {

    /// Encode the dot-separated wire form. Used by tests; production code
    /// only consumes the wire form from the operator/server.
    public static func encode(payload: LicenseTokenPayload, signedBy privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payloadBytes = try payload.canonicalJSON()
        let signature    = try privateKey.signature(for: payloadBytes)
        return Self.base64url(payloadBytes) + "." + Self.base64url(signature)
    }

    /// Verify a license token against the bundled Ed25519 public key.
    ///
    /// Returns the parsed payload on success; throws `LicenseVerifyError`
    /// otherwise. Expiry is NOT consulted here — see LicenseManager.
    @discardableResult
    public static func verify(_ token: String, publicKey: Curve25519.Signing.PublicKey) throws -> LicenseTokenPayload {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw LicenseVerifyError.malformed("token must have exactly one '.' separator")
        }
        guard let payloadBytes = Self.base64urlDecode(String(parts[0])),
              let signature    = Self.base64urlDecode(String(parts[1])) else {
            throw LicenseVerifyError.invalidBase64
        }

        // CryptoKit verifies CONSTANT-time; we don't need to wrap.
        guard publicKey.isValidSignature(signature, for: payloadBytes) else {
            throw LicenseVerifyError.badSignature
        }

        let decoder = JSONDecoder()
        let payload: LicenseTokenPayload
        do {
            payload = try decoder.decode(LicenseTokenPayload.self, from: payloadBytes)
        } catch {
            throw LicenseVerifyError.malformed("payload JSON: \(error.localizedDescription)")
        }
        try payload.validate()
        return payload
    }

    // MARK: - base64url (no padding) helpers

    public static func base64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    public static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        // Restore padding to a multiple of 4.
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

// MARK: - Public key (bundled)

/// The Ed25519 public key compiled into the app. Operators rotate this
/// by re-signing tokens with the matching private key and shipping a new
/// build. The placeholder default is INTENTIONALLY non-functional so any
/// unconfigured deployment fails-closed (no token verifies); the build
/// script overwrites this via `LICENSE_PUBLIC_KEY_BASE64URL` at compile
/// time before release.
///
/// HONEST-LEDGER: at PKT-909 W1 ship the operator-provided key is not
/// yet integrated; the LicensePublicKey type is the seam. Tests use a
/// freshly-generated keypair, NOT the production key, so they remain
/// correct regardless of the production key's status.
public enum LicensePublicKey {

    /// Bundled key, base64url-encoded raw 32-byte Ed25519 public key.
    ///
    /// Until the production key is wired (release engineering task in
    /// PKT-909 close-out), this string is empty so `bundled()` returns
    /// nil. A nil bundled key + a non-grandfather user means "no paste-
    /// key path works yet" — the trial timer is the only gate. Once
    /// wired the string is non-empty and paste-key activation works.
    public static let bundledBase64URL: String = ""

    /// Returns the bundled public key, or nil if no key has been
    /// compiled in. Callers should treat nil as "paste-key activation
    /// disabled" not "every token verifies".
    public static func bundled() -> Curve25519.Signing.PublicKey? {
        guard !bundledBase64URL.isEmpty,
              let raw = LicenseToken.base64urlDecode(bundledBase64URL) else {
            return nil
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}
