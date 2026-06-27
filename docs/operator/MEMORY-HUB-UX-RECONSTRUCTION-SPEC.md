# Memory Hub UX Reconstruction Spec

**Status:** Decision survey in progress  
**Created:** 2026-06-27  
**Purpose:** Source of truth for reconstructing The Bridge Memory interface and preparing coding-agent implementation packets.

## Objective

Rebuild the Memory section around a clearer user workflow for retained memory, agent memory, voice memo processing, review disposition, and operational evidence.

The reconstructed surface must make memory handling legible to the operator, preserve agent queryability, and support provider-agnostic inference configuration without hiding consequential actions behind ambiguous card buttons.

## Locked Decisions

### D1 - Source of Truth Artifact

**Decision:** Create a new reconstruction spec as the durable handoff artifact.

**Rationale:** The requested work is a redesign and architecture clarification, not a small patch to the existing Memory Hub execution spec.

**Contract patch:** This file, `docs/operator/MEMORY-HUB-UX-RECONSTRUCTION-SPEC.md`, is the SSOT for the reconstruction survey and coding-agent handoff. Existing Memory Hub specs remain reference material unless explicitly pulled forward here.

### D2 - Top-Level Section Model

**Decision:** Replace the current Memory tab model with the user-facing order:

1. `KEEP`
2. `AGENTS`
3. `PROCESSING`
4. `INBOX`
5. `ACTIVITY`

**Rationale:** The revised order starts from durable user memory, then agent memory, then system configuration, then review queue, then operational evidence.

**Impact:** Current sections `Process / Inbox / Notion / Agent / Processing` must be re-mapped. Legacy deep links and accessibility identifiers should be preserved or aliased where practical.

### D3 - Inbox Review UX

**Decision:** INBOX uses summary cards plus a review drawer.

**Rationale:** The current action-heavy cards make disposition effects hard to understand. A card-plus-drawer model keeps scanning fast while making consequences explicit before commit.

**Contract patch:** Cards expose summary state, audio playback, trash, and primary review affordances. The review drawer explains the selected disposition, target system, write behavior, processed-state effect, and reversibility before execution.

### D4 - KEEP Model

**Decision:** KEEP is the Notion Memory registry experience, backed by local cache and spaced review.

**Rationale:** The operator wants retained memories that stay queryable for agents and periodically reviewable by the user.

**Impact:** The current `Notion` tab is renamed and redesigned as `KEEP`. It is not a generic Notion row preview. It must support retained-memory review, quiz/spaced repetition workflows, and a local cache of the Notion Memory registry.

### D5 - AGENTS Model

**Decision:** AGENTS is an editable, agent-agnostic local memory table.

**Rationale:** The on-device SQLite memory store is the SSOT for agent memory and should be manageable by the operator.

**Impact:** The current card list with pin/forget only is insufficient. The reconstructed AGENTS view must expose table management, search/filtering, source/client context, and editable cells.

### D6 - PROCESSING Provider Model

**Decision:** PROCESSING uses provider-agnostic inference profiles.

**Rationale:** The current single OpenAI-compatible provider card is too narrow. The architecture should support Anthropic, OpenAI, Cursor, Google, and ElevenLabs through provider families/adapters without making provider examples the primary UI.

**Contract patch:** Provider-specific details belong in configuration controls and information hover-over affordances. The main UI should describe capabilities and profiles, not market or rank providers.

### D7 - Default Landing Surface

**Decision:** KEEP is the default Memory landing surface.

**Rationale:** The operator explicitly selected KEEP as the first/default surface. This makes retained memory the anchor of the section rather than raw processing or exception handling.

**Impact:** Opening Memory with no deep link should show KEEP. Deep links to INBOX, PROCESSING, AGENTS, ACTIVITY, and legacy anchors must still route correctly.

### D8 - Mark Handled vs Dismiss Semantics

**Decision:** Dismiss should mark the memo as processed.

**Rationale:** The operator selected a simpler mental model where dismissing a review removes it from unresolved work rather than leaving the source memo effectively unprocessed.

**Impact:** This revises current behavior. Today `Dismiss` only marks a review entry dismissed and does not mark the memo processed. The reconstruction must define the exact sibling-review behavior before implementation so unresolved lanes are not accidentally hidden.

### D9 - Trash Behavior

**Decision:** Trash should move the source memo and Bridge sidecars to macOS Trash, dismiss all pending lanes, and record an activity receipt.

**Rationale:** This satisfies the operator's desire to manage memo lifecycle from the interface while preserving reversibility through Trash.

**Impact:** Requires confirmation UI, review-state cleanup, sidecar discovery, and ACTIVITY evidence.

