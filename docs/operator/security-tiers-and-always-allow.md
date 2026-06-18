# Security tiers and Always-Allow scope

The Bridge gates every tool call through `SecurityGate` using a three-tier model
(`SecurityTier` in `TheBridge/Security/SecurityGate.swift`):

| Tier       | Behavior                                                              |
|------------|----------------------------------------------------------------------|
| `.open`    | Executes immediately. No prompt, no notification. Read-only ops.      |
| `.notify`  | Executes immediately, then fires a fire-and-forget notification.     |
| `.request` | Requests explicit approval (Allow / Deny / Always Allow) first.      |

## Read-only tools are `.open`

Tools that strictly read state — those whose names end in `_list`, `_get`,
`_read`, or `_search` — are registered at tier `.open` so they run without a
confirmation prompt. This is enforced by `ReadOnlyTierAuditTests`
(`TheBridgeTests/ReadOnlyTierAuditTests.swift`), which fails the build if any
read-only-named tool is registered above `.open` without an explicit, justified
allowlist entry.

Deliberate exceptions (kept above `.open` on purpose):

- `credential_read`, `credential_list` — expose secret material; confirmation
  is intentional.
- `git_worktree_list` — inherits GitModule's uniform module-wide `.request`
  policy (see the `GitModule.swift` header).

## Always-Allow is per-tool, not global

When you tap **Always Allow** on a `.request`-tier approval prompt, the override
applies **only to that one tool, identified by its exact tool name**. It does
not blanket-approve other tools, other tools in the same module, or any future
tool.

Mechanism: `SecurityGate.persistNotifyTierOverride(toolName:)` writes a single
keyed entry — `tierOverrides[toolName] = "notify"` — into the persisted
`BridgeDefaults.tierOverrides` dictionary. Because the override is keyed by the
individual tool name, granting Always-Allow for, say, `messages_send` has no
effect on `notion_page_update` or any other tool. Each tool you want to silence
must be approved (or re-tiered via the Tool Registry) individually.

To revoke a per-tool Always-Allow, change the tool's tier back in the Tool
Registry (the same `tierOverrides` map is the source of truth).
