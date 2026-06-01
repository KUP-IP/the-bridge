# NL-5 — Assembly: Decision Log, Supersession Log, Client-SLA Ruling & Open-Questions Register

**Date:** 2026-05-30
**Owner:** Isaiah Peters
**Status:** Ratified
**Source:** Neutral-layer assembly session (Ship-The-Bridge-v3)

---

## Purpose

Assemble [NL-1](./NL-1-frame-corrections.md) through [NL-4](./NL-4-neutrality-matrix.md) into one decision log of record for the Bridge Neutral-Layer. This is the single page the build references for what is ratified, what was superseded, and what is still open. Source specs remain authoritative for full rationale; this page is the index plus the rulings that span them.

---

## 1. Consolidated Decision Log

Every ratified decision in the neutral-layer line, one line each, pointing to its source spec. Rationale lives in the source; the pointer is load-bearing.

### From [NL-1 — Frame Corrections](./NL-1-frame-corrections.md)

- **NL-1·D1 — Moat is aggregation.** Defensibility = breadth (tools) × neutrality (clients); no single integration is the moat. → [NL-1 D1](./NL-1-frame-corrections.md)
- **NL-1·D2 — Identity provider is WorkOS.** Enterprise SSO/SAML/SCIM + directory-sync fit the buyer and the multi-tenant posture; supersedes Clerk. → [NL-1 D2](./NL-1-frame-corrections.md)
- **NL-1·D3 — Relay, not vault.** The Bridge brokers calls; secrets sit in a vault, payloads pass through. Architectural invariant. → [NL-1 D3](./NL-1-frame-corrections.md)
- **NL-1·D4 — ChatGPT is remote-only (for now).** Reaches the Bridge via hosted transport only; no local-Mac delegation path until its client capability changes. → [NL-1 D4](./NL-1-frame-corrections.md)

### From [NL-2 — Local vs Cloud Split](./NL-2-local-vs-cloud-split.md)

- **NL-2·D1 — Two execution planes, named.** Local plane = Mac-bound; cloud plane = hosted APIs. Every tool is tagged one or the other. → [NL-2 D1](./NL-2-local-vs-cloud-split.md)
- **NL-2·D2 — Local plane requires Mac presence.** No presence, no local execution; the call fails closed, never silently degrades. → [NL-2 D2](./NL-2-local-vs-cloud-split.md)
- **NL-2·D3 — Cloud plane is presence-independent.** Hosted-API tools run regardless of Mac presence; this is the portable surface every client reaches. → [NL-2 D3](./NL-2-local-vs-cloud-split.md)
- **NL-2·D4 — The graduation marker.** Tracks how much of the operator's *own async work* runs cloud-only without the Mac. Progress metric, not a client guarantee. (Scope tightened — see Supersession S2 and §3.) → [NL-2 D4](./NL-2-local-vs-cloud-split.md)

### From [NL-3 — Cloud→Mac Delegation & Auth Pass-Down](./NL-3-cloud-mac-delegation-authpassdown.md)

- **NL-3·D1 — Delegation is presence-gated.** Cloud→Mac delegation only when the Mac is online and device-bound; absent presence, fail closed (consistent with NL-2·D2). → [NL-3 D1](./NL-3-cloud-mac-delegation-authpassdown.md)
- **NL-3·D2 — Auth passes down, never caches.** Caller auth is passed to the Mac for the call's duration and discarded; no server-side credential storage (consistent with NL-1·D3). → [NL-3 D2](./NL-3-cloud-mac-delegation-authpassdown.md)
- **NL-3·D3 — The Worker is the broker.** A Cloudflare Worker authenticates (WorkOS), checks device-binding + presence, relays the call, and holds no durable user data. → [NL-3 D3](./NL-3-cloud-mac-delegation-authpassdown.md)
- **NL-3·D4 — Device-binding is the trust anchor.** Sessions are bound to a known device; revoking the binding revokes delegation. → [NL-3 D4](./NL-3-cloud-mac-delegation-authpassdown.md)

### From [NL-4 — Neutrality Matrix](./NL-4-neutrality-matrix.md)

- **NL-4·D1 — Neutrality is scored per plane, per client.** Cloud-plane and local-plane reach scored separately. → [NL-4 D1](./NL-4-neutrality-matrix.md)
- **NL-4·D2 — The matrix (current state).** Claude: cloud ✓ / local ✓. Cursor: cloud ✓ / local ✓. ChatGPT: cloud ✓ / local ✗. → [NL-4 D2](./NL-4-neutrality-matrix.md)
- **NL-4·D3 — Neutrality is a cloud-plane guarantee.** Equal cloud-plane reach for every client; local-plane reach is best-effort, gated by each client's own capability. → [NL-4 D3](./NL-4-neutrality-matrix.md)
- **NL-4·D4 — Failure modes must be neutral too.** Identical failure shape across clients; validated, not assumed. → [NL-4 D4](./NL-4-neutrality-matrix.md)

