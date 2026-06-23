# Commands Palette — Operator Smoke Checklist

The Commands palette's pure logic (controller state machine, status derivation,
Cocoa→Carbon mapping, OSStatus classification, visibility filter, empty-state
decision) is 100% unit-tested in the suite. The items below are the
**irreducible operator-smoke ceiling** — they require a live login session /
WindowServer and cannot be asserted headlessly. Run them after every
`make install` + relaunch of The Bridge.

## Pre-req
- [ ] Quit and relaunch **The Bridge** (install does not kill the running app).
- [ ] Open **Settings → Commands**.

## 1. Status row (Bug 2 regression guard)
- [ ] With the palette enabled and the default `⌃⌥⌘C` free, the status row reads
      **"Active — ⌃⌥⌘C"** in green (not a red ⚠).
- [ ] Toggle the master switch off → row shows **Disabled**; on → returns to
      **Active** within a moment (reactive, no relaunch).

## 2. Hot-key recorder (Bug 1 regression guard)
- [ ] Click the **Shortcut** field directly → it enters "Press shortcut…" and
      is focused (no separate button click required).
- [ ] Press a valid combo (e.g. `⌥⌘J`) → it is accepted, the row updates, and
      the **new** combo opens the palette immediately (no relaunch).
- [ ] Click the field, press **Escape** → recording cancels, combo unchanged.
- [ ] **Reset to default** → returns to `⌃⌥⌘C`.

## 3. Collision diagnosis (genuine vs false unavailable)
- [ ] If a combo is owned by another app, recording it shows a red
      **"⚠ … in use by another app — record a different shortcut"** (a true
      collision), distinct from a generic plumbing message. Recording a free
      combo clears it.

## 4. Palette behavior (.command filter)
- [ ] With **no** skills marked `Command`, press the hot-key → the box shows
      the hint **"No commands yet — mark a skill as Command in Settings → Commands"**
      (not a blank list).
- [ ] In Settings, set one skill's visibility to **Command**. Press the hot-key
      → that skill appears; type to filter; `⏎` copies its page body to the
      clipboard; paste verifies the body. If body fetch fails, check that the
      stored Notion page is still shared with The Bridge integration before
      leaving the skill marked `Command`.
- [ ] A skill left as **Standard**/**Routing** does **not** appear in the
      palette.

## 5. Non-regression
- [ ] `fetch_skill <name>` (via an MCP client) still returns a `Command`-type
      skill by name (properties + body).
- [ ] `skills_routing_list` is unchanged — `Command` skills are not listed
      there; `Routing` skills still are.
