# NL-1 — Corrections & Frame Decision Record

**Date:** 2026-05-30
**Owner:** Isaiah Peters
**Status:** Accepted — spec of record
**Source:** Foundation packet for the Neutral Layer (NL) series. Corrects and supersedes the strategic frame as carried in `docs/product-strategy.md` (§2 positioning, §3 identity layer, D3 client-SLA ruling, Supersession Log). Later NL specs build on the frame fixed here.

---

## Purpose

This record fixes four corrections to the strategic frame. Each is stated as a labeled decision with its rationale attached. Where a correction changes a prior commitment, the supersession is dated and scoped so the build references one authority, not two. Nothing here contradicts `product-strategy.md` §2, §3 identity layer, the D3 client-SLA ruling, or the existing Supersession Log; it tightens and disambiguates them.

---

## Correction 1 — The moat is aggregation of portable state, not cross-platform compatibility

**Decision:** The defensible moat of The Bridge is the **aggregation of portable state** — one vault, one identity, one routing policy, one skills library, all referenced from everywhere a user works. Cross-platform compatibility is **table stakes, not moat**.

**Rationale:**

- **Compatibility is given away free by the protocol.** MCP is an open standard. Any client that speaks MCP can talk to any compliant server. "We work across platforms" describes conformance to a published spec — it is replicable by anyone in a weekend and confers no durable advantage. Treating compatibility as the moat would stake the business on a property the protocol hands to every competitor at zero cost.
- **Aggregation compounds and does not transfer.** The value is not that a credential, skill, or route *can* be reached from a given client; it is that **the same vault, identity, routing, and skills are the single referenced source from every client at once.** Each connection added, each skill authored, each credential vaulted raises switching cost and deepens the single point of reference. That accumulated, user-owned, portable state is what a competitor cannot clone by implementing the same protocol — they would have to re-accumulate the state, which the user, not the competitor, owns.
- **The real threat is "unplugging," not imitation.** Because compatibility is free, the danger is not a rival building a better-compatible bridge. The danger is a **platform barring credential-bearing third-party MCP servers** — a host (model vendor or client app) that disallows or sandboxes external MCPs that carry credentials/capabilities, cutting The Bridge off from that surface. Imitation does not erode aggregation; unplugging does, by removing a reference surface. Strategy therefore optimizes for breadth and resilience of reference surfaces and for keeping aggregated state portable and user-owned, so an unplug at one surface degrades reach but never strands the user's state.

**Implication for the build:** Feature priority follows aggregation depth and surface resilience, not breadth of protocol conformance. Conformance is a baseline gate, not a differentiator.

---

## Correction 2 — Identity provider is WorkOS (supersedes the Clerk candidacy)

**Decision (2026-05-30):** **WorkOS is the committed default IdP.** This **supersedes the earlier Clerk candidacy** named in the prior identity frame. The identity layer **remains abstracted and swappable** — IdP is a dependency behind an interface, not a hard-wired vendor — but WorkOS is the default the build commits to today.

**Rationale:**

- **Consistency with in-flight work.** The cloud packets already in progress build on **WorkOS sign-in**. Committing WorkOS as the default removes a fork between the written frame and shipping code; the spec of record now matches what is being built.
- **Abstraction is preserved, so the commitment is low-risk.** Per `product-strategy.md` §3, identity is consumed through an internal interface. WorkOS sits behind that interface as the default implementation; swapping providers remains a contained change, not a rewrite. Naming a committed default does not re-couple the system to a vendor.
- **Decide-once removes ambiguity.** Carrying two candidate IdPs ("Clerk or WorkOS") forces every downstream packet to hedge. One committed default with a preserved abstraction layer lets downstream work proceed against a concrete provider while keeping the exit cheap.

**Supersession Log entry:** Clerk (IdP candidate) → **WorkOS (committed default IdP), 2026-05-30, NL-1.** IdP abstraction layer unchanged.

---

## Correction 3 — Relay vs. Vault, mapped onto the D4 custody rule

**Decision:** Two custody modes are defined and named distinctly.

- **Relay** — the cloud **passes a credential or capability through without persisting it.** The flow is **synchronous and user-present**: the user is in the loop at the moment of use, the secret transits for the duration of the call, and nothing is stored after.
- **Vault** — the cloud **stores a token.** The flow is **asynchronous and user-absent**: the secret is held so a capability can run later without the user present (scheduled jobs, background agents, deferred execution).

**Mapping onto the D4 custody rule (custody follows capability; one-way ratchet, only tightens):**

