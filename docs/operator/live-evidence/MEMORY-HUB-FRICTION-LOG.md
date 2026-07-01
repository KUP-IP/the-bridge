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

---

## Template (agent appends rows)

```
| FR-NNN | scenario T2a / operator / agent | P? | … | screenshot path | code area | W? | open/fixed/deferred |
```
