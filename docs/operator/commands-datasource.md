# Commands Data Source — operator setup (cmd-w2)

This is the **operator-only** schema for the Notion data source backing
the **Commands** feature. The cmd-w2 code change ships the data layer
only (fetch + mention-resolve + cache); it does **not** create anything
in Notion and makes **no live Notion calls** in tests. Creating this data
source is a deferred operator dependency — do it once, in Notion, then
point the app at it (wiring is a later slice).

This mirrors how the **Skills** data source works: lightweight config
rows live in app storage, and the *body* of each entry lives in the
Notion **page content** (blocks), fetched on demand via
`GET /v1/pages/{id}/markdown`.

## Schema

Create a Notion **database → data source**. Each row is one command; the
command's body is the **page content** of that row's page (not a
property).

| Property       | Notion type    | Required | Maps to `Command` field | Notes |
|----------------|----------------|----------|-------------------------|-------|
| `Name`         | `title`        | yes      | `name`                  | Human-readable command name. |
| `Abbreviation` | `rich_text`    | yes      | `abbreviation`          | Short unique trigger (e.g. `gm`, `sig`). Keep unique within the DS. |
| `Group`        | `select`       | no       | `group`                 | Grouping for UI/organization. Defaults to `General` when empty. |
| `Tags`         | `multi_select` | no       | `tags`                  | Free-form labels. |
| *(page body)*  | `blocks`       | yes      | `text`                  | The actual command body. Authored as normal Notion page content. Retrieved via `/markdown`; Notion `<mention-*/>` tags are resolved to portable Markdown by the app's `MentionResolver`. |

### Body / mention handling

The page body is fetched with `GET /v1/pages/{id}/markdown`
(`{ "markdown": "..." }`) and then run through `MentionResolver`:

- `<mention-page url="https://www.notion.so/<id>"/>` → `[Title](url)`
  where `Title` is resolved via an injectable, cached page-title lookup
  (one lookup per distinct page URL). If the title cannot be resolved →
  `[link](url)`.
- `<mention-user url="user://<id>"/>` and any other mention subtype
  (date / database / inline-link / unknown) → `[link](url)` when a URL
  is present, otherwise the original tag is passed through verbatim.

The resolver **never drops content** and **never throws** — an
unresolved or unrecognized tag always degrades to a safe link or a
verbatim pass-through.

> Verification note: only the `mention-page` and `mention-user` tag
> shapes are stated as verified. `date` / `database` / `inline-link`
> tag shapes are modelled from spec; the resolver routes every non-page
> `<mention-*/>` through the same safe path, so it is correct
> independent of those exact wire shapes.

## Caching

Command bodies are cached in-memory with a **10-minute TTL** (identical
to the Skills cache). When a refresh fails (offline / API error) the app
serves the **last known good body** as an offline fallback. A manual
resync entry point drops a single page's cache entry (or all of them) so
the next fetch is forced live.

## Out of scope (deferred)

- Creating the data source in Notion (operator does this).
- Querying the DS for the row list (a later slice; the data layer here
  is verified against synthetic recorded `/markdown` JSON).
- Any UI, hotkey, or MCP tool registration for Commands.