### D10 - KEEP Review Metadata

**Decision:** Store KEEP review metadata in Notion Memory rows and mirror locally.

**Rationale:** This keeps spaced repetition and review state agent-queryable outside The Bridge while allowing Bridge to cache and operate efficiently.

**Impact:** Requires Memory registry schema mapping for review metadata, local cache fields, and sync/error states.

### D11 - AGENTS Edit Model

**Decision:** AGENTS table edits are direct in-place SQLite edits.

**Rationale:** The operator selected the expected spreadsheet-like table behavior over audit-style superseding rows.

**Impact:** The implementation spec must define which fields are editable, validation rules, and how edits interact with FTS/vector indexes, source attribution, and pinned/forgotten state.

### D12 - ACTIVITY Scope

**Decision:** ACTIVITY is a unified operator timeline.

**Rationale:** The Memory system needs a visible evidence surface for trust, debugging, and review.

**Impact:** ACTIVITY should include memo processing, dispositions, provider runs, KEEP sync, AGENTS edits, trash events, and errors.

### D13 - INBOX Multi-Lane Dismiss

**Decision:** Ask when siblings exist.

**Rationale:** This preserves the simpler "Dismiss processes it" model for single-lane reviews while preventing multi-intent memo work from being silently hidden.

**Contract patch:** For a single pending lane, Dismiss dismisses the review and marks the memo processed. When the memo has sibling pending lanes, Dismiss must present a choice between dismissing only the selected lane or dismissing the whole memo. The memo is marked processed only after all sibling lanes are resolved, dismissed, saved, marked handled, or trashed.

### D14 - KEEP Review Mode

**Decision:** KEEP uses a hybrid review model.

**Rationale:** Retention requires more than archival review, but quiz generation should not block every memory row from being reviewable.

**Contract patch:** KEEP review shows the retained memory first and supports optional quiz prompts when available. The UX must support recall-quality marking even when no quiz prompt exists.

### D15 - KEEP Schema Control

**Decision:** Add required review fields to the Notion Memory registry.

**Rationale:** Review status, cadence, and recall evidence should remain agent-queryable in the Memory registry rather than being trapped in local Bridge-only state.

**Impact:** The implementation spec must define a schema migration or schema-check flow for review fields, local cache mirroring, and stale/error states when Notion fields are unavailable.

### D16 - AGENTS Editable Columns

**Decision:** Editable AGENTS columns are text, scope, entity, type, pinned, source, and expiry.

**Rationale:** This gives meaningful operator control while protecting system identity and lifecycle fields such as IDs, creation timestamps, last-used timestamps, use counts, content hashes, and supersession metadata.

**Impact:** Direct SQLite edits must validate editable fields and refresh dependent search/vector indexes where needed.

### D17 - PROCESSING Profile Model

**Decision:** PROCESSING uses a hybrid provider + capability matrix.

**Rationale:** Providers differ by capability. The UI should show which provider profile powers transcription, routing, summarization, title generation, quiz generation, or other inference needs.

**Contract patch:** Provider profiles should support Anthropic, OpenAI, Cursor, Google, and ElevenLabs through adapters/capabilities. Provider examples belong in configuration controls and hover/help affordances, not as primary marketing copy.

### D18 - Visual Layout Direction

**Decision:** Use a hybrid layout direction by section.

**Rationale:** The five sections perform different jobs and should not force one component pattern everywhere.

**Contract patch:** KEEP and AGENTS use dense tables/review surfaces. INBOX uses summary cards plus a review drawer. PROCESSING uses a profile workbench. ACTIVITY uses a timeline/log surface.

### D19 - KEEP Review Fields

**Decision:** Use required minimal review fields plus optional quiz/SRS fields.

**Rationale:** This supports a usable first review version without blocking richer spaced-repetition and quiz behavior.

**Contract patch:** Required KEEP review fields are `reviewStatus`, `nextReviewAt`, `lastReviewedAt`, and `recallScore`. Optional fields include interval, ease, lapse count, review count, prompt, answer, and source memo linkage when available.

### D20 - KEEP Review States

**Decision:** Use simple user-facing review states: `New`, `Learning`, `Review`, `Mastered`, `Archived`.

**Rationale:** These states are understandable without requiring the operator to think in spaced-repetition implementation terms.

**Impact:** Internal SRS calculations can map onto these states, but the UI should expose the simple state names by default.

### D21 - INBOX Audio Controls

**Decision:** Use a mini player on the selected or expanded card plus full drawer controls.

**Rationale:** This keeps the card list scannable while allowing fast playback for the item under review.

