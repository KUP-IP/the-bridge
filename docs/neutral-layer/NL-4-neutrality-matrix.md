# NL-4 — Neutrality Matrix + Failure-Mode Neutrality (Claude / Cursor / ChatGPT)

**Date:** 2026-05-30
**Owner:** Isaiah Peters
**Status:** Draft — spec of record
**Source:** NL-1 (frame corrections), product-strategy.md §2 (neutrality spine)

---

## 0. Purpose

NL-1 fixed the frame: the moat is **aggregation**, not any single capability. The
Bridge is one vendor-neutral surface that presents the same identity, skills,
credentials, and routing to whatever client connects. NL-4 makes that claim
falsifiable. It states, cell by cell, where "identical everywhere" holds, where
it degrades, and where it is structurally impossible — across Claude, Cursor, and
ChatGPT.

**Decision — Neutrality is a measured property, not a slogan.** Every value prop
gets a per-platform grade (`same` / `degraded` / `unavailable`) with a stated
reason. A cell with no reason is a bug in this doc. *Rationale: an aggregation
moat only holds if the aggregate behaves predictably; unmeasured "neutrality"
erodes into per-client special-casing, which is exactly the lock-in NL-1 rejects.*

**Decision — Sameness is defined at the Bridge boundary, not the pixel.** "Same"
means the Bridge returns the same data, runs the same logic, and enforces the same
policy for a given request. It does **not** mean the client renders it
identically. *Rationale: we control the relay and the vault; we do not control
client chrome. Claiming UI parity we can't deliver is the overclaim NL-1 warns
against.*

---

## 1. Definitions (grading legend)

- **same** — Identical Bridge behavior and identical observable result for the
  user. The platform exposes the surface the feature needs (tool calls + an
  instruction-loading path) and the Bridge drives it the same way.
- **degraded** — The capability is present but reduced on this platform: fewer
  triggers, manual invocation instead of automatic, narrower payload, or a
  weaker delivery surface. The *data and policy* are still the Bridge's; the
  *ergonomics* are worse. Always paired with a workaround.
- **unavailable** — The platform cannot host the capability at all in its current
  form. No Bridge-side workaround restores it; only a platform change would.

**Decision — `degraded` always ships a workaround; `unavailable` always ships a
reason rooted in a platform constraint, not our backlog.** *Rationale: keeps the
matrix honest. If we could fix a cell ourselves it is `degraded` (with the fix as
the workaround), not `unavailable`. `unavailable` is reserved for things outside
our control (§4).*

---

## 2. Neutrality Matrix — Feature × Platform

Platforms: **Claude** (desktop/Code, full local MCP), **Cursor** (IDE, local MCP),
**ChatGPT** (remote MCP connector only, per NL-1).

| Value prop | Claude | Cursor | ChatGPT | Notes |
|---|---|---|---|---|
| **Standing orders / identity** (who you are, defaults, operating baseline) | same | same | degraded | Identity lives in the vault and is injected by the Bridge on session start. Claude/Cursor load it via project instructions + an init handshake (the `standing-orders` skill pattern). ChatGPT has no persistent local instruction file the Bridge controls; identity is delivered as a tool-returned preamble the model must fetch, so it is opt-in per session rather than ambient. |
| **Portable skills / commands** (fetch_skill, routing skills, slash-equivalents) | same | same | degraded | Skill bodies are stored once and served by the Bridge to any client. Resolution and content are identical. Claude/Cursor invoke them as native commands; ChatGPT can only reach them as remote tool calls, with no slash UI and lazy (search-then-fetch) discovery — same skill, weaker trigger surface. |
| **Credential vault access** (credential_read/list, scoped capability grants) | same | same | same | The vault is server-side and reached purely through tool calls. Every platform that can call a tool gets byte-identical credentials under identical scope/expiry policy. No client-side secret material on any platform — this is the cleanest `same` in the matrix and the core of the relay-vs-vault split (NL-1). |
| **Multi-account routing** (pick the right Notion/Stripe/Gmail connection per request) | same | same | same | Routing is decided in the relay from the request + active capability grants, not the client. The client never sees account selection logic; it sees one resolved tool result. Identical on all three. |
| **Live local actions** (Mac shell, AX, screen, Messages — Bridge MCP local tools) | same | same | unavailable | Requires a local MCP transport to the user's Mac. ChatGPT is remote-only (NL-1) and cannot reach a local process, so Mac-resident tools are structurally absent there. Listed for completeness; it is an *infrastructure* prop, not one of the four core value props, but it is the sharpest neutrality boundary so it belongs in the matrix. |
| **Ambient automatic invocation** (skills/orders firing without the user naming them) | same | degraded | degraded | Depends on the platform honoring loaded instructions that say "do X automatically." Claude desktop/Code honor a loaded instruction surface well; Cursor's instruction precedence varies by mode; ChatGPT requires the model to first pull the preamble tool, so "automatic" becomes "automatic-after-first-fetch." Data identical; proactivity differs. |

