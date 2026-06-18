# keepr-bridge — Code Review, Pruning & Test Hardening Sprint
## Post-v1.8.0 Quality Sprint

**Prerequisite:** `docs/sprint-v1.8.0.md` sprint complete. All 17 items shipped. `swift run TheBridgeTests` green on `main` at v1.8.0.
**Branch:** `chore/code-review-v1.8`
**Contract:** `sk mac-dev v3.0.1` — Workflows B (BUILD), C (GIT), E (TEST), CODE
**Maturity target:** Production-grade. Every line earns its place. Every tool is validated. Every failure mode is tested.

---

## Agent Operating Principles

You are taking **ownership** of this codebase. That means:

- You do not skip things because they are hard. You find a way.
- You do not leave partial work. If you start a file, you finish it.
- When a test fails, you diagnose the root cause and fix it. You do not disable the test or work around it.
- When you find something wrong that is not on the list, you fix it or log it — you do not ignore it.
- You hold the standard: **would a senior Swift engineer with security expertise be impressed by this code?** If the answer is no, it is not done.
- You run `swift run TheBridgeTests` after every substantive change. A green test suite is not the end state — it is the minimum bar.
- You commit in logical, atomic units with clear conventional commit messages. You do not batch unrelated changes into a single commit.
- You operate within `sk mac-dev v3.0.1` boundaries: code and tests are yours; TheBridge lifecycle (restart, reload) hands off to `sk mac ops`.

---

## Codebase Map

```
TheBridge/
├── App/            AppDelegate, TheBridgeApp, StatusBarController, WindowTracker
├── Config/         ConfigManager, Version, ConnectionRegistry, ConnectionHealthChecker, BridgeConnectionModels
├── Modules/        ~20 feature modules (Notion, File, Shell, Screen, Messages, Skills, Stripe, ...)
├── Notion/         NotionClient, NotionClientRegistry, NotionModels
├── Security/       SecurityGate, PermissionManager, CredentialManager, KeychainManager, AuditLog, LogManager, StripeClient, StripeMcpProxy
├── Server/         ServerManager, SSETransport, ToolRouter, MCPHTTPValidation
└── UI/             DashboardView, SettingsWindow, ConnectionsManagementView, PermissionView, ...

TheBridgeTests/
├── main.swift                          Custom test harness (swift run TheBridgeTests)
├── *ModuleTests.swift                  Per-module unit tests (22 files)
└── IntegrationTests/EndToEndTests.swift
```

Test runner: `swift run TheBridgeTests` (custom harness — NOT `swift test`).
Build: `swift build -c release` or `make app`.

---

## Phase 1 — Discovery & Audit

**Before touching a single line of code, build a full picture.**

Read every source file. For each file, answer:
1. What is this file's single responsibility?
2. Does it have one, or has scope crept in?
3. Are there any symbols defined here that are never used anywhere else?
4. Are there any imports that are never referenced?
5. Are there TODO/FIXME comments — and are they still valid?
6. Does the error handling match the project standard (throw + `NotionClientError` / `ToolRouterError`)?
7. Does the SecurityGate tier assignment match the actual risk level of the tool?

**Deliverable at end of Phase 1:** A written audit report in chat — one line per file, flagging each issue category found (DEAD, ARCH, ERR, SEC, DOC, TEST). This report is the work queue for Phases 2–6. Do not start Phase 2 until this report is complete.

---

## Phase 2 — Dead Code Pruning

Work through the audit report. For each DEAD flag:

### 2.1 Unused Symbols
- Swift public API: a `public` method not referenced outside its file or test is a candidate for removal or scope reduction (`internal`/`private`)
- Private methods: if no call site exists anywhere in the module, delete
- Unused parameters: rename to `_` or remove from signature if the parameter is always ignored
- Unreachable branches: `guard`/`if` conditions that can never be false given type guarantees

### 2.2 Orphaned Files
- Any `.swift` file not included in the build target and not referenced — delete
- Any test file testing a type that no longer exists — delete or repurpose

### 2.3 Commented-Out Code
- Remove all commented-out code blocks. If the code is worth keeping, it is in git history.
- Exception: intentionally disabled tests with an explicit `// Disabled: <reason>` comment referencing a known issue. These stay but must be documented.

