# Messages: Mac Continuity “Not Delivered” (#199)

## What Bridge can prove

`messages_send` (and THREAD receipts) report **local** evidence only:

- AppleScript / Messages.app accepted the send request.
- Optional `chat.db` correlation found a matching outbound row.

That correlation is **not** provider delivery. Envelopes always set
`providerDeliveryConfirmed=false`. Bridge will never flip that flag from a
local chat.db match, a Messages.app success dialog, or a later read of
`is_read` / `date_read`.

## What Bridge cannot do

When SMS is sent from a Mac via **Continuity** (iPhone as the radio), Messages
on the Mac can show **Not Delivered** even after the iPhone actually delivered
the message. There is **no public Apple API** to:

- clear or rewrite that Mac bubble,
- query the iPhone’s true SMS delivery state,
- force Continuity to refresh the Mac transcript.

Closing GitHub #199 is therefore **documentation + honesty**, not a UI wipe.
False Mac “failed to send / try again” while the phone delivered continues
as [#302](https://github.com/KUP-IP/the-bridge/issues/302). Protocol pick
(RCS vs SMS vs iMessage) is [#303](https://github.com/KUP-IP/the-bridge/issues/303)
— see `docs/operator/messages-protocol-discriminator.md`.

## Operator / agent contract

- Treat `sent` / local correlation as **consequence-possible**, not delivered.
- Do not tell the user “delivered” because chat.db has a row.
- The Mac bubble may still lie after a successful iPhone send. That is an
  Apple Continuity display bug, not a Bridge send failure.
- Group **create** is a separate residual (#204): existing-group send via
  `chatIdentifier` works; creating a new group is not built.
