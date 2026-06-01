# NL-2 — Per-Call Local-vs-Cloud Split Spec (Two-Clause Rule)

**Date:** 2026-05-30
**Owner:** Isaiah Peters
**Status:** Accepted — spec of record
**Source:** Extends NL-1 (frame corrections: moat=aggregation, WorkOS auth, relay-vs-vault, ChatGPT remote-only). Binds to product-strategy.md D1 (local-first execution), D2 (cloud relay is transport, not store), D3 (client-account access is permanently Mac-resident under client SLA).

---

## Purpose

The Bridge exposes one tool surface to a model regardless of where that model runs (Claude Desktop on the Mac, ChatGPT remote-only, a cloud agent). Each call must resolve to exactly one execution site: **cloud** or **the active Mac**. This packet defines the rule that makes that routing deterministic, and classifies the live tool surface against it. The build references this table directly — it is the routing contract, not commentary.

---

## The Two-Clause Rule

**Decision (NL-2·R):** A call is **MAC-DELEGATED** if *either* clause is true. Otherwise it is **CLOUD-ONLY**.

> **Clause A — Execution/credential locality.**
> Does the call require local-machine execution (a Mac process, the local filesystem, the screen, an input device, a LAN resource) *or* a credential that lives only in the Mac Keychain?
>
> **Clause B — Client-scope (D3).**
> Is the data or credential operator-CLIENT-scoped? Per D3, every client-account credential is permanently Mac-resident and never relayed. Client scope alone forces delegation even if the same vendor would otherwise be reachable from the cloud.

**Evaluation:** `mac_delegated = A OR B`. Clause B is not redundant with A — it catches the case where a vendor (e.g. Notion, Stripe) is reachable cloud-side via the operator's *own* token but the *specific call* operates on a *client's* account. Vendor reachability does not override client scope.

**Rationale.** Clause A is the physics: some things only exist on the Mac, so the cloud must delegate down through the relay (NL-1 relay-vs-vault: the relay is a transport that forwards the call to the Mac and streams the result back; it never persists the credential or the payload). Clause B is the contract: D3 promises clients that their account access never leaves the operator's machine, so scope — not capability — governs. Either condition is sufficient; neither is necessary alone.

**Relay-vs-vault consistency (NL-1).** "Mac-delegated" does **not** mean the cloud holds the secret and reaches down. It means the cloud holds *nothing*: the relay forwards an authenticated request to the Mac, the Mac unlocks the Keychain credential locally, executes, and returns only the result. The vault (Keychain) stays on the Mac. The relay is a pipe. This is why a remote-only client (ChatGPT, NL-1) can still trigger a Mac-delegated call without any secret ever transiting or resting in the cloud.

---

## Classification Table

Categories map to the live Bridge tool surface (`tools_list`). Each row is tagged with the decisive clause.

