# Command Bridge popup — operator smoke checklist (PKT-878 · v3.6.3)

This checklist covers the manual smoke surface for the Command Bridge
popup rebuild. The DECISION layer underneath is fully unit-tested
headlessly — see `TheBridgeTests/CommandBridgeControllerTests.swift`
for placement math, recents MRU, animation config, view-model
builders, the clipboard contract, lifecycle defaults, and the
modifier-less hot-key plumbing-failure shape. What this document
catches is the **AppKit ceiling**: the global hot-key actually firing
on a live WindowServer, a borderless NSPanel becoming key without
activating the app, the SwiftUI Liquid Glass rendering, multi-display
placement, the macOS reduce-motion path, and focus-loss dismissal.

## Build & launch

- [ ] `make build && make run` (or open the .app from `/Applications`)
- [ ] No console errors mentioning `CommandBoxController` (the legacy
      type was retired — every code path now logs `[CommandBridge]`)
- [ ] Status bar item appears; clicking it opens the dashboard popover
- [ ] First launch: open Settings → Commands and verify the status
      row reads "Active · ⌃⌥⌘C" (or the persisted combo if you've
      rebound). If it reads "⚠ Shortcut unavailable", the operator
      smoke ceiling is hit on this machine — another app owns the
      combo. Rebind via the recorder and retry.

## Open / close lifecycle

- [ ] Press the registered hot-key combo (default ⌃⌥⌘C). The popup
      appears at the bottom-centre of the active display
- [ ] The panel **does not** steal app focus — the frontmost app's
      title-bar stays active
- [ ] The popup centre sits ≈25 % up from the bottom of the visible
      frame (excluding the dock). Eyeball: the centre of the pill is
      roughly one-quarter of the way up from the bottom edge
- [ ] The query field is the first responder — the caret is visible
      and typing immediately enters the field
- [ ] Press Esc → the popup closes. Press the hot-key again → it
      re-opens
- [ ] Press the hot-key while the popup is open → it closes
      (toggle behaviour)
- [ ] Click outside the popup (e.g. into the frontmost app) → the
      popup closes (focus-loss dismiss)

## 10-slot favorites tray

- [ ] The tray shows 10 evenly-spaced positions. Assigned slots show
      a glass bubble with the icon; **unassigned slots are blank but
      hold their position** (the keycap labels 1, 2, 3 … 9, 0 stay
      aligned even with a sparse set of favorites)
- [ ] Pressing a number key for an assigned slot (e.g. `1` if the
      Execute command is bound) fires that command:
  - [ ] The popup closes
  - [ ] The system clipboard now holds the exact markdown body of the
        fired command (`pbpaste` to verify byte-for-byte)
  - [ ] The command's lastUsedAt is updated (visible next time you
        open the popup and press ↓ — the row will show "just now")
- [ ] Pressing a number key for an **unassigned** slot is a no-op:
  - [ ] The popup stays open
  - [ ] The clipboard is not clobbered
- [ ] Clicking an assigned bubble fires the command in the same way

## Recents slide-in (↓ key)

- [ ] With the popup open, press ↓. The recents panel slides in below
      the pill in ~140 ms (recents are session-only — see Q1 locked
      decision; a fresh launch starts with an empty recents list)
- [ ] The most-recently-fired command is the first row and pre-selected
      (highlighted with the Notion blue tint)
- [ ] Each row shows: icon · name · relative timestamp ("just now",
      "2m ago", "yesterday", "3d ago") · keycap label if the command
      has an assigned slot
- [ ] Press Enter → the top-selected row fires (clipboard write +
      close)
- [ ] Click a row → that command fires (clipboard write + close)

## Search-as-you-type

- [ ] Type into the query field (e.g. "clo"). The recents panel
      collapses; the search-results panel appears with substring
      matches ranked by recency (matching letters bolded)
- [ ] Backspace the query to empty → the search panel disappears
- [ ] Press Enter while typing → the top-ranked match fires
- [ ] No-match query → the search panel shows "No match for
      \"<query>\"."

## Menu-bar pill ⌘ chip

- [ ] Click the ⌘ glyph at the trailing end of the pill. The popup
      closes and Settings opens to the Commands section. The
      `SettingsNavigation.shared.section` value is `.commands`

## Animations

- [ ] Open animation: 180 ms ease-out, fades from opacity 0 → 1 and
      scales from 0.94 → 1.0. The 10 bubbles cascade in with ~10 ms
      stagger (the first bubble is visible noticeably before the
      tenth)
- [ ] **Reduce motion path**: System Settings → Accessibility →
      Display → "Reduce motion" ON. Reopen the popup → it appears
      instantly with no scale/opacity ramp and no cascade

## Multi-display placement

- [ ] If you have two displays: drag your active window to the
      secondary display, then trigger the popup. It opens on the
      secondary display (the one containing the key window)
- [ ] With no key window: move the mouse to the secondary display
      and trigger. It opens on the display under the mouse
- [ ] Resize a display in System Settings (if available) — the popup
      keeps its bottom-centre-25% anchor on the new visible frame

## Hot-key rebind

- [ ] Open Settings → Commands → Hot-key recorder. Press a new
      modifier-bearing combo (e.g. ⌃⌥⌘B). Status reads "Active · ⌃⌥⌘B"
- [ ] The new combo fires the popup; the old combo no longer does
- [ ] Try a combo already owned by another app (e.g. ⌃⇧⌘4 if a
      screen-capture tool owns it) → the recorder surfaces the
      ⚠ collision and **keeps the prior working combo** alive
- [ ] Try a modifier-less key → the recorder refuses to record it

## Negative paths

- [ ] Disable the palette via Settings → Commands master toggle →
      hot-key is unregistered; pressing the combo does nothing
- [ ] Re-enable → hot-key is re-registered; combo works again
- [ ] Quit and relaunch → the persisted combo registers; the rebound
      hot-key still works

## What is explicitly NOT in scope (and is asserted ELSEWHERE)

The following live in the **headless** test surface, not this
operator smoke. Re-running the harness covers them:

- Placement math (`CommandBridgeController.placementOrigin`,
  `pickScreenFrame`)
- Recents MRU / cap / reset (`CommandBridgeRecents`)
- Animation config + reduce-motion collapse
  (`CommandBridgeAnimation.locked` / `.reduced`)
- View-model builders (`buildSlotRows` / `buildRecentRows`)
- The clipboard contract (`applyCommit(.paste / .notFound /
  .unavailable)`)
- The modifier-less hot-key refusal → `.plumbingFailure` (NEVER
  `.collision`)

If a smoke step fails but the headless tests are green, the failure
is in the **AppKit glue** — open a follow-up with the exact reproducer
(macOS version, display arrangement, system reduce-motion setting,
focused-app state).
