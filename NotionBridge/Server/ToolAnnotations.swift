// ToolAnnotations.swift — WS-B (v2.3, PKT-803)
// NotionBridge · Server
//
// Explicit tool-annotation surface for the entire static tool set, so
// Anthropic Connector review (WS-G / Wave 4) does not block on it later,
// and so MCP clients receive faithful readOnly/destructive/open-world
// hints. Decision D1 (v3 hub Decision Log) parked formal ToolAnnotations
// here in WS-B.
//
// CONTRACT — "no implicit default fallback" (packet DoD):
//   • `BridgeToolAnnotations` has four NON-optional Bool fields and an
//     initializer with NO default values — a registration cannot be
//     annotated implicitly.
//   • `ToolAnnotationCatalog.entries` carries one EXPLICIT entry per
//     static tool. `annotations(for:)` is a pure lookup returning nil on
//     a miss — there is no permissive default.
//   • `resolved(for:)` exists only as a runtime SAFETY backstop and is
//     fail-CLOSED (most-restrictive). The annotation audit test
//     (`runToolAnnotationAuditTests`) hard-fails the build if ANY live
//     registration lacks an explicit entry, so the backstop is provably
//     never reached for the static surface — it is a guard, not a
//     silent default that could mask an unclassified tool.
//   • Stripe proxy tools are discovered dynamically over the network and
//     are intentionally out of the static catalog (same exclusion the
//     E2E static-surface count already applies). They are annotated
//     explicitly + fail-closed at proxy-registration time.

import Foundation
import MCP

// MARK: - Model

/// Bridge-side tool annotations. `requiresConfirmation` has no MCP
/// equivalent; the other three map onto MCP `Tool.Annotations`.
public struct BridgeToolAnnotations: Sendable, Equatable, Hashable {
    /// Tool does not modify its environment.
    public let readOnlyHint: Bool
    /// Tool may perform destructive/irreversible updates (meaningful only
    /// when `readOnlyHint == false`).
    public let destructiveHint: Bool
    /// Dispatch is gated on human confirmation. Mirrors the existing
    /// Bridge security model: `tier == .request` OR `neverAutoApprove`.
    public let requiresConfirmation: Bool
    /// Tool interacts with an open world of external entities (network,
    /// other apps, the wider machine) rather than a closed local domain.
    public let openWorld: Bool

    /// No default arguments — every annotation must be stated explicitly.
    public init(
        readOnlyHint: Bool,
        destructiveHint: Bool,
        requiresConfirmation: Bool,
        openWorld: Bool
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.requiresConfirmation = requiresConfirmation
        self.openWorld = openWorld
    }

    /// Fail-closed most-restrictive annotation. Runtime safety backstop
    /// only — the audit test guarantees it is never reached for static
    /// tools. Also the explicit annotation for dynamically-discovered
    /// proxy tools whose behaviour is not statically known.
    public static let failClosed = BridgeToolAnnotations(
        readOnlyHint: false,
        destructiveHint: true,
        requiresConfirmation: true,
        openWorld: true
    )
}

// MARK: - Catalog

public enum ToolAnnotationCatalog {

