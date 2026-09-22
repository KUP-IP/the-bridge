# Messages protocol discriminator (#303)

Parent epic: [#301](https://github.com/KUP-IP/the-bridge/issues/301).
Reopen-class of closed [#198](https://github.com/KUP-IP/the-bridge/issues/198)
(inherit / fail-closed) and [#249](https://github.com/KUP-IP/the-bridge/issues/249)
(conscious SMS override). Sibling [#302](https://github.com/KUP-IP/the-bridge/issues/302)
is the false Mac “failed to send” UI track — **not** this document.

Authority in source: `MessagesProtocolDiscriminator` +
`MessagesModule.resolveSendService`.

## Rule

When chat.db has a **clear live 1:1 thread or contact service**, Bridge
**inherits** it or **refuses with an explicit reason**. It never silent-remaps
RCS→SMS, iMessage↔SMS, or “first AppleScript service that contains this
handle.”

Agents must **not** guess `service` from prior outbound history.

## Bind order (1:1)

1. **Latest inbound normal row** on that 1:1 thread
   (`is_from_me = 0`, `associated_message_type = 0`, `item_type = 0`).
   Outbound history is ignored (Veronica).
2. Else the **thread identity** — `chat.guid` prefix or `chat.service_name`
   — when it is unambiguous (Mary: RCS thread with no inbound required).
3. Else **fail closed**. Two 1:1 chats (iMessage and SMS/RCS) with no inbound
   to break the tie is ambiguous — pass explicit `iMessage` or `SMS`.

Tapbacks and group chats (`participant_count > 1` or raw `chatNNNN`) do not
set 1:1 inherit. Handle match is exact keys only (raw, canonical E.164/email,
constructed `iMessage|SMS|RCS;-;<handle>` guids). **No `LIKE '%'`. **

## `messages_send` contract

| Caller | Live bind | Result |
|---|---|---|
| omit `service` | iMessage | send iMessage |
| omit `service` | SMS | send SMS |
| omit `service` | RCS / unknown | refuse (inherit-only; do not guess SMS) |
| omit `service` | none | refuse (pass explicit iMessage or SMS) |
| omit `service` | iMessage **and** SMS/RCS threads, no inbound | refuse (ambiguous) |
| `service=SMS` | iMessage | refuse mismatch |
| `service=iMessage` | SMS | refuse mismatch |
| `service=SMS` | RCS / unknown | refuse; error names `allowSmsDespiteLiveService:true` |
| `service=SMS` + `allowSmsDespiteLiveService:true` | RCS / unknown | send SMS (operator override; may hit Continuity UI, see #302 / #199) |
| `service=SMS` + flag | iMessage | still refuse mismatch |
| `service=RCS` / `auto` / `sms` | any | refuse (not a sendable enum) |
| 1:1 `chatIdentifier` (`+1…`, `ada@…`, `iMessage\|SMS\|RCS\|any;-;handle`) | that thread | **same table** — buddy send, not service iteration |
| group `chatIdentifier` | n/a | existing-chat AppleScript; group create is not built |

RCS is first-class in chat.db and on list tools (`messages_chat` /
`messages_recent` / `messages_search` expose `service`). It is **not** a
sendable AppleScript service until a live RCS `send` is Source Tested.

`allowSmsDespiteLiveService` does **not** map omit→SMS and does **not**
unlock iMessage↔SMS.

Catalog default remains Notify for ordinary 1:1 plain text (#298). Groups,
attachments, and the SMS-override flag stay Request. This does **not**
change host Auto-review (#294).

## Historical specimens (do not resend)

Filed on #198; reused here so the LIVE matrix has stable ROWIDs.

| Specimen | Handle | Live evidence | Wrong path then | Required now |
|---|---|---|---|---|
| Veronica | `+16056013705` | inbound **ROWID 54580** `service=iMessage` | SMS 54587 (guess from outbound 54499 / 54577) | inherit iMessage, or refuse if explicit SMS |
| Wayne | `+12537920959` | inbound **54506–54508** `service=RCS` | SMS 54586 | omit → refuse; SMS only with `allowSmsDespiteLiveService` |
| Mary | `+17575257951` | thread rewritten to `service=RCS` (local **54695**); live RCS thread already existed | guessed `service=iMessage` | bind RCS thread identity; omit/iMessage refuse |

## LIVE matrix (Isaiah PASS)

Fill on-device. Do **not** resend from this ticket. Do **not** claim
Installed Verified from Source Tested alone.

| Thread | chat.db bind (ROWID / guid / service) | `messages_send` args | Expected | PASS |
|---|---|---|---|---|
| iMessage 1:1 | | omit `service` | sends iMessage or explicit refuse | |
| SMS 1:1 | | omit `service` | sends SMS or explicit refuse | |
| RCS 1:1 | | omit `service` | refuse inherit-only | |
| RCS 1:1 | | `service=SMS` only | refuse, names flag | |
| RCS 1:1 | | `service=SMS` + flag | SMS override (Mac bubble may still lie — #302) | |
| iMessage 1:1 | | `service=SMS` + flag | refuse mismatch | |
| 1:1 `chatIdentifier` `iMessage;-;+…` | | omit `service` | iMessage buddy send, not first-match SMS | |
| 1:1 `chatIdentifier` `RCS;-;+…` | | omit `service` | refuse RCS inherit | |

Tip SHA and PR URL go on the draft PR, not in this table.
