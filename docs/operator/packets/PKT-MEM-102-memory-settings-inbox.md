# PKT-MEM-102 — Memory Settings Section + Inbox UI

**Wave:** 1 (parallel)  
**Class:** Standard (UI = operator REVIEW-FIRST before merge)  
**Spec:** `docs/operator/MEMORY-HUB-EXECUTION-SPEC.md` §2, §4  
**Branch:** `feat/pkt-mem-102-memory-inbox` off `origin/main`

---

## Objective

Add **Memory** as a dedicated Settings section with Inbox tab for voice memo review; remove review card from Advanced.

## Scope

**IN:**
- `SettingsSection.memory` enum + sidebar entry (after Connection, before Data Sources)
- `MemorySection.swift` with tab bar: Inbox (default) | Notion (stub) | Agent (stub)
- **Inbox:** list from `VoiceMemoReviewStore`, transcript preview, source badge (stub OK until 101 lands), Reveal in Finder
- Disposition buttons wired to existing tools where possible (`voice_memo_review_dismiss`); disable File as Memory until PKT-MEM-103
- Remove `voiceMemosReviewCard` from `AdvancedSection.swift`
- `bridge_settings_navigate(section: "Memory", anchor: "inbox"|"notion"|"agent")` + alias `voice-memos` → Memory/inbox
- `SettingsUIValidationHarness` AX ids for Memory section
- Badge on sidebar when pending review count > 0

**OUT:**
- Full disposition backend (PKT-MEM-103)
- Notion/Agent tab full UI (PKT-MEM-104)
- Notification tap routing (PKT-MEM-104)

## Definition of Done

- [ ] Settings shows Memory section; Advanced no longer shows voice review card
- [ ] Inbox lists pending entries with transcript expand + dismiss
- [ ] `bridge_settings_navigate` opens Memory/Inbox with focus
- [ ] `make test` green; harness includes Memory AX paths
- [ ] Design tokens match `BridgeTokens.swift` patterns (DataSourcesSection reference)

## QA Checklist

- [ ] Pending review.json entry visible in Inbox
- [ ] Dismiss removes row and persists
- [ ] Navigate MCP opens correct section from cold start
- [ ] Sidebar badge clears when queue empty

## Execution Directives

- Follow `DataSourcesSection` / `JobsView` patterns for list + detail
- Use `@Observable` view model if needed; `@MainActor` for UI
- Cross-link chip in DataSources: "Memory entity → Memory pane" (one line, not scope creep)
- Do not move Local Models out of Advanced

## Dependencies

Can start parallel with PKT-MEM-101; merge after both green (transcript source badge completes when 101 merges)

## Verification command

```bash
make test && make test-floor
make app && make install-copy  # operator smoke
```