**Impact:** Audio controls should not crowd every collapsed card. The selected card and review drawer must support playback, position, duration, and basic play/pause behavior.

### D22 - AGENTS Edit Persistence

**Decision:** Edit row draft, then Save or Cancel.

**Rationale:** Local agent memory edits are consequential enough to need a clear commit point, while still feeling table-oriented.

**Impact:** Inline cell edits can enter row draft state, but persistence occurs through explicit row-level Save/Cancel. Validation errors keep the row in draft state and explain the issue.

### D23 - PROCESSING Secret Handling

**Decision:** Use shared credential references.

**Rationale:** Provider and capability profiles should not duplicate secrets. A reusable credential reference model is cleaner for multi-provider, multi-capability configuration.

**Impact:** Profiles point to Keychain-backed credential references. The UI must support creating/selecting/updating credential references without exposing raw secrets after save.

### D24 - ACTIVITY Retention

**Decision:** Retain 2,000 events or 90 days, whichever is smaller.

**Rationale:** The Memory system is new and needs enough evidence for debugging, trust-building, and regression review while it stabilizes.

**Impact:** This revises the existing nearby 500-event/30-day activity cap for the reconstructed ACTIVITY surface.

### D25 - Implementation Slice Order

**Decision:** Use a vertical-slice-first implementation order.

**Rationale:** The reconstruction must prove trust through real workflows, not just new screens or isolated infrastructure.

**Contract patch:** Build one complete path across KEEP, INBOX disposition, and ACTIVITY evidence first, then expand the remaining section coverage.

### D26 - Migration Strategy

**Decision:** Use forward migration with rollback notes.

**Rationale:** The live memo backlog and existing memory rows matter, but the reconstruction needs schema/cache/activity changes that should not remain as compatibility-only shims.

**Impact:** Migration must cover tab names, cache fields, activity retention, KEEP review metadata, and provider profile changes. The implementation handoff must include rollback notes.

### D27 - Legacy Tab Anchors

**Decision:** Preserve all legacy anchors indefinitely.

**Rationale:** Deep-link aliases are cheap compared with the cost of breaking existing links, tests, or agent instructions.

**Impact:** Legacy anchors such as `process`, `processing`, `inbox`, `notion`, `registry`, `agent`, and `voice-memos` should continue to route to the appropriate reconstructed section.

### D28 - QA Gate

**Decision:** Use unit/scenario tests plus a live manual smoke script for five real workflows.

**Rationale:** The code needs automated regression coverage, but the operator's confidence problem is workflow- and UI-visible.

**Impact:** The spec must define automated tests and a manual smoke script that exercises real Bridge behavior.

### D29 - Spec Output Shape

**Decision:** Prepare three coding-agent packets: foundation, UI reconstruction, and QA/migration.

**Rationale:** One packet would be too large and section-by-section packets would add coordination overhead. Three packets match the actual dependency structure.

**Impact:** The final handoff should produce packet-ready scopes for data/foundation work, visible UI work, and verification/migration work.

### D30 - First Live Workflow To Prove

**Decision:** First prove voice memo to KEEP review item.

**Rationale:** KEEP is now the landing surface and durable memory anchor.

**Impact:** The first vertical smoke path must capture or select a voice memo, route it into KEEP, create/update the Notion Memory registry row and local cache, assign review metadata, and emit ACTIVITY evidence.

### D31 - Foundation Packet Boundary

**Decision:** Foundation packet covers data plus backend contracts.

**Rationale:** The UI reconstruction needs stable contracts before it can safely rebuild the visible workflows.

**Contract patch:** Foundation includes KEEP fields/cache, activity retention, migration, review/disposition APIs, trash behavior, agent-memory update path, provider profiles, and activity event contracts.

### D32 - UI Packet Boundary

**Decision:** UI packet starts with the vertical UI slice.

**Rationale:** This matches the locked vertical-slice strategy and produces a real workflow instead of a navigation shell.

**Contract patch:** UI packet first builds KEEP landing, INBOX drawer, and ACTIVITY evidence for the first live workflow, then fills AGENTS and PROCESSING.

### D33 - Five Live Smoke Workflows

**Decision:** Use the KEEP-first workflow set.

**Rationale:** This covers the redesigned surfaces without overfitting the reconstruction to old live-test cases.

**Contract patch:** The live smoke suite is: voice memo to KEEP, INBOX multi-lane dismiss, Trash memo, AGENTS row edit, and PROCESSING provider test with ACTIVITY evidence.

### D34 - Migration Rollback Standard

**Decision:** Use rollback notes only.

**Rationale:** The operator revised this decision to prioritize implementation speed and manual recovery over pre-migration backup automation.

