// StripeClientTests.swift – PKT-381 StripeClient Tests
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runStripeClientTests() async {
    print("\n💸 StripeClient Tests")

    _ = URLProtocol.registerClass(StripeMockURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(StripeMockURLProtocol.self)
        StripeMockURLProtocol.reset()
    }

    await test("PaymentIntentResult initializer stores values") {
        let result = PaymentIntentResult(
            id: "pi_123",
            amount: 2500,
            currency: "usd",
            status: "succeeded",
            created: 1_717_171_717
        )
        try expect(result.id == "pi_123")
        try expect(result.amount == 2500)
        try expect(result.currency == "usd")
        try expect(result.status == "succeeded")
        try expect(result.created == 1_717_171_717)
    }

    await test("StripeError descriptions are user-facing") {
        let errors: [StripeError] = [
            .authenticationFailed,
            .cardDeclined("do_not_honor"),
            .insufficientFunds,
            .processingError("boom"),
            .rateLimited,
            .networkError(URLError(.notConnectedToInternet)),
            .invalidResponse,
            .amountExceedsCeiling(amount: 60000, ceiling: 50000),
            .missingIdempotencyKey,
            .invalidAmount
        ]
        for error in errors {
            try expect(!(error.localizedDescription).isEmpty, "Description should not be empty for \(error)")
        }
    }

    await test("formURLEncoded escapes reserved characters") {
        let encoded = StripeClient.formURLEncoded([
            "description": "Coffee & croissant",
            "metadata[order id]": "A/B #42"
        ])
        try expect(encoded.contains("description=Coffee+%26+croissant"))
        try expect(encoded.contains("metadata%5Border+id%5D=A%2FB+%2342"))
    }

    await test("createPaymentIntent sends auth and idempotency headers") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            let idem = request.value(forHTTPHeaderField: "Idempotency-Key")
            try expect(auth == "Bearer sk_test_auth", "Expected Bearer auth header")
            try expect(idem == "idem-123", "Expected idempotency key header")
            let payload = """
            {"id":"pi_auth","amount":2500,"currency":"usd","status":"succeeded","created":1700000000}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let client = StripeClient(
            session: makeStripeMockSession(),
            apiKeyProvider: { "sk_test_auth" }
        )
        let result = try await client.createPaymentIntent(
            amount: 2500,
            currency: "usd",
            paymentMethod: "pm_1",
            idempotencyKey: "idem-123",
            description: "Test payment",
            metadata: ["order_id": "ord_1"]
        )
        try expect(result.id == "pi_auth")
    }

    await test("retrieveAccountInfo parses Stripe account metadata") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            try expect(request.url?.absoluteString == "https://api.stripe.com/v1/account")
            let payload = """
            {"id":"acct_123","email":"ops@example.com","country":"US","charges_enabled":true,"business_profile":{"name":"KEEP Ops"}}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_account" })
        let account = try await client.retrieveAccountInfo()
        try expect(account.id == "acct_123")
        try expect(account.email == "ops@example.com")
        try expect(account.displayName == "KEEP Ops")
        try expect(account.country == "US")
        try expect(account.chargesEnabled == true)
    }

    await test("createPaymentIntent maps card_declined to StripeError.cardDeclined") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { _ in
            let payload = """
            {"error":{"type":"card_error","code":"card_declined","decline_code":"do_not_honor","message":"Card declined"}}
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://api.stripe.com/v1/payment_intents")!,
                statusCode: 402,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_decline" })
        do {
            _ = try await client.createPaymentIntent(
                amount: 2500,
                currency: "usd",
                paymentMethod: "pm_decline",
                idempotencyKey: "idem-decline",
                description: nil,
                metadata: nil
            )
            throw TestError.assertion("Expected cardDeclined error")
        } catch let error as StripeError {
            if case .cardDeclined(let reason) = error {
                try expect(reason.contains("do_not_honor"), "Expected decline reason in error")
            } else {
                throw TestError.assertion("Expected cardDeclined, got \(error)")
            }
        }
    }

    await test("createPaymentIntent maps 429 to StripeError.rateLimited") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { _ in
            let payload = #"{"error":{"message":"Too many requests"}}"#
            let response = HTTPURLResponse(
                url: URL(string: "https://api.stripe.com/v1/payment_intents")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }

        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_rate" })
        do {
            _ = try await client.createPaymentIntent(
                amount: 1000,
                currency: "usd",
                paymentMethod: "pm_rate",
                idempotencyKey: "idem-rate",
                description: nil,
                metadata: nil
            )
            throw TestError.assertion("Expected rateLimited error")
        } catch let error as StripeError {
            if case .rateLimited = error { } else {
                throw TestError.assertion("Expected rateLimited, got \(error)")
            }
        }
    }

    await test("createPaymentIntent surfaces URLSession failures as networkError") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestError = URLError(.notConnectedToInternet)

        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_network" })
        do {
            _ = try await client.createPaymentIntent(
                amount: 1000,
                currency: "usd",
                paymentMethod: "pm_net",
                idempotencyKey: "idem-net",
                description: nil,
                metadata: nil
            )
            throw TestError.assertion("Expected networkError")
        } catch let error as StripeError {
            if case .networkError = error { } else {
                throw TestError.assertion("Expected networkError, got \(error)")
            }
        }
    }
}

private func makeStripeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StripeMockURLProtocol.self]
    return URLSession(configuration: config)
}

private final class StripeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestError: Error?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let requestError = Self.requestError {
            client?.urlProtocol(self, didFailWithError: requestError)
            return
        }
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        requestError = nil
    }
}
