# Memory Hub UI Vision (PKT-MEM-111)

**Approved:** 2026-06-24

## Tab model

1. **Process** (default) — unprocessed memo list + 4-step pipeline drawer (Transcribe → Understand → Plan → Execute)
2. **Inbox** — review queue dispositions (existing)
3. **Notion** — registry Memory rows (read)
4. **Agent** — SQLite recall list
5. **Processing** — curator mode + transcription ladder toggles

## Shipped (U1 + U6)

- `MemoryProcessTab` — list, preview via `voice_memo_get`, dry-run / process buttons
- `MemoryProcessingTab` — curator mode picker + ladder toggles
- Deep-link anchors: `process`, `processing`

## Deferred (U2–U5, U7)

- Registry target picker on Process preview
- Agent tab forget/pin buttons
- Notion CRUD/backfill from pane
- Activity strip + notification deep-link to Process tab
- Cloud API key fields in Processing tab
