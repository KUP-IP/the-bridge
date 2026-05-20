// ToolDeprecationAlias.swift — Sprint A · mcp-builder
// NotionBridge · Server
//
// Shared helper for the mcp-builder Top-15 sprint that introduces a
// one-cycle deprecation window for every renamed / merged / split tool.
// The audit's deprecation-alias policy (operator Q4=a — one cycle):
//
//   • Old name registered as a ToolRegistration that forwards 1:1 to the
//     new tool's handler (with optional input transformation for the
//     manage_skill/git_worktree splits where the alias has to dispatch
//     into a specific primitive).
//   • Description gets a `DEPRECATED — use \`<new_name>\` instead.
//     Removed in 3.5.0.` prefix so MCP clients see the migration hint.
//   • Tier / neverAutoApprove / schema / metadata mirror the primary's.
//   • Catalog keeps an entry for the OLD name so the
//     ToolAnnotationCatalog audit invariant doesn't break during the
//     one-cycle window.
//   • Audit items 5 (file_edit) and 9 (chrome_screenshot_tab merge) were
//     recommended at 2 cycles; operator Q4=a override drops them to 1.

import Foundation
import MCP

public enum ToolDeprecationAlias {

    /// Wrap a renamed primary tool in a one-cycle deprecation alias under
    /// the old name. Same handler, same input schema, same tier — only
    /// the description gains the `DEPRECATED ...` prefix.
    public static func renameAlias(
        oldName: String,
        newName: String,
        from primary: ToolRegistration
    ) -> ToolRegistration {
        ToolRegistration(
            name: oldName,
            module: primary.module,
            tier: primary.tier,
            neverAutoApprove: primary.neverAutoApprove,
            description: "DEPRECATED — use `\(newName)` instead. Removed in 3.5.0. \(primary.description)",
            inputSchema: primary.inputSchema,
            metadata: primary.metadata,
            handler: primary.handler
        )
    }

    /// Wrap a split or merged tool in a one-cycle deprecation alias whose
    /// handler can transform input before forwarding (e.g. inject an
    /// `action`/`mode` key into the args before dispatching to the
    /// underlying primitive's handler).
    public static func transformAlias(
        oldName: String,
        newName: String,
        module: String,
        tier: SecurityTier,
        neverAutoApprove: Bool = false,
        inputSchema: Value,
        // operatorOverride: when true, prepend the audit-recommended
        // 2-cycle marker as a comment in the description so a future
        // grep can find the policy decision. Honors Q4=a (1-cycle).
        operatorOverride: Bool = false,
        forwardingDescription: String,
        handler: @escaping @Sendable (Value) async throws -> Value
    ) -> ToolRegistration {
        let overrideTag = operatorOverride
            ? " (audit-recommended 2-cycle; operator Q4=a override to 1-cycle)"
            : ""
        return ToolRegistration(
            name: oldName,
            module: module,
            tier: tier,
            neverAutoApprove: neverAutoApprove,
            description: "DEPRECATED — use `\(newName)` instead. Removed in 3.5.0\(overrideTag). \(forwardingDescription)",
            inputSchema: inputSchema,
            handler: handler
        )
    }
}
