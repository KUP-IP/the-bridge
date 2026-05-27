// PaymentModule.swift — Payment MCP Tools
// NotionBridge · Modules

import Foundation
import MCP

// MARK: - PaymentModule

public enum PaymentModule {
    public static let moduleName = "payment"
    public nonisolated(unsafe) static var amountCeiling = 50_000

    /// Register all PaymentModule tools on the given router.
    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "payment_execute",
            module: moduleName,
            tier: .request,
            neverAutoApprove: true,
            description: "Charge a Stripe payment method stored in the Keychain via a server-side PaymentIntent (no hosted checkout). Requires idempotency_key and user approval.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "credentialService": .object([
                        "type": .string("string"),
                        "description": .string("Service name for the stored payment method credential (legacy alias: credential_service)")
                    ]),
                    "credentialAccount": .object([
                        "type": .string("string"),
                        "description": .string("Account name for the stored payment method credential (legacy alias: credential_account)")
                    ]),
                    "amount": .object([
                        "type": .string("integer"),
                        "description": .string("Amount in cents (e.g. 2500 = $25.00)")
                    ]),
                    "currency": .object([
                        "type": .string("string"),
                        "description": .string("ISO 4217 currency code (default: usd)")
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Optional payment description")
                    ]),
                    "idempotencyKey": .object([
                        "type": .string("string"),
                        "description": .string("Client-supplied idempotency key (UUID recommended) (legacy alias: idempotency_key)")
                    ])
                ]),
                "required": .array([
                    .string("credentialService"),
                    .string("credentialAccount"),
                    .string("amount"),
                    .string("idempotencyKey")
                ])
            ]),
            handler: { arguments in
                // v3.0·0.5: camelCase canonical; snake_case accepted as
                // legacy alias (Q2 — connector-safe back-compat).
                func str(_ camel: String, _ legacy: String) -> String? {
                    if case .object(let a) = arguments {
                        if case .string(let v)? = a[camel] { return v }
                        if case .string(let v)? = a[legacy] { return v }
                    }
                    return nil
                }
                guard case .object(let args) = arguments,
                      let credentialService = str("credentialService", "credential_service"),
                      let credentialAccount = str("credentialAccount", "credential_account"),
                      case .int(let amount) = args["amount"],
                      let idempotencyKey = str("idempotencyKey", "idempotency_key") else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "payment_execute",
                        reason: "missing required 'credentialService', 'credentialAccount', 'amount', or 'idempotencyKey' parameter"
                    )
                }

                guard CredentialsFeature.isEnabled else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "payment_execute",
                        reason: "Credentials are disabled. Enable Keychain credentials in The Bridge Settings → Credentials to charge stored payment methods."
                    )
                }

                let currency: String = {
                    if case .string(let c) = args["currency"], !c.isEmpty { return c }
                    return "usd"
                }()
                let description: String? = {
                    if case .string(let d) = args["description"], !d.isEmpty { return d }
                    return nil
                }()

                do {
                    let trimmedIdempotencyKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedIdempotencyKey.isEmpty else {
                        throw StripeError.missingIdempotencyKey
                    }
                    guard amount > 0 else {
                        throw StripeError.invalidAmount
                    }
                    guard amount <= amountCeiling else {
                        throw StripeError.amountExceedsCeiling(amount: amount, ceiling: amountCeiling)
                    }

                    try await CredentialManager.shared.requireBiometric(
                        reason: "Execute payment of \(amount) \(currency.uppercased())"
                    )

                    let credential = try CredentialManager.shared.read(
                        service: credentialService,
                        account: credentialAccount
                    )
                    guard let paymentMethod = credential.password, !paymentMethod.isEmpty else {
                        throw StripeError.processingError("Stored credential is missing payment method token")
                    }

                    let result = try await StripeClient.shared.createPaymentIntent(
                        amount: amount,
                        currency: currency,
                        paymentMethod: paymentMethod,
                        idempotencyKey: trimmedIdempotencyKey,
                        description: description,
                        metadata: [
                            "credential_service": credentialService,
                            "credential_account": credentialAccount
                        ]
                    )

                    return .object([
                        "payment_intent_id": .string(result.id),
                        "amount": .int(result.amount),
                        "currency": .string(result.currency),
                        "status": .string(result.status),
                        "created": .int(result.created)
                    ])
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))
    }
}
