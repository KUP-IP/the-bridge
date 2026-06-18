import Foundation

public struct PaymentIntentResult: Sendable, Equatable {
    public let id: String
    public let amount: Int
    public let currency: String
    public let status: String
    public let created: Int

    public init(id: String, amount: Int, currency: String, status: String, created: Int) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.status = status
        self.created = created
    }
}

public struct StripeAccountInfo: Sendable, Equatable {
    public let id: String
    public let email: String?
    public let displayName: String?
    public let country: String?
    public let chargesEnabled: Bool

    public init(id: String, email: String?, displayName: String?, country: String?, chargesEnabled: Bool) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.country = country
        self.chargesEnabled = chargesEnabled
    }
}

public final class StripeClient: @unchecked Sendable {
    public static let shared = StripeClient()

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?

    public init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = {
            KeychainManager.shared.read(key: KeychainManager.Key.stripeAPIKey)
        }
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    public func createPaymentIntent(
        amount: Int,
        currency: String,
        paymentMethod: String,
        idempotencyKey: String,
        description: String?,
        metadata: [String: String]?
    ) async throws -> PaymentIntentResult {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StripeError.missingIdempotencyKey
        }
        guard amount > 0 else {
            throw StripeError.invalidAmount
        }

        var formFields: [String: String] = [
            "amount": String(amount),
            "currency": currency,
            "payment_method": paymentMethod,
            "confirm": "true"
        ]
        if let description, !description.isEmpty {
            formFields["description"] = description
        }
        if let metadata {
            for (key, value) in metadata {
                formFields["metadata[\(key)]"] = value
            }
        }

        let bodyString = Self.formURLEncoded(formFields)
        var request = try authorizedRequest(
            method: "POST",
            endpoint: "payment_intents",
            idempotencyKey: idempotencyKey
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)
        return try await executePaymentIntentRequest(request)
    }

    public func retrievePaymentIntent(id: String) async throws -> PaymentIntentResult {
        var request = try authorizedRequest(
            method: "GET",
            endpoint: "payment_intents/\(id)"
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await executePaymentIntentRequest(request)
    }

    public func retrieveAccountInfo() async throws -> StripeAccountInfo {
        let request = try authorizedRequest(method: "GET", endpoint: "account")
        let data = try await performRequest(request)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? String
        else {
            throw StripeError.invalidResponse
        }

        let businessProfile = json["business_profile"] as? [String: Any]
        let displayName = businessProfile?["name"] as? String
            ?? json["display_name"] as? String
            ?? json["business_type"] as? String

        return StripeAccountInfo(
            id: id,
            email: json["email"] as? String,
            displayName: displayName,
            country: json["country"] as? String,
            chargesEnabled: json["charges_enabled"] as? Bool ?? false
        )
    }

    private func executePaymentIntentRequest(_ request: URLRequest) async throws -> PaymentIntentResult {
        let data = try await performRequest(request)
        return try Self.parsePaymentIntent(data: data)
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StripeError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StripeError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.parseStripeError(statusCode: http.statusCode, data: data)
        }
        return data
    }

    private func authorizedRequest(
        method: String,
        endpoint: String,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw StripeError.authenticationFailed
        }
        guard let url = URL(string: "https://api.stripe.com/v1/\(endpoint)") else {
            throw StripeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        return request
    }

    public static func parseStripeError(statusCode: Int, data: Data) -> StripeError {
        if statusCode == 429 {
            return .rateLimited
        }
        if statusCode == 401 || statusCode == 403 {
            return .authenticationFailed
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorObj = json["error"] as? [String: Any]
        else {
            return .processingError("Stripe request failed with HTTP \(statusCode)")
        }

        let message = (errorObj["message"] as? String) ?? "Stripe request failed with HTTP \(statusCode)"
        let code = errorObj["code"] as? String
        let declineCode = errorObj["decline_code"] as? String
        let type = errorObj["type"] as? String

        if declineCode == "insufficient_funds" || code == "insufficient_funds" {
            return .insufficientFunds
        }
        if code == "card_declined" || type == "card_error" {
            return .cardDeclined(declineCode ?? message)
        }
        return .processingError(message)
    }

    private static func parsePaymentIntent(data: Data) throws -> PaymentIntentResult {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? String,
            let amount = json["amount"] as? Int,
            let currency = json["currency"] as? String,
            let status = json["status"] as? String,
            let created = json["created"] as? Int
        else {
            throw StripeError.invalidResponse
        }
        return PaymentIntentResult(
            id: id,
            amount: amount,
            currency: currency,
            status: status,
            created: created
        )
    }

    public static func formURLEncoded(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }
}
