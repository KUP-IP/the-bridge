// ConnectorScopeGate.swift — WS-F S2 (PKT-800)
// NotionBridge · Modules · Auth
//
// The `ScopeGating` conformer. Maps a remote connector client's granted
// OAuth scopes onto the Bridge tool surface so a bearer's grant bounds
// which tools it may dispatch. This *complements* — does not replace —
// `SecurityGate`: SecurityGate still runs its open/notify/request tiers
// on every dispatch regardless of transport; this gate is an ADDITIONAL
// front-door check that fires ONLY on the remote `/mcp` connector path
// (the only caller is the connector dispatch shim — stdio / legacy SSE /
// local dispatch never construct or consult it, preserving byte-for-byte
// behaviour on every existing transport).
//
// Mapping policy (connector scope → tool surface):
//   • snippets.read   → read-only snippet tools (list/get/search/export)
//   • snippets.write   → mutating snippet tools (create/update/rename/
//                         delete/import) — a write also implies read,
//                         so snippets.write satisfies read-only tools too
//   • runners.exec     → command / process / job execution + dev runners
//   • contacts.read    → tools that RETURN contact records / personal
//                         data (`contacts_get`, `contacts_search`). S4
//                         (PKT-800): split out of `voice.resolve` so a
//                         grant that only needs voice-handle resolution
//                         can no longer read the full address book —
//                         least-privilege per data-sensitivity tier.
//   • voice.resolve    → voice-resolution-specific tools ONLY: handle →
//                         identity resolution + the resolver health probe
//                         (`contacts_resolve_handle`, `contacts_health`).
//                         These take/return a handle or a liveness bool,
//                         NOT a contact record, so they remain on the
//                         narrower voice scope. A `contacts.read` grant
//                         does NOT implicitly satisfy `voice.resolve` and
//                         vice-versa: the two are independent surfaces
//                         (no superset relationship — distinct data).
//   • a tool the connector does not expose (everything else) is DENIED
//     by default — the connector surface is an explicit allowlist, not
//     "everything minus a blocklist".

import Foundation

/// Canonical connector scope identifiers (wire strings — must match the
/// PRM `scopes_supported` contract in `ProtectedResourceMetadataProvider`).
public enum ConnectorScopeName {
    public static let snippetsRead = "snippets.read"
    public static let snippetsWrite = "snippets.write"
    public static let voiceResolve = "voice.resolve"
    public static let runnersExec = "runners.exec"
    /// S4 (PKT-800): a dedicated scope for tools that return contact
    /// RECORDS / personal data, split out of the over-broad
    /// `voice.resolve`. Independent of `voice.resolve` (neither implies
    /// the other) — see the mapping policy in the file header.
    public static let contactsRead = "contacts.read"

    public static let all: [String] = [
        snippetsRead, snippetsWrite, voiceResolve, runnersExec, contactsRead,
    ]
}

/// Concrete `ScopeGating` conformer for the remote connector surface.
///
/// Pure value logic — deterministic and side-effect-free so it is fully
/// testable without a server. The scope→tool table is the single source
/// of truth for what a connector grant can reach.
public struct ConnectorScopeGate: ScopeGating {

    public init() {}

    // MARK: Tool → required scopes

    /// Read-only snippet tools: satisfied by `snippets.read` OR the
    /// strictly-stronger `snippets.write`.
    private static let snippetReadTools: Set<String> = [
        "snippets_list", "snippets_get", "snippets_search", "snippets_export",
    ]

    /// Mutating snippet tools: require `snippets.write`.
    private static let snippetWriteTools: Set<String> = [
        "snippets_create", "snippets_update", "snippets_rename",
        "snippets_delete", "snippets_import",
    ]

    /// Execution / process / job-runner surface: requires `runners.exec`.
    private static let runnerExecTools: Set<String> = [
        "shell_exec", "run_script",
        "bg_process_start", "bg_process_kill", "bg_process_list",
        "bg_process_logs", "bg_process_status",
        "job_create", "job_run", "job_update", "job_delete",
        "job_pause", "job_resume", "job_duplicate", "job_import",
        "job_export", "job_get", "job_list", "job_history",
        "job_templates", "jobs_pause_all", "jobs_resume_all",
        "devserver_start", "devserver_stop", "devserver_health",
    ]

