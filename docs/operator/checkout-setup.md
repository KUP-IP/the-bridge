# Checkout Setup (Payment P1)

Operator runbook for the purchase flow. Grounded against `TheBridge/Security/`
(`BridgeCheckout`, `StripeClient.createCheckoutSession`) and
`TheBridge/UI/Sections/LicenseCardHost.swift` (`openBuyPage`) as of v3.8.x.

## Architecture (read this first)

- **The customer app never holds a Stripe secret key.** The "Buy a license"
  button (`LicenseCard` → `LicenseCardHost.openBuyPage`) opens an operator-
  configured **Stripe Payment Link** — a static URL that carries the price,
  success/cancel pages, and metadata configured in the Stripe dashboard. No API
  call, no `sk_…` key on the user's Mac.
- **Session creation (with brand-scoped metadata) is server-side.**
  `StripeClient.createCheckoutSession(priceID:successURL:cancelURL:metadata:
  clientReferenceID:)` is the canonical session shape — `mode=payment`, one
  line item, brand metadata (`product=the-bridge`, `app_version`, `channel`),
  optional `client_reference_id`. The **fulfillment worker** (operator/external,
  `kup.solutions/workers/nb-fulfillment`) uses this shape and holds the secret
  key. The in-app method exists so the worker contract and the app agree on one
  definition and is covered by tests.
- **Fulfillment is decoupled.** On `checkout.session.completed`, the worker mints
  a license (`license-cli mint` shape — see `license-ops-runbook.md`) and emails
  it (`license-issuance-email.md`). The app's job ends at opening the buy URL.

## Operator setup steps

1. **Create the product + price** in the Stripe dashboard (live mode). One-time
   price for The Bridge (see `TERMS.md` for the headline price).
2. **Create a Payment Link** on that price. Configure on the link:
   - **After payment →** redirect to your hosted success page
     (`BridgeCheckout.successURL` = `https://kup.solutions/the-bridge/checkout/success`).
   - **Metadata:** `product=the-bridge` (so the worker routes the SKU).
   - Optionally enable "collect email" so the buyer's email lands on the session.
3. **Host the return pages:** `…/checkout/success` (tell the buyer to watch for
   the license email) and `…/checkout/cancel`. These are `BridgeCheckout
   .successURL` / `.cancelURL`.
4. **Point the app at the link:** set `STRIPE_PAYMENT_LINK` for the app process
   (a launchd `EnvironmentVariables` entry, or wire it to Settings/Keychain in a
   follow-up). Until set, the buy button falls back to `https://kup.solutions/the-bridge`.
5. **Deploy the fulfillment worker:** verify endpoint + `checkout.session
   .completed` handler that mints + emails the key and persists an
   `id → {email, order, issued_at}` row (the `id` becomes the license token's
   `id`; see `license-ops-runbook.md` §4 mapping).
6. **For a server-mediated checkout** (instead of a static link), the worker can
   call the `createCheckoutSession` shape with `STRIPE_PRICE_ID`
   (`BridgeCheckout.priceID`) and brand metadata, then return the session URL.

## Operator gates (cannot be closed in-repo)

- Stripe **live** product/price + Payment Link creation.
- The **fulfillment worker** deploy (mint + email + persist) — external.
- Hosting the **success/cancel** pages.
- Setting `STRIPE_PAYMENT_LINK` (and, for the server path, `STRIPE_PRICE_ID`).

## Key references

- `TheBridge/Security/BridgeCheckout.swift` — brand metadata, success/cancel,
  `paymentLinkURL` / `priceID` providers.
- `TheBridge/Security/StripeClient.swift` — `createCheckoutSession` (session
  shape + brand metadata), error mapping.
- `TheBridge/UI/Sections/LicenseCardHost.swift` — `openBuyPage` (payment-link
  first, store fallback).
- `docs/operator/license-ops-runbook.md` — mint/revoke; `DELIVERY-GAPS.md` —
  off-repo operator actions.
