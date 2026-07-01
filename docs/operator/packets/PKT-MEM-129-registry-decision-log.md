# PKT-MEM-129 — Registry Decision Log dual-write (universal)

**Execution Class:** REVIEW-FIRST  
**Status:** BLOCKED  
**Blocked by:** PKT-MEM-127 DONE + PKT-MEM-128 DONE  
**PROJECT:** Memory Hub v3.9.4

## Goal Contract

Every voice registry_update dual-writes: append management properties (summary/brief) + standardized decision-log Notion page block. Entity-agnostic for contact, project, session.

## GOAL_CONDITION

Implement dual-write with partial-failure receipts, dryRun preview of both legs, decisionLogEnabled opt-out per RegistryEntity — verified on disposable memo and Greg memo dryRun.

## Product guardrails

- Partial failure: ✓ property / ✗ block visible in receipt
- RegistryRateLimiter respected
- memory_keep separate from decision log
- Notion-native blocks (heading + bullets)

## Scope IN

RegistryWriter, VoiceMemoProcessor, RegistryEntity config (decisionLogEnabled, managementAppendFields), intentWritePreview block leg

## Replay and Recovery

Property PATCH success + block append fail → partial receipt; idempotent block key for retry.

## Definition of Done

- [ ] dryRun shows property + block preview
- [ ] Live disposable memo: per-leg receipts
- [ ] Hermetic dual-write once per commit

## Packet Runner Output

### Current Canonical Result

### Artifact Manifest

### Exceptional History

FR-011: gap confirmed at closeout.
