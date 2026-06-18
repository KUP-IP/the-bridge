# Bundled Skills — Attribution + License Matrix

The Bridge ships a curated set of default SKILL.md files alongside the
app. They are loaded at runtime by `FilesystemSkillIndex` from
`Bundle.module/skills/<name>/SKILL.md`. Operators can override or add
their own skills by placing a `SKILL.md` under
`~/Library/Application Support/The Bridge/skills/<name>/SKILL.md` —
the user dir wins on a name collision.

Skills marked **Apache-2.0** are redistributed in their entirety. Skills
marked **source-available** (the document-handling family) are NOT
redistributed; we ship a `STUB.md` that points at the upstream URL so
operators can install them locally.

| Skill                 | License          | Upstream                                                                 | Bundled body? | Notes                          |
| --------------------- | ---------------- | ------------------------------------------------------------------------ | ------------- | ------------------------------ |
| algorithmic-art       | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/algorithmic-art    | Yes           |                                |
| brand-guidelines      | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/brand-guidelines   | Yes           |                                |
| canvas-design         | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/canvas-design      | Yes           |                                |
| claude-api            | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/claude-api         | Yes           |                                |
| doc-coauthoring       | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/doc-coauthoring    | Yes           |                                |
| frontend-design       | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/frontend-design    | Yes           |                                |
| internal-comms        | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/internal-comms     | Yes           |                                |
| mcp-builder           | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/mcp-builder        | Yes           |                                |
| skill-creator         | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/skill-creator      | Yes           |                                |
| slack-gif-creator     | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/slack-gif-creator  | Yes           |                                |
| theme-factory         | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/theme-factory      | Yes           |                                |
| web-artifacts-builder | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/web-artifacts-builder | Yes        |                                |
| webapp-testing        | Apache-2.0       | https://github.com/anthropics/skills/tree/main/skills/webapp-testing     | Yes           |                                |
| docx                  | source-available | https://github.com/anthropics/skills/tree/main/skills/docx               | No (STUB.md)  | Linked-only; install via user dir |
| pdf                   | source-available | https://github.com/anthropics/skills/tree/main/skills/pdf                | No (STUB.md)  | Linked-only; install via user dir |
| pptx                  | source-available | https://github.com/anthropics/skills/tree/main/skills/pptx               | No (STUB.md)  | Linked-only; install via user dir |
| xlsx                  | source-available | https://github.com/anthropics/skills/tree/main/skills/xlsx               | No (STUB.md)  | Linked-only; install via user dir |

13 skills bundled (Apache-2.0); 4 stubs (source-available). Total
defaults: 17.

## License Verification

The Apache-2.0 status is sourced from the upstream `README.md` in
[anthropics/skills](https://github.com/anthropics/skills), which states
verbatim: "Many skills in this repo are open source (Apache 2.0)" and
explicitly lists the four source-available skills (`docx`, `pdf`,
`pptx`, `xlsx`). The classification was confirmed at sprint authoring
time (2026-05-19). If any upstream skill's license changes, audit the
table above before the next release.

## Override Model

The default-bundle model is **additive, not authoritative**. Operators
can:

  * **Override a bundled skill** — drop a SKILL.md with the same `name`
    into `~/Library/Application Support/The Bridge/skills/<name>/`.
    The user-dir version wins on collision (`FilesystemSkillIndex` D4).
  * **Add a new skill** — same path, any name. The file watcher picks
    up new entries within the cache TTL (60s) or immediately on file-
    system change.
  * **Disable a default** — toggle the row in Settings → Skills.
    Disabling writes to `BridgeDefaults.fileSkillEnabled` (per-path);
    the SKILL.md itself is read-only.

Notion-page-backed skills (configured via `manage_skill` / Settings →
Skills) take precedence over file-source skills with the same name; the
file-source row is annotated `shadows: file:<path>` in
`list_routing_skills` (D4).

## Plugin Manifest Gaps

When publishing Bridge MCP as a Claude Code / Cowork plugin, the
upstream plugin schema assumes an npm-packageable runtime. Bridge MCP
is a signed `.app` bundle (stdio + streamable-HTTP), NOT an npm
package. The `.mcp.json` in this repo registers the app's local
endpoint accordingly. Marketplace submission must handle this gap
explicitly (see the `plugin.json` `notes` field at repo root).
