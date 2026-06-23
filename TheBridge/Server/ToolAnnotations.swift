// ToolAnnotations.swift — WS-B (v2.3, PKT-803) · Sprint A (mcp-builder)
// TheBridge · Server
//
// Explicit tool-annotation surface for the entire static tool set, so
// Anthropic Connector review (WS-G / Wave 4) does not block on it later,
// and so MCP clients receive faithful readOnly/destructive/idempotent/
// open-world hints. Decision D1 (v3 hub Decision Log) parked formal
// ToolAnnotations here in WS-B. Sprint A (mcp-builder Top-15 #13) added
// the `idempotentHint` axis per the audit §4 heuristic.
//
// CONTRACT — "no implicit default fallback" (packet DoD):
//   • `BridgeToolAnnotations` has FIVE non-optional Bool fields and an
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
/// equivalent; the other four map onto MCP `Tool.Annotations`.
public struct BridgeToolAnnotations: Sendable, Equatable, Hashable {
    /// Tool does not modify its environment.
    public let readOnlyHint: Bool
    /// Tool may perform destructive/irreversible updates (meaningful only
    /// when `readOnlyHint == false`).
    public let destructiveHint: Bool
    /// Calling the tool repeatedly with the same arguments lands on the
    /// same end state (pure-read OR "set-to-value-X" semantics). Mirrors
    /// MCP `idempotentHint`. Sprint A · mcp-builder Top-15 #13 added this
    /// axis with the same hard-fail invariant as `requiresConfirmation`.
    public let idempotentHint: Bool
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
        idempotentHint: Bool,
        requiresConfirmation: Bool,
        openWorld: Bool
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.requiresConfirmation = requiresConfirmation
        self.openWorld = openWorld
    }

    /// Fail-closed most-restrictive annotation. Runtime safety backstop
    /// only — the audit test guarantees it is never reached for static
    /// tools. Also the explicit annotation for dynamically-discovered
    /// proxy tools whose behaviour is not statically known.
    /// `idempotentHint:false` is the conservative default (assume calling
    /// twice doubles the effect until proven otherwise).
    public static let failClosed = BridgeToolAnnotations(
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        requiresConfirmation: true,
        openWorld: true
    )
}

// MARK: - Catalog

public enum ToolAnnotationCatalog {

