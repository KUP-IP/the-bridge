# NL-3 — Cloud→Mac Delegation / Auth-Passdown Protocol

**Date:** 2026-05-30
**Owner:** Isaiah Peters (isaiah@kup.solutions)
**Status:** Accepted — spec of record
**Source:** Neutral-Layer (NL) series. Implements Open Loop #2 of `docs/product-strategy.md` ("Define the cloud→Mac delegation + auth-passdown protocol"). Builds on `product-strategy.md` §3 (cloud=control plane, Mac=execution node; auth flows down) and the locked decisions **D3** (two-tier custody; client creds Mac-only, passkey-gated), **D4** (custody follows capability). Stays consistent with **NL-1**: moat = aggregation, **WorkOS** as default-but-abstracted IdP, **relay** custody mode, ChatGPT remote-only. This document is the **design authority that the WS-F (Enable flow) build packet cites.**

---

## Purpose

Specify the protocol by which a request arriving at the cloud control plane is **bound to the authenticated owner**, converted into a **short-lived scoped capability** for one Mac operation, **delivered** to the owner's active Mac node, and **executed only after a local passkey gate** unlocks the Keychain-held client credential. The raw client credential **never leaves the Mac and is never sent to the cloud** (upholds **D3**).

The protocol is defined against interfaces, not vendors. WorkOS is the default IdP implementation; it is not named in the wire format.

---

## Scope

