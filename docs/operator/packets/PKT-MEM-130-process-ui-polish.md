# PKT-MEM-130 — Process tab UI polish

**Execution Class:** REVIEW-FIRST  
**Status:** REVIEW  
**Blocked by:** Phase 0 UI notes (FR-010, FR-013)  
**PROJECT:** Memory Hub v3.9.4

## Goal Contract

Resolve operator UI friction from Greg memo Process tab session without changing routing or write protocols.

## GOAL_CONDITION

Close each FR row tagged UI (FR-010, FR-013) with fix or documented deferral; operator spot-check on Greg memo; W1/W2 regressions pass.

## Evidence seed

- FR-010: UI shows 1 intent tag "Update record 86% ★" while MCP plan has 2 intents
- FR-013: Operator dissatisfied with intent display and project suggestion UX

## Scope IN

MemoryProcessTab.swift, MemoryProcessCockpit presentation, picker sheet, PKT-1005 AX if touched

## Scope OUT

Parser (128), dual-write (129)

## Definition of Done

- [ ] FR-010 resolved or deferred with reason
- [ ] FR-013 items addressed from operator notes
- [ ] MemoryProcessLayoutAXTests green if manifest changed

## Packet Runner Output

### Current Canonical Result

### Artifact Manifest

### Exceptional History

Operator to add verbatim UI notes during review if additional items beyond FR-010/013.