**Impact:** Migration work must document what changed and how to manually recover or reverse it, but it does not need to create a pre-migration backup or automatic rollback command.

### D35 - AGENTS Update Surface

**Decision:** Add a `memory_update` MCP tool plus UI store support.

**Rationale:** Agent memory is intended to be agent-agnostic and locally authoritative, so row updates should go through a supported contract rather than raw SQLite edits.

**Impact:** `memory_update` must support validated updates for editable fields and keep indexes/store invariants consistent with the AGENTS table.

### D36 - PROCESSING Provider Validation

**Decision:** Add manual "Test profile" validation per capability.

**Rationale:** This gives confidence in endpoint, key, model, and capability wiring without triggering unwanted external calls during save.

**Contract patch:** Saving a provider profile validates local syntax only. Explicit Test actions validate selected capabilities and emit ACTIVITY evidence.

### D37 - KEEP Scheduling Logic

**Decision:** Use hybrid scheduling.

**Rationale:** KEEP needs retention intelligence without taking scheduling control away from the operator.

**Contract patch:** The system suggests the next review date from review state, recall score, and optional SRS fields. The operator can override the date manually.

### D38 - KEEP Quiz Generation

**Decision:** Generate quiz prompts only on explicit user action.

**Rationale:** This preserves privacy and provider-call control while still allowing enriched review rows when useful.

**Impact:** Saving a memory to KEEP must not automatically call an external provider for quiz generation. Quiz generation is an explicit action and should emit ACTIVITY evidence.

### D39 - INBOX Action Language

**Decision:** Use icon-first compact actions.

**Rationale:** The operator revised this decision to prioritize cleaner, less text-heavy cards.

**Contract patch:** Collapsed and card-level INBOX actions should be icon-first with tooltips and accessibility labels. Full consequence explanations belong in the selected-card state and review drawer, not as long visible button labels on every card.

### D40 - INBOX Confirmation Rules

**Decision:** Confirm only Trash.

**Rationale:** The operator revised this decision to keep review flow fast and avoid over-confirming normal dispositions.

**Impact:** Trash requires confirmation. Other dispositions do not use confirmation dialogs. For multi-lane reviews, sibling scope selection should be part of the normal review drawer state, not a separate confirmation modal.

### D41 - AGENTS Update Authorization

**Decision:** `memory_update` is notify-tier for all editable fields.

**Rationale:** The operator revised this decision to prioritize fast agent workflows and consistent editable-table behavior.

**Contract patch:** The `memory_update` tool supports all editable fields at notify tier. The UI still uses explicit row Save/Cancel before persisting edits.

### D42 - PROCESSING Capability Routing

**Decision:** Use an ordered fallback chain per capability.

**Rationale:** Provider routing should be resilient while remaining understandable in the UI.

**Contract patch:** Each capability can define an ordered fallback chain. The UI must show active provider order, fallback status, and validation state per capability.

### D43 - Notion Schema Migration Gate

**Decision:** Auto-create missing KEEP fields.

**Rationale:** The operator selected speed and direct migration over approval-gated schema diff review.

**Contract patch:** When required KEEP review fields are missing from the Notion Memory registry, the migration may create them automatically. This contract-level decision authorizes that shared-structure change for the reconstruction scope.

### D44 - AGENTS Edit Conflict Handling

**Decision:** Last save wins.

**Rationale:** The operator selected fast table editing over stale-row detection or edit locks.

**Impact:** AGENTS row edits do not need conflict prompts. The final saved row state overwrites prior editable-field values, while protected fields remain non-editable.

### D45 - Release Safety

**Decision:** Replace the current Memory UI directly.

**Rationale:** The operator selected implementation speed and a clean replacement over a beta toggle or side-by-side mode.

**Impact:** The reconstruction does not require a feature flag or parallel legacy UI. Legacy deep-link anchors still route to the new sections per D27.

## Current Behavior To Preserve Or Revise

- `Mark handled` currently resolves a review and marks the memo processed only if no sibling pending review remains.
- `Dismiss` currently dismisses only the review entry and does not mark the memo processed. This is revised by D8, pending exact sibling-review rules.
- `File as Memory` currently writes to the Notion Memory registry and appends the transcript to the Notion page.
- `Agent should know` currently writes the full transcript into local SQLite agent memory.
- Provider config currently stores provider rows in local JSON and stores API keys in Keychain, but the UI only exposes a single OpenAI-compatible profile.

## Open Decisions

The next survey batch should lock:

- KEEP review session layout.
- External provider auto-run policy.
- Design-detail handoff depth.
- Final section-level acceptance criteria.
- Packet closeout format.