### 2.4 Stale TODOs and FIXMEs
- Read every TODO and FIXME in the codebase
- For each: either fix it now, convert it to a filed issue in AGENT_FEEDBACK.md with a date, or delete it
- Do not leave TODOs that are older than the current sprint or that reference removed features

### 2.5 Import Hygiene
- Remove unused `import` statements from every file
- If a file imports a framework only for one symbol that could be scoped, consider narrowing

---

## Phase 3 — Architecture Review

### 3.1 Layering
The correct dependency direction is:
```
UI → App → Config/Security → Server → Modules → Notion/Security utilities
```
Flag and fix any violation where a lower layer imports from a higher one. Specifically:
- `Modules/` must not import from `UI/`
- `Server/` must not import from `Modules/` (it receives registrations, not implementations)
- `Notion/` must not import from `Modules/`

### 3.2 Module Responsibility Boundaries
Each module file in `Modules/` should own exactly one domain. Review:
- `ScreenModule.swift` vs `ScreenAnalyze.swift` vs `ScreenRecording.swift` — three files for one conceptual domain. Assess whether they should be one file or whether the split is principled and clearly named.
- `StripeMcpModule.swift` in `Modules/` vs `StripeClient.swift` and `StripeMcpProxy.swift` in `Security/` — the Security layer is the wrong home for Stripe infrastructure. Assess whether these belong in a dedicated `Stripe/` layer or alongside other module infrastructure.
- `SkillsModule.swift`, `SkillsManager.swift`, `SkillNotionMetadata.swift` — three files for skills. Verify responsibility split is clean and not redundant.

### 3.3 Actor Isolation
- All `NotionClient` and `ToolRouter` operations must be actor-isolated. Verify no data races are possible at call sites.
- Any shared mutable state outside an actor is a defect. Flag and fix.
- `@MainActor` usage in UI layer must be consistent — no ad-hoc `DispatchQueue.main.async` mixing with `@MainActor`.

### 3.4 Protocol / Interface Seams
- `ToolRouter` dispatches to registered handlers. Verify the `ToolRegistration` type is the single contract — no module reaches into the router internals.
- `SecurityGate` must be the only path through which tools are approved. Verify no module bypasses it.
- `NotionClientRegistry` is the only path to a `NotionClient`. Verify no module holds a direct `NotionClient` reference outside the registry pattern.

### 3.5 Naming Consistency
Audit for naming drift across the codebase:
- Method prefix: `get` vs `fetch` vs `load` vs `read` — pick one convention per operation type and apply it consistently
- Module names: `XModule.swift` is the pattern — verify all modules follow it
- Tool names: `noun_verb` snake_case — verify all registered tool names follow the pattern
- Error type names: verify all thrown errors use the established error enum types, not `NSError` or raw `Error` strings

---

## Phase 4 — Security Audit

### 4.1 SecurityGate Tier Assignments
Review every tool registration in every module. For each tool, verify the tier is correct:

| Tier | Criteria |
|------|----------|
| `.open` | Read-only. No side effects. No data exfiltration risk. |
| `.notify` | Writes, mutations, or sends. User is informed but not blocked. |
| `.request` | Destructive, irreversible, or high-privilege. User must actively approve. |

Specific checks:
- Any tool that **deletes** content must be `.request`, not `.notify`
- Any tool that **sends a message** externally (messages, email, Stripe payment) must be `.request`
- Any tool that **executes arbitrary shell code** (`shell_exec`, `applescript_exec`) must be `.request`
- Read-only tools incorrectly marked `.notify` waste SecurityGate friction — downgrade them

### 4.2 Input Validation
Every tool handler receives `arguments` from an external MCP client. Treat all inputs as untrusted:
- String parameters used in file paths: verify no path traversal (`../`) is possible
- Shell commands passed to `shell_exec`: verify no injection surface exists
- Notion IDs: verify the `cleanId` (strip hyphens) pattern is applied consistently before any API call
- Credential names/services: verify they cannot be manipulated to read arbitrary keychain items

### 4.3 Credential & Keychain Handling
- No token, API key, or bearer credential may appear in logs, error messages, or MCP tool output
- `CredentialManager` and `KeychainManager` — verify read operations never leak values into stack traces
- `AuditLog` — verify it logs the operation and actor, never the credential value

### 4.4 Entitlement Hygiene
Review `TheBridge.entitlements`:
- Each entitlement must correspond to an active feature. Document the mapping.
- Any entitlement not currently exercised by live code is a security surface that should be removed.

