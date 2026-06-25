# PKT-MEM-110 — Hybrid Curator Routing

**Status:** Foundation shipped (mode enum + get/commit tools); cloud client deferred

## Modes

| Mode | Understand | Execute |
|------|------------|---------|
| auto | Local Ollama when enabled, else heuristics | Bridge |
| heuristics | Phrase rules only | Bridge |
| local | Ollama classify + summarize | Bridge |
| agent | Transcribe + notify; agent calls `voice_memo_get` → `voice_memo_commit` | Bridge on commit |
| cloud | Deferred — Anthropic/OpenAI keys in Keychain | Bridge on commit |

## Shipped tools

- `voice_memo_get` — transcript + parsed plan preview (open)
- `voice_memo_commit` — execute one approved lane (notify)
- `VoiceMemoCuratorRouter` + Settings → Memory → Processing tab

## Deferred

- `CloudCuratorClient` + Keychain API key UI
- 9am job agent-deferred notify copy polish
