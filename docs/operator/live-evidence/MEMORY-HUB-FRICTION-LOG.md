# Memory Hub — Friction & Bug Log

Agent-owned running log for HITL testing. Severity: **P0** blocker · **P1** major · **P2** moderate · **P3** polish.

| ID | Source | Sev | Symptom | Evidence | Root cause | Fix wave | Status |
|----|--------|-----|---------|----------|------------|----------|--------|
| FR-001 | PKT-MEM-123 live | P1 | Memo click auto-runs full Understand (slow) | MEMORY-HUB-UI-SCENARIOS L1 notes | `loadPreview` → `voice_memo_get` always calls `buildPlan` | W1 Phase A | **fixed** — inspect-only select + opt-in Process |
| FR-002 | PKT-MEM-123 live | P2 | `process/<memoId>` anchor alone does not select memo when tab mounted | ax-memory-full-2026-06-30 | `lastSelectedMemoId` without `onAppear` restore | W0 | open — use Skills sandwich |
| FR-003 | PKT-MEM-123 live | P2 | Long memo first load blocks ToolRouter queue | operator quote | synchronous understand on select | W1 | **fixed** — opt-in understand |
| FR-004 | PKT-MEM-123 live | P2 | Confirm summary too shallow (first field only) | MemoryProcessCockpit commitValuePreview | truncated preview by design | W2 Phase B | **fixed** — per-intent write inspector |
| FR-005 | UX architecture | P1 | Notion keep appends full transcript to page body | VoiceMemoProcessor.executeMemoryKeep | `appendTranscriptToNotionPage` | W3 Phase C | **fixed** — summary body only |
| FR-006 | PKT-MEM-123 live | P2 | PKT-1005 `activityDrawer` grep false-positive | L8 notes | substring match on `activityDrawerToggle` | W5 | open |
| FR-007 | PKT-MEM-123 live | P2 | Triage await timeout without operator Confirm | L7 PARTIAL | UI Confirm not clicked | W4 | open — operator step |
| FR-008 | T-Real Greg memo closeout 2026-07-01 | P1 | No registry_update intents for Greg/client or project | mem-closeout-plan.json | Local curator collapsed memo to memory_keep + agent_memory only | PKT-MEM-128 | open |
| FR-009 | T-Real Greg memo closeout 2026-07-01 | P1 | No row title + Notion row id in intent inspector | mem-closeout-plan.json | No registry lanes emitted | PKT-MEM-128 | open |
| FR-010 | T-Real Greg memo closeout 2026-07-01 | P2 | UI↔MCP intent parity drift | AX: 1 tag "Update record 86%"; MCP: 2 intents (memory_keep, agent_memory) | UI may show merged/stale primary only | PKT-MEM-130 | open |
| FR-011 | T-Real Greg memo closeout 2026-07-01 | P1 | No dual-write preview (property + decision log block) | mem-closeout-plan.json | PKT-MEM-129 not implemented | PKT-MEM-129 | open |
| FR-012 | T-Real Greg memo closeout 2026-07-01 | P2 | `voice_memo_process` dryRun skips auto lanes (agent-deferred) | dryRun receipt skippedReason | By design for MCP agent mode — Process tab Confirm required | — | documented |
| FR-013 | T-Real operator UI | P3 | Operator dissatisfied with intent quality + project suggestion | operator quote pre-closeout | See FR-008–011 | PKT-MEM-128/130 | open |
| FR-014 | Registry audit 2026-07-01 | P2 | No `client` entity key — contacts DS used for people | mem-closeout-registry-audit.json | Naming mismatch voice router vs registry | PKT-MEM-127 | open |

---

## Template (agent appends rows)

```
| FR-NNN | scenario T2a / operator / agent | P? | … | screenshot path | code area | W? | open/fixed/deferred |
```
