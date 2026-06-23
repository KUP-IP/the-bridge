# License Operations Runbook

Operator runbook for the license lifecycle: mint, re-issue, revoke. Grounded
against `TheBridge/Core/Licensing/` as of v3.8.2.

## Mental model (read this first)

- **The signature is the security boundary.** A license token is an
  **Ed25519-signed** payload. The app verifies it **offline** against the public
  key compiled into the build (`LicensePublicKey`). If the signature is good and
  the payload is well-formed and unexpired, the app is licensed. No network call
  is required to *use* a license.
- **Hard enforcement is contract-based, not technical.** The CUL (one Mac, one
  named user) is enforced by **agreement**, not by the app. There is no online
  seat check, no hardware-locking in the token. A determined user could run a
  valid key on two Macs; that's a contract breach, handled like any other.
- **Revocation is best-effort and fails OPEN.** The online check
  (`LicenseRevocationClient`) is a *hint* that lets you disable a refunded/abused
  key **without shipping a new build**. A network outage or a worker error returns
  "no signal," and the app keeps the offline-verified state. The revocation
  response can **never upgrade** a key whose signature failed.

---

## Token payload schema (v1)

`LicenseTokenPayload` — the signed inner JSON, canonical (sorted keys). Wire form
is `<base64url(payload)>.<base64url(signature)>`:

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Schema version. **Must be `1`** (only accepted value). |
| `id` | string | Opaque license/order id. **Set this to the Stripe checkout/order id** (see "Mapping" below). Non-empty. |
| `sub` | string | Subject — buyer email, **display only**. Non-empty. |
| `kind` | string | `"paid"` or `"grandfather"`. |
| `iat` | int64 | Issued-at, unix seconds. `> 0`. |
| `exp` | int64 \| null | Expiry, unix seconds. **`null` = perpetual** (the normal case for a one-time purchase). If set, must be `>= iat`. |

A correctly-signed token that fails any of these checks is **rejected as forgery**,
not accepted as "partial."

---

## 1. Minting a new license

> The mint CLI is **`scripts/license-cli`** (Packet B) — a SwiftPM executable that
> depends on `TheBridgeLib`, so it signs with the SAME `LicenseToken.encode` the
> app verifies with (they can never drift). It is **not committed with the signing
> key** — the Ed25519 **private key is custody-controlled by the operator** and
> never ships in the app or the repo (the app is verify-only). The matching
> **public** half is compiled into the build via the `LICENSE_PUBLIC_KEY_BASE64URL`
> CI secret (`make inject-license-key`) — see `DELIVERY-GAPS.md`.
>
> **One-time setup — generate the production keypair (operator machine):**
> ```
> swift run license-cli keygen
> #  → prints `private <b64url>` and `public <b64url>`.
> #  • Store the PRIVATE key in operator custody (password manager / secure note).
> #    NEVER commit it — it is the only thing that can mint valid licenses.
> #  • Put the PUBLIC key in the LICENSE_PUBLIC_KEY_BASE64URL GitHub repo secret;
> #    release.yml injects it at build time so shipped builds verify your tokens.
> ```

To mint:

1. Gather the fields: `id` = the Stripe checkout/order id, `sub` = buyer email,
   `kind` = `"paid"`, `iat` = now (unix seconds), `exp` = `null` (perpetual) unless
   you're issuing a time-boxed promo.
2. Run the mint CLI with the operator private key:
   ```
   swift run license-cli mint --private <PRIVATE_b64url> \
       --id <stripe_order_id> --sub buyer@example.com --kind paid
   #  add --days N for a time-boxed promo; omit for a perpetual one-time purchase.
   ```
   It prints the dot-separated wire token
   (`<base64url(payload)>.<base64url(signature)>`). Sanity-check any token with
   `swift run license-cli verify --token <token> --public <PUBLIC_b64url>`.