**Decision — The four core value props are `same` on Claude and Cursor, and split
`same`/`degraded` on ChatGPT, with the split caused entirely by surface, never by
the data.** Credential vault and multi-account routing are `same` on all three;
standing orders and portable skills are `degraded` on ChatGPT only. *Rationale:
this is the precise, bounded version of "identical everywhere." The vault and the
router are reached by tool calls alone, so they are platform-blind. Identity and
skills additionally want an ambient instruction surface, which ChatGPT does not
give us — hence `degraded`, not `unavailable`, because the tool-call path still
delivers the same payload.*

**Decision — There is no cell where the Bridge returns different data per
platform.** Every `degraded`/`unavailable` in the matrix is a delivery-surface or
transport limitation, not a content difference. *Rationale: content divergence
would be the Bridge picking favorites — the anti-pattern the neutrality spine
(§2 of the strategy) exists to prevent.*

---

## 3. Failure-Mode Neutrality

Neutrality must also hold when things break. The rule: **under a given failure,
all three platforms see the same behavior class and the same message shape.** A
user moving from Cursor to ChatGPT mid-incident must not have to relearn what
"offline" or "expired" looks like.

**Decision — Failures are returned as structured, identical-across-platforms tool
results, never as silent empties or client-specific errors.** Each failure has
one canonical Bridge response that every client receives verbatim. *Rationale:
the failure surface is part of the product; inconsistent errors are
indistinguishable from inconsistent capability and quietly kill the "identical
everywhere" promise.*

### 3.1 Mac offline / local transport down

- **Behavior (all platforms):** Local-only tools (shell, AX, screen, Messages)
  return a `BRIDGE_LOCAL_UNREACHABLE` result naming the unreachable host and the
  last-seen timestamp. Vault, routing, skills, and identity — all server-side —
  **continue to work unchanged.**
- **Consistency:** ChatGPT already never had local tools, so for the
  vault/routing/skills set ChatGPT's behavior offline is *indistinguishable from
  its behavior online* — and Claude/Cursor converge to that same ChatGPT-shaped
  behavior for the server-side props. The degradation is symmetric: everyone
  loses exactly the local tools, no one loses the aggregate.

### 3.2 Capability expired (grant lapsed / trial gate / scope timeout)

- **Behavior (all platforms):** The call returns `BRIDGE_CAPABILITY_EXPIRED` with
  the capability name, expiry time, and the renewal path. No partial execution,
  no fallback to a different account. The vault does not emit the secret.
- **Consistency:** Expiry is evaluated in the relay before any client-specific
  formatting, so the gate fires at the same point in the request on every
  platform. A request that is blocked on Claude is blocked identically on ChatGPT.
- *Rationale: enforcement in the relay (not the client) is what makes the
  license/trial gate uniform; pushing it client-side would let the weakest
  client become the bypass.*

### 3.3 Missing connection (account never linked / connection deleted)