| # | Tool category | Representative tools | Split | Decisive clause | One-line reason |
|---|---|---|---|---|---|
| 1 | Filesystem | `file_read/write/edit`, `dir_create`, `file_zip`, `file_watch` | **Mac-delegated** | A | Operates on the local disk; no cloud filesystem exists. |
| 2 | Shell / process | `shell_exec`, `run_script`, `bg_process_*`, `process_list` | **Mac-delegated** | A | Spawns processes on the Mac OS. |
| 3 | Screen | `screen_capture`, `screen_ocr`, `screen_record_*`, `screen_analyze` | **Mac-delegated** | A | Reads the physical display; cloud has no frame buffer. |
| 4 | Input / UI automation | `mouse_click`, `keyboard_type`, `cgevent_send`, `ax_*`, `applescript_exec` | **Mac-delegated** | A | Drives the Mac's input stack and AX tree. |
| 5 | Browser (local Chrome) | `chrome_navigate`, `chrome_execute_js`, `chrome_read_page`, `chrome_tabs` | **Mac-delegated** | A | Controls the user's logged-in local browser session. |
| 6 | Contacts | `contacts_search/get/resolve_handle/health` | **Mac-delegated** | A | Reads the macOS Contacts store (Mac-only data). |
| 7 | Messages | `messages_search/send/content/recent` | **Mac-delegated** | A | Reads/writes the local Messages SQLite + macOS send path. |
| 8 | Clipboard / pasteboard | `clipboard_read/write`, `pasteboard_history` | **Mac-delegated** | A | The pasteboard is a Mac-resident object. |
| 9 | System / Spotlight | `system_info`, `spotlight_query`, `port_inspect`, `notify` | **Mac-delegated** | A | Queries the local OS, index, and ports. |
| 10 | Credential ops | `credential_save/read/list/delete` | **Mac-delegated** | A | The vault is the Mac Keychain (NL-1); secrets never relay. |
| 11 | Local dev / code intel | `git_*`, `gh_*` (local checkout), `lsp_*`, `devserver_*`, `vitest_run`, `playwright_run`, `code_search`, `tree_sitter_query` | **Mac-delegated** | A | Acts on the local working tree, ports, and toolchains. |
| 12 | Skill management | `skill_create/update/delete/rename`, `manage_skill`, `skill_sync_notion` | **Cloud-only** | (neither) | Mutates the cloud-hosted skill registry. |
| 13 | Skill / routing read | `fetch_skill`, `list_routing_skills`, `skills_routing_list` | **Cloud-only** | (neither) | Reads the cloud registry; no Mac state required. |
| 14 | Plugin / connector install | MCP-registry + `plugin_*` authenticate/install | **Cloud-only** | (neither) | Provisions a cloud-side connector via vendor OAuth. |
| 15 | Vendor OAuth MCP (operator's own scope) | Notion `notion-*`, Stripe `stripe_*`, GitHub/Linear/Slack/etc. plugins | **Cloud-only** | (neither) | Reached via the operator's own OAuth token held cloud-side. |
| 16 | Notion via operator's stored token | `notion_query/search/page_read/page_update`, etc. | **Cloud-only** | (neither) | Operator-scoped token + remote API; no Mac dependency. |
| 17 | HTTP fetch / web | `http_fetch`, web fetch/search | **Cloud-only** | (neither) | Plain outbound network; cloud is the cheaper egress point. |
| 18 | Snippets / jobs registry | `snippets_*`, `job_*`, `jobs_*` | **Cloud-only** | (neither) | CRUD against cloud-stored definitions and schedules. |
| 19 | **Client-account access (ANY vendor)** | Any call operating on a CLIENT's Notion/Stripe/GitHub/Messages/files | **Mac-delegated** | **B** | D3: client credentials are permanently Mac-resident; scope overrides vendor reachability. |

**Note on row 19 vs rows 15–16.** The same `notion_*` or `stripe_*` tool is **cloud-only** when bound to the operator's own scope and **Mac-delegated** when the resolved scope is a client's. Routing is decided per call at scope-resolution time, not per tool name. See Edge Case 2.

---

## Edge Cases (Resolved)

**Edge 1 — Notion file upload (`notion_file_upload`).**
*Tension:* It targets a cloud vendor (looks like row 15) but its payload is often a local file (clause A pull).
**Resolution (NL-2·E1):** Split the call. The **byte source** governs locality. If bytes come from the local filesystem, the Mac reads the file and streams it through the relay to Notion's upload endpoint — **Mac-delegated** (clause A), file never lands in cloud storage. If bytes already live in a cloud-reachable URL/object, the upload is **cloud-only**. The Notion *target* never makes it cloud-only on its own; the *source* of the bytes does.

**Edge 2 — Multi-workspace / multi-tenant routing.**
*Tension:* One vendor, several scopes (operator workspace + N client workspaces) behind identical tool names.
**Resolution (NL-2·E2):** Scope is resolved *before* the split is computed. Operator-own scope → evaluate clauses normally (typically cloud-only). Any client scope → clause B fires → **Mac-delegated**, unconditionally, regardless of vendor reachability. A multi-workspace request that fans out to both is split into per-scope calls and routed independently; there is no "mixed" execution site for a single call. The router must reject a call whose scope cannot be resolved rather than defaulting to cloud.

**Edge 3 — Vendor-MCP commodity reads (e.g. `notion-fetch`, `stripe_api_search`, web search).**
*Tension:* Tempting to delegate everything vendor-touching to the Mac "to be safe."
**Resolution (NL-2·E3):** Commodity reads against the **operator's own** scope are **cloud-only** by default. This is the NL-1 aggregation moat in action: the value is centralizing reachable vendor surface in the cloud relay, not round-tripping a Mac that adds latency and a single point of failure. Delegating a cloud-reachable read to the Mac is a defect, not a safety measure. Clause B (client scope) is the *only* thing that pulls these reads down.

**Edge 4 — Local Chrome reading a cloud app (e.g. driving Notion's web UI in `chrome_*`).**
*Tension:* The data is cloud (Notion) but the actor is the local browser.
**Resolution (NL-2·E4):** **Mac-delegated** (clause A). The deciding factor is that execution rides the user's *local, logged-in browser session* — a Mac-resident artifact — not that the destination is a cloud app. Prefer the cloud-only vendor MCP (row 15) for the same data when the operator's token covers it; fall back to local-browser delegation only when no API path exists or the session cookie is the only available auth.

**Edge 5 — `gh_*` against a remote repo with no local checkout.**
*Tension:* `gh_*` is listed under local dev (row 11, clause A) but a pure GitHub API call needs no working tree.
**Resolution (NL-2·E5):** If the call touches the local checkout (status, diff, branch, worktree) → **Mac-delegated** (A). If it is a pure remote API action under the operator's own token (open PR, comment, check status) → **cloud-only**. Same per-call principle as rows 15–16: tool name does not decide; the resolved target does.

---

## Routing Invariants (build must enforce)

1. **Single site per call.** Every resolved call executes entirely cloud-side or entirely Mac-side. No straddling.
2. **Scope before split.** Vendor scope is resolved first; the two-clause rule runs against the resolved scope.
3. **Fail closed on client scope.** If scope resolves to a client, the call is Mac-delegated even if a cloud path exists. If scope is unresolvable, reject — never default to cloud.
4. **Relay carries no secret, no payload at rest (NL-1).** Mac-delegated calls move through the relay as transient forwarded requests; the Keychain credential and the payload exist only on the Mac and in flight.
5. **Cloud-only never touches the Mac.** A cloud-only call must not wake or depend on the Mac; this preserves remote-only clients (ChatGPT, NL-1) when the Mac is asleep.

---

## Cross-References

- **NL-1** — relay-vs-vault (relay = transport, vault = Mac Keychain), aggregation moat, WorkOS auth, ChatGPT remote-only constraint.
- **D1** — local-first execution: anything local stays local.
- **D2** — cloud relay is transport, not store: justifies "relay carries no payload at rest."
- **D3** — client-account access is permanently Mac-resident: the entire basis of Clause B and row 19.
