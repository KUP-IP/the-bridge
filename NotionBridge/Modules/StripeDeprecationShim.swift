// StripeDeprecationShim.swift — v2.2 deprecation wrapper for Stripe long-tail tools (PKT-754)
// NotionBridge · Modules
//
// Wraps 25 Stripe long-tail MCP tools (create_invoice, list_customers, ...) with a
// deprecation shim that:
//   1. Emits a one-line deprecation warning to stdout the first time each tool is
//      invoked (referencing the canonical replacement: stripe_api_execute /
//      stripe_api_search).
//   2. Increments an actor-backed telemetry counter so we can decide what to keep
//      at the v2.3 hard-remove ramp.
//   3. Translates the original tool's argument shape to the canonical MCP tool's
//      argument shape (`{stripe_api_operation_id, parameters}` for execute,
//      `{query}` for search) and forwards the call through StripeMcpProxy.
//   4. Prefixes the tool description with `[DEPRECATED v2.2 · PKT-754 — prefer
//      stripe_api_execute]` so it shows up in tool listings / Settings.
//
// Two-release ramp: warn now (v2.2), hard-remove the wrapped registrations in v2.3.
// fetch_stripe_resources / search_stripe_resources do not have a single clean
// stripe_api_execute mapping — they are routed through stripe_api_search instead.

import Foundation
import MCP

// MARK: - Telemetry

/// Thread-safe counter that records how many times each deprecated Stripe tool was
/// invoked during the running session. Used by the v2.3 hard-remove decision.
public actor StripeDeprecationTelemetry {
    public static let shared = StripeDeprecationTelemetry()

    private var counts: [String: Int] = [:]
    /// Tracks which tools have already had a startup warning logged this session,
    /// so we don't spam stdout on every invocation.
    private var loggedOnce: Set<String> = []

    public init() {}

    /// Increment the counter for `toolName`. Returns the new count.
    @discardableResult
    public func increment(_ toolName: String) -> Int {
        let next = (counts[toolName] ?? 0) + 1
        counts[toolName] = next
        return next
    }

    /// Returns true the first time a tool name is observed; subsequent calls return false.
    /// Used to gate per-session deprecation log output.
    public func shouldLogOnce(_ toolName: String) -> Bool {
        if loggedOnce.contains(toolName) { return false }
        loggedOnce.insert(toolName)
        return true
    }

    /// Snapshot of all counts (test/observability hook).
    public func snapshot() -> [String: Int] { counts }

    /// Reset state. Test-only.
    public func reset() {
        counts.removeAll()
        loggedOnce.removeAll()
    }
}

// MARK: - Mapping Table

/// Registry of v2.2 → canonical Stripe MCP tool mappings.
public enum StripeDeprecationShim {

    /// PKT identifier baked into description prefix and warning message.
    public static let pktId = "PKT-754"
    public static let descriptionPrefix = "[DEPRECATED v2.2 · \(pktId) — prefer stripe_api_execute]"

    /// Canonical replacement tool for the deprecated long-tail tools.
    public enum CanonicalTool: String, Sendable {
        case execute = "stripe_api_execute"
        case search  = "stripe_api_search"
    }

    /// One row in the deprecation table.
    public struct Mapping: Sendable {
        /// Canonical MCP tool to forward to.
        public let canonical: CanonicalTool
        /// Stripe API operation_id (only used when canonical == .execute).
        public let operationId: String?
        /// Optional human note appended to the deprecation warning (e.g. "args translated to operation PostInvoices").
        public let note: String?

        public init(canonical: CanonicalTool, operationId: String? = nil, note: String? = nil) {
            self.canonical = canonical
            self.operationId = operationId
            self.note = note
        }
    }

