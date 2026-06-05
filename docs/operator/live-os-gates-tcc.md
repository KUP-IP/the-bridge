# PKT-968 — Live OS Gates: macOS Reminders + Calendar TCC Runbook

Operator runbook to grant and verify the macOS privacy (TCC) permissions that The
Bridge's Reminders and Calendar tools require. The code-side gates are already in
place and verified (Info.plist usage strings, module registration, and
`requestFullAccess*` consent calls) — this runbook covers the on-device grant +
verification that only the operator can perform.

- App: **The Bridge** (`kup.solutions.notion-bridge`), menu-bar agent (`LSUIElement`).
- Version audited: 3.7.6 (build 51), branch `integration/v3.7.6`.
- macOS: target is `LSMinimumSystemVersion 26.0`; consent uses the macOS-14+
  full-access APIs (`requestFullAccessToReminders` / `requestFullAccessToEvents`).

---

## What the code requires (context)

| Permission | Info.plist key | EventKit call (on first use) | Settings pane |
|---|---|---|---|
| Reminders (full) | `NSRemindersFullAccessUsageDescription` | `requestFullAccessToReminders()` | Privacy & Security > Reminders |
| Calendars (full) | `NSCalendarsFullAccessUsageDescription` | `requestFullAccessToEvents()` | Privacy & Security > Calendars |

Each module's `ensureAccess()` checks authorization status:
- **notDetermined** -> the app self-activates and shows the native consent dialog.
- **denied / restricted / writeOnly** -> fails closed (tools return `accessDenied`); the dialog will NOT reappear — you must enable it in System Settings.
- **authorized / fullAccess** -> proceeds.

---

## Step 1 — Trigger the consent dialogs (fresh Mac)

With The Bridge running, call one WRITE tool for each domain. A write tool is used
because it exercises the same `ensureAccess()` path and proves read+write in one shot:

1. `reminders_create` — e.g. `{ "title": "Bridge TCC probe" }`
2. `calendar_create` — e.g. `{ "title": "Bridge TCC probe", "start": "2026-06-05T09:00:00", "end": "2026-06-05T09:15:00" }`

On a `.notDetermined` Mac, macOS shows:
- **"The Bridge" would like to access your Reminders** -> click **Allow Full Access** (or **OK**).
- **"The Bridge" would like to access your Calendar** -> click **OK** / grant **Full Access**.

The app brings itself to the foreground first, so the dialogs appear above other windows.

> Clean up the two probe records afterward with `reminders_delete` / `calendar_delete` using the ids returned by the create calls.

---

## Step 2 — Manual grant (if already denied)

If you were previously prompted and clicked Don't Allow, status is `.denied` and the
dialog will not reappear. The tools will return `accessDenied`. Enable manually:

**Reminders**
1. Open **System Settings**.
2. Go to **Privacy & Security > Reminders**.
3. Toggle **The Bridge** to **ON**.

**Calendars**
1. Open **System Settings**.
2. Go to **Privacy & Security > Calendars**.
3. Set **The Bridge** to **Full Access** (not "Add Only" — write-only/add-only is treated as restricted and fails the read paths).

If The Bridge does not appear in the list at all, run Step 1 once to register the
entry, or quit and relaunch The Bridge after granting.

CLI fallback to open the panes directly:
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
```

---

## Step 3 — One-command verification (read + write)

Call the two read tools, then a write round-trip per domain, and confirm the success
shapes below.

### Read check
- `reminders_lists` with `{}` -> expected success shape:
```json
{ "count": 2, "lists": [ { "id": "<uuid>", "title": "Reminders", "isDefault": true, "allowsModify": true } ] }
```
- `calendar_list` with `{}` -> expected success shape:
```json
{ "count": 3, "calendars": [ { "id": "<uuid>", "title": "Home", "isDefault": true, "allowsModify": true } ] }
```
A non-zero `count` and at least one entry with `allowsModify: true` confirms read access and a writable target. `count: 0` with a clean (non-error) return means access is granted but no lists/calendars exist; `accessDenied` means TCC is not granted (go to Step 2).

### Write round-trip (proves Full Access, not Add-Only)
Reminders:
1. `reminders_create` `{ "title": "Bridge verify" }` -> returns new reminder `id`.
2. `reminders_delete` `{ "id": "<that id>" }` -> succeeds.

Calendar:
1. `calendar_create` `{ "title": "Bridge verify", "start": "2026-06-05T09:00:00", "end": "2026-06-05T09:15:00" }` -> returns new event `id`.
2. `calendar_delete` `{ "id": "<that id>" }` -> succeeds.

If all four reads/writes succeed with the shapes above, both Live OS gates are
granted and operational.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Tools return `accessDenied` | TCC status `.denied`/`.restricted` | Step 2 — enable in System Settings, then relaunch The Bridge |
| No consent dialog ever appears | Status already `.denied` (won't re-prompt) | Step 2 |
| `calendar_create` works but `calendar_list`/`calendar_events` fail | Calendar granted "Add Only" (write-only) | Set to **Full Access** in Privacy & Security > Calendars |
| The Bridge missing from the Settings list | Never prompted / entry not registered | Run Step 1 once, then relaunch The Bridge |
| Dialog appears behind another app | rare focus race | Click The Bridge in the menu bar / Dock, retry the tool |

---

## Reset (for re-testing the first-run consent flow)

To force the `.notDetermined` state again so Step 1's dialogs reappear:
```bash
tccutil reset Reminders kup.solutions.notion-bridge
tccutil reset Calendar kup.solutions.notion-bridge
```
Then relaunch The Bridge and re-run Step 1. (`tccutil reset` requires confirming
any consequent prompts; it clears the recorded decision for this bundle id only.)