### 4.5 Bearer Token Validation
`MCPHTTPValidation.swift` validates the bearer token on every inbound request. Verify:
- Constant-time comparison is used (not `==` string comparison, which is timing-attackable)
- Empty bearer token is rejected, not treated as a wildcard match
- The validation applies to all endpoints, not just tool dispatch

---

## Phase 5 — Test Coverage Expansion

The test suite uses a custom harness (`swift run TheBridgeTests`). Tests live in `TheBridgeTests/` as `swift run` executable targets, not XCTest.

### 5.1 Coverage Audit
For each module, map existing tests against the tool's handler logic:

| Module | Test File | What to check |
|--------|-----------|----------------|
| AccessibilityModule | AccessibilityModuleTests | AX tree traversal, element lookup, action dispatch |
| AppleScriptModule | AppleScriptModuleTests | Script execution, error propagation |
| ChromeModule | ChromeModuleTests | Tab operations, JS execution, screenshot |
| ConnectionsModule | ConnectionsModuleTests | Health check, capability introspection |
| CredentialModule | CredentialModuleTests | Read/list/save/delete, unknown-label items (A2 from v1.8.0) |
| FileModule | FileModuleTests | Read/write/copy/move/rename, **HTML entity round-trip** (A1 from v1.8.0) |
| MessagesModule | MessagesModuleTests | Send guard (raw chat identifier rejection — A3 from v1.8.0) |
| NotionModule | NotionModuleTests | All 17 registered tools, tiers, missing-param rejection |
| PaymentModule | PaymentModuleTests | Stripe operations, error handling |
| ScreenModule | ScreenModuleTests | Capture, record start/stop, analyze |
| SessionModule | SessionModuleTests | Session lifecycle, expiry, diagnostics |
| ShellModule | ShellModuleTests | Exec, approved list enforcement, timeout behavior |
| SkillsModule | SkillsModuleTests | Fetch normalization (C1 from v1.8.0), list, manage |
| SystemModule | SystemModuleTests | System info, process list |
| BuiltinModule | BuiltinModuleTests | echo tool |
| StripeMcpModule | StripeClientTests | Dynamic tool discovery, proxy dispatch |

### 5.2 Missing Test Classes
Write new tests for any of the following that lack coverage. Each new test class follows the existing harness pattern in `main.swift`:

**Priority 1 — Test gaps for known past bugs (from AGENT_FEEDBACK.md):**
- `file_write` HTML entity round-trip: write JSX content, read back, assert no encoding mutation
- `credential_read` unknown-label fallback: mock a keychain item with non-standard label, assert value is returned
- `messages_send` raw chat guard: call with `chat12345` identifier, assert `ToolRouterError` thrown before dispatch
- `notion_query` retry behavior: simulate a 404 response, assert one retry fires, assert error surfaced after second failure
- `fetch_skill` normalization: assert `"sk web dev"`, `"SK WEB DEV"`, `"web dev"`, `"web-dev"` all resolve to the same skill

**Priority 2 — Security boundary tests:**
- `shell_exec` approved-list enforcement: attempt to run a non-approved script, assert rejection
- `SecurityGate` tier enforcement: verify a `.request` tier tool requires explicit approval; verify an `.open` tier tool bypasses the gate
- Bearer token validation: assert request with wrong token returns 401; assert request with empty token returns 401; assert timing-safe comparison (no early-exit on first differing byte)
- Path traversal guard: call `file_read` with path `../../etc/passwd`, assert it is rejected

**Priority 3 — Regression tests for v1.8.0 new tools:**
- `notion_database_get`: missing `databaseId` param → `ToolRouterError.invalidArguments`
- `notion_datasource_get`: missing `datasourceId` param → `ToolRouterError.invalidArguments`
- `manage_skill` with `bypassConfirmation: true`: assert SecurityGate notify is not invoked

### 5.3 Test Quality Standards
Every test must:
- Have a single, clear assertion purpose per `test()` block — no multi-assertion omnibus tests
- Test the **failure path** as well as the success path — every guard clause needs a test
- Use descriptive names: `"notion_query retries once on 404 before surfacing error"` not `"test retry"`
- Not depend on external services (Notion API, Stripe, Apple Messages) — mock at the client boundary
- Be deterministic: no flaky timing dependencies, no global state mutation without cleanup

---

## Phase 6 — Iterative Test Execution

