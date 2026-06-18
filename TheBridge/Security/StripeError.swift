import Foundation

public enum StripeError: Error, LocalizedError {
    case authenticationFailed
    case cardDeclined(String)
    case insufficientFunds
    case processingError(String)
    case rateLimited
    case networkError(Error)
    case invalidResponse
    case amountExceedsCeiling(amount: Int, ceiling: Int)
    case missingIdempotencyKey
    case invalidAmount

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Stripe authentication failed. Check STRIPE_API_KEY."
        case .cardDeclined(let reason):
            return "Card was declined: \(reason)"
        case .insufficientFunds:
            return "Card was declined due to insufficient funds."
        case .processingError(let message):
            return "Stripe processing error: \(message)"
        case .rateLimited:
            return "Stripe rate limit exceeded. Please retry shortly."
        case .networkError(let error):
            return "Network error while calling Stripe: \(error.localizedDescription)"
        case .invalidResponse:
            return "Stripe returned an invalid response."
        case .amountExceedsCeiling(let amount, let ceiling):
            return "Amount \(amount) exceeds configured ceiling \(ceiling)."
        case .missingIdempotencyKey:
            return "Missing required idempotency key."
        case .invalidAmount:
            return "Amount must be greater than zero."
        }
    }
}
