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

    // ── Payment P1: hosted Stripe Checkout Session ───────────────────────
    await test("createCheckoutSession posts mode/price/urls + brand metadata + client_reference_id") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            try expect(request.url?.absoluteString == "https://api.stripe.com/v1/checkout/sessions",
                       "expected checkout/sessions endpoint, got \(request.url?.absoluteString ?? "nil")")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test_co",
                       "expected bearer auth")
            let body = stripeRequestBody(request)
            try expect(body.contains("mode=payment"), "missing mode=payment in \(body)")
            try expect(body.contains("line_items%5B0%5D%5Bprice%5D=price_live_123"), "missing price line item in \(body)")
            try expect(body.contains("line_items%5B0%5D%5Bquantity%5D=1"), "missing quantity in \(body)")
            try expect(body.contains("success_url=https%3A%2F%2Fok"), "missing success_url in \(body)")
            try expect(body.contains("cancel_url=https%3A%2F%2Fno"), "missing cancel_url in \(body)")
            try expect(body.contains("metadata%5Bproduct%5D=the-bridge"), "missing brand metadata in \(body)")
            try expect(body.contains("client_reference_id=ord_42"), "missing client_reference_id in \(body)")
            let json = #"{"id":"cs_test_123","url":"https://checkout.stripe.com/c/pay/cs_test_123"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_co" })
        let session = try await client.createCheckoutSession(
            priceID: "price_live_123",
            successURL: "https://ok",
            cancelURL: "https://no",
            metadata: BridgeCheckout.brandMetadata(appVersion: "9.9.9"),
            clientReferenceID: "ord_42",
            idempotencyKey: "idem-co"
        )
        try expect(session.id == "cs_test_123", "expected cs_test_123, got \(session.id)")
        try expect(session.url == "https://checkout.stripe.com/c/pay/cs_test_123")
    }

    await test("createCheckoutSession with empty priceID throws missingPriceID (no network)") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { _ in
            throw TestError.assertion("network must NOT be called when priceID is empty")
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_co" })
        do {
            _ = try await client.createCheckoutSession(priceID: "  ", successURL: "https://ok", cancelURL: "https://no")
            throw TestError.assertion("expected missingPriceID")
        } catch let error as StripeError {
            if case .missingPriceID = error { } else {
                throw TestError.assertion("expected missingPriceID, got \(error)")
            }
        }
    }

    await test("createCheckoutSession surfaces a Stripe error response") {
        StripeMockURLProtocol.reset()
        StripeMockURLProtocol.requestHandler = { request in
            let json = #"{"error":{"type":"invalid_request_error","message":"No such price"}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let client = StripeClient(session: makeStripeMockSession(), apiKeyProvider: { "sk_test_co" })
        do {
            _ = try await client.createCheckoutSession(priceID: "price_bad", successURL: "https://ok", cancelURL: "https://no")
            throw TestError.assertion("expected a StripeError")
        } catch let error as StripeError {
            if case .processingError = error { } else {
                throw TestError.assertion("expected processingError, got \(error)")
            }
        }
    }

    await test("BridgeCheckout brand metadata + priceID provider") {
        let md = BridgeCheckout.brandMetadata(appVersion: "4.0.0")
        try expect(md["product"] == "the-bridge")
        try expect(md["app_version"] == "4.0.0")
        try expect(md["channel"] == "in-app")
        try expect(BridgeCheckout.priceID({ nil }) == nil, "nil provider → nil")
        try expect(BridgeCheckout.priceID({ "   " }) == nil, "whitespace → nil")
        try expect(BridgeCheckout.priceID({ " price_x " }) == "price_x", "trimmed value")
        try expect(BridgeCheckout.paymentLinkURL({ nil }) == nil, "nil link → nil")
        try expect(BridgeCheckout.paymentLinkURL({ " https://buy.stripe.com/x " }) == "https://buy.stripe.com/x",
                   "trimmed payment link")
    }
}

private func makeStripeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StripeMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Read a URLRequest body whether URLSession left it as httpBody or moved it
/// to httpBodyStream (it does the latter for bodies handed to a URLProtocol).
private func stripeRequestBody(_ request: URLRequest) -> String {
    if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return String(decoding: data, as: UTF8.self)
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
