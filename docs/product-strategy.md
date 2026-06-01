# The Bridge — Product Strategy & Decision Log

**Date:** 2026-05-30
**Owner:** Isaiah Peters (isaiah@kup.solutions)
**Status:** Living document — strategy of record
**Scope:** Repositioning of The Bridge from "a Notion app" to a vendor-neutral MCP infrastructure layer, plus the locked architecture and security decisions that the build must keep referencing.

> This is the canonical home for the repositioning and architecture decisions that previously lived only in conversation. **Locked decisions** below are settled — surface new tensions as build-ons, do not relitigate. **Open loops** are the live work. The Notion Project hub gets synced from this doc after major milestones.

---

## 1. The Thesis (end-state vision)

The Bridge is being repositioned from **"a Notion app"** to a **vendor-neutral MCP infrastructure layer** that sits between a person and every AI platform.

You connect your tools and credentials **once**; you carry your identity (standing orders) and your skills/commands **everywhere**; it all works **identically** in Claude, Cursor, and ChatGPT.

**The pain it kills:** AI-platform lock-in. People are scared to over-invest in one platform, and nobody wants to rebuild their setup per-tool.

**Value props:**
- A **credential vault** (keychain-safe)
- **Portable standing orders** — one identity, referenced from Claude's `CLAUDE.md`, Cursor rules, and ChatGPT instructions via the Bridge MCP
- **Portable skills/commands**
- **Multi-workspace / multi-account routing**
- **Centralized security control** in one place

---

## 2. The Moat (non-negotiable)

**The moat is aggregation of portable state, not cross-platform compatibility.** Be precise about the difference — "identical everywhere" hides two claims, and only one is defensible:

- **Compatibility ("it *works* everywhere") is table stakes, NOT the moat.** The Bridge speaking to Claude, Cursor, and ChatGPT is just speaking MCP — an open standard all three already support via remote servers and custom connectors. The protocol hands compatibility out for free, and that only increases as MCP matures. Anchoring on this is a trap: every platform improving native MCP support would then *erode* the reason to exist.
- **Aggregation ("your *state* lives in one place, referenced everywhere") IS the moat.** One vault, one identity (standing orders), one routing table, one set of skills — the single neutral home for state that would otherwise be shattered across three walled gardens. The value is not the pipe; it's being the source of truth every platform points at. Under this framing, every platform speaking more MCP is **pure tailwind** — more doors the one vault is the key to.

The vault, skills, memory, and identity are each being commoditized by the platforms *inside their own walls* (connectors, memory, custom instructions, skills). The one thing no platform will ever build is the thing that makes *itself* swappable — a trusted neutral broker that holds your state and keeps you un-locked-in from the platforms.

**The real threat is unplugging, not imitation.** No platform will copy neutrality (it cannibalizes their lock-in). The genuine risk is the inverse: a platform restricting credential-bearing third-party MCP servers — "only our own connectors may hold creds" — which beats the Bridge not by copying it but by **unplugging** it from that platform. This is the threat to monitor; defenses (e.g. local-only client custody per D3) partly hedge it.

So neutrality is the **spine**: every feature must work the same across all three platforms. **Never optimize for "great in Claude."** Any idea that quietly makes the product better on one platform at the cost of sameness across all three must be challenged on these grounds.

---

## 3. Architecture (the golden vision, sequenced)

Unify the local Mac app and the cloud into **one product**:

- The **cloud is the control plane** — credential broker and source of truth for identity + connections.
- The **Mac is an optional execution node** — called only when a tool needs local execution.

**Flow:** Connect an account once at the cloud. The cloud delegates down to the Mac via short-lived, scoped capabilities when local work is required. Cloud-only work (e.g. Notion fetch, skill management) never touches the Mac. **Auth flows from the cloud down to the Mac** — connect once, not twice.