    /// One explicit entry per static (non-Stripe) registered tool.
    public static let entries: [String: BridgeToolAnnotations] = [
        "applescript_exec": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: true),
        "ax_element_info": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "ax_find_element": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "ax_focused_app": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "ax_perform_action": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "ax_query": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "ax_tree": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "bg_process_kill": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: false),
        "bg_process_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "bg_process_logs": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "bg_process_start": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "bg_process_status": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "cgevent_send": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "chrome_execute_js": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "chrome_navigate": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "chrome_read_page": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "chrome_screenshot_tab": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "chrome_tabs": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "clipboard_read": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "clipboard_write": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "code_search": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "connections_capabilities": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "connections_get": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "connections_health": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "connections_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "connections_validate": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "contacts_get": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "contacts_health": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "contacts_resolve_handle": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "contacts_search": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "credential_delete": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: false),
        "credential_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "credential_read": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "credential_save": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "dev_module_info": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "devserver_health": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "devserver_start": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "devserver_stop": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: false),
        "diff_render": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "dir_create": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "echo": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "fetch_skill": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "file_append": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "file_apply_patch": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "file_copy": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "file_hash": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "file_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "file_metadata": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "file_move": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "file_read": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "file_rename": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "file_search": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "file_str_replace": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "file_unzip": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "file_watch": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "file_write": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "file_zip": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "gh_actions_runs": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "gh_check_status": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "gh_issue_close": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: true),
        "gh_issue_comment": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "gh_issue_open": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "gh_pr_comment": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "gh_pr_merge": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: true),
        "gh_pr_open": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "gh_pr_status": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "git_apply_patch": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: true),
        "git_blame": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "git_create_branch": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "git_diff": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "git_log": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "git_merge": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: true),
        "git_show": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "git_status": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "git_worktree": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "http_fetch": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "job_create": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_delete": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: false),
        "job_duplicate": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_export": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_get": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_history": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_import": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_pause": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_resume": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_run": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_templates": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "job_update": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "keyboard_type": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "lighthouse_run": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "list_routing_skills": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "lsp_definition": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "lsp_diagnostics": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "lsp_hover": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "lsp_references": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "lsp_rename": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "lsp_session_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "manage_skill": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "messages_chat": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "messages_content": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "messages_participants": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "messages_recent": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "messages_search": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "messages_send": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "mouse_click": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "notify": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "notion_block_delete": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "notion_block_read": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_block_update": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "notion_blocks_append": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_code_block_append": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_comment_create": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_comments_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_connections_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_database_get": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_datasource_create": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_datasource_get": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_datasource_update": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "notion_discussion_create": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_file_upload": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_page_create": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_page_markdown_read": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_page_move": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "notion_page_read": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_page_update": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: true),
        "notion_query": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_search": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_token_introspect": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "notion_users_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "pasteboard_history": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "payment_execute": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: true),
        "playwright_run": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "port_inspect": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "process_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "run_script": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: true),
        "screen_analyze": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "screen_capture": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "screen_ocr": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "screen_record_start": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "screen_record_stop": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "session_clear": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: false, openWorld: false),
        "session_info": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "shell_exec": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: true),
        "snippets_create": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_delete": .init(readOnlyHint: false, destructiveHint: true, requiresConfirmation: true, openWorld: false),
        "snippets_export": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_get": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_import": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_rename": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_search": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_update": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: false),
        "spotlight_query": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "stripe_reconnect": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "system_info": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "tools_list": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
        "tree_sitter_query": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: true),
        "vitest_run": .init(readOnlyHint: false, destructiveHint: false, requiresConfirmation: true, openWorld: true),
        "wrangler_d1_status": .init(readOnlyHint: true, destructiveHint: false, requiresConfirmation: false, openWorld: false),
    ]

    /// Pure lookup. Returns nil on a miss — NO permissive default.
    public static func annotations(for toolName: String) -> BridgeToolAnnotations? {
        entries[toolName]
    }

    /// Runtime resolver: explicit entry, else fail-closed. The audit test
    /// guarantees the fail-closed branch is unreachable for static tools.
    public static func resolved(for toolName: String) -> BridgeToolAnnotations {
        entries[toolName] ?? .failClosed
    }
}

// MARK: - MCP bridging

public extension BridgeToolAnnotations {
    /// Project onto the MCP `Tool.Annotations` hint surface. MCP has no
    /// `requiresConfirmation`; that stays Bridge-internal (enforced by
    /// SecurityGate via tier / neverAutoApprove). `idempotentHint` is
    /// left unspecified — not in WS-B scope.
    var mcp: Tool.Annotations {
        Tool.Annotations(
            readOnlyHint: readOnlyHint,
            destructiveHint: destructiveHint,
            openWorldHint: openWorld
        )
    }
}
