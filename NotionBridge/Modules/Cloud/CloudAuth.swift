// CloudAuth.swift — WS-F (Bridge Cloud Access · Enable flow)
// NotionBridge · Modules · Cloud
//
// The WorkOS sign-in primitives for the Enable Cloud Access flow, kept in
// the LIB target (not App/) so every branch is unit-testable headlessly —
// no NSWorkspace, no live WorkOS network, no .app bundle. Three pieces:
//
//   1. `WorkOSConfig`        — env-configurable client_id + base URL +
//                              redirect_uri. Live values come from the
//                              operator's WorkOS tenant (PKT-810); tests
//                              and the un-provisioned local build fall back
//                              to documented placeholders. NO secret here.
//   2. `WorkOSAuthURLBuilder`— builds the system-browser authorization URL
//                              (Q1 decision lock: system browser + the
//                              `bridge-auth://callback` redirect, no
//                              WKWebView).
//   3. `CloudAuthCallback`   — the PURE parse of an inbound
//                              `bridge-auth://callback?code=…` URL into an
//                              auth code (or a typed failure). The Keychain
//                              write + Notification post that wrap it live
//                              in `AppDelegate` (App target), but the brittle
//                              URL-shape logic is here and fully tested.
//
// Per the packet OUT-of-scope note: this builds the URL builder with an
// env-configurable WORKOS_CLIENT_ID; a LIVE code→token exchange requires
// the real client id + redirect_uri configured in the WorkOS dashboard
// (PKT-810 operator provisioning). The token-exchange HTTP call is modeled
// behind the injectable `CloudTokenExchanging` seam so unit tests never
// touch the network.

import Foundation

/// Env-configurable WorkOS OAuth configuration. Live values are provisioned
/// by the operator (PKT-810); absent env vars fall back to documented
/// placeholders so the local build compiles and the Enable flow can be
/// exercised end-to-end against mocks. Carries NO client secret — the
/// public OAuth client_id + the `bridge-auth://callback` redirect only.
public struct WorkOSConfig: Sendable, Equatable {
    /// WorkOS authorization base, e.g. `https://api.workos.com`.
    public let baseURL: String
    /// The public OAuth client id (env `WORKOS_CLIENT_ID`). A placeholder
    /// until PKT-810 provisions the real tenant.
    public let clientID: String
    /// The OAuth redirect — the custom scheme the app registers (Q1 lock).
    public let redirectURI: String

    public init(baseURL: String, clientID: String, redirectURI: String) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    /// Documented placeholder for an un-provisioned build / tests.
    public static let placeholder = WorkOSConfig(
        baseURL: "https://api.workos.com",
        clientID: "client_PLACEHOLDER_pkt810",
        redirectURI: "bridge-auth://callback"
    )

    /// Resolve config from the environment, falling back to `placeholder`
    /// for any unset value. Injectable `environment` keeps this pure for
    /// tests (no real `ProcessInfo` dependency).
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WorkOSConfig {
        WorkOSConfig(
            baseURL: environment["WORKOS_BASE_URL"]?.nonEmpty ?? placeholder.baseURL,
            clientID: environment["WORKOS_CLIENT_ID"]?.nonEmpty ?? placeholder.clientID,
            redirectURI: environment["WORKOS_REDIRECT_URI"]?.nonEmpty ?? placeholder.redirectURI
        )
    }
}

/// Builds the WorkOS authorization URL opened in the system browser. Pure
/// + deterministic so the query shape is unit-asserted without opening a
/// browser.
public enum WorkOSAuthURLBuilder {
    /// The authorization URL for `config`. Returns `nil` only if the base
    /// URL is unparseable (a misconfigured tenant) — callers treat that as
    /// `CloudError.authURLUnavailable`.
    public static func authorizationURL(for config: WorkOSConfig) -> URL? {
        guard var components = URLComponents(string: config.baseURL) else { return nil }
        // WorkOS AuthKit / User Management authorization endpoint.
        let basePath = components.path
        components.path = (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
            + "/user_management/authorize"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "provider", value: "authkit"),
        ]
        return components.url
    }
}

/// The two ways parsing an inbound auth callback URL can resolve.
public enum CloudAuthCallback: Sendable, Equatable {
    /// A well-formed `bridge-auth://callback?code=…` — carries the code to
    /// exchange. The code is an opaque one-time grant, NOT a credential.
    case code(String)
    /// The URL is not a usable auth callback (wrong scheme/host, no code,
    /// or WorkOS returned an `error` query param).
    case invalid(reason: String)

    /// Pure parse of an inbound URL. Accepts only the `bridge-auth` scheme
    /// with host `callback` and a non-empty `code` query item. A WorkOS
    /// `error=…` param (user denied, etc.) maps to `.invalid`.
    ///
    /// This is the brittle bit AppDelegate's `application(_:open:options:)`
    /// delegates to before it writes the Keychain + posts the Notification.
    public static func parse(_ url: URL) -> CloudAuthCallback {
        guard url.scheme?.lowercased() == "bridge-auth" else {
            return .invalid(reason: "wrong scheme: \(url.scheme ?? "nil")")
        }
        guard url.host?.lowercased() == "callback" else {
            return .invalid(reason: "wrong host: \(url.host ?? "nil")")
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value, !err.isEmpty {
            return .invalid(reason: "workos error: \(err)")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .invalid(reason: "missing code")
        }
        return .code(code)
    }
}

/// The injectable code→token exchange seam (POST WorkOS `/oauth/token`).
/// Production wraps `URLSession`; tests inject a deterministic fake so no
/// live WorkOS call is made (per the packet's hard "mocks only" rule).
public protocol CloudTokenExchanging: Sendable {
    /// Exchange a one-time auth `code` for a session token string. Throws on
    /// any non-success / transport failure.
    func exchange(code: String, config: WorkOSConfig) async throws -> String
}

/// Production `URLSession`-backed exchange. NOT used by unit tests. Left
/// thin: the live wire-up is gated on PKT-810 (real client id + a tenant
/// that will actually mint a token), so this is the seam the operator
/// completes, not a network path the test suite ever drives.
public struct URLSessionTokenExchange: CloudTokenExchanging {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func exchange(code: String, config: WorkOSConfig) async throws -> String {
        guard let url = URL(string: config.baseURL.appendingPathComponentSafe("user_management/authenticate")) else {
            throw CloudError.authURLUnavailable
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": config.clientID,
            "grant_type": "authorization_code",
            "code": code,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.tokenExchangeFailed
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = (obj["access_token"] as? String) ?? (obj["token"] as? String),
            !token.isEmpty
        else {
            throw CloudError.tokenExchangeFailed
        }
        return token
    }
}

// MARK: - Small private helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }

    func appendingPathComponentSafe(_ component: String) -> String {
        let trimmed = hasSuffix("/") ? String(dropLast()) : self
        return trimmed + "/" + component
    }
}
