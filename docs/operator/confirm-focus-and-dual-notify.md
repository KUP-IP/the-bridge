# Confirm delivery — Focus, Time Sensitive, and dual-notify

Operator notes for Request-tier Confirm (`SECURITY_APPROVAL`) after #262.
This is **Source** documentation. Bridge Keepr still owns **LIVE UX PASS**
under Focus/DND — do not treat this file as Installed Verified.

Related: [security-tiers-and-always-allow.md](security-tiers-and-always-allow.md).
Technical lanes **#263** (awaiting_approval) and **#264** (notify stickies /
compact-banner order) are separate.

## What Bridge does on escalate

1. **Sticky Confirm panel** auto-presents Deny / Allow / **Always Allow**.
   Always Allow is the visual primary (full-width tap-only control — not
   a SwiftUI `Button`, so it cannot become AppKit's default). It is
   **not** the Return-key default — that misfire is #264 / PR #267 /
   the f1c71cc7 LIVE follow-up.
2. The panel **activates The Bridge** (`LSUIElement` → `.regular`
   **before the window is created**, then unhide + activate, then
   orderFront). Creating the panel while still `.accessory` yields
   `NSApp.windows == 0` (LIVE fail on `2bd375aa`). ATTENTION badge /
   Dashboard section are backups, not the only surface.
   Compact `ALWAYS_ALLOW` is **not** `.foreground` — unique-foreground
   Always Allow was invoked by Time Sensitive with no tap (#264 LIVE).
3. A **Time Sensitive** User Notification posts as a Focus-breaking banner
   (`UNNotificationInterruptionLevel.timeSensitive`, thread
   `bridge.confirm`). Banner tap / swipe-away opens the same panel (does
   not Deny).

## Time Sensitive / Focus limits (TCC + Settings)

| Layer | What Bridge can do | What the operator must grant |
|---|---|---|
| Notification TCC | `requestAuthorization([.alert, .sound, .badge, .timeSensitive])` | System Settings → Notifications → **The Bridge** → Allow Notifications |
| Time Sensitive | Sets `interruptionLevel = .timeSensitive` on Confirm only (not every Notify-tier fire-and-forget) | Same pane → **Time Sensitive Notifications** = On. If this is Off, macOS silently downgrades to Active and Focus can hide the banner. |
| Alert style | `willPresent` asks for banner + list + sound | Alert style **Banners** or **Alerts**. Style **None** hides the banner; the panel is then the only interrupt. |
| Focus / DND | Time Sensitive is the API interrupt | A Focus that **disables Time Sensitive** (or silences The Bridge in Allowed Apps) will still hide banners. The sticky panel still fronts on the Mac. |
| First-prompt race | The **first** `requestAuthorization` in-process wins. All Bridge callers now include `.timeSensitive`. | If an older install prompted without Time Sensitive, toggle The Bridge off/on in Notifications or re-grant so macOS records the option. |

Confirm does **not** use Critical Alerts (entitlement / MDM). There is no
API to punch through a Focus that has Time Sensitive off and Allowed Apps
excluding The Bridge. In that case the panel + menu-bar ATTENTION remain.

Notify-tier (“tool was called”) stays **Active** + sound so ordinary
tool chatter does not break Focus.

## Dual-notify: Grok iPhone → Mac + Bridge

When Grok (or another client) on iPhone fires a Continuity / iPhone
mirroring banner **and** Bridge posts `SECURITY_APPROVAL` on the Mac, two
banners stack. **Bridge cannot suppress another app’s mirrored
notifications.**

In-app mitigation:

- Bridge Confirm banners share `threadIdentifier = bridge.confirm` so
  *our* repeats group instead of stacking.
- The sticky panel is the primary interrupt; the UN banner is the
  Focus / away-from-screen backup.

Operator OS / Grok settings (pick one):

1. **System Settings → Notifications → iPhone Notifications** (or
   **Notification Mirroring** / Continuity) — turn off mirroring for
   Grok, or disable iPhone notification mirroring while working at the
   Mac.
2. **System Settings → Notifications → Grok** — Alert style None, or
   disable “Allow Notifications” on this Mac if Grok’s Mac app / mirror
   is the noisy copy.
3. **Focus** — allow **The Bridge** + Time Sensitive; leave Grok out of
   Allowed Apps if the mirrored copy is the nuisance.

Do not mute The Bridge to “fix” the stack — that hides Confirm when
Focus is on.

## LIVE verify (Bridge Keepr, not this PR)

1. Focus / DND on, Time Sensitive allowed for The Bridge.
2. Trigger a Request-tier tool (clean prefs).
3. Confirm panel must front without opening Dashboard or glancing NC.
4. Always Allow must be the obvious primary control.
5. Optional: with Grok iPhone mirroring on, note whether two banners
   appear — expected unless the operator applied the OS settings above.
