# Agent Handshake Contract

Status: Draft
Updated: 2026-06-26
Source: choice-to-contract survey, delegated selection

## Objective

Make The Bridge handshake coherent for every connected agent platform: enough
shared doctrine to behave consistently, enough routing structure to avoid
misownership, and enough tool guidance to execute safely without platform lock-in.

## Current Evidence

- Live Bridge is online with Mac tools available.
- Live `skills_routing_list` returns 8 routing entries.
- Live roster still includes `executor`, even though standing orders describe it
  as a packet specialist rather than a routing owner.
- Current source still had handshake copy telling agents to call
  `list_routing_skills`; the primary tool is `skills_routing_list`.
- The repo already defines `bridge://standing-orders`,
  `bridge://routing-skills`, and `bridge://memory` resource URIs.

## Decision Ledger

1. Handshake shape: use a compact constitution plus `bridge://` resources.
   Rationale: the resource surface already exists, and full doctrine inline is
   too heavy for every initialize path.

2. Routing tree: expose only routing owners in `skills_routing_list`; load
   specialists through parent `fetch_skill` routing.
   Rationale: routing owners own user intent. Specialists execute narrower
   protocols after a parent has accepted the route.

3. Executor placement: keep `executor` packet-only, not a normal routing owner.
   Rationale: standing orders already say focus-keepr owns dispatch decisions;
   exposing executor as a routing owner invites agents to bypass orchestration.

4. Enforcement level: combine doctrine, tool metadata, tests, and targeted
   runtime warnings before hard rejection.
   Rationale: the skill tree is still evolving, so enforcement should prevent
   known drift without making registry work brittle.

5. Tool usage contract: use one platform-agnostic core contract with host
   adapters.
   Rationale: "agent-platform agnostic" means stable semantics across hosts,
   while still allowing Codex, Claude, ChatGPT, Cursor, Notion, and Raycast to
   use their native tool surfaces.

## Contract Patch Plan

1. Immediate source patch: handshake copy must advertise
   `skills_routing_list`, not `list_routing_skills`.
2. Registry migration: update the live `executor` skill visibility from
   `routing` to `standard`, after confirming no packet runner depends on
   direct routing discovery.
3. Compact handshake: add a compact initialize payload that points to
   `bridge://standing-orders`, `bridge://routing-skills`, and
   `bridge://memory` for full context.
4. Enforcement: add tests and tool annotations that define routing owner versus
   specialist behavior.
5. Host adapters: document the small translation layer for Codex, Claude,
   ChatGPT, Cursor, Notion, and Raycast without changing the core doctrine.

## Survey Exit Rule

Continue survey batches while they expose real forks. Stop when a new batch
would mostly repeat decisions already present here. Practical threshold: if 3
of 4 proposed questions are repeats, near-repeats, or implementation details
the agent can decide from this contract, stop surveying and move to
implementation readiness.

## Open Questions

- Which initialize clients should receive compact instructions first?
- Should specialist misroutes produce warnings only, or structured recoverable
  errors once the registry migration is complete?
- What minimum host adapter docs are needed before this becomes the published
  Bridge handshake contract?
