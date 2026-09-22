# Messages: Mac “failed to send” / Continuity “Not Delivered” (#199 / #302)

## Discriminator

A premature AppleScript / Messages.app error is **not** the same as a missed
send. `messages_send` can return a script error while `chat.db` already has
the matching outbound row (iMessage or Continuity SMS). Recipients receive
the text; Mac Messages may still paint **failed to send** / **Try again** /
**Not Delivered**.

That is a **display/status** bug, not a delivery miss.

## What Bridge can prove

`messages_send` (and THREAD receipts) report **local** evidence only:

- AppleScript / Messages.app was invoked (`deliveryInvoked`).
- Optional `chat.db` correlation found a matching outbound row
  (`correlatedLocalRecord` / `verified`).

After invoke, Bridge **always** polls for that local row — including when
AppleScript returned an error (#302). If the row is found:

- `sent` is **true** (dispatch succeeded).
- MCP `error` is **null** so `dispatchFormatted` does not mark `isError`.
- `scriptError` / `scriptErrorNumber` stay observational.
- `agentGuidance` tells the caller not to report failure.
- `macErrorCode` / `macIsDelivered` are chat.db flags only.

That correlation is **not** provider delivery. Envelopes always set
`providerDeliveryConfirmed=false`. Bridge will never flip that flag from a
local chat.db match, a Messages.app success dialog, `is_delivered`, or a
later read of `is_read` / `date_read`.

## What Bridge cannot do

When SMS is sent from a Mac via **Continuity** (iPhone as the radio), and
sometimes when iMessage ACKs late, Messages on the Mac can show **Not
Delivered** / **failed to send** even after the phone delivered. There is
**no public Apple API** to:

- clear or rewrite that Mac bubble,
- query the iPhone’s true SMS delivery state,
- force Continuity to refresh the Mac transcript.

Closing GitHub #199 was **documentation + honesty**, not a UI wipe.
#302 continues that honesty onto the **tool response**: agents must not
claim failure when local correlation succeeded. Protocol pick (RCS vs SMS
vs iMessage) is **#303**, not this path.

## Operator / agent contract

- Treat `sent` / local correlation as **consequence-possible**, not
  provider-delivered.
- Do **not** tell the user “the send failed” because AppleScript returned
  an error if `correlatedLocalRecord` is true.
- Do not tell the user “delivered” because chat.db has a row.
- The Mac bubble may still lie after a successful iPhone or iMessage send.
  That is an Apple display/Continuity bug, not a Bridge send failure.
- Group **create** is a separate residual (#204): existing-group send via
  `chatIdentifier` works; creating a new group is not built.
