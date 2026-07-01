# Memory Hub — Transcript fate (W3 decision)

**Decision (2026-06-30):** Full voice memo transcript is **UI-only** in Process tab. Notion `memory_keep` commits write:

- Registry properties (`title`, `summary` with action bullets, `alias`, `status`, `type`, `url`)
- Notion page body: structured **Summary** heading + paragraph + **Action items** bullets

The legacy `appendTranscriptToNotionPage` helper remains for explicit opt-in callers only; default `executeMemoryKeep` does **not** append transcript blocks.

**Rationale:** Operator trust + summary-first keeps (FR-005). Transcript remains visible via expandable transcript fade in Process.
