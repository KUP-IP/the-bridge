// WorkerTokenExchangeTests.swift — WS-F remediation (2026-06-10)
// TheBridge · Tests (custom harness — no XCTest)
//
// Covers the production CloudTokenExchanging conformer that POSTs the
// one-time auth code to the kup-worker /auth/exchange route (the worker holds
// the WorkOS secret). A URLProtocol stub intercepts the request so no live
// network call is made: asserts the request shape (POST {base}/auth/exchange,
// JSON {code}) and the response parse (access_token → token; non-2xx throws).

import Foundation
import TheBridgeLib

/// URLProtocol stub: captures the outbound request and returns a canned reply.
final class StubExchangeProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: @unchecked Sendable { var status: Int; var body: Data }
    nonisolated(unsafe) static var stub: Stub?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLProtocol strips httpBody into httpBodyStream; read it back.
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n > 0 { data.append(buf, count: n) } else { break }
            }
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let s = Self.stub ?? Stub(status: 200, body: Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: s.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: s.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubExchangeProtocol.self]
    return URLSession(configuration: cfg)
}

@MainActor
func runWorkerTokenExchangeTests() async {
    await test("WorkerTokenExchange: POSTs {code} to {base}/auth/exchange and returns access_token") {
        StubExchangeProtocol.stub = .init(
            status: 200,
            body: #"{"access_token":"session-jwt-xyz","refresh_token":"r","user":{"id":"u_1"}}"#.data(using: .utf8)!
        )
        let ex = WorkerTokenExchange(baseURL: "https://bridge.test", session: stubbedSession())
        let token = try await ex.exchange(code: "one-time", config: .placeholder)
        try expect(token == "session-jwt-xyz", "should relay access_token")

        let req = StubExchangeProtocol.lastRequest
        try expect(req?.url?.absoluteString == "https://bridge.test/auth/exchange",
                   "wrong URL: \(req?.url?.absoluteString ?? "nil")")
        try expect(req?.httpMethod == "POST", "must POST")
        let sent = try JSONSerialization.jsonObject(with: StubExchangeProtocol.lastBody ?? Data()) as? [String: Any]
        try expect((sent?["code"] as? String) == "one-time", "body must carry the code")
        // The Mac must NOT send any secret — only the code.
        try expect(sent?.count == 1, "body must contain only {code}, got \(sent ?? [:])")
    }

    await test("WorkerTokenExchange: non-2xx throws tokenExchangeFailed") {
        StubExchangeProtocol.stub = .init(status: 502,
            body: #"{"error":"exchange_failed","workosError":"invalid_grant"}"#.data(using: .utf8)!)
        let ex = WorkerTokenExchange(baseURL: "https://bridge.test", session: stubbedSession())
        var threw = false
        do { _ = try await ex.exchange(code: "bad", config: .placeholder) }
        catch { threw = true }
        try expect(threw, "a 502 from the worker must throw")
    }

    await test("WorkerTokenExchange: 200 without access_token throws") {
        StubExchangeProtocol.stub = .init(status: 200, body: #"{"nope":true}"#.data(using: .utf8)!)
        let ex = WorkerTokenExchange(baseURL: "https://bridge.test", session: stubbedSession())
        var threw = false
        do { _ = try await ex.exchange(code: "c", config: .placeholder) }
        catch { threw = true }
        try expect(threw, "missing access_token must throw")
    }
}