3. Deliver the token to the customer via the welcome email
   (`docs/operator/license-issuance-email.md`, `{{license_key}}`).
4. Customer pastes it into **Settings → License → Activate**.

**Verify before you send:** activation only works if the running build has a
**non-empty** bundled public key matching your signing key. If the customer's card
says "Paste-activation is unavailable in this build," the build shipped without
`LICENSE_PUBLIC_KEY_BASE64URL` wired — fix the release, not the key.

---

## 2. Re-issuing on a machine change

The CUL (§6.2) allows moving a key between Macs; it stays valid for **one
concurrent Mac**. Two paths:

- **Customer self-service (preferred):** customer clicks **Remove license** in
  **Settings → License** on the old Mac (`LicenseManager.deactivate()` — clears the
  token; the trial timer is *not* reset), then pastes the **same** key on the new
  Mac. No operator action needed; the same token verifies on any Mac.
- **Operator re-mint:** if the customer can't reach the old Mac, mint a **new
  token with a new `id`** (keep `sub` the same) and send it. If you want to ensure
  the old token can no longer be used, **revoke the old `id`** (§3). Record the
  id swap against the Stripe order so the mapping stays clean.

---

## 3. Revoking a license

Use this for refunds, chargebacks, or confirmed abuse. Revocation is a **KV
entry** the verify endpoint reads; the app polls it.

1. Write a revocation entry in the verify endpoint's KV store under the key
   **`revoke:<id>`** (where `<id>` is the token's `id` field), in the fulfillment
   worker (`kup.solutions/workers/nb-fulfillment` or equivalent). An **absent**
   id returns `"active"` — the worker is a hint table, not the gate.
2. The app's `LicenseRevocationClient` POSTs `{ "id": "<id>", "v": 1 }` to
   **`https://kup.solutions/api/nb/verify`** and reads back
   `{ status, expiresAt, checkedAt }` where `status` ∈
   `active | revoked | refunded | unknown`.
3. **Cadence + safety:** the check is rate-limited to **once per hour per
   process**, with a 5s timeout, and is **fail-open** — a `nil`/non-2xx response
   is treated as "no signal," never as "revoked." So a revoked key keeps working
   until the next hourly poll lands, and a worker outage never locks out a paying
   customer. This is intentional.

Because enforcement is fail-open and the signature still verifies offline,
revocation is **not** a hard kill switch. For a hard guarantee you would have to
rotate the signing key and ship a new build (invalidating *all* outstanding
tokens) — almost never the right move for a single bad actor.

---

## 4. Mapping a license id → customer

The token's `id` is **opaque** — by itself it tells you nothing about who bought
it. To resolve a customer you need the **Stripe / fulfillment record**:

- Set `id` to the **Stripe checkout/order id** at mint time (the convention above).
  Then `id` → Stripe Checkout Session / order → customer email, name, payment.
- The fulfillment worker should persist a licenses table keyed by the same id
  (per `license-issuance-email.md` implementation notes: "issue + persist the key
  **before** sending the email"). That table is your `id → {email, name, order,
  issued_at}` lookup.
- `sub` (buyer email) is carried in the token for display, but treat it as a hint,
  not the system of record — the Stripe/worker record is authoritative.

> There is no built-in operator dashboard yet; the licenses table + Stripe are the
> source of truth. Standing up that fulfillment store is an operator task — see
> `DELIVERY-GAPS.md`.

---

## Key references

- `TheBridge/Core/Licensing/LicenseToken.swift` — payload schema, verify
  contract, base64url, `encode(payload:signedBy:)` (the signing shape the mint CLI
  mirrors).
- `TheBridge/Core/Licensing/LicenseManager.swift` — activate / deactivate /
  trial gate / grandfather safety contract.
- `TheBridge/Core/Licensing/LicenseRevocationClient.swift` — verify endpoint,
  request/response shape, fail-open contract.
- `docs/operator/license-issuance-email.md` — welcome email + fulfillment notes.
