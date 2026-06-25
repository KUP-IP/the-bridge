# PKT-MEM-103 — Review Resolve, Dispositions & TTL

**Wave:** 2 (after Wave 1 merge)  
**Class:** Standard  
**Spec:** `docs/operator/MEMORY-HUB-EXECUTION-SPEC.md` §4  
**Branch:** `feat/pkt-mem-103-review-resolve` off Wave 1 integration branch

---

## Objective

Enable full review dispositions via MCP + Inbox UI actions; implement review queue TTL sweeper.

## Scope

**IN:**
- `voice_memo_review_resolve` tool: actions `memory_keep`, `reminder`, `agent_remember`, `registry_update`, `retry_routing`, `mark_handled`
- Wire Inbox buttons to resolve handler (reuse `VoiceMemoProcessor` paths)
- `voice_memo_transcript_refresh` (optional): force transcription ladder step
- TTL sweep: pending 30d → auto-dismiss; dismissed 7d → purge
- Hook sweep on app launch + wake (reuse JobsReconciler / similar pattern)
- Idempotency: warn or block duplicate `memory_keep` for same memo id
- `ToolAnnotationCatalog` entries for new tools
- Tests for resolve actions + TTL logic (hermetic stores)

**OUT:**
- Notification categories (PKT-MEM-104)
- Notion/Agent tab polish

## Definition of Done

- [ ] File as Memory from Inbox creates registry row + transcript body
- [ ] Retry routing re-runs Ollama without re-transcribe
- [ ] TTL unit tests pass with injected clock or date overrides
- [ ] `make test` + floor green

## QA Checklist

- [ ] 20260613 memo: File as Memory from Inbox → Notion page + processed.json
- [ ] Dismiss vs mark_handled semantics correct
- [ ] Auto-dismiss after 30d simulated

## Execution Directives

- Disposition handlers should call existing processor methods, not duplicate Notion writes
- Security tiers: memory_keep = notify, dismiss = open, registry_update = notify/request per field
- Processed store updated per spec table §4

## Dependencies

PKT-MEM-101, PKT-MEM-102 merged