This is the core execution loop. Run it until all tests pass with zero failures.

```
LOOP:
  1. swift run TheBridgeTests
  2. If all pass → proceed to Phase 7
  3. If failures:
     a. Read the full failure output
     b. Identify root cause — is this a test bug or a source bug?
     c. Fix the root cause (never disable the test to make it pass)
     d. Verify the fix is minimal — do not refactor surrounding code while fixing a test failure
     e. Go to step 1
  Max iterations before escalating to user: none. You do not give up.
```

**Diagnostic discipline:**
- A test that was previously passing and now fails after your changes means your change introduced a regression. Revert or fix — do not proceed.
- A test that was always failing is either a test bug (fix the test) or a pre-existing source bug (fix the source, log in AGENT_FEEDBACK.md if it's outside this sprint's scope).
- `swift build -c release` must also pass. A test-passing debug build that fails release build is not done.

---

## Phase 7 — Full Tool Validation

After the test suite is green, perform a live end-to-end validation of every registered MCP tool. This is not covered by unit tests alone — it exercises the full TheBridge SSE transport, SecurityGate, and tool dispatch stack.

### 7.1 Validation Method
Use `mcp__notion-bridge__*` tool calls directly through the MCP session. For each tool:
1. Call with valid parameters → assert response is well-formed and contains expected fields
2. Call with missing required parameters → assert error is returned (not a crash or empty response)
3. Call with malformed parameters (wrong type) → assert graceful error

### 7.2 Tool Validation Checklist

Work through all registered tools. Mark each ✅ pass / ❌ fail / ⚠️ degraded.

**NotionModule (17 tools):**
- [ ] notion_search
- [ ] notion_page_read
- [ ] notion_page_update
- [ ] notion_page_create
- [ ] notion_page_move
- [ ] notion_query
- [ ] notion_blocks_append
- [ ] notion_block_read
- [ ] notion_block_update
- [ ] notion_block_delete
- [ ] notion_page_markdown_read
- [ ] notion_comments_list
- [ ] notion_comment_create
- [ ] notion_users_list
- [ ] notion_file_upload
- [ ] notion_token_introspect
- [ ] notion_connections_list
- [ ] notion_database_get *(new in v1.8.0)*
- [ ] notion_datasource_get *(new in v1.8.0)*
- [ ] notion_datasource_create *(if implemented)*
- [ ] notion_datasource_update *(if implemented)*

**FileModule:**
- [ ] file_read
- [ ] file_write *(HTML entity round-trip)*
- [ ] file_append
- [ ] file_copy
- [ ] file_move
- [ ] file_rename
- [ ] file_delete
- [ ] file_list
- [ ] file_search
- [ ] file_metadata
- [ ] dir_create

**ShellModule:**
- [ ] shell_exec *(approved list enforcement)*
- [ ] run_script

**SkillsModule:**
- [ ] fetch_skill *(normalization)*
- [ ] list_routing_skills
- [ ] manage_skill

**ScreenModule:**
- [ ] screen_capture
- [ ] screen_analyze
- [ ] screen_ocr
- [ ] screen_record_start
- [ ] screen_record_stop

**AccessibilityModule:**
- [ ] ax_tree
- [ ] ax_element_info
- [ ] ax_find_element
- [ ] ax_focused_app
- [ ] ax_perform_action

**MessagesModule:**
- [ ] messages_recent
- [ ] messages_search
- [ ] messages_content
- [ ] messages_participants
- [ ] messages_send *(raw chat guard)*
- [ ] messages_chat

**CredentialModule:**
- [ ] credential_read *(unknown-label fallback)*
- [ ] credential_list *(unknown-label inclusion)*
- [ ] credential_save
- [ ] credential_delete

**SystemModule:**
- [ ] system_info
- [ ] process_list
- [ ] notify
- [ ] echo

**SessionModule:**
- [ ] session_info
- [ ] session_clear

**ChromeModule:**
- [ ] chrome_tabs
- [ ] chrome_navigate
- [ ] chrome_read_page
- [ ] chrome_screenshot_tab
- [ ] chrome_execute_js

**AppleScriptModule:**
- [ ] applescript_exec

**ConnectionsModule:**
- [ ] connections_list
- [ ] connections_get
- [ ] connections_health
- [ ] connections_capabilities
- [ ] connections_validate

**ContactsModule:**
- [ ] contacts_search