- **Custody follows capability.** The required custody mode is determined by what the capability needs to do, not by convenience. A capability that only ever runs synchronously with the user present requires **relay** (passthrough, no storage). A capability that must run asynchronously while the user is absent requires **vault** (storage). You provision the *minimum* custody the capability's execution model demands: **sync ⇒ relay**, **async ⇒ vault**.
- **One-way ratchet — only tightens.** Custody can move toward *less* exposure but never silently toward more. A capability may be downgraded from vault to relay (stop storing, require presence) or revoked entirely; it may **not** be upgraded from relay to vault — from passthrough to stored — without an explicit, re-consented capability change that re-derives custody from the (new) capability. The ratchet prevents scope creep where a passthrough credential quietly becomes a stored one.
- **Default to relay.** Where a capability *can* be satisfied synchronously, relay is mandatory; vault is reserved for capabilities that genuinely require user-absent execution. This keeps stored-token surface area minimal and keeps the ratchet pointed at "tighten."

**Consistency note:** This refines, and does not alter, the D4 custody rule in `product-strategy.md`. It supplies the relay/vault vocabulary D4 implies and the sync/async test that selects between them.

---

## Correction 4 — ChatGPT is remote-only

**Decision:** ChatGPT reaches The Bridge **exclusively via the cloud remote-MCP endpoint.** There is **no local stdio connection** from ChatGPT to The Bridge. Consequently, **any neutrality guarantee made for ChatGPT must hold over the remote path** — it cannot be satisfied by a local-only mechanism.

**Rationale:**

- **The transport is fixed by the client.** ChatGPT connects to MCP servers over a remote endpoint, not over local stdio. The Bridge does not get to choose the channel for this client; it must serve ChatGPT through the cloud. Designing as if a local connection were available for ChatGPT would produce guarantees that never apply in practice.
- **Neutrality must be proven on the path that exists.** Because the only ChatGPT path is remote, the **neutrality guarantee** (vendor-neutral routing, no preferential treatment of any model/host, honest capability exposure) has to be **enforced and demonstrable in the cloud remote-MCP layer.** A neutrality property that holds only at a local boundary is, for ChatGPT, vacuous.

**What this constrains:**

- **Custody for a cloud user's OWN accounts over the ChatGPT path skews to vault, by the D4 mapping.** For a cloud user's own accounts (**D3 Tier 2**), remote, often user-absent invocation means many ChatGPT-served capabilities fall on the **async ⇒ vault** side of Correction 3. The relay-default still governs: any such capability that *can* run synchronously with the user present uses relay; only genuinely user-absent ones vault. The ratchet (Correction 3) applies unchanged over the remote path. This vault skew is confined to the cloud user's **own** accounts; it does **not** reach the operator's clients' accounts (**D3 Tier 1**), which are governed separately below.
- **Neutrality controls live cloud-side.** Routing policy, capability advertisement, and any "no preferential host" assurance must be implemented and auditable in the remote endpoint, since that is the sole surface ChatGPT touches.
- **Unplug exposure is concentrated at one surface (Correction 1).** ChatGPT reach depends entirely on the remote endpoint remaining permitted to carry a credential-bearing third-party MCP. If that surface is barred, ChatGPT reach is lost — but, per Correction 1, the user's aggregated state is unaffected and remains reachable from other surfaces.
- **Consistency with the D3 client-SLA ruling.** D3 assigns custody by **whose account** is being accessed, not by which MCP client application connects. "ChatGPT" here is a **remote MCP-client transport**, not a custody tier — connecting over the remote path creates no new SLA and no "client class." The D3 client-SLA ruling stands unchanged over this path: the **operator's clients' accounts (D3 Tier 1)** are **permanently Mac-present by design**, local-only (Keychain, passkey-gated), and **out of scope for async/absent (vault) custody** — there is no laptop-off mode for client accounts, including over the ChatGPT remote endpoint. The vault skew noted above therefore applies **only** to a cloud user's own accounts (D3 Tier 2) and never relocates a client account into vault/async custody. Remote-only does not invent an SLA for ChatGPT; it locates the ChatGPT transport within the existing two-tier custody rules.

---

## Summary of decisions

| # | Correction | Decision label |
|---|------------|----------------|
| 1 | Moat reframe | Moat = aggregation of portable state; compatibility is table stakes; threat = "unplugging" (platform barring credential-bearing 3rd-party MCPs) |
| 2 | IdP supersession | WorkOS is committed default IdP (supersedes Clerk, 2026-05-30); IdP stays abstracted/swappable |
| 3 | Relay vs. Vault | relay = sync/user-present passthrough, no storage; vault = async/user-absent storage; custody follows capability, ratchet only tightens |
| 4 | ChatGPT remote-only | ChatGPT reaches The Bridge only via cloud remote-MCP; neutrality guarantee must hold over the remote path |
