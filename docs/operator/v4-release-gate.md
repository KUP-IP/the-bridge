# The Bridge v4 — Release-Gate Runbook (the path to first sale)

**Status:** everything *code-side* for v4 is merged to `main` (PRs #43/#44/#45 · floor 2250/0 · security audit clean — `docs/audits/v4-security-audit-2026-06-23.md`). What remains is **operator-only**: set secrets, prove the durable identity on-device, publish legal + submit the connector, then cut the release. **No code changes are required below.**

The committed defaults are all **fail-closed** (empty license key → no activation; empty OAuth identity → placeholder AS that now *fails loud*), so nothing ships insecure if a step is skipped — it just won't activate/connect until configured.

## At a glance (ordered; **0 blocks everything**, 1–3 gate the release build, 7 triggers it)
0. **Apple Developer legal agreement signed** — notarization (and the published build) fails until then
1. Licensing keypair + CI secret
2. Stripe live price + Payment Link + fulfillment + `STRIPE_PAYMENT_LINK`
3. Remote-Access: 5 OAuth/WorkOS CI secrets → on-device PRM proof → retire env agent
4. Connector: privacy/ToS published + Anthropic Directory submission
5. Legal sign-off (TERMS / refund)
6. Decide the `ServerManager.swift` one-liner
7. Version bump → push the `v4.0.0` tag (the release trigger)

---

## 0 · Apple Developer legal agreement — notarization prerequisite ⚠️ (blocks the release)
**Discovered 2026-06-24** running `make install`: code-signing succeeds, but the Apple notary service rejects the upload —
> HTTP 403 — "A required agreement is missing or has expired. … Ensure your team has signed the necessary legal agreements and that they are not expired."

Notarization is REQUIRED for the published DMG (gate 7 · `release.yml` → `notarize`), so this blocks the v4 release **ahead of everything below**. It is an Apple-account action, not a code change.
- [ ] As the **Account Holder**, sign in at [developer.apple.com/account](https://developer.apple.com/account) **and** App Store Connect; accept any pending agreements (updated **Apple Developer Program License Agreement**, **Paid Apps Agreement**, etc.).
- [ ] Confirm a clean notarize: re-run `make install` (or `xcrun notarytool submit … --keychain-profile "notarytool-profile" --wait`) → no 403.
- [ ] Until then, `make install-copy` (signed, no notarize) deploys to *this* Mac for local use — but the build is **not distributable / auto-updatable** without notarization.

## 1 · Licensing (Packet B) — first-sale activation
- [ ] Generate the **prod Ed25519 keypair** under your custody: `swift run license-cli keygen` (details: `docs/operator/license-ops-runbook.md`). **The private key NEVER enters the repo** — store it in your password manager / secure store.
- [ ] Set GitHub repo secret **`LICENSE_PUBLIC_KEY_BASE64URL`** = the public key (base64url). `release.yml`'s `make inject-license-key` bakes it into the build so a minted token verifies against the bundled key. (Committed default is EMPTY = fail-closed → an unconfigured build accepts no license.)
- [ ] Mint customer tokens with `swift run license-cli mint …` (operator custody).
- [ ] **Verify:** baked build + a freshly-minted token → activates end-to-end.

## 2 · Payment (P1) — the buy flow
- [ ] Create the Stripe **live** product + price.
- [ ] Create a Stripe **Payment Link** for that price.
- [ ] Stand up the **fulfillment worker**: on `checkout.session.completed` → `license-cli mint` → deliver the token to the buyer. (The app holds **no Stripe secret key** — it only opens the link.)
- [ ] Set **`STRIPE_PAYMENT_LINK`** (the live link URL) where `BridgeCheckout` reads it — see `docs/operator/checkout-setup.md`.

## 3 · Remote-Access (Packet E) — durable cloud-connector identity
Set these 5 `release.yml` secrets so `make inject-remote-access` bakes the IdP identity into the build (this is what ends the launchctl-setenv placeholder-PRM revert). **All five are non-secret public values:**

| Secret | Value |
|---|---|
| `BRIDGE_OAUTH_ISSUER` | `https://agile-expression-49.authkit.app` |
| `BRIDGE_PUBLIC_RESOURCE` | `https://mcp.kup.solutions/mcp` |
| `WORKOS_CLIENT_ID` | `client_01KTQKXQ6V30NS7H6QM7YPAWWV` |
| `WORKOS_BASE_URL` | `https://api.workos.com` |
| `WORKOS_REDIRECT_URI` | `bridge-auth://callback` |

- [ ] Set the 5 secrets above.
- [ ] **On-device proof:** install the baked build, **restart the Mac**, then confirm `/.well-known/oauth-protected-resource` serves the **real** WorkOS authorization server — *not* the `auth.example.invalid` placeholder and *not* a 503 — **with the `solutions.kup.bridge-env` LaunchAgent NOT running**. (Wave 3 makes a misconfigured build fail loud, so a 503/placeholder means the bake didn't take.)
- [ ] Once proven, **retire the `solutions.kup.bridge-env` LaunchAgent** — the baked identity replaces it.

## 4 · Connector go-live (v3.0·3.1) — directory listing
- [ ] Publish **privacy policy + ToS** at stable `kup.solutions` URLs.
- [ ] File the **Anthropic Connectors Directory** submission — handoff at `docs/operator/connector-directory-submission.md`. (External review ~2–4 weeks; background, does not block the app release.)
- *Note:* the WS-F token-exchange blocker is resolved and the connector is proven live on Claude web + mobile + ChatGPT; this gate is just the listing/legal.

## 5 · Legal (Packet D)
- [ ] Sign off on the **TERMS / refund policy** (refund window 7→14d is already in the copy).

## 6 · `ServerManager.swift` one-liner
- [ ] Decide the uncommitted `_ = await manager.enable()` line in `TheBridge/Server/ServerManager.swift` (cloud-enabled block): **include** (commit it), **revert**, or **leave**. Not authored this sprint — your call before the release build.

## 7 · Cut the release (the trigger)
- [ ] Bump `TheBridge/Config/Version.swift` (marketing → **4.0.0**) **and** root `Info.plist` (`CFBundleShortVersionString` / `CFBundleVersion`) in sync; +1 build number.
- [ ] Ensure 1–6 are landed on `main`.
- [ ] **Push the `v4.0.0` tag** → `release.yml` builds, notarizes, and publishes the DMG + signed appcast (and commits the appcast to `main`). **Do NOT hand-build the DMG/appcast** — it breaks the Sparkle signature.
- [ ] **Verify:** the appcast updates an existing install end-to-end; a grandfathered (v3.x) user sees **no trial-countdown leak**.

---

## Definition of "selling"
Secrets set (1–3) · on-device identity proven (3) · buy flow live (2) · legal published (4–5) · `v4.0.0` tagged and the DMG/appcast published (7). At that point a buyer can **pay → receive a token → activate → use the connector** — the full first-sale loop.