    /// 25-tool deprecation table. Keys are the deprecated tool names as exposed
    /// by the Stripe MCP discovery; values describe how to forward each call.
    public static let mappings: [String: Mapping] = [
        // Invoices
        "create_invoice":         Mapping(canonical: .execute, operationId: "PostInvoices"),
        "list_invoices":          Mapping(canonical: .execute, operationId: "GetInvoices"),
        "finalize_invoice":       Mapping(canonical: .execute, operationId: "PostInvoicesInvoiceFinalize",
                                          note: "path param: invoice"),
        "create_invoice_item":    Mapping(canonical: .execute, operationId: "PostInvoiceitems"),

        // Customers
        "create_customer":        Mapping(canonical: .execute, operationId: "PostCustomers"),
        "list_customers":         Mapping(canonical: .execute, operationId: "GetCustomers"),

        // Products / Prices
        "create_product":         Mapping(canonical: .execute, operationId: "PostProducts"),
        "list_products":          Mapping(canonical: .execute, operationId: "GetProducts"),
        "create_price":           Mapping(canonical: .execute, operationId: "PostPrices"),
        "list_prices":            Mapping(canonical: .execute, operationId: "GetPrices"),

        // Coupons
        "create_coupon":          Mapping(canonical: .execute, operationId: "PostCoupons"),
        "list_coupons":           Mapping(canonical: .execute, operationId: "GetCoupons"),

        // Payment links / refunds / disputes / payment intents
        "create_payment_link":    Mapping(canonical: .execute, operationId: "PostPaymentLinks"),
        "create_refund":          Mapping(canonical: .execute, operationId: "PostRefunds"),
        "list_refunds":           Mapping(canonical: .execute, operationId: "GetRefunds"),
        "list_disputes":          Mapping(canonical: .execute, operationId: "GetDisputes"),
        "list_payment_intents":   Mapping(canonical: .execute, operationId: "GetPaymentIntents"),
        "update_dispute":         Mapping(canonical: .execute, operationId: "PostDisputesDispute",
                                          note: "path param: dispute"),

        // Subscriptions
        "update_subscription":    Mapping(canonical: .execute, operationId: "PostSubscriptionsSubscriptionExposedId",
                                          note: "path param: subscription"),
        "list_subscriptions":     Mapping(canonical: .execute, operationId: "GetSubscriptions"),
        "cancel_subscription":    Mapping(canonical: .execute, operationId: "DeleteSubscriptionsSubscriptionExposedId",
                                          note: "path param: subscription"),

        // Account
        "retrieve_balance":         Mapping(canonical: .execute, operationId: "GetBalance"),
        "get_stripe_account_info":  Mapping(canonical: .execute, operationId: "GetAccount"),

        // Multi-resource aggregator tools — no clean execute mapping; route through search.
        "fetch_stripe_resources":   Mapping(canonical: .search,
                                            note: "id-prefix dispatch; routed through stripe_api_search query"),
        "search_stripe_resources":  Mapping(canonical: .search,
                                            note: "identical query syntax to stripe_api_search"),
    ]

    /// Set of deprecated tool names — used by StripeMcpModule.registerDiscoveredTools
    /// to decide whether to wrap a discovered tool.
    public static let deprecatedToolNames: Set<String> = Set(mappings.keys)

    /// Decorate the original Stripe MCP description with the [DEPRECATED] prefix and
    /// the canonical replacement hint.
    public static func decoratedDescription(originalDescription: String, toolName: String) -> String {
        let mapping = mappings[toolName]
        let canonical = mapping?.canonical.rawValue ?? CanonicalTool.execute.rawValue
        let trimmed = originalDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "Stripe \(toolName)" : trimmed
        return "\(descriptionPrefix) prefer `\(canonical)`. \(body)"
    }

    /// Build the canonical-tool argument payload for a deprecated invocation.
    /// For `.execute`, returns `{stripe_api_operation_id, parameters: <originalArgs>}`.
    /// For `.search`, returns `{query: <originalArgs.query or originalArgs.id>}` with
    /// best-effort translation for fetch_stripe_resources (id → search query).
    public static func translateArgs(toolName: String, originalArgs: Value) -> Value {
        guard let mapping = mappings[toolName] else { return originalArgs }

        switch mapping.canonical {
        case .execute:
            let opId = mapping.operationId ?? ""
            let params: Value = {
                if case .object = originalArgs { return originalArgs }
                return .object([:])
            }()
            return .object([
                "stripe_api_operation_id": .string(opId),
                "parameters": params,
            ])

        case .search:
            // search_stripe_resources: pass through the `query` field verbatim.
            // fetch_stripe_resources: translate `{id: "cus_123"}` into a search query
            // using id-prefix → resource-name dispatch.
            if toolName == "search_stripe_resources" {
                if case .object(let dict) = originalArgs, case .string(let q) = dict["query"] {
                    return .object(["query": .string(q)])
                }
                return .object(["query": .string("")])
            }
            // fetch_stripe_resources
            if case .object(let dict) = originalArgs, case .string(let id) = dict["id"] {
                let query = searchQueryForStripeId(id)
                return .object(["query": .string(query)])
            }
            return .object(["query": .string("")])
        }
    }