    /// One explicit entry per static (non-Stripe) registered tool.
    /// `idempotentHint` values are sourced from the audit (§2 + §4 heuristic):
    /// `true` for pure-read-with-stable-input OR set-to-value-X writes;
    /// `false` for append/create/run, network-mutating, time-dependent, or chain-effect ops.
    public static let entries: [String: BridgeToolAnnotations] = [
        "applescript_exec": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        // Sprint A · mcp-builder #1: ax_element_info / ax_find_element removed
        // (PKT-755 v2.2 deprecation cycle complete; callers use ax_inspect modes).
        // #11: ax_query → ax_inspect rename (alias kept). ax_focused_app
        // revived as a NEW dedicated top-level tool (NOT a deprecation shim).
        "ax_focused_app": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "ax_inspect": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "ax_perform_action": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "ax_tree": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        // FB-AUTOMATION: drives the in-app Settings nav selection model.
        // Deep-links to a section (and may open the window) but mutates no
        // user data and is fully idempotent (re-selecting a section is a no-op).
        // Touches only this app's own UI — not an open world.
        "bridge_settings_navigate": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        // PKT-1005 (Pillar A): cold-opens the in-app Settings window + deep-links
        // a section. Same posture as bridge_settings_navigate — opens this app's
        // own UI, mutates no user data, idempotent (re-opening an open window is
        // a no-op re-point), not an open world.
        "bridge_open_settings": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        // WS-D (PKT-921): cloud-gated health probe. Reads the local
        // BridgeCloudManager state machine; touches nothing — pure read.
        "bridge_status": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "cgevent_send": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        // Sprint A · mcp-builder #14: chrome_tabs → chrome_tabs_list rename
        // (alias kept; old + new are both live for one cycle).
        "clipboard_read": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "clipboard_write": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "code_search": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "connections_capabilities": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "connections_get": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "connections_health": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "connections_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "connections_validate": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "contacts_get": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "contacts_health": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "contacts_resolve_handle": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "contacts_search": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "credential_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: false),
        "credential_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "credential_read": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: true, openWorld: false),
        "credential_save": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: true, openWorld: false),
        // Sprint A · mcp-builder #8: dev_module_info removed (scaffold placeholder).
        "diff_render": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "dir_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        // Sprint A · mcp-builder #8: builtin `echo` removed (session_info covers health).
        "fetch_skill": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "file_append": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        // Sprint A · mcp-builder #5: file_edit merges file_str_replace + file_apply_patch.
        "file_edit": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "file_copy": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "file_hash": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "file_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "file_metadata": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "file_move": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "file_read": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "file_rename": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "file_search": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "file_unzip": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "file_write": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "file_zip": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        // Sprint A · mcp-builder #7: gh_* renames. Both old and new names
        // are live tools (the old is a one-cycle deprecation alias).
        "gh_actions_runs_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "gh_check_status": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "gh_issue_close": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "gh_issue_comment": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "gh_issue_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "gh_pr_comment": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "gh_pr_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "gh_pr_merge": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "gh_pr_status": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "git_apply_patch": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "git_blame": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: true, openWorld: true),
        "git_create_branch": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: true, openWorld: true),
        "git_diff": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "git_log": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "git_show": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: true, openWorld: true),
        "git_status": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        // Sprint A · mcp-builder #6: git_worktree split into 3 primitives.
        "http_fetch": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "job_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "job_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: false),
        "job_duplicate": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "job_export": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "job_get": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "job_history": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "job_import": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "job_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        // Sprint A · audit Top-15 #12: job_pause / job_resume mutate LaunchAgent state.
        // Was readOnlyHint:true (incorrect — pause unregisters the LaunchAgent).
        // Sprint A · #3: jobs_pause_all / jobs_resume_all reinstated as 1-cycle
        // deprecation aliases that forward to job_pause/job_resume with all:true.
        "job_pause": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "job_resume": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "job_run": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "job_templates": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "job_update": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "keyboard_type": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        // Sprint A · mcp-builder #14: list_routing_skills → skills_routing_list.
        "skills_routing_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        // v3.7·H (PKT-961): Apple Mail family. list/read/search are read-only
        // (.open → requiresConfirmation:false); draft is non-destructive but
        // writing (.notify → creates an UNSENT draft, requiresConfirmation:false);
        // send is the GUARDED tool (.request → requiresConfirmation:true, mirrors
        // tier==.request). All openWorld (Mail.app is an external surface).
        "mail_draft": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "mail_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "mail_read": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "mail_search": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "mail_send": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        // Sprint A · mcp-builder #2: manage_skill split into 5 primitives.
        // The 11-action polymorphism is preserved as a one-cycle alias.
        "skill_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "skill_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: false),
        "skill_update": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "skill_rename": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "skill_sync_notion": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        // Unified Memory foundation (Wave 1): local SQLite memory store.
        // remember WRITES but is non-destructive + reversible (soft tombstone)
        // and tier .notify, so requiresConfirmation stays false; openWorld is
        // false (a closed local store). recall is read-only — recall DOES bump
        // useCount/lastUsedAt (use-promotion), but that is metadata-only and
        // does not mutate content, so readOnlyHint stays true.
        "memory_export": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: false),
        "memory_import": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: false),
        "memory_recall": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "memory_remember": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "messages_chat": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "messages_content": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "messages_participants": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "messages_recent": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "messages_search": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "messages_send": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "mouse_click": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        // v3.7·G — notes_* (Apple Notes via AppleScript). list/read/search are
        // pure reads (.open → requiresConfirmation:false). create/update are
        // .notify (informational notification, NOT a human gate). delete is
        // .request + destructive (move-to-trash, irreversible from the API).
        // openWorld:true — each tool drives Notes.app over Apple events.
        "notes_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notes_read": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notes_search": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notes_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notes_update": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notes_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: true, openWorld: true),
        "notify": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        // Data-Source Registry (generic CRUD + introspect + possess). CRUD
        // annotations are deterministic: reads are read-only+idempotent; create
        // is a non-idempotent write; update is an idempotent (set-to-X) write;
        // delete is a destructive, confirmation-gated archive; introspect writes
        // config (idempotent). `registry_entities` reads LOCAL config (closed).
        "registry_entities": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "registry_add_entity": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        // remove_entity drops a LOCAL binding + evicts its cache (no Notion write
        // → closed world); destructive + confirmation-gated (.request tier).
        "registry_remove_entity": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: true, openWorld: false),
        "registry_introspect": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "registry_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "registry_get": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "registry_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "registry_update": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "registry_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: true, openWorld: true),
        "registry_possess": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_block_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        // Sprint A · mcp-builder #1: notion_block_read removed
        // (PKT-738 v2.2 deprecation cycle complete).
        "notion_block_update": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_blocks_append": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_comment_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_comments_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_database_get": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_datasource_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_datasource_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: true, openWorld: true),
        "notion_datasource_get": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_datasource_update": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_discussion_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_file_upload": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_page_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_page_edit": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_page_markdown_read": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_page_move": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_page_read": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_page_update": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_query": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_search": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "notion_token_introspect": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "notion_users_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "pasteboard_history": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        // fb-permissions: pure read of local TCC grant state — no prompt, no
        // mutation, no network. Same stable input → same output (idempotent).
        "permissions_status": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "process_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        // PKT-962 (v3.7·I): Calendar family over EventKit (.event entities,
        // reusing v3.7·D's store + calendars entitlement). list/events are
        // read-only (.open); create/update non-destructive but writing
        // (.notify); delete is destructive + confirmation-gated (tier
        // .request). Mirrors the reminders annotations below.
        "calendar_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "calendar_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: true, openWorld: true),
        "calendar_events": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "calendar_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "calendar_update": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        // PKT-957 (v3.7·D): Reminders family over EventKit. lists/list are
        // read-only (.open); create/update non-destructive but writing;
        // complete is idempotent (set-to-state X); delete is destructive +
        // confirmation-gated (tier .request).
        "reminders_complete": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "reminders_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "reminders_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: true, openWorld: true),
        "reminders_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "reminders_lists": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "reminders_update": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "run_script": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "screen_capture": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "screen_ocr": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "screen_record_start": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "screen_record_stop": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "session_clear": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "session_info": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "shell_exec": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        // Tool-Dev (PRJCT-2754): detached background execution (`bgprocess` family).
        // bg_run launches an arbitrary detached command — same destructive posture
        // as shell_exec (not read-only, can do anything, not idempotent since each
        // call spawns a NEW job), tier .request ⇒ requiresConfirmation:true, openWorld
        // (compiler / dependency fetch / wider machine). bg_poll is a pure read of
        // file-backed job state (read-only + idempotent, closed local world, no gate).
        // bg_kill terminates a process (destructive, but idempotent — killing a dead
        // job is a no-op / set-to-terminated), tier .notify ⇒ requiresConfirmation:false,
        // openWorld (acts on a process in the wider machine).
        "bg_run": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: true, openWorld: true),
        "bg_poll": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "bg_kill": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        // shortcuts_* (PKT-959, v3.7·F): Apple Shortcuts via /usr/bin/shortcuts.
        // _list is read-only (.open). _run is destructive (a Shortcut can do
        // anything) but tier .notify, so requiresConfirmation stays false —
        // .notify surfaces every run to the operator without a hard gate.
        "shortcuts_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        "shortcuts_run": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        "snippets_create": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: true, openWorld: false),
        "snippets_export": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_get": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "snippets_import": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, requiresConfirmation: true, openWorld: false),
        "snippets_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "snippets_rename": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: true, openWorld: false),
        "snippets_search": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: false),
        "snippets_update": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: true, openWorld: false),
        "spotlight_query": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, requiresConfirmation: false, openWorld: true),
        // standing_orders_* (PKT-931): operator-curated config. read/list are
        // read-only but tier .notify (deliberate exception — see ReadOnlyTierAuditTests).
        "standing_orders_delete": .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, requiresConfirmation: true, openWorld: false),
        "standing_orders_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "standing_orders_read": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "standing_orders_save": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "stripe_reconnect": .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: true),
        // FB [buildtools]: swift_build / swift_test / make_run wrap BgProcessRuntime
        // (start + poll + tail). Same shape as the vitest/playwright/lighthouse
        // runners: not read-only, not destructive (builds produce artifacts, no
        // irreversible mutation), not idempotent, tier .request ⇒ requiresConfirmation,
        // openWorld (compiler / dependency fetch / wider machine).
        "system_info": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
        "tools_list": .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, requiresConfirmation: false, openWorld: false),
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
    /// SecurityGate via tier / neverAutoApprove). Sprint A added
    /// `idempotentHint` to the projection.
    var mcp: Tool.Annotations {
        Tool.Annotations(
            readOnlyHint: readOnlyHint,
            destructiveHint: destructiveHint,
            idempotentHint: idempotentHint,
            openWorldHint: openWorld
        )
    }
}
