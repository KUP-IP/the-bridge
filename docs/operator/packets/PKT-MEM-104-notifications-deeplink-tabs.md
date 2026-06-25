# PKT-MEM-104 — Notifications, Deep Links & Memory Tabs

**Wave:** 2 (after Wave 1 merge)  
**Class:** Standard  
**Spec:** `docs/operator/MEMORY-HUB-EXECUTION-SPEC.md` §5  
**Branch:** `feat/pkt-mem-104-notify-tabs` off Wave 1 integration branch

---

## Objective

Fix notification copy and deep links to Memory/Inbox; complete Notion + Agent tabs in Memory section.

## Scope

**IN:**
- `VoiceMemoNotifier`: distinct messages for review / no-transcript / routing-failed
- Tap → `bridge_settings_navigate(Memory, inbox)` (not Advanced)
- **Notion tab:** recent Memory registry rows via `RegistryReader` / view model
- **Agent tab:** read-only list from `MemoryStore` with scope/type filters
- Update `SettingsUIValidationHarness` for all three tabs
- Fix any remaining stale references to Advanced voice review

**OUT:**
- UNNotification quick actions (Wave 3)
- Handshake auto-inject agent memory (v3.7.7 open questions)

## Definition of Done

- [ ] Notification tap opens Memory Inbox
- [ ] Notion tab shows last N Memory rows with open-in-Notion link
- [ ] Agent tab lists SQLite memories (read-only)
- [ ] `make test` green

## QA Checklist

- [ ] Trigger review notification → lands on Inbox
- [ ] Three tabs navigable via MCP anchors

## Dependencies

PKT-MEM-102 (Memory section shell), PKT-MEM-103 (dispositions for full Inbox UX)
