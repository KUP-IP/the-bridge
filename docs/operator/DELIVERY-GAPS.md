# Delivery Gaps — Operator Action List

The items below **cannot be closed inside the app repo**. They need an operator
decision, an external account/service, or a credential under operator custody. The
app's code seams for each already exist (or are stubbed fail-closed); what's
missing is the off-device half.

Treat this as the "Sell The Bridge" go-live checklist. Order is roughly
dependency-first.

---

## Payments & fulfillment

- [ ] **Stripe live mode + checkout surface.** A live (not test-mode) Stripe
  account and a published checkout/pricing page. *Why:* there is no purchase path
  yet — `https://thebridge.kup.solutions/pricing` is referenced in the CUL but not
  stood up. Nothing can be sold until checkout exists.
- [ ] **Fulfillment worker (external repo).** The `checkout.session.completed`
  webhook that mints a license, persists it, and sends the welcome email — lives
  in `kup.solutions/workers/nb-fulfillment` (or equivalent), **not** in this repo.
  *Why:* this is the bridge between a paid Stripe order and a token in the
  customer's inbox; the email template (`license-issuance-email.md`) and its
  implementation notes are the spec, but the worker itself must be built/deployed.

## Signing & verification

- [ ] **Private signing key — generation + custody.** Generate the Ed25519
  keypair; the **private** key stays under operator custody (used only by the mint
  CLI / fulfillment worker, never committed). *Why:* every license token is signed
  with it; the app is verify-only and has no way to mint.
- [ ] **`LICENSE_PUBLIC_KEY_BASE64URL` CI secret.** Wire the **public** half into
  the release build via this secret so `LicensePublicKey.bundledBase64URL` is
  non-empty. *Why:* until then `LicensePublicKey.bundled()` returns `nil`, the
  Settings → License card shows "Paste-activation is unavailable in this build,"
  and **no key activates** — the trial timer is the only gate.
- [ ] **Deploy the verify / revocation endpoint.** Stand up
  `POST https://kup.solutions/api/nb/verify` with the `revoke:<id>` KV table
  (request `{id, v:1}` → `{status, expiresAt, checkedAt}`; absent id ⇒ `"active"`).
  *Why:* without it, refund/abuse revocation has nowhere to write. (The check is
  fail-open, so its absence doesn't break paying customers — but you lose the only
  soft kill switch.)

## Distribution

- [ ] **DMG / R2 hosting decision (vs GitHub Releases).** Decide whether the DMG
  download (the email's `{{download_url}}`, signed R2 URL with a 7-day TTL) is
  served from Cloudflare R2 or from GitHub Releases. *Why:* the Sparkle appcast
  and the post-purchase download URL must point at a real, stable host; this also
  affects the signed-URL fulfillment logic.

## Cloud track (only if selling remote access)

- [ ] **WorkOS tenant + cloudflared for the cloud track.** Provision the WorkOS
  AuthKit tenant and the `cloudflared` tunnel that fronts `mcp.kup.solutions`.
  *Why:* the local loopback connector needs none of this, but the authenticated
  cloud connector (claude.ai / mobile) does. See `cloud-deploy-runbook.md`.

## Legal / hosting

- [ ] **Host the legal URLs.** Publish `kup.solutions/terms` and
  `kup.solutions/privacy` (and the CUL URL the email links to). *Why:* TERMS §13
  and the Privacy Policy reference these as live pages; the welcome email links to
  the commercial-license URL. They must exist before the webhook goes live.
- [ ] **Finalize `COMMERCIAL_LICENSE.md`.** It is still **v1.0 DRAFT** — complete
  legal review, set the effective date, confirm the governing-law/venue clause
  (§12 currently defaults to Texas with an open operator-review note), and remove
  the DRAFT banner. *Why:* the doc explicitly states it is "**not** the operative
  commercial license" until the DRAFT banner is removed.

---

## ⚠️ FLAGGED CONFLICT — refund window disagrees across three places

The refund window is **stated inconsistently**. Pick **one** number and make all
three agree before launch. **Do not let me change the legal files** — this is an
operator/legal decision. Exact locations:

| File | Location | Says |
|---|---|---|
| `TERMS.md` | §3, line 38 (`After 7 days…` also on the same line) | **7 days** |
| `COMMERCIAL_LICENSE.md` | §5.2, line 75 (and §5.3 "No refund after 14 days", line 77) | **14 days** |
| `docs/operator/license-issuance-email.md` | plain-text body lines 76–77; HTML body line 181 | **14 days** |

- [ ] **Decide the canonical refund window (7 vs 14 days)** and reconcile all three
  files to match. Note that `COMMERCIAL_LICENSE.md` references the number **twice**
  (§5.2 and §5.3), and the email template states it in **both** the plain-text and
  HTML bodies — every occurrence must be updated to the chosen value.

> This doc only flags the conflict; the legal files (`TERMS.md`,
> `COMMERCIAL_LICENSE.md`) and the email template must be edited by the operator,
> not auto-reconciled.
