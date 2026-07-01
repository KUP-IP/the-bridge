# PR #72 — Memory Hub Sprint Merge GO Checklist

**Branch:** `feat/mem-120-routing-quality-ux` → `main`  
**Version bump:** None in this contract (sprint closeout batch).

## Gate checklist

| Gate | Artifact | Status |
|------|----------|--------|
| G1 Audit | `docs/operator/TEST-SUITE-AUDIT-2026-06-30.md` | ✅ |
| G2 Hermetic | `make test-floor` ≥ **2824** | ✅ |
| G3 UI scenarios | `docs/operator/live-evidence/MEMORY-HUB-UI-SCENARIOS.md` | ✅ (UI-6 operator, UI-9 partial live) |
| G4 Navigation | Compound Memory anchors + `resolved` JSON | ✅ |
| G5 PKT-MEM-121 | Packet REVIEW + hermetic 10/10 | ✅ |
| G6 PKT-MEM-122 | Triage tools + banner + hermetic tests | ✅ |
| G7 Wireframes | `docs/operator/MEMORY-PROCESS-LAYOUT-WIREFRAMES.md` | ⏳ PENDING operator pick (blocks layout only) |
| W1-B | `PKT-MEM-113` W1-B row | ⏳ PARTIAL — operator quit Cursor ≥5s smoke |
| W5-Triage | `PKT-MEM-113` W5 row | ⏳ PARTIAL — operator UI commit step |

## Pre-merge commands

```bash
make test-floor          # must print passed >= 2824, failed=0
make install-copy        # refresh /Applications/The Bridge.app
open -a "The Bridge"     # inherit launchd OAuth env
```

## Operator GO

- [ ] UI-6 commit eviction on test memo
- [ ] W5-Triage live smoke (optional before merge; required for full sprint sign-off)
- [ ] Wireframe option A–E selected (for follow-on layout wave)
- [ ] **GO merge PR #72**
