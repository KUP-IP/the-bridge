// StripeDeprecationShimTests.swift — PKT-754
// NotionBridge · Tests
//
// Covers the v2.2 Stripe long-tail deprecation shim:
//   - Mapping table completeness (all 25 deprecated names)
//   - Description prefix
//   - Argument translation to stripe_api_execute / stripe_api_search shape
//   - Telemetry actor counters
//   - fetch_stripe_resources id-prefix dispatch
//
// Tests follow the standalone-harness pattern (no XCTest); registered in main.swift.

import Foundation
import MCP
import NotionBridgeLib

func runStripeDeprecationShimTests() async {
    print("\n\u{1F4B3} StripeDeprecationShim Tests (PKT-754)")

    // MARK: - Mapping table coverage

    await test("all 25 deprecated tool names present in the mapping table") {
        let expected: Set<String> = [
            "create_invoice", "list_invoices", "create_customer", "list_customers",
            "create_product", "list_products", "create_price", "list_prices",
            "create_coupon", "list_coupons", "create_invoice_item", "create_payment_link",
            "create_refund", "list_refunds", "list_disputes", "list_payment_intents",
            "update_dispute", "update_subscription", "list_subscriptions",
            "cancel_subscription", "finalize_invoice", "retrieve_balance",
            "get_stripe_account_info", "fetch_stripe_resources", "search_stripe_resources",
        ]
        try expect(StripeDeprecationShim.deprecatedToolNames == expected,
                   "deprecatedToolNames mismatch (got \(StripeDeprecationShim.deprecatedToolNames.count), expected 25)")
        try expect(StripeDeprecationShim.mappings.count == 25,
                   "mappings.count \(StripeDeprecationShim.mappings.count) ≠ 25")
    }

    // MARK: - Description prefix (DoD: tool descriptions carry the prefix)

    await test("descriptionPrefix matches PKT-754 spec") {
        try expect(StripeDeprecationShim.descriptionPrefix
                   == "[DEPRECATED v2.2 · PKT-754 — prefer stripe_api_execute]",
                   "descriptionPrefix=\(StripeDeprecationShim.descriptionPrefix)")
    }

    await test("decoratedDescription prepends [DEPRECATED ...] for execute-mapped tools") {
        let decorated = StripeDeprecationShim.decoratedDescription(
            originalDescription: "Create a Stripe invoice.",
            toolName: "create_invoice")
        try expect(decorated.hasPrefix("[DEPRECATED v2.2 · PKT-754 — prefer stripe_api_execute]"),
                   "missing prefix: \(decorated)")
        try expect(decorated.contains("`stripe_api_execute`"), "missing canonical hint")
        try expect(decorated.contains("Create a Stripe invoice."), "missing original description")
    }

    await test("decoratedDescription points search-mapped tools at stripe_api_search") {
        let decorated = StripeDeprecationShim.decoratedDescription(
            originalDescription: "Search Stripe resources by query.",
            toolName: "search_stripe_resources")
        try expect(decorated.contains("`stripe_api_search`"),
                   "search-mapped tool should reference stripe_api_search: \(decorated)")
    }

    // MARK: - Argument translation — 5 of 25 spot-checks (DoD)

    await test("translateArgs(create_invoice) wraps args with PostInvoices op id") {
        let original: Value = .object([
            "customer": .string("cus_123"),
            "days_until_due": .int(30),
        ])
        let translated = StripeDeprecationShim.translateArgs(
            toolName: "create_invoice", originalArgs: original)
        guard case .object(let dict) = translated,
              case .string(let opId) = dict["stripe_api_operation_id"],
              case .object(let params) = dict["parameters"] else {
            throw TestError.assertion("translated args have wrong shape: \(translated)")
        }
        try expect(opId == "PostInvoices", "opId=\(opId)")
        guard case .string(let cust) = params["customer"] else {
            throw TestError.assertion("missing parameters.customer")
        }
        try expect(cust == "cus_123")
        guard case .int(let days) = params["days_until_due"] else {
            throw TestError.assertion("missing parameters.days_until_due")
        }
        try expect(days == 30)
    }

    await test("translateArgs(list_invoices) wraps args with GetInvoices op id") {
        let original: Value = .object(["limit": .int(10), "customer": .string("cus_123")])
        let translated = StripeDeprecationShim.translateArgs(
            toolName: "list_invoices", originalArgs: original)
        guard case .object(let dict) = translated,
              case .string(let opId) = dict["stripe_api_operation_id"] else {
            throw TestError.assertion("wrong shape: \(translated)")
        }
        try expect(opId == "GetInvoices", "opId=\(opId)")
    }

    await test("translateArgs(finalize_invoice) wraps args with PostInvoicesInvoiceFinalize op id") {
        let original: Value = .object(["invoice": .string("in_456")])
        let translated = StripeDeprecationShim.translateArgs(
            toolName: "finalize_invoice", originalArgs: original)
        guard case .object(let dict) = translated,
              case .string(let opId) = dict["stripe_api_operation_id"],
              case .object(let params) = dict["parameters"],
              case .string(let invoice) = params["invoice"] else {
            throw TestError.assertion("wrong shape: \(translated)")
        }
        try expect(opId == "PostInvoicesInvoiceFinalize", "opId=\(opId)")
        try expect(invoice == "in_456")
    }

    await test("translateArgs(retrieve_balance) wraps empty args with GetBalance op id") {
        let translated = StripeDeprecationShim.translateArgs(
            toolName: "retrieve_balance", originalArgs: .object([:]))
        guard case .object(let dict) = translated,
              case .string(let opId) = dict["stripe_api_operation_id"] else {
            throw TestError.assertion("wrong shape: \(translated)")
        }
        try expect(opId == "GetBalance")
    }

    await test("translateArgs(cancel_subscription) wraps args with DeleteSubscriptionsSubscriptionExposedId op id") {
        let original: Value = .object(["subscription": .string("sub_999")])
        let translated = StripeDeprecationShim.translateArgs(
            toolName: "cancel_subscription", originalArgs: original)
        guard case .object(let dict) = translated,
              case .string(let opId) = dict["stripe_api_operation_id"] else {
            throw TestError.assertion("wrong shape: \(translated)")
        }
        try expect(opId == "DeleteSubscriptionsSubscriptionExposedId")
    }

    // MARK: - Search-canonical translations

    await test("translateArgs(search_stripe_resources) passes query verbatim") {
        let original: Value = .object(["query": .string("customers:email:'a@b.co'")])
        let translated = StripeDeprecationShim.translateArgs(
            toolName: "search_stripe_resources", originalArgs: original)
        guard case .object(let dict) = translated,
              case .string(let q) = dict["query"] else {
            throw TestError.assertion("wrong shape: \(translated)")
        }
        try expect(q == "customers:email:'a@b.co'", "q=\(q)")
        // Must NOT carry stripe_api_operation_id when routed through search.
        try expect(dict["stripe_api_operation_id"] == nil,
                   "search canonical must not include operation_id")
    }

    await test("translateArgs(fetch_stripe_resources) translates id prefix to search query") {
        let cases: [(String, String)] = [
            ("cus_123",   "customers:id:\"cus_123\""),
            ("pi_abc",    "payment_intents:id:\"pi_abc\""),
            ("sub_999",   "subscriptions:id:\"sub_999\""),
            ("in_xyz",    "invoices:id:\"in_xyz\""),
            ("prod_42",   "products:id:\"prod_42\""),
        ]
        for (id, expected) in cases {
            let translated = StripeDeprecationShim.translateArgs(
                toolName: "fetch_stripe_resources",
                originalArgs: .object(["id": .string(id)]))
            guard case .object(let dict) = translated,
                  case .string(let q) = dict["query"] else {
                throw TestError.assertion("wrong shape for id=\(id): \(translated)")
            }
            try expect(q == expected, "id=\(id) q=\(q) expected=\(expected)")
        }
    }

    // MARK: - Telemetry actor

    await test("telemetry increments per-tool counts independently") {
        let telemetry = StripeDeprecationTelemetry()
        _ = await telemetry.increment("create_invoice")
        _ = await telemetry.increment("create_invoice")
        _ = await telemetry.increment("list_customers")
        let snap = await telemetry.snapshot()
        try expect(snap["create_invoice"] == 2, "create_invoice=\(snap["create_invoice"] ?? -1)")
        try expect(snap["list_customers"] == 1, "list_customers=\(snap["list_customers"] ?? -1)")
        try expect(snap["finalize_invoice"] == nil, "unset key should be nil")
    }

    await test("telemetry shouldLogOnce gates per-tool first-call logging") {
        let telemetry = StripeDeprecationTelemetry()
        let first  = await telemetry.shouldLogOnce("create_invoice")
        let second = await telemetry.shouldLogOnce("create_invoice")
        let third  = await telemetry.shouldLogOnce("list_customers")
        try expect(first == true,  "first call should log")
        try expect(second == false, "second call must not re-log")
        try expect(third == true,  "different tool first call should log")
    }

    // MARK: - Warning message contents

    await test("warningMessage references PKT-754, deprecated name, canonical, and op id") {
        let msg = StripeDeprecationShim.warningMessage(for: "create_invoice")
        try expect(msg.contains("PKT-754"), "missing PKT id: \(msg)")
        try expect(msg.contains("create_invoice"), "missing tool name: \(msg)")
        try expect(msg.contains("stripe_api_execute"), "missing canonical: \(msg)")
        try expect(msg.contains("PostInvoices"), "missing op id: \(msg)")
    }

    await test("warningMessage for search-mapped tools references stripe_api_search") {
        let msg = StripeDeprecationShim.warningMessage(for: "fetch_stripe_resources")
        try expect(msg.contains("stripe_api_search"), "missing canonical: \(msg)")
    }

    // MARK: - Result decoration

    await test("decorateResult attaches _deprecation_warning sibling on object results") {
        let warned = StripeDeprecationShim.decorateResult(
            .object(["id": .string("in_42")]), with: "DEP MSG")
        guard case .object(let dict) = warned,
              case .string(let id) = dict["id"],
              case .string(let warn) = dict["_deprecation_warning"] else {
            throw TestError.assertion("wrong shape: \(warned)")
        }
        try expect(id == "in_42")
        try expect(warn == "DEP MSG")
    }

    await test("decorateResult wraps non-object results into {result, _deprecation_warning}") {
        let warned = StripeDeprecationShim.decorateResult(.string("raw"), with: "DEP MSG")
        guard case .object(let dict) = warned,
              case .string(let r) = dict["result"],
              case .string(let w) = dict["_deprecation_warning"] else {
            throw TestError.assertion("wrong shape: \(warned)")
        }
        try expect(r == "raw")
        try expect(w == "DEP MSG")
    }

    // MARK: - Operation id coverage for the 23 execute-mapped tools

    await test("all 23 execute-mapped tools have a non-empty stripe_api_operation_id") {
        let executeMapped = StripeDeprecationShim.mappings.filter { $0.value.canonical == .execute }
        try expect(executeMapped.count == 23, "executeMapped.count=\(executeMapped.count) (expected 23)")
        for (name, mapping) in executeMapped {
            guard let opId = mapping.operationId, !opId.isEmpty else {
                throw TestError.assertion("\(name): missing operationId")
            }
            // Stripe op ids are {Verb}{Resource} — must start with a known verb.
            let knownVerbs = ["Get", "Post", "Delete", "Put", "Patch"]
            try expect(knownVerbs.contains(where: { opId.hasPrefix($0) }),
                       "\(name): operation_id=\(opId) does not start with a known verb")
        }
    }

    await test("both search-mapped tools route through stripe_api_search") {
        let searchMapped = StripeDeprecationShim.mappings.filter { $0.value.canonical == .search }
        try expect(searchMapped.count == 2, "searchMapped.count=\(searchMapped.count) (expected 2)")
        try expect(searchMapped["fetch_stripe_resources"] != nil)
        try expect(searchMapped["search_stripe_resources"] != nil)
    }
}
