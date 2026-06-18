// BridgeCheckout.swift — Payment P1 (PRJCT-2754 · Ship The Bridge v4, Wave 1)
// TheBridge · Security
//
// Brand-scoped checkout configuration: the hosted success/cancel return pages
// and the session metadata the (external) fulfillment worker reads to mint +
// email a license after a completed checkout. The live Stripe Price id is
// operator-configured (resolved via an injectable provider) — Stripe live
// product/price config and the fulfillment worker are operator/external and
// out of P1 scope.

import Foundation

public enum BridgeCheckout {
    /// Product slug stamped on every checkout session's metadata so the
    /// fulfillment worker can route the purchase to the right SKU.
    public static let product = "the-bridge"

    /// Operator-hosted return pages. Stripe redirects the buyer here after
    /// pay/cancel. The success page tells them to watch for the license email;
    /// `{CHECKOUT_SESSION_ID}` is substituted by Stripe so the page (and
    /// support) can correlate the session.
    public static let successURL = "https://kup.solutions/the-bridge/checkout/success?session_id={CHECKOUT_SESSION_ID}"
    public static let cancelURL = "https://kup.solutions/the-bridge/checkout/cancel"

    /// Brand-scoped session metadata for the fulfillment worker. `appVersion`
    /// lets support correlate a purchase to the build that initiated it.
    public static func brandMetadata(appVersion: String, channel: String = "in-app") -> [String: String] {
        [
            "product": product,
            "app_version": appVersion,
            "channel": channel
        ]
    }

    /// Resolve the operator-configured live Stripe Price id. Defaults to the
    /// `STRIPE_PRICE_ID` process-environment value (set in CI / a launchd
    /// EnvironmentVariables entry / a wrapper); nil ⇒ checkout is not yet
    /// configured and the UI shows a "checkout unavailable" state rather than
    /// opening a broken session. Operators may later wire this to Keychain /
    /// Settings — see docs/operator/checkout-setup.md.
    public static func priceID(
        _ provider: () -> String? = { ProcessInfo.processInfo.environment["STRIPE_PRICE_ID"] }
    ) -> String? {
        guard let raw = provider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// Resolve the operator-configured Stripe **Payment Link** the customer app
    /// opens to buy. A Payment Link carries the price, success/cancel pages, and
    /// metadata configured in the Stripe dashboard, so the app needs NO Stripe
    /// secret key (unlike the server-side `StripeClient.createCheckoutSession`).
    /// Defaults to the `STRIPE_PAYMENT_LINK` process-environment value; nil ⇒
    /// not yet configured (the buy button falls back to the store page).
    public static func paymentLinkURL(
        _ provider: () -> String? = { ProcessInfo.processInfo.environment["STRIPE_PAYMENT_LINK"] }
    ) -> String? {
        guard let raw = provider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }
}