**In scope:** Any cloud-originated request that requires touching a **D3 Tier-1** credential (operator accessing a client's account — Keychain-resident, passkey-gated, Mac-present by design). The same delegation path is reused for any operation that needs local execution on the Mac (files, shell, local browser, Messages, screen) where a credential or local resource is involved.

**Out of scope:** Cloud-only work (Notion fetch, skill management, plugin install) never enters this path — it executes in the control plane and never delegates down. Async/user-absent **vault** custody for a cloud user's *own* accounts (D3 Tier 2) is governed by D4/NL-1 Correction 3 and is **not** this protocol; this protocol is the **relay-shaped, user-present, Mac-present** path. Client work has no laptop-off mode (D3 client-SLA ruling); if the Mac node is not active, the request fails closed (§Failure).

---

## Roles & Terms

- **Owner** — the WorkOS-authenticated principal who owns the connections. Identified by a stable `owner_id` (IdP subject), never by client-app identity.
- **Control plane (cloud)** — issuer of capabilities and broker of identity/connections. Holds **no** Tier-1 client credentials.
- **Mac node** — the owner's execution node; holds Tier-1 credentials in Keychain; enforces the passkey gate. Registered with a device-bound public key.
- **Capability** — a short-lived, scoped, signed token authorizing **one** operation against **one** connection on **one** device. Not a credential; it cannot be exchanged for the raw secret anywhere but on the owning Mac, behind the passkey gate.
- **IdP interface** — the abstraction the control plane authenticates against (default impl: WorkOS).

---

## Interfaces (IdP-abstracted — the protocol binds to these, not to WorkOS)

The protocol depends only on the following interface. **WorkOS is one implementation; nothing in the wire format names it.** Swapping IdP is a contained change behind this interface (consistent with `product-strategy.md` §3 and NL-1 Correction 2).

```
interface IdentityProvider {
  // Verify an inbound session/credential, return the bound owner principal.
  verify(requestAuth) -> { owner_id, session_id, auth_time, amr[], aud, iss } | reject

  // Stable subject used as owner_id across the system. IdP-opaque.
  subject(principal) -> owner_id

  // Signing material / JWKS for capability issuance is the control plane's,
  // NOT the IdP's — the IdP authenticates the owner; the control plane mints capabilities.
}
```

**Decision — D-NL3.1: Identity is consumed through `IdentityProvider`, never via vendor SDK calls in protocol code.** *Rationale:* keeps the IdP swappable per NL-1 Correction 2; the capability format and validation logic carry zero vendor coupling, so an IdP change never touches the Mac-side validator or the wire format.

---

## Decisions

### D-NL3.2 — Every request is bound to the authenticated owner before anything else
**Decision:** On entry, the control plane calls `IdentityProvider.verify(...)` and resolves a stable `owner_id`. No capability is minted, and no Mac is contacted, until the request carries a verified `owner_id`. The **client application identity** (Claude, Cursor, ChatGPT remote endpoint) is recorded for audit but **never** substitutes for owner identity (consistent with NL-1 Correction 4: ChatGPT is a transport, not a custody tier).
**Rationale:** Custody (D3) is assigned by *whose account* is accessed, keyed on the owner — not on which MCP client connected. Binding first makes the owner the subject of every downstream capability and audit record.

### D-NL3.3 — The cloud mints a short-lived, scoped capability; it NEVER sees or sends the raw client credential
**Decision:** The control plane issues a **capability token**, signed with the control plane's key, scoped to exactly one `(connection, operation, device, params-hash)` and expiring in **≤ 120 s** (default 60 s). The capability is an *authorization to ask the Mac to act*, not the secret itself. The **raw Tier-1 credential is resolved only on the Mac, from Keychain, after the passkey gate** — it is **never transmitted to, stored by, logged by, or derivable from the cloud** (upholds **D3**, selling point: "your most sensitive credentials never touch our servers").
**Rationale:** D3 forbids cloud custody of Tier-1 client creds. A scoped, sub-2-minute capability is the minimum authority that lets the cloud delegate work down without ever holding the secret. Short TTL bounds replay; tight scope bounds blast radius.

### D-NL3.4 — Capability is device-bound to the active Mac node
**Decision:** The capability's `aud` is the specific Mac node's `device_id`, and the capability is bound to that device's registered public key (`cnf` / proof-of-possession). A capability minted for device A is unusable on device B. The Mac proves possession of the device key during delivery (§Transport).
**Rationale:** Prevents a leaked capability from being redeemed off-device; ties §Failure revocation to a concrete device; aligns with D3 "the Mac must be active."

### D-NL3.5 — The Mac enforces the passkey gate BEFORE any Keychain / client-cred access
**Decision:** The Mac node validates the capability, then **requires a successful local passkey (platform authenticator / Secure Enclave, e.g. Touch ID) assertion** as a **mandatory, non-bypassable step** before it reads the Keychain item or uses the client credential. Validation-passes-but-no-passkey ⇒ **no Keychain read, request fails closed.** The passkey assertion is fresh per gated operation (subject to the freshness window in D-NL3.6); a valid capability alone is **never** sufficient to touch a Tier-1 secret.
**Rationale:** D3 mandates Tier-1 creds be "passkey-gated" on the Mac. The cloud authorizes *what* may run; the human at the Mac authorizes *that it runs now*. This is the local enforcement point that makes cloud compromise insufficient to exfiltrate or use a secret.

### D-NL3.6 — Expiry, freshness, and a bounded passkey window
**Decision:** Capability TTL ≤ 120 s (default 60 s). A passkey assertion may satisfy a short **freshness window** (default 0 s — re-prompt per operation; configurable up to a small ceiling, e.g. 120 s, as a one-way-looser operator setting that the operator can ratchet back to 0). Outside the window, re-prompt. Replayed or expired capabilities are rejected by `jti`/`exp`.
**Rationale:** Balances the D3 security posture against gate fatigue without ever making the gate optional. The window only ever shortens by default and is operator-controlled, mirroring the D4 "ratchet only tightens" instinct.

### D-NL3.7 — Revocation lifecycle is first-class
**Decision:** Capabilities are revocable before expiry via (a) `jti` denylist checked at the Mac on redemption when reachable, and (b) **device-key rotation / deregistration** that invalidates all outstanding capabilities for that `device_id` immediately. Owner session revocation at the IdP (`verify` now rejects) stops new minting at once. A lost/compromised Mac is handled by deregistering its `device_id` (cloud) **and** the local Keychain+passkey remaining the last line of defense (no usable secret without the local authenticator).
**Rationale:** TTL alone is insufficient for theft/compromise. Device-binding (D-NL3.4) gives a clean, immediate revocation primitive; IdP session revocation halts the pipeline at the source.

---

## End-to-End Sequence (request → bind → mint → deliver → passkey gate → execute → return)

1. **Request arrives.** A cloud-originated MCP request reaches the control plane (from Claude, Cursor, or the ChatGPT remote endpoint). It names an intended operation and a target connection (e.g. "post invoice to client X's Stripe").

2. **Bind to owner identity (IdP-abstracted).** The control plane calls `IdentityProvider.verify(requestAuth)` (default impl: WorkOS) and resolves a stable `owner_id`. If verification fails ⇒ **401, stop** — nothing is minted, no Mac is contacted (D-NL3.2). Client-app identity is logged for audit only.

3. **Authorize & resolve target.** The control plane confirms `owner_id` owns the named connection and that the operation maps to a **Tier-1 / local-execution** path (else it is cloud-only and exits this protocol). It resolves the owner's **active** `device_id`. If no active Mac node ⇒ **409 "Mac not present", fail closed** (D3: no laptop-off mode for client work).

4. **Mint scoped capability.** The control plane issues a signed capability:
   - `sub = owner_id`, `aud = device_id`, `iss = control-plane`
   - `scope = { connection_id, operation, params_hash }`
   - `cnf = device public-key thumbprint` (proof-of-possession, D-NL3.4)
   - `jti`, `iat`, `exp = iat + ≤120s` (D-NL3.3, D-NL3.6)
   - **No credential material is included or referenced** (D-NL3.3, D3).

5. **Deliver to the active Mac node.** The capability is pushed to the owner's Mac over the established control-plane↔node channel (persistent outbound connection from the Mac, e.g. the `/heartbeat`-maintained session; reuses Bridge Cloud Access transport). The Mac proves possession of its device key (`cnf`) on the channel; a capability whose `aud`/`cnf` doesn't match this device is dropped (D-NL3.4).

6. **Validate capability locally.** The Mac verifies: control-plane signature, `aud == this device_id`, `cnf` matches its device key, `exp` not passed, `jti` not in denylist, and `scope` matches the requested operation+`params_hash`. Any failure ⇒ **reject, no Keychain access** (D-NL3.7).

7. **Passkey gate (mandatory).** The Mac requires a fresh local passkey assertion (Secure Enclave / platform authenticator) unless within the configured freshness window (D-NL3.6). **Until this succeeds, the Keychain item is not read and the client credential is not touched** (D-NL3.5). Gate failure/cancel ⇒ **fail closed**, capability consumed/denied.

8. **Resolve credential & execute.** Only now does the Mac read the scoped Tier-1 credential from Keychain and perform exactly the authorized operation against the target service. The credential stays in-process on the Mac; it is **never** sent upward.

9. **Return result.** The Mac returns the **operation result only** (never the credential) over the channel; the control plane relays it to the originating client. `jti` is marked consumed.

10. **Settle lifecycle.** Capability expires (or is consumed); audit record written keyed on `owner_id` + `device_id` + `jti` + client-app. On revocation events (IdP session revoked, device deregistered/rotated), outstanding capabilities are invalidated per D-NL3.7.

---

## WS-F (Enable flow) — what this spec authorizes the build to assume

This document is the design authority WS-F cites. WS-F may build directly against:

- **Identity binding contract:** WS-F obtains `owner_id` solely via `IdentityProvider.verify` (WorkOS default) — step 2. WS-F must not read client-app identity as owner identity.
- **Capability contract:** the token shape in step 4 (claims, TTL ≤120s, device `cnf`, scope, no credential material). WS-F mints via the control-plane signer, not the IdP.
- **Delivery contract:** push over the existing Mac↔cloud channel with device proof-of-possession (step 5), reusing Bridge Cloud Access transport.
- **Local enforcement contract:** the Mac validator + **mandatory passkey gate before Keychain read** (steps 6–7); fail-closed on every negative branch.
- **Lifecycle contract:** expiry, `jti` denylist, device-key rotation/deregistration, IdP session revocation (step 10, D-NL3.7).

If WS-F needs behavior not covered here, raise it as an NL build-on; do not re-decide locked items.

---

## Consistency Check (against locked frame)

- **D3 (two-tier custody):** raw Tier-1 client credential is Keychain-only, passkey-gated, **never sent to cloud** — upheld by D-NL3.3 / D-NL3.5 and steps 7–9. No laptop-off mode: step 3 fails closed when the Mac is absent.
- **D4 + NL-1 Correction 3 (relay vs vault):** this protocol is the **relay-shaped, user-present, Mac-present** path; it does not store secrets. Vault/async custody (Tier-2 own accounts) is explicitly out of scope.
- **NL-1 Correction 2 (WorkOS abstracted):** IdP enters only via `IdentityProvider`; the wire format names no vendor (D-NL3.1).
- **NL-1 Correction 4 (ChatGPT remote-only):** ChatGPT is handled as a remote transport in step 1; it is bound to the owner like any client (D-NL3.2) and creates no new custody tier.
- **Moat = aggregation:** the cloud remains the single referenced source of identity + connections; the Mac contributes execution and the last-line secret custody — reinforcing the one-vault-referenced-everywhere posture.

---

## Summary of decisions

| # | Decision label |
|---|----------------|
| D-NL3.1 | Identity consumed only through `IdentityProvider` interface (WorkOS = default impl, never in wire format) |
| D-NL3.2 | Bind every request to verified `owner_id` before mint/delivery; client-app identity ≠ owner identity |
| D-NL3.3 | Cloud mints short-lived (≤120s) scoped capability; raw client credential NEVER sent to / held by cloud (D3) |
| D-NL3.4 | Capability is device-bound (`aud`=device_id, `cnf`=device key) to the active Mac node |
| D-NL3.5 | Mandatory local passkey gate BEFORE any Keychain / client-cred access |
| D-NL3.6 | Expiry + per-operation passkey freshness window (default re-prompt; operator-tightened) |
| D-NL3.7 | First-class revocation: `jti` denylist, device rotation/deregistration, IdP session revocation |
