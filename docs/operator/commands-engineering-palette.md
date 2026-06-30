# Bridge Command Engineering Palette

Operator reference for the 10-slot Command Bridge palette (keys **1–0**). Bodies live on disk at `~/Library/Application Support/The Bridge/commands/` (`index.json` + `<slug>.md`); this doc is the contract map only.

## Slot map

| Key | Slug | Display name | Intent |
|-----|------|--------------|--------|
| **1** | `initiate` | Initiate Bridge | Full handshake + mentor mode until operator pivots |
| **2** | `propose` | Propose | Step-by-step proposal thought process + light contract; C2C survey on real forks only |
| **3** | `scope-cut` | Scope Cut | Trim IN/OUT after propose, before validate |
| **4** | `validate` | Validate | Optional spec hardening + orchestrator dispatch |
| **5** | `execute` | Execute | Post-approval sprint (*Plan approved…* opener) |
| **6** | `review` | Review | Destructive/release checkpoint — operator GO required |
| **7** | `refocus` | Refocus | Mini-handshake realignment mid-session |
| **8** | `open-loops` | Loops | Phase A: inventory · Phase B: survey-driven close (lighter choice-to-contract per loop) |
| **9** | `close-agent` | Close Agent | Telemetry, AGENT_FEEDBACK, Bridge memory, **Notion AI LOG Session row + URL**, close-agent protocol |
| **0** | `hand-off` | Hand Off | Fresh-agent prompt when work continues elsewhere |

## Lifecycle

```
Initiate → Propose → Scope Cut → Validate → Execute → Review → Refocus → Loops → Close Agent → Hand Off
                              ↘ Execute (fast ship) ↗
```

## Stacking (multi-key paste)

Command Bridge fires one body per key. Paste keys back-to-back in one prompt.

| Stack | Keys | When |
|-------|------|------|
| Full pipeline | 2 → 3 → 4 → 5 | Big/multi-domain work |
| Fast ship | 2 → 5 | Scope already tight; skip validate |
| Scope trim | 2 → 3 → 2 | Propose overscoped — cut then re-propose |
| Post-ship | 5 → 6 | Execute then review checkpoint |
| Continue | 6 → 7 → 2 | Review → refocus → new propose |
| Loop open | 8 | Phase A inventory only (default single fire) |
| Loop close | 8 (re-fire or stack) | Phase B: closing survey per fork, then evidence-backed close |
| Session end | 8 → 9 | Close loops then close-agent |
| Continue elsewhere | 9 → 0 | Close-agent then handoff prompt |
| End only | 9 | Session ends at close-agent |

## Voice

Each command opens with identity and why the moment matters, then separates set-in-stone protocol from creative latitude — not generic checklist drones.

## Composition rules

- **Propose** is planning-only — no executor fetch, no implement language.
- **Execute** opens *Plan approved. Execute per contract below.* — never reuse propose language.
- **Validate** is operator-fired; default path is **2 → 5** not **2 → 4 → 5**.
- **Execute size gate:** >3 files OR >2 domains → orchestrator before material work.
- **Loops (8):** Phase B uses lighter choice-to-contract surveys before closing ambiguous loops — operator chooses forks, agent executes.
- **Hand Off (0)** does not run close-agent — that is **Close Agent (9)**.
- **Close Agent (9)** writes a short `memory_remember` session summary (scope `project`, ~7d TTL) and a **Notion AI LOG Session** row (DS `992fd5ac-d938-4be4-95fb-8ef18bd86bba`) — **URL required in the closeout receipt**.

## Test harness note

`CommandsModuleTests` must use `BridgePaths.overrideHomeForTesting` before `CommandStore.shared.resetForTesting()`. Without it, `make test` wipes the live command store. Fixed 2026-06-29 after a production wipe from an un-sandboxed test run.

## Related

- [`skill-command-routing-schema.md`](skill-command-routing-schema.md) — slug naming conventions
- [`TheBridge/App/CommandBridge.swift`](../../TheBridge/App/CommandBridge.swift) — hot-key UI
- [`TheBridge/Modules/Commands/CommandStore.swift`](../../TheBridge/Modules/Commands/CommandStore.swift) — persistence