    /// Map a Stripe object ID prefix (cus_, pi_, ch_, ...) to a stripe_api_search
    /// `resource:id:...` query. Best-effort; defaults to `customers:id:<id>` if the
    /// prefix is unrecognized.
    static func searchQueryForStripeId(_ id: String) -> String {
        let prefixMap: [(String, String)] = [
            ("cus_",  "customers"),
            ("pi_",   "payment_intents"),
            ("ch_",   "charges"),
            ("in_",   "invoices"),
            ("sub_",  "subscriptions"),
            ("prod_", "products"),
            ("price_","prices"),
        ]
        for (prefix, resource) in prefixMap {
            if id.hasPrefix(prefix) {
                return "\(resource):id:\"\(id)\""
            }
        }
        return "customers:id:\"\(id)\""
    }

    /// Build the deprecation warning string surfaced both to stdout (once per
    /// session) and embedded in the tool's response payload as `_deprecation_warning`.
    public static func warningMessage(for toolName: String) -> String {
        let mapping = mappings[toolName]
        let canonical = mapping?.canonical.rawValue ?? CanonicalTool.execute.rawValue
        var msg = "[DEPRECATED v2.2 · \(pktId)] Stripe MCP tool `\(toolName)` is deprecated and will be removed in v2.3. Use `\(canonical)`"
        if let opId = mapping?.operationId {
            msg += " with stripe_api_operation_id=`\(opId)`"
        }
        msg += "."
        if let note = mapping?.note { msg += " (\(note))" }
        return msg
    }

    /// Wrap the original (proxy-call) handler for a deprecated tool. The wrapped
    /// handler:
    ///   1. Increments the per-tool telemetry counter.
    ///   2. Logs a one-shot stdout deprecation warning the first time the tool is
    ///      invoked this session.
    ///   3. Translates the args to the canonical-tool shape.
    ///   4. Forwards the call to the canonical tool through StripeMcpProxy.
    ///   5. Wraps the result with a `_deprecation_warning` field so callers see
    ///      it in the JSON payload too.
    public static func wrapHandler(
        toolName: String,
        proxy: StripeMcpProxy = .shared,
        telemetry: StripeDeprecationTelemetry = .shared
    ) -> @Sendable (Value) async throws -> Value {
        return { arguments in
            // Telemetry first.
            await telemetry.increment(toolName)
            if await telemetry.shouldLogOnce(toolName) {
                print("[StripeDeprecationShim] \(warningMessage(for: toolName))")
            }

            // Resolve canonical target.
            let mapping = mappings[toolName]
            let canonicalName = (mapping?.canonical ?? .execute).rawValue
            let translated = translateArgs(toolName: toolName, originalArgs: arguments)

            do {
                let result = try await proxy.callTool(name: canonicalName, arguments: translated)
                return decorateResult(result, with: warningMessage(for: toolName))
            } catch {
                return .object([
                    "error": .string(error.localizedDescription),
                    "_deprecation_warning": .string(warningMessage(for: toolName)),
                ])
            }
        }
    }

    /// Embed the deprecation warning into a result Value.
    /// - If the result is an object, add `_deprecation_warning` as a sibling key.
    /// - Otherwise wrap into `{result: <original>, _deprecation_warning: <msg>}`.
    public static func decorateResult(_ result: Value, with warning: String) -> Value {
        if case .object(let dict) = result {
            var copy = dict
            copy["_deprecation_warning"] = .string(warning)
            return .object(copy)
        }
        return .object([
            "result": result,
            "_deprecation_warning": .string(warning),
        ])
    }
}