**Identity layer:** **WorkOS** is the identity provider for the cloud tier. (Supersedes an earlier Clerk candidacy — see Supersession Log. The cloud's IdP is abstracted so the choice is swappable, but WorkOS is the committed default; remote-MCP OAuth go-live and the Enable flow both build on WorkOS sign-in.)

### Current state vs. target

| | Today | Target |
|---|---|---|
| **Local** | Native macOS app; MCP server exposing local-machine tools (files, shell, messages, screen, browser, contacts, Keychain credentials) + hand-wrapped service tools (Notion, Stripe). | Optional execution node, invoked by the cloud for local-only work. |
| **Cloud** | "Bridge Cloud Access" in flight: multi-tenant Cloudflare deployment, `/provision` + `/heartbeat`, add-to-claude.ai install flow. | Control plane / credential broker / source of truth for identity + connections. |

---

## 4. Locked Decisions

> Build on these. Do not re-decide. Each carries its rationale so the *why* survives.

### D1 — Delegate the commodity, own the differentiator
**Decision:** Use vendor MCPs for commodity operations; keep only thin custom tools for the delta vendors can't do.
- **Stripe** → use Stripe's own MCP. Do **not** hand-roll payment endpoints — that's pure liability.
- **Notion** → stop trying to be "the best Notion client." Use the vendor MCP for commodity ops (read page, query db). Keep only **thin** custom tools for the delta: chiefly **multi-workspace routing** and **Notion file upload**.
- **Google** (later) → same rule.

**Rationale:** Commodity surface area is undifferentiated maintenance burden and liability. The moat is neutrality + routing, not client completeness.

**Watch — vendor execution tiers (Notion Workers, etc.):** Vendors are shipping walled, single-platform execution runtimes (e.g. Notion Workers via the `ntn` CLI). These are *confirming evidence* for the thesis (lock-in we sell against), not threats. Treat them as delegate candidates for platform-internal automation; never let one become load-bearing in a way that breaks neutrality.

### D2 — Multi-account routing is the real reason to keep custom tools
**Decision:** Multi-account routing stays custom, and it IS part of the neutral-layer value.

**Rationale:** Vendor OAuth MCPs authenticate **one identity per connection** and cannot fan out across many client workspaces. The credential vault is the multi-account engine:
- **Notion** → internal integration tokens, one per workspace (**not** a member seat).
- **Google** → per-client OAuth refresh tokens (**not** API keys — those only reach public data; also not a seat).

Hold N credentials, route by account.

### D3 — Security is two-tier custody
**Decision:** Custody splits by *whose* account it is.

1. **Operator accessing CLIENTS' accounts** → those credentials live **only on the Mac**, in Keychain, passkey-gated. The cloud never holds them; it delegates down to the Mac, which must be active.
   - **Selling point:** "your most sensitive credentials never touch our servers."
   - **Client-SLA ruling (2026-05-30):** client work is **permanently Mac-present by design** — there is no laptop-off mode for client accounts, and the answer to "can it run for my client overnight?" is **no**. Client async-while-absent is *out of scope*, not a future feature. The laptop-off graduation marker (D5) applies **only to the operator's OWN async work**, never to client work.
2. **A cloud user's OWN accounts** → store-vs-passthrough question, governed by D4.

### D4 — Custody follows capability, not user preference
**Decision:** The custody model is dictated by *what the work needs*, never offered as a symmetric user toggle.
- **Synchronous / user-present** work → **pass-through, store nothing**.
- **Asynchronous / user-absent** work (schedules, webhooks, background agents) → **requires a stored token**.

**Never** offer a symmetric "pick your model" toggle — users can't judge it, and it doubles the attack surface. The only allowed user option is a **one-way ratchet that only tightens** ("never store" hard mode).

**If/when the cloud must store tokens**, it needs its own "keychain": envelope encryption, per-tenant keys in a KMS, decrypt-in-memory-only, never logged.

### D5 — V1 scope is LOCAL-ONLY
**Decision:** No cloud vault in V1. Everything lives in Keychain behind a passkey.
- The Bridge's built-in **scheduler** runs recurring jobs. **"Mac must be on" is accepted** (Isaiah is fine being present and responsible).
- Missed runs **catch up on reconnect** (persistent scheduling, anacron / `Persistent=true` style).
- V1 jobs are all **internal / idempotent**, so "run latest on reconnect" is enough. Per-job missed-run policy is **deferred**.
- The **cloud execution tier is explicitly a next-version feature** — built only after the idea is validated AND the **operator's own** async work genuinely needs to run without the laptop awake. That operator-own-async need is the **graduation marker**. (Note: a *client* SLA is **not** a graduation trigger — client work stays Mac-present per the D3 client-SLA ruling.)

---

## 5. Open Loops (the live work)

1. **Capture this repositioning + architecture durably** — *this document.* ✅ (keep it current; sync to Notion hub after milestones)
2. **Flesh out the local-vs-cloud split.** Enumerate exactly which capabilities are **cloud-only** (Notion fetch, skill management, plugin install) vs which **require Mac delegation**. Define the **cloud→Mac delegation + auth-passdown protocol**: how a cloud request is bound to the authenticated owner, and how the Mac enforces the passkey gate locally.
3. **Pin down the cloud-tier store-vs-passthrough boundary** and the **catch-up / missed-run policy model** (coalesce / run-each / skip-stale) for when jobs eventually become time- or money-sensitive.
4. **Pressure-test the neutrality promise concretely.** Prove the standing-orders + skills mechanism renders **identically** across Claude, Cursor, and ChatGPT. List the platform wrappers / context differences that **can't** be controlled.
5. **Decide the Notion custom-tool delta to keep** (multi-workspace routing, file upload) vs hand to Notion's own MCP — and whether an integration token can ride Notion's MCP or must stay on custom endpoints.

---

## 6. Guardrails (how to work against this doc)

- Don't re-decide locked items; surface new tensions as build-ons.
- **Neutrality is the spine** — challenge any idea that quietly makes the product better on one platform at the cost of sameness across all three.
- Propose before any destructive or multi-surface write.

---

## Glossary

- **The Bridge / NotionBridge** — the native macOS MCP server app.
- **Bridge Cloud Access** — the in-flight multi-tenant Cloudflare deployment (multi-tenant routing, `/provision` + `/heartbeat`, add-to-claude.ai install flow).
- **Standing orders** — the portable-identity mechanism; one identity referenced from each platform's instruction surface.
- **Graduation marker** — the trigger to build the cloud execution tier: idea validated AND the **operator's own** async work needing laptop-independent execution. (Client work never qualifies — see D3 client-SLA ruling.)

---

## Supersession Log

> Decisions that have changed. Old → new, dated, with the reason, so the history is auditable.

- **2026-05-30 — IdP: Clerk → WorkOS.** Earlier framing named Clerk as the candidate cloud identity layer. Superseded by **WorkOS**, which the in-flight cloud packets already build on (remote-MCP OAuth go-live, Enable flow WorkOS sign-in). The IdP remains abstracted/swappable; WorkOS is the committed default. *Source: Bridge Neutral-Layer NL-1 / NL-5 decision log.*
- **2026-05-30 — Graduation marker scope tightened.** Earlier framing said a *client SLA* forcing laptop-off execution was the trigger to build the cloud execution tier. Corrected: client work is permanently Mac-present (clients hear "no"); the graduation marker applies **only to the operator's own async work**. *Source: NL-5 client-SLA ruling.*