    /// Contact-RECORD / personal-data tools: require `contacts.read`.
    /// S4 (PKT-800): split out of `voiceResolveTools`. These return the
    /// caller's address-book entries (name, phones, emails, etc.) — the
    /// highest-sensitivity contact surface — so they sit behind their own
    /// scope and are NOT reachable with only `voice.resolve`.
    private static let contactsReadTools: Set<String> = [
        "contacts_get", "contacts_search",
    ]

    /// Voice-resolution-specific tools: require `voice.resolve`. RETAINED
    /// on the narrower scope because neither returns a contact record:
    ///   • `contacts_resolve_handle` — maps a single phone/email handle to
    ///     a display identity (handle→name resolution for a known handle,
    ///     the literal "voice resolve" use-case), not address-book search.
    ///   • `contacts_health` — a liveness/availability probe of the
    ///     contacts subsystem (returns a status bool, no personal data).
    /// `voice.resolve` does NOT grant `contactsReadTools` and vice-versa.
    private static let voiceResolveTools: Set<String> = [
        "contacts_resolve_handle", "contacts_health",
    ]

    /// The complete connector-reachable tool set (union of the five
    /// buckets). Anything outside this set is not exposed to remote
    /// connector clients at all and is denied regardless of scope.
    public static var connectorReachableTools: Set<String> {
        snippetReadTools
            .union(snippetWriteTools)
            .union(runnerExecTools)
            .union(contactsReadTools)
            .union(voiceResolveTools)
    }

    /// Scopes that, if granted, authorize `toolName`. Empty ⇒ the tool is
    /// not part of the connector surface (always denied on this path).
    /// A read-only snippet tool lists BOTH `snippets.read` and
    /// `snippets.write` because write strictly implies read.
    public func requiredScopes(for toolName: String) async throws -> [ConnectorScope] {
        if Self.snippetReadTools.contains(toolName) {
            return [
                ConnectorScope(name: ConnectorScopeName.snippetsRead),
                ConnectorScope(name: ConnectorScopeName.snippetsWrite),
            ]
        }
        if Self.snippetWriteTools.contains(toolName) {
            return [ConnectorScope(name: ConnectorScopeName.snippetsWrite)]
        }
        if Self.runnerExecTools.contains(toolName) {
            return [ConnectorScope(name: ConnectorScopeName.runnersExec)]
        }
        if Self.contactsReadTools.contains(toolName) {
            return [ConnectorScope(name: ConnectorScopeName.contactsRead)]
        }
        if Self.voiceResolveTools.contains(toolName) {
            return [ConnectorScope(name: ConnectorScopeName.voiceResolve)]
        }
        return []
    }

    /// Allow iff `grantedScopes` intersects the tool's required-scope set.
    /// A tool with no required scopes (not connector-reachable) is denied.
    public func evaluate(
        toolName: String,
        grantedScopes: [ConnectorScope]
    ) async -> ScopeDecision {
        let required = (try? await requiredScopes(for: toolName)) ?? []
        guard !required.isEmpty else {
            return .deny(
                reason: "tool '\(toolName)' is not exposed to remote connector clients"
            )
        }
        let grantedSet = Set(grantedScopes.map(\.name))
        // PKT-810 directory-connector model: WorkOS AuthKit cannot mint the
        // connector's custom scopes (an authorize that requests them is
        // rejected with `invalid_scope`), so a validly-authenticated directory
        // token arrives carrying NO connector scopes. Treat authentication as
        // the grant for the connector-reachable ALLOWLIST: the tool is already
        // known-reachable (`required` is non-empty above), tools outside the
        // allowlist are still denied, and SecurityGate (open/notify/confirm) +
        // step-up consent on destructive tools remain the real per-call safety
        // layer. A token that DOES carry connector scopes keeps the strict
        // per-scope intersection below (back-compatible with scoped grants).
        if grantedSet.isEmpty { return .allow }
        let satisfied = required.contains { grantedSet.contains($0.name) }
        if satisfied { return .allow }

        let need = required.map(\.name).joined(separator: " | ")
        return .deny(
            reason: "tool '\(toolName)' requires connector scope [\(need)]; granted [\(grantedSet.sorted().joined(separator: ", "))]"
        )
    }
}
