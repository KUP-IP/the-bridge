# Skill, Command, and Routing Schema

The Bridge has two separate discovery surfaces:

- `skills_routing_list` is for agent routing. It should contain only skills that
  can own a user request.
- The Commands palette is for user-invoked snippets/actions. It should contain
  skills or local commands that are useful when selected from the global hot-key.

## Visibility Flags

For Notion-source skills, the registry exposes two independent booleans:

| Flag | Meaning |
|------|---------|
| `routingDiscoverable` | Include the skill in `skills_routing_list`. |
| `inCommandPalette` | Include the skill in the Commands palette. |

The legacy `visibility` string is a compact UI/admin representation:

| Value | Routing | Command palette |
|-------|---------|-----------------|
| `standard` | no | no |
| `routing` | yes | no |
| `command` | no | yes |

If a future workflow needs both routing and command membership, callers should
read and write the explicit booleans instead of relying on the single
`visibility` string.

For file-source skills, routing discovery is opt-in. A file skill appears in
`skills_routing_list` only when its explicit per-path routing toggle is true, or
when its frontmatter contains `visibility: routing`. Missing frontmatter means
standard/non-routing by default.

## Naming Schema

Use names that indicate ownership level:

| Kind | Pattern | Examples |
|------|---------|----------|
| Routing owner | `<domain>-keepr` | `mac-keepr`, `project-keepr`, `people-keepr`, `focus-keepr` |
| Platform mechanic | `<platform>-<capability>` | `mac-message`, `mac-contacts`, `mac-files` |
| Domain specialist | `<domain>-<workflow>` | `project-planning`, `video-producer`, `web-dev` |
| Command | imperative verb or verb-noun | `propose`, `capture`, `draft-update`, `log-call` |

Routing owners should have summaries, trigger phrases, and anti-trigger phrases.
Mechanic and specialist skills should usually stay `standard` and be loaded by
a routing owner. Commands should be command-only unless they can also own an
agent routing decision.

`bridge-keepr` is the root standing-orders identity, not a normal routing
owner. Keep it `standard` and fetchable for policy lookup; it must not appear in
`skills_routing_list`.

## Specialist Exposure

`skills_routing_list` may include child specialist hints, but the handshake
surface is capped to the first five specialists per parent. Rows with more
children include `specialistCount` and `specialistsTruncated: true`; callers can
load the full parent with `fetch_skill <name>` or resolve a child with
`fetch_skill <name>/<child>` when deeper routing is needed.

## Commands Store

The active production Commands palette has two inputs:

- Local user commands in `~/Library/Application Support/The Bridge/commands`
  (`index.json` plus one markdown file per command).
- Skills explicitly marked `command`/`inCommandPalette`.

The older Notion Commands data-source design is historical/deferred and is not
the active command source of truth.

## Operator Checks

Before marking a Notion skill as `Command`, verify that `fetch_skill <name>`
returns the page body. A valid-looking page ID can still be inaccessible if the
page was moved, deleted, or no longer shared with The Bridge integration.

Before marking a skill as `routing`, verify that its summary states ownership
and its anti-triggers exclude adjacent owners. Routing skills with blank metadata
create ambiguous dispatch.