**PaymentModule / StripeMcpModule:**
- [ ] (all dynamically discovered Stripe tools)

### 7.3 Failure Handling During Validation
- Any ❌ failure: diagnose, fix source, re-run. Do not mark as "known issue" without a corresponding AGENT_FEEDBACK.md entry with full context.
- Any ⚠️ degraded (tool works but response is incomplete, slow, or poorly formatted): log in AGENT_FEEDBACK.md and open a follow-up fix if it can be addressed within this sprint.

---

## Phase 8 — Documentation Cleanup

After code and tests are clean:

### 8.1 Inline Comments
- Remove comments that restate what the code does (the code is the documentation)
- Keep comments that explain **why** — non-obvious decisions, API quirks, historical context
- Update any comment referencing a removed feature, old method name, or stale API endpoint

### 8.2 AGENTS.md
- Verify documented tool count matches actual registered tool count after v1.8.0 additions and removals
- Update known patterns and workarounds from this sprint (e.g., `shell_exec` PATH pattern, `nohup` detection)

### 8.3 README.md
- Feature list must match shipped tools
- Any mention of `notion_page_markdown_write` must be removed
- Installation and setup steps must be accurate

### 8.4 AGENT_FEEDBACK.md
- Mark any entries resolved in v1.8.0 with `**RESOLVED (v1.8.0)**` inline annotation
- Do not edit existing entry text — annotate only

---

## Definition of Done

This sprint is complete when **all** of the following are true:

### Code Quality
- [ ] Zero unused `import` statements across all source files
- [ ] Zero commented-out code blocks (excluding intentionally-disabled tests with documented reason)
- [ ] Zero TODO/FIXME comments older than this sprint
- [ ] Every `public` symbol either has an external call site or is downscoped to `internal`/`private`
- [ ] All actor isolation is explicit and consistent — no `DispatchQueue.main.async` mixed with `@MainActor`
- [ ] Naming conventions are consistent across all modules (tool names, method prefixes, error types)
- [ ] No layering violations: UI does not reach into Server; Modules do not reach into UI

### Security
- [ ] Every `.request` tool deserves `.request` — no under-tiered destructive tools
- [ ] Every `.open` tool truly has no side effects — no over-tiered read tools
- [ ] Input validation present at every tool handler for all string parameters used in paths, shell, or API calls
- [ ] Bearer token comparison is timing-safe
- [ ] No credential value appears in any log entry, error message, or tool response

### Tests
- [ ] `swift run TheBridgeTests` passes with zero failures
- [ ] `swift build -c release` passes with zero warnings
- [ ] Every tool handler has at least one test for the missing-parameter failure path
- [ ] HTML entity round-trip test passes for `file_write`
- [ ] Raw chat identifier guard test passes for `messages_send`
- [ ] `fetch_skill` normalization test passes for all four input variants
- [ ] SecurityGate tier enforcement tests pass for `.open`, `.notify`, and `.request`
- [ ] Path traversal guard test passes for `file_read`

### Tool Validation
- [ ] All tools in the validation checklist marked ✅
- [ ] Zero ❌ failures remaining
- [ ] All ⚠️ degraded items have a filed AGENT_FEEDBACK.md entry

### Documentation
- [ ] Tool count in AGENTS.md matches actual registered count
- [ ] `notion_page_markdown_write` removed from all documentation
- [ ] All resolved v1.8.0 feedback entries annotated in AGENT_FEEDBACK.md

---

## Commit Convention for This Sprint

```
chore(review): remove unused imports from FileModule and ShellModule
chore(review): delete orphaned DesktopOrganizationScenarioTests
fix(security): downscope SecurityGate tier for notion_page_read to .open
fix(security): timing-safe bearer token comparison in MCPHTTPValidation
test(file): add HTML entity round-trip test for file_write
test(messages): add raw chat identifier guard test for messages_send
test(security): add path traversal guard tests for file_read
test(skills): add fetch_skill normalization tests for 4 input variants
docs(agents): update tool count and v1.8.0 resolved feedback entries
```

Each commit covers one logical change. Do not batch. The git log for this sprint should read as a clear, reviewable history of exactly what was done and why.

---

## Escalation

If you encounter a problem that blocks progress:
1. Attempt at least two distinct diagnostic approaches before escalating
2. Document what you tried and what you found
3. Then surface to user with a precise problem statement and your best hypothesis

You do not quit. You do not silently skip. You own this.
