# Bridge Tool-Surface Audit — prune for the "Universal Context Mac Bridge" thesis

> Status: DRAFT for operator review (2026-06-10). No deletions executed — this is the
> keep/cut/trim decision doc; execution is a separate packet.

## The razor
**If an agent can already get a capability from a dedicated MCP or cloud integration,
the Bridge should not reimplement it. The Bridge keeps only what requires being on the
physical Mac.** The moat is the Apple/macOS surface no other connector can reach
(files, shell, screen, AX, Apple apps, local dev). Everything cloud-native that has its
own MCP is bloat that also worsens tool-selection accuracy by inflating the surface.

**Named exception:** Notion-API stays even though a Notion MCP exists — it is *internal
infrastructure* for the skills + memory system, not a user-facing tool offering. Deliberate,
documented, not drift.

## Verdicts by family

### KEEP — Mac/Apple surface (the moat)
- **Files**: `file_*`, `dir_create`, `file_search`, `file_watch`, `file_zip/unzip`, `spotlight_query` — local FS, irreplaceable.
- **Shell / process**: `shell_exec`, `run_script`, `bg_process_*`, `process_list`, `port_inspect` — local execution.
- **Apple apps (EventKit/AppleScript/native)**: `messages_*`, `contacts_*`, `calendar_*`, `reminders_*`, `notes_*`, `mail_*`, `shortcuts_*`, `notes`/iWork surfaces — the differentiated Apple-ecosystem bridge.
- **macOS control**: `applescript_exec`, `ax_*` (accessibility), `screen_*` (capture/OCR/record), `clipboard_*`/`pasteboard_history`, `cgevent_send`/`keyboard_type`/`mouse_click`, `notify`, `system_info`.
- **Local browser steering**: `chrome_*` (drives the user's actual Chrome — distinct from a cloud browser MCP).
- **Local credentials**: `credential_*` (Keychain-backed, on-device).

### KEEP — Bridge's own brain / governance (core to "universal context")
- `skills_*`/`fetch_skill`/`manage_skill`/`skill_*`, `memory_*`, `standing_orders_*`, `snippets_*`, `job_*`/`jobs_*` (cron engine), `tools_list`, `connections_*`, `permissions_status`, `session_*`.

### KEEP — Notion (infrastructure exception)
- `notion_*` (API-backed). Skills + memory depend on it. Keep the API control; MCP-Notion swap optional later.

### CUT — has its own MCP, pure bloat
- **Stripe (entire family)**: `create_*`, `stripe_api_*`, `payment_execute`, `retrieve_balance`, `create_payment_link/invoice/coupon/price/product/refund/customer`, `finalize_invoice`, `update_subscription/dispute`, `cancel_subscription`, `fetch_stripe_*`, `search_stripe_*`, `get_stripe_account_info`, `send_stripe_mcp_feedback`, `stripe_integration_recommender`. → Stripe ships its own MCP connectable to any agent. Operator already decided: cut.
- **GitHub cloud API**: `gh_*` (PRs, issues, checks, actions runs) → GitHub's MCP covers these. Cut.

### TRIM — keep the local subset, cut the cloud/heavy
- **Git**: KEEP `git_*` that operate on the local working copy (status/diff/log/blame/show/branch/merge/apply_patch/worktree*). These act on on-disk repos — GitHub's MCP can't. The split is "git the local VCS = keep; GitHub the cloud service = cut."
- **Local dev runners** (KEEP only if "local development" is a claimed use case): `swift_build`, `swift_test`, `make_run`, `lsp_*`, `tree_sitter_query`, `code_search`, `devserver_*`, `vitest_run`, `lighthouse_run`, `playwright_run`, `wrangler_d1_status`, `diff_render`. If not claiming dev, these are the next prune candidates after Stripe/GitHub.
- **http_fetch**: generic; agents have their own fetch. Candidate cut unless a local-network/credentialed use is needed.

## Default-deny principle (governance)
The toggle/governance layer is only a *feature* if the starting surface is **minimal and
opt-in**. If it ships "everything on" with opt-out, it's the tool-bloat problem with a
settings page bolted on. Default-deny; opt tools in.

## Execution plan (separate packet)
1. Cut Stripe family + `gh_*` (lowest risk, operator-confirmed) → measure tool-count drop + suite.
2. Decide the local-dev-runner question (claim it or cut it).
3. Re-baseline `staticFeatureModuleToolCount` + the test floor; update family count.
4. Verify remote connector allowlist (`ConnectorScopeGate.connectorReachableTools`) still reflects the intended public surface after cuts.
