# Memory Hub — Ship gate (W6)

**Version prepared:** v3.9.3 build 69  
**Branch:** `feat/mem-120-routing-quality-ux`  
**Test floor:** 2863 green  
**PR:** [#72](https://github.com/KUP-IP/the-bridge/pull/72)

## Completed (agent)

- [x] W1 opt-in Understand (inspect vs explicit Process locally/cloud)
- [x] W2 per-intent write inspector (expand tag chevron)
- [x] W3 summary-first Notion keep (no default transcript append)
- [x] HITL docs: scenario catalog, voice scripts, friction log, transcript fate
- [x] W0 T0–T1 baseline documented
- [x] Version bump + CHANGELOG + test-floor 2863

## Operator GO required

Per app-dev Workflow G and plan sacred gate:

1. **Tier 2–3 live** — record voice memos from [MEMORY-HUB-VOICE-SCRIPTS.md](MEMORY-HUB-VOICE-SCRIPTS.md); approve notify-tier commits on disposable memos.
2. Reply **GO** in chat to authorize merge + tag.
3. Agent (or operator) then:
   - Merge PR #72 to `main`
   - `git tag -a v3.9.3 -m "Memory Hub opt-in Understand + summary-first keeps"`
   - `git push origin v3.9.3`
   - Wait for CI release (~28 min)
   - `make verify-sparkle-feed`

**Teaching:** `make install-copy` validates locally; **tag push** ships to all Sparkle users.
