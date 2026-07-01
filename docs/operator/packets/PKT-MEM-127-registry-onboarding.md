# PKT-MEM-127 — Registry entity onboarding

**Execution Class:** REVIEW-FIRST  
**Status:** BLOCKED  
**Blocked by:** Operator must confirm Clients DS maps to `contact` entity or add `client` alias; verify `session` = PACKETS for voice router  
**PROJECT:** Memory Hub v3.9.4

## Goal Contract

Bind voice-routable entities so Greg-memo class updates can target contact (client), project, session (packet) with bound summary/brief fields.

## GOAL_CONDITION

Achieve `registry_entities` listing contact, project, session with fully bound property ids and documented entityKey strings matching VoiceMemo parser output, verified via registry_entities JSON and Data Sources UI, before PKT-MEM-128 proceeds.

## Current System State

Phase 0 audit (2026-07-01): project, contact, session bound; no `client` key; contact has `brief` not `summary`; session displayName "Sessions".

## Dependencies

- PKT-MEM-CLOSEOUT-001 DONE
- Operator: confirm entityKey mapping table (contact=clients, session=packets)

## Definition of Done

- [ ] entityKey alias doc: client → contact or new entity
- [ ] Voice router emits keys matching registry
- [ ] Hermetic registry read per entity

## Verification

`registry_entities` + Settings → Data Sources screenshot

## Packet Runner Output

### Current Canonical Result

### Artifact Manifest

### Exceptional History

Blocked: FR-014 — naming mismatch client vs contact.