- **Behavior (all platforms):** `BRIDGE_CONNECTION_MISSING` with the connection
  type, the routing key that needed it, and the link instruction. Multi-account
  routing fails *closed* — it never silently substitutes another account.
- **Consistency:** Same structured result on all three; the only platform
  difference is rendering (Claude/Cursor may surface it as a tool error block,
  ChatGPT inline in the assistant turn), which is client chrome, not behavior.

**Decision — Degraded behavior fails closed and fails identically; it never fails
toward a different account, a stale secret, or a silent no-op.** *Rationale:
"same everywhere" under failure is only meaningful if the safe direction is the
same everywhere. Fail-open would make neutrality a security regression.*

---

## 4. Uncontrollable Platform Differences (where sameness is bounded)

These are the seams we **cannot** close from the Bridge. They bound the
"identical everywhere" claim. We list them so the build never promises past them.

1. **ChatGPT is remote-only (NL-1).** ChatGPT reaches the Bridge solely as a
   remote MCP connector. It cannot host a local transport to the user's Mac, so
   the entire local-action surface is permanently `unavailable` there. This is a
   platform architecture fact, not a roadmap item.

2. **Instruction-loading surfaces differ.** Claude (desktop/Code) loads ambient
   project/user instructions and supports an init handshake; Cursor has its own
   rules/instruction precedence that varies by mode; ChatGPT exposes **no
   Bridge-controlled persistent instruction file** — identity and standing orders
   must be pulled via a tool each session. We cannot make standing orders equally
   *ambient* across all three; we can only make the *content* identical once
   loaded.

3. **Tool-call semantics differ.** Discovery (eager vs. lazy/search-then-fetch),
   parallel-call support, argument schema surfacing, and result-block rendering
   vary per client. The Bridge normalizes payloads but not the *invocation
   ergonomics* — e.g., ChatGPT's lazy discovery turns "automatic" skills into
   "fetch-first" skills.

4. **Slash / command UI is client-owned.** Native slash menus exist on
   Claude/Cursor and not in ChatGPT's connector surface. Portable skills are the
   same artifact everywhere; their *entry point* is not.

5. **Proactivity / system-prompt weighting is client-owned.** How strongly a
   client honors a loaded "do this automatically" instruction is set by the
   client's own system prompt and model behavior, outside our reach. This is why
   ambient invocation is `degraded` rather than `same` off-Claude.

6. **Session persistence and memory are client-owned.** Whether identity loaded
   once carries across turns/sessions depends on the client. The Bridge can
   re-serve identity cheaply, but cannot force a client to retain it.

**Decision — "Identical everywhere" is ABSOLUTE for the vault and the router, and
BOUNDED for standing orders, skills, and proactivity.** Concretely: credential
vault access and multi-account routing are identical on Claude, Cursor, and
ChatGPT with no caveats. Standing orders and portable skills are identical *in
content and policy* but bounded *in delivery* — full and ambient on Claude/Cursor,
fetch-first and non-ambient on ChatGPT. Local actions are not claimed on ChatGPT
at all. *Rationale: this is the most we can truthfully promise. The aggregation
moat (NL-1) survives the bound because the aggregate — one vault, one router, one
skill store, one identity — is reached by tool calls, and tool calls are the one
thing every MCP client must support. What we lose off-Claude is ambient
ergonomics, not the aggregate. Claiming UI/proactivity parity we cannot enforce
would trade a defensible moat for a falsifiable slogan.*

---

## 5. Build Implications (carry-forward)

- The relay must emit the three canonical failure results (§3) before any
  client-specific formatting. One code path, all clients.
- Identity and skills must be reachable via a single tool (`fetch`-style) so
  ChatGPT's fetch-first path returns byte-identical content to Claude's ambient
  load.
- The matrix (§2) is the conformance target: a per-platform smoke test should
  assert each `same` cell returns identical Bridge output, and each `degraded`
  cell returns identical *content* under a different invocation path.
- No client may hold secret material or routing logic. Any such code is a
  neutrality regression and a §4 violation.
