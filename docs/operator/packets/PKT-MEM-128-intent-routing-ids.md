# PKT-MEM-128 — Intent routing + row ID surfacing

**Execution Class:** REVIEW-FIRST  
**Status:** BLOCKED  
**Blocked by:** PKT-MEM-127 DONE  
**PROJECT:** Memory Hub v3.9.4

## Goal Contract

Greg memo (`20260630 163652…`) must produce registry_update intents for Greg/contact + specific project; inspector shows title + row id + entityKey + dataSourceId.

## GOAL_CONDITION

Re-run Greg memo Understand; satisfy oracle O1–O3; registry_update previews include resolved row ids; hermetic test from FR-008 — within VoiceMemoParser/ParseRouter/Processor and MemoryProcessCockpit.intentWritePreview only.

## Evidence seed (FR-008, FR-009)

Actual plan: memory_keep + agent_memory only. Missing Greg/client project lanes.

## Scope IN

- VoiceMemoParser.swift, VoiceMemoParseRouter.swift, VoiceMemoProcessor.swift
- MemoryProcessCockpit.intentWritePreview — rowId, entityKey, dataSourceId lines
- Row search/disambiguation via registry list

## Scope OUT

Dual-write (129), onboarding (127), UI chrome (130)

## Definition of Done

- [ ] ≥2 intent kinds including registry_update for contact + project
- [ ] Inspector shows row id when resolved
- [ ] make test-floor green

## Verification

voice_memo_get understand:true on Greg memo; dryRun; operator sign-off

## Packet Runner Output

### Current Canonical Result

### Artifact Manifest

### Exceptional History