---

## 2. Supersession Log

Decisions that replaced earlier framing. Each dated to the spec that ratified the change.

- **S1 — Clerk → WorkOS (2026-05-22).** The pre-NL-1 assumption that Clerk would be the identity provider is **superseded**. WorkOS is the identity provider of record for the entire neutral-layer line (enterprise SSO/SAML/SCIM, directory-sync, org-modeling). Ratified in [NL-1·D2](./NL-1-frame-corrections.md); WorkOS is assumed by NL-3's broker design and all downstream specs. No code path may target Clerk.
- **S2 — Graduation-marker scope tightened → operator-own-async-only (2026-05-30).** The graduation marker from [NL-2·D4](./NL-2-local-vs-cloud-split.md) is **narrowed** so it can never be read as a client-facing or client-work guarantee. It measures *only* the share of the **operator's own async work** that runs cloud-only without the Mac. It does **not** apply to client engagements and is not an SLA. Ratified here in NL-5 (see §3) and reflected back onto NL-2·D4's reading.

---

## 3. Client-SLA Ruling

**Decision (2026-05-30, ratified) — Client work is permanently Mac-present; the graduation marker applies only to the operator's own async work.**

- **Client work is permanently Mac-present.** Any engagement delivered for a client runs on the local plane with the operator's Mac present and device-bound. This is a standing commitment, not a phase to be graduated out of.
- **Clients hear "no" to laptop-off.** Requests to run client work with the Mac offline / laptop closed are declined. There is no cloud-only delivery mode for client engagements. The answer is "no," stated plainly.
- **The graduation marker is operator-own-async only.** [NL-2·D4](./NL-2-local-vs-cloud-split.md)'s marker tracks the operator's personal async workflow exclusively (cf. Supersession S2). It is an internal progress metric and never a client SLA.

**Rationale (travels with the decision).** Client trust and the relay-not-vault invariant ([NL-1·D3](./NL-1-frame-corrections.md)) both depend on client execution staying on a present, device-bound Mac — auth passes down per-call and is discarded ([NL-3·D2](./NL-3-cloud-mac-delegation-authpassdown.md)), so there is no safe way to run client work absent the Mac. Letting the graduation marker bleed into client expectations would manufacture a promise the architecture deliberately refuses to make. Keeping the marker scoped to the operator's own async work preserves it as an honest progress signal without converting it into a liability.

---

## 4. Open-Questions Register

Each question carries an explicit owner. These block nothing already ratified above; they gate future re-scoring and the validation harnesses NL-3/NL-4 call for.

| # | Question | Owner | Source |
|---|----------|-------|--------|
| Q1 | **Verify current ChatGPT / Cursor MCP capability state.** Re-confirm ChatGPT is still remote-only and Cursor still supports local delegation; re-score the matrix on any change. | Isaiah Peters (founder / venture lead) | [NL-1·D4](./NL-1-frame-corrections.md), [NL-4·D2](./NL-4-neutrality-matrix.md) |
| Q2 | **Multi-tenant Worker isolation.** Validate that the Cloudflare Worker isolates tenants with no cross-tenant data or auth bleed. | Platform / Worker eng | [NL-3·D3](./NL-3-cloud-mac-delegation-authpassdown.md) |
| Q3 | **Device-binding revocation lifecycle.** Define and test issue / rotate / revoke, including immediate delegation revocation on unbind. | Auth-layer owner (WorkOS integration) | [NL-3·D4](./NL-3-cloud-mac-delegation-authpassdown.md) |
| Q4 | **Failure-mode neutrality validation.** Build the harness proving identical failure shape across clients (presence absent, auth invalid). | QA / neutrality eng | [NL-4·D4](./NL-4-neutrality-matrix.md) |
| Q5 | **Instruction-loading fidelity across platforms.** Verify instructions/tool definitions load identically across Claude, Cursor, and ChatGPT — no client gets a richer or degraded surface. | QA / neutrality eng | [NL-4·D1](./NL-4-neutrality-matrix.md), [NL-4·D3](./NL-4-neutrality-matrix.md) |

---

## Consistency Notes

- WorkOS is the only identity provider referenced; Clerk appears only as superseded (S1), consistent with [NL-1·D2](./NL-1-frame-corrections.md) and [product-strategy.md](../product-strategy.md).
- The graduation marker is treated as operator-own-async only everywhere it appears (NL-2·D4 reading, S2, §3) — no contradiction with NL-2.
- Relay-not-vault and auth-passes-down-never-caches are preserved in the SLA rationale, consistent with [NL-1·D3](./NL-1-frame-corrections.md) and [NL-3·D2](./NL-3-cloud-mac-delegation-authpassdown.md).
- ChatGPT remains cloud ✓ / local ✗; neutrality is a cloud-plane guarantee, consistent with [NL-4·D3](./NL-4-neutrality-matrix.md).

---

*End NL-5. Assembly point for the Ship-The-Bridge-v3 neutral-layer line.*
