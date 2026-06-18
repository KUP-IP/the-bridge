// StripeTokenizationTests.swift – PKT-372 D4 backfill
// TheBridge · Tests

import Foundation
import TheBridgeLib

/// Read request body — URLSession converts httpBody to httpBodyStream in URLProtocol handlers
private func readRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4096)
        if read > 0 { data.append(buffer, count: read) }
        else { break }
    }
    return data.isEmpty ? nil : data
}

func runStripeTokenizationTests() async {
    print("\n🧪 Stripe Tokenization Tests")

    let enableKey = "com.notionbridge.tests.enableStripeTokenizationOutsideApp"
    let apiKey = "com.notionbridge.tests.stripeApiKey"

    UserDefaults.standard.set(true, forKey: enableKey)
    UserDefaults.standard.set("sk_test_tokenize", forKey: apiKey)
    _ = URLProtocol.registerClass(TokenizationMockURLProtocol.self)

    defer {
        URLProtocol.unregisterClass(TokenizationMockURLProtocol.self)
        TokenizationMockURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: enableKey)
        UserDefaults.standard.removeObject(forKey: apiKey)
    }

    await test("credential_save(card) tokenizes card into pm_ token") {
        TokenizationMockURLProtocol.reset()
        TokenizationMockURLProtocol.requestHandler = { _ in
            let responseBody = """
            {"id":"pm_12345","card":{"last4":"4242","brand":"visa"}}
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://api.stripe.com/v1/payment_methods")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let manager = CredentialManager.shared
        let entry = try await manager.save(
            service: "stripe-tokenization-success",
            account: "card_1",
            password: "4242 4242 4242 4242",
            type: .card,
            metadata: CredentialMetadata(brand: "visa", expMonth: 12, expYear: 2030)
        )

        try expect(entry.type == .card)
        try expect(entry.metadata.stripePm == "pm_12345", "Expected pm_ token in metadata")
        try expect(entry.metadata.last4 == "4242")
        try expect(entry.metadata.brand?.lowercased() == "visa")
    }

    await test("credential_save(card) tokenization failure propagates StripeError") {
        TokenizationMockURLProtocol.reset()
        TokenizationMockURLProtocol.requestHandler = { _ in
            let responseBody = """
            {"error":{"type":"card_error","code":"card_declined","decline_code":"insufficient_funds","message":"Declined"}}
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://api.stripe.com/v1/payment_methods")!,
                statusCode: 402,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let manager = CredentialManager.shared
        do {
            _ = try await manager.save(
                service: "stripe-tokenization-failure",
                account: "card_2",
                password: "4000 0000 0000 9995",
                type: .card,
                metadata: CredentialMetadata(brand: "visa", expMonth: 12, expYear: 2030)
            )
            throw TestError.assertion("Expected StripeError on tokenization failure")
        } catch let error as StripeError {
            if case .insufficientFunds = error { } else {
                throw TestError.assertion("Expected insufficientFunds, got \(error)")
            }
        }
    }

    await test("credential_save(card) sends form-urlencoded card fields") {
        TokenizationMockURLProtocol.reset()
        TokenizationMockURLProtocol.requestHandler = { request in
            guard let body = readRequestBody(request), let bodyString = String(data: body, encoding: .utf8) else {
                throw TestError.assertion("Missing request body")
            }
            try expect(bodyString.contains("type=card"), "Expected card type in body")
            try expect(bodyString.contains("card[number]=4242424242424242"), "Expected card number in body")
            try expect(bodyString.contains("card[exp_month]=1"), "Expected exp_month in body")
            try expect(bodyString.contains("card[exp_year]=2031"), "Expected exp_year in body")

            let responseBody = """
            {"id":"pm_formcheck","card":{"last4":"4242","brand":"visa"}}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseBody.utf8))
        }

        let manager = CredentialManager.shared
        _ = try await manager.save(
            service: "stripe-tokenization-form",
            account: "card_3",
            password: "4242424242424242",
            type: .card,
            metadata: CredentialMetadata(brand: "visa", expMonth: 1, expYear: 2031)
        )
    }

    // ============================================================
    // MARK: - Finding 3 (T1 audit): card-number validation + form-injection
    //
    // The MCP credential_save card path must Luhn/digit-validate BEFORE
    // tokenizing (parity with the UI path) and must build the Stripe POST body
    // so an attacker-supplied value cannot break out of its key=value position.
    // ============================================================

    await test("Finding3: a form-injection card number is rejected before any network call") {
        TokenizationMockURLProtocol.reset()
        // If the request reaches Stripe, fail loudly — validation must stop it first.
        TokenizationMockURLProtocol.requestHandler = { _ in
            throw TestError.assertion("tokenizeCard must NOT POST an unvalidated card number")
        }

        let manager = CredentialManager.shared
        do {
            _ = try await manager.save(
                service: "stripe-injection-attempt",
                account: "card_inj",
                // Tries to inject an extra form field / override `type`.
                password: "4242424242424242&type=evil",
                type: .card,
                metadata: CredentialMetadata(brand: "visa", expMonth: 12, expYear: 2030)
            )
            throw TestError.assertion("Expected validation to reject the injected card number")
        } catch let error as CredentialError {
            if case .stripeTokenizationFailed = error { /* expected */ }
            else { throw TestError.assertion("Expected stripeTokenizationFailed, got \(error)") }
        }
    }

    await test("Finding3: a non-Luhn (but digits-only) card number is rejected before network") {
        TokenizationMockURLProtocol.reset()
        TokenizationMockURLProtocol.requestHandler = { _ in
            throw TestError.assertion("tokenizeCard must NOT POST a number that fails Luhn")
        }

        let manager = CredentialManager.shared
        do {
            _ = try await manager.save(
                service: "stripe-bad-luhn",
                account: "card_bad",
                password: "4242424242424241", // last digit flipped → fails Luhn
                type: .card,
                metadata: CredentialMetadata(brand: "visa", expMonth: 12, expYear: 2030)
            )
            throw TestError.assertion("Expected validation to reject the non-Luhn card number")
        } catch let error as CredentialError {
            if case .stripeTokenizationFailed = error { /* expected */ }
            else { throw TestError.assertion("Expected stripeTokenizationFailed, got \(error)") }
        }
    }

    await test("Finding3: card number with spaces/dashes is normalized then accepted (Luhn passes)") {
        TokenizationMockURLProtocol.reset()
        TokenizationMockURLProtocol.requestHandler = { request in
            guard let body = readRequestBody(request), let bodyString = String(data: body, encoding: .utf8) else {
                throw TestError.assertion("Missing request body")
            }
            // Normalized digits reach the body; no spaces/dashes survive.
            try expect(bodyString.contains("card[number]=4242424242424242"),
                       "spaces/dashes must be stripped before tokenization")
            let responseBody = #"{"id":"pm_norm","card":{"last4":"4242","brand":"visa"}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseBody.utf8))
        }

        let manager = CredentialManager.shared
        _ = try await manager.save(
            service: "stripe-normalize",
            account: "card_norm",
            password: "4242-4242 4242-4242",
            type: .card,
            metadata: CredentialMetadata(brand: "visa", expMonth: 1, expYear: 2031)
        )
    }
}

private final class TokenizationMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.stripe.com" && request.url?.path == "/v1/payment_methods"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
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
    }
}
