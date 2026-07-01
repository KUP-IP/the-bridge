# Memory Hub HITL Scenario Catalog (T0–T5)

Ordered **easy → hard**. Agent drives Mac/UI; operator supplies voice + GO gates only.

| Tier | ID | Scenario | Voice? | Pass criteria |
|------|-----|----------|--------|---------------|
| T0 | T0a | Hermetic floor | No | `make test-floor` green |
| T0 | T0b | Install | No | `make install-copy` + `/Applications/The Bridge.app` |
| T0 | T0c | MCP health | No | `bridge_status` running |
| T0 | T0d | AX manifest | No | PKT-1005 memory section |
| T1 | T1a | Three-pane chrome | No | sidebar + center + drawer toggle |
| T1 | T1b | Inspect-only select | No | Select memo without auto Understand spinner |
| T1 | T1c | Session cache | No | Skills sandwich restores preview |
| T2 | T2a | Cloud memory keep | Yes | Script T2a; intents + summary-first keep |
| T2 | T2b | Multi-intent cloud | Yes | Script T2b; ≥2 intent tags |
| T2 | T2c | Local T2a | Yes | Process locally button |
| T2 | T2d | Local T2b load | Yes | Activity phases visible |
| T2 | T2e | No cloud UX | Yes | Link/settings prompt |
| T3 | T3a | Batch happy path | Yes + approve | 2+ receipts; memo evicts |
| T3 | T3b | Registry sheet | Yes | Sheet → row → Confirm |
| T3 | T3c | Partial fail | Yes | Continue-on-failure |
| T3 | T3d | Intent inspector | No | Expand tag → full write map |
| T3 | T3e | Triage | Yes + approve | triage_await committed N/M |
| T4 | T4a | Long memo | Optional | UI responsive; phases logged |
| T4 | T4b | Backlog scroll | No | No queue deadlock |
| T4 | T4c | Re-run Understand | Optional | Plan refresh; triage invalidate |
| T5 | T5a | PR CI | No | GitHub Actions green |
| T5 | T5b | Operator GO | GO only | Explicit merge+tag approval |
| T5 | T5c | Sparkle | No | Tag → `make verify-sparkle-feed` |

**Evidence files:** [MEMORY-HUB-UI-SCENARIOS.md](MEMORY-HUB-UI-SCENARIOS.md) · [MEMORY-HUB-VOICE-SCRIPTS.md](MEMORY-HUB-VOICE-SCRIPTS.md) · [MEMORY-HUB-FRICTION-LOG.md](MEMORY-HUB-FRICTION-LOG.md)

**Sacred pause:** ≥2 P0/P1 in one tier after one fix → re-plan wave → resume at failed tier.
