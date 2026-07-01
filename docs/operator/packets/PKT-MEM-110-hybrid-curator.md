# PKT-MEM-110 — Hybrid Curator Routing

**Status:** Foundation shipped; **Auto+MCP defer** → PKT-MEM-120  
**Supersedes:** mode table below for Auto/cloud (2026-06-30 validate)

## Modes (current + PKT-MEM-120 target)

| Mode | Understand | Execute |
|------|------------|---------|
| **auto** | **Cloud → local → heuristic** (frontier-first) when autonomous | **PKT-MEM-120:** defer to MCP agent when interactive session connected; else Bridge auto-execute + guardrails |
| heuristics | Phrase rules only | Bridge |
| local | Ollama classify + summarize | Bridge |
| agent | Heuristic preview in-app; agent refines via `voice_memo_get` | Bridge on `voice_memo_commit` only |
| cloud | Cloud → heuristic | Bridge auto-execute + guardrails |

## Shipped tools

- `voice_memo_get` — transcript + parsed plan preview (open)
- `voice_memo_commit` — execute one approved lane (notify)
- `VoiceMemoCuratorRouter` + Settings → Memory → Processing tab
- `CloudParseProvider` + Processing provider UI (OpenAI-compatible)
- `VoiceMemoParseRouter` frontier-first chain

## Deferred → PKT-MEM-120 / follow-up

- Auto+MCP presence seam (`MCPClientPresence`)
- 9am job respects Auto defer when MCP connected
- Agent-defer notifier + activity receipts
