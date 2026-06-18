// LicenseRevocationClient.swift — PKT-909 (Sell/Distribute v3 · 1) W4
// TheBridge · Core · Licensing
//
// Optional online revocation check. The signature gate is the SECURITY
// BOUNDARY — this is a best-effort hint that lets us disable a refunded
// or revoked license without shipping a new public key.
//
// CONTRACT:
//   • Every call is short-circuited offline-first: a nil URL session or
//     a non-2xx response returns `.unknown` and the caller is expected
//     to keep the offline-verified state.
//   • The response is *never* trusted to UPGRADE state. A worker that
//     replies "active" for a token whose signature failed cannot
//     bypass the gate (the signature check ran first).
//   • The endpoint is rate-limited to once per hour per process; the
//     LicenseManager caches the last result.
//   • Tests inject a fake URLSession; production calls
//     https://kup.solutions/api/nb/verify with a 5s timeout.

import Foundation

public enum LicenseRevocationStatus: String, Codable, Equatable, Sendable {
    case active
    case revoked
    case refunded
    case unknown
}

public struct LicenseRevocationResponse: Codable, Equatable, Sendable {
    public let status: LicenseRevocationStatus
    public let expiresAt: Int64?
    public let checkedAt: Int64

    public init(status: LicenseRevocationStatus, expiresAt: Int64?, checkedAt: Int64) {
        self.status = status
        self.expiresAt = expiresAt
        self.checkedAt = checkedAt
    }
}

/// Pluggable network transport so tests can drive the client without
/// mocking URLSession's class hierarchy.
public protocol LicenseRevocationTransport: Sendable {
    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)?
}

/// URLSession-backed default transport.
public struct URLSessionRevocationTransport: LicenseRevocationTransport {
    public init() {}
    public func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return (data, code)
        } catch {
            return nil
        }
    }
}

public actor LicenseRevocationClient {
    public static let defaultURL = URL(string: "https://kup.solutions/api/nb/verify")!

    private let url: URL
    private let transport: LicenseRevocationTransport
    private let timeout: TimeInterval

    public init(
        url: URL = LicenseRevocationClient.defaultURL,
        transport: LicenseRevocationTransport = URLSessionRevocationTransport(),
        timeout: TimeInterval = 5.0
    ) {
        self.url = url
        self.transport = transport
        self.timeout = timeout
    }

    /// Check the revocation status of a license id. Returns nil if the
    /// network is unreachable / response malformed. Callers MUST treat
    /// nil as "no signal" — never as "revoked".
    public func check(licenseId: String) async -> LicenseRevocationResponse? {
        // Defensive input shape — match worker validation.
        let trimmed = licenseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 128 else { return nil }

        let req = ["id": trimmed, "v": 1] as [String: Any]
        guard let body = try? JSONSerialization.data(withJSONObject: req) else { return nil }
        guard let (data, code) = await transport.post(url, body: body, timeout: timeout) else { return nil }
        guard (200..<300).contains(code) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(LicenseRevocationResponse.self, from: data)
    }
}
