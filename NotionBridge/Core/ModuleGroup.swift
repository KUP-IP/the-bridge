// ModuleGroup.swift — PKT-877 (Bridge v3.6·2)
// NotionBridge · Core
//
// `ModuleGroup` is the visual + behavioural grouping the Tools page uses
// in v3.6·2. It is derived from tool-name prefix at runtime so that adding
// a new tool that follows the convention automatically falls into the
// right group; the explicit-override annotation handles edge cases.
//
// SAFETY CONTRACT (W3): `ToolRouter.dispatch` checks the group-enabled
// state before routing. A tool that belongs to a disabled group MUST
// return a structured `BridgeToolError.moduleGroupDisabled` — silent
// failure is unacceptable. This file owns the grouping + state-derivation
// logic; the router consumes `ModuleGroupGate` (see below) at dispatch
// time.
//
// Locked decisions (per Notion packet):
//   Q1 — orphans auto-group as "system" (no tool left ungrouped).
//   Q2 — group enabled state DERIVED from per-tool state (no separate
//        persistence; no sync failure mode). The user-facing master
//        toggle writes per-tool disabled-state for every member, so the
//        existing `BridgeDefaults.disabledTools` array remains the single
//        source of truth for "is this tool currently allowed to run?".
//
// History:
//   v3.6·2 — W1: introduce ModuleGroup + prefix derivation + override
//            annotation, persisted disabled-groups key, and the pure
//            `ModuleGroupGate` consumed by the router (W3).

import Foundation

// MARK: - Identity

/// Stable identifier for a module group (display name + persistence key).
/// Groups are pre-declared rather than inferred so the UI gets stable
/// labels, accent colours, and dependency-hint copy. Adding a new prefix
/// requires adding a `ModuleGroupID` case AND a row in `prefixMap` below.
public enum ModuleGroupID: String, CaseIterable, Sendable, Hashable {
    case file
    case notion
    case messages
    case notes
    case contacts
    case reminders
    case calendar
    case memory
    case screen
    case chrome
    case stripe
    case applescript
    case accessibility
    case shell
    case credential
    case git
    case gh
    case snippets
    case jobs
    case skills
    case lsp
    case bgProcess
    case connections
    case devserver
    case clipboard
    case http
    case payment
    case synthetic
    case system

    /// Display name used in the Tools page group cards.
    public var displayName: String {
        switch self {
        case .file:          return "file"
        case .notion:        return "notion"
        case .messages:      return "messages"
        case .notes:         return "notes"
        case .contacts:      return "contacts"
        case .reminders:     return "reminders"
        case .calendar:      return "calendar"
        case .memory:        return "memory"
        case .screen:        return "screen"
        case .chrome:        return "chrome"
        case .stripe:        return "stripe"
        case .applescript:   return "applescript"
        case .accessibility: return "accessibility"
        case .shell:         return "shell"
        case .credential:    return "credential"
        case .git:           return "git"
        case .gh:            return "gh"
        case .snippets:      return "snippets"
        case .jobs:          return "jobs"
        case .skills:        return "skills"
        case .lsp:           return "lsp"
        case .bgProcess:     return "bg_process"
        case .connections:   return "connections"
        case .devserver:     return "devserver"
        case .clipboard:     return "clipboard"
        case .http:          return "http"
        case .payment:       return "payment"
        case .synthetic:     return "synthetic_input"
        case .system:        return "system"
        }
    }

    /// One-line subtitle shown under the group name on the card.
    public var subtitle: String {
        switch self {
        case .file:          return "local file I/O — sensitive-path-aware"
        case .notion:        return "workspace data sources, pages, comments"
        case .messages:      return "Messages.app — iMessage / SMS"
        case .notes:         return "Apple Notes — list, read, write, search"
        case .contacts:      return "handle resolution for relationship work"
        case .reminders:     return "iCloud Reminders — list, create, complete"
        case .calendar:      return "Calendar — list, query events, create/update/delete"
        case .memory:        return "unified memory — remember + salience-ranked recall"
        case .screen:        return "capture, OCR, recording"
        case .chrome:        return "tab inspection, JS exec, navigation"
        case .stripe:        return "billing, payments, customers"
        case .applescript:   return "arbitrary script execution — power-user only"
        case .accessibility: return "AX tree, focus, action perform"
        case .shell:         return "shell + run_script"
        case .credential:    return "Keychain credential I/O"
        case .git:           return "local git plumbing — log, diff, worktree"
        case .gh:            return "GitHub CLI wrappers — PRs, issues, runs"
        case .snippets:      return "saved snippet library"
        case .jobs:          return "scheduled job CRUD + run"
        case .skills:        return "skill index — fetch, create, sync"
        case .lsp:           return "language server — hover, refs, rename"
        case .bgProcess:     return "background process supervision"
        case .connections:   return "connection inventory + health"
        case .devserver:     return "dev server lifecycle"
        case .clipboard:     return "pasteboard read/write"
        case .http:          return "outbound HTTP fetch"
        case .payment:       return "payment execution"
        case .synthetic:     return "synthetic input — keyboard / mouse / cgevent"
        case .system:        return "session, system info, tools list, misc"
        }
    }

    /// SF Symbol used in the group card icon.
    public var systemImage: String {
        switch self {
        case .file:          return "doc.fill"
        case .notion:        return "n.square.fill"
        case .messages:      return "bubble.left.and.bubble.right.fill"
        case .notes:         return "note.text"
        case .contacts:      return "person.crop.circle.fill"
        case .reminders:     return "checklist"
        case .calendar:      return "calendar"
        case .memory:        return "brain"
        case .screen:        return "rectangle.on.rectangle"
        case .chrome:        return "globe"
        case .stripe:        return "dollarsign.circle.fill"
        case .applescript:   return "applescript"
        case .accessibility: return "figure.wave"
        case .shell:         return "terminal.fill"
        case .credential:    return "key.fill"
        case .git:           return "arrow.triangle.branch"
        case .gh:            return "chevron.left.forwardslash.chevron.right"
        case .snippets:      return "scroll"
        case .jobs:          return "clock.badge.checkmark"
        case .skills:        return "sparkles"
        case .lsp:           return "text.alignleft"
        case .bgProcess:     return "gearshape.2"
        case .connections:   return "network"
        case .devserver:     return "server.rack"
        case .clipboard:     return "doc.on.clipboard"
        case .http:          return "antenna.radiowaves.left.and.right"
        case .payment:       return "creditcard.fill"
        case .synthetic:     return "cursorarrow.click"
        case .system:        return "gear"
        }
    }
}

// MARK: - Dependency hints

/// A cross-page dependency surfaced as a chip on the group card. Maps to
/// `BridgeDepLink` in the UI. `route` is the SettingsSection the chip
/// should jump to; the per-section anchor is optional.
public struct ModuleGroupDependency: Sendable, Equatable, Hashable {
    public enum Severity: Sendable, Equatable, Hashable {
        case info
        case bad
    }
    public let label: String
    public let route: String
    public let severity: Severity

    public init(label: String, route: String, severity: Severity = .info) {
        self.label = label
        self.route = route
        self.severity = severity
    }
}

// MARK: - Group instance

/// A concrete group derived from the live registry. `tools` is the sorted
/// list of tool names that belong to this group; `disabledNames` is the
/// subset that the user has currently switched off (per-tool state).
public struct ModuleGroup: Sendable, Equatable, Hashable, Identifiable {
    public let id: ModuleGroupID
    public let tools: [String]
    public let disabledNames: Set<String>
    public let dependencies: [ModuleGroupDependency]

    public init(
        id: ModuleGroupID,
        tools: [String],
        disabledNames: Set<String>,
        dependencies: [ModuleGroupDependency] = []
    ) {
        self.id = id
        // Sorted so derivation is stable across runs / test snapshots.
        self.tools = tools.sorted()
        self.disabledNames = disabledNames
        self.dependencies = dependencies
    }

    public var displayName: String { id.displayName }
    public var subtitle: String { id.subtitle }
    public var systemImage: String { id.systemImage }

    /// Count of currently-enabled tools in this group.
    public var enabledCount: Int { tools.count - disabledNames.intersection(tools).count }

    /// Total tools in this group.
    public var total: Int { tools.count }

    /// Master toggle state — derived (Q2). off if all members are disabled;
    /// on if none are disabled; partial otherwise.
    public var masterState: TripleStateLike {
        let disabledInGroup = disabledNames.intersection(tools).count
        if disabledInGroup == 0 { return .on }
        if disabledInGroup == tools.count { return .off }
        return .partial
    }
}

/// Mirror of `TripleState` (defined in BridgeThemeV2 — a SwiftUI file).
/// Kept here so this Core file does not import SwiftUI; the UI layer maps
/// between the two trivially.
public enum TripleStateLike: Sendable, Equatable {
    case off, partial, on
}

// MARK: - Override annotation

/// Edge-case path: a tool whose prefix doesn't match the group it
/// belongs to. Keyed by tool name; value is the target group. This is
/// intentionally small — the prefix convention is the rule, this is the
/// exception list (Q1's "explicit annotation can override").
public enum ModuleGroupOverride {

    /// Authored overrides for tools whose name prefix doesn't match
    /// their natural group. Extend cautiously: every entry is a hand-
    /// audited claim that the tool's actual surface fits the target
    /// group better than its prefix-derived default. Keys are tool
    /// names, values are the target `ModuleGroupID`.
    ///
    /// Audit trail (entry → reason):
    ///   • `applescript_exec` → applescript   (singleton, no shared prefix; explicit)
    ///   • `code_search`      → system         (orphan prefix; surface is system-wide grep)
    ///   • `diff_render`      → system         (pure rendering utility)
    ///   • `dir_create`       → file           (file-system mutation; "dir_" is the only such prefix)
    ///   • `fetch_skill`      → skills         (skill-index fetch, naturally a skills tool)
    ///   • `manage_skill`     → skills         (skill CRUD shim — predates skill_* split)
    ///   • `list_routing_skills` → skills      (legacy alias for skills_routing_list)
    ///   • `skills_routing_list` → skills      (skills routing inventory)
    ///   • `notify`           → system         (singleton notification primitive)
    ///   • `tools_list`       → system         (registry self-inspection)
    ///   • `session_info` / `session_clear` → system  (cross-cutting session ops)
    ///   • `system_info`      → system         (canonical)
    ///   • `process_list`     → system         (top-level supervision)
    ///   • `port_inspect`     → system         (network primitive but read-only and system-level)
    ///   • `spotlight_query`  → system         (system search)
    ///   • `permissions_status` → system       (TCC grant self-inspection; cross-cutting, read-only)
    ///   • `tree_sitter_query` → system        (parser utility — not LSP)
    ///   • `pasteboard_history` → clipboard    (pasteboard surface)
    ///   • `cgevent_send`     → synthetic      (synthetic-input primitive)
    ///   • `keyboard_type`    → synthetic
    ///   • `mouse_click`      → synthetic
    ///   • `payment_execute`  → payment
    ///   • `vitest_run` / `playwright_run` / `lighthouse_run` → system  (dev test runners; group as system to avoid 1-tool "vitest"/"playwright"/"lighthouse" groups)
    ///   • `run_script`       → shell          (shell-adjacent)
    ///   • `http_fetch`       → http
    ///   • `stripe_reconnect` → stripe
    public static let map: [String: ModuleGroupID] = [
        "applescript_exec":     .applescript,
        "code_search":          .system,
        "diff_render":          .system,
        "dir_create":           .file,
        "fetch_skill":          .skills,
        "manage_skill":         .skills,
        "list_routing_skills":  .skills,
        "skills_routing_list":  .skills,
        "notify":               .system,
        "tools_list":           .system,
        "session_info":         .system,
        "session_clear":        .system,
        "system_info":          .system,
        "process_list":         .system,
        "port_inspect":         .system,
        "spotlight_query":      .system,
        "permissions_status":   .system,
        "tree_sitter_query":    .system,
        "pasteboard_history":   .clipboard,
        "cgevent_send":         .synthetic,
        "keyboard_type":        .synthetic,
        "mouse_click":          .synthetic,
        "payment_execute":      .payment,
        "vitest_run":           .system,
        "playwright_run":       .system,
        "lighthouse_run":       .system,
        "run_script":           .shell,
        "http_fetch":           .http,
        "stripe_reconnect":     .stripe,
    ]
}

// MARK: - Prefix derivation

public enum ModuleGroupDerivation {

    /// First-token prefix → `ModuleGroupID`. The convention is "the part
    /// before the first underscore" for the multi-tool prefixes; the
    /// override map handles singletons and the legacy renames.
    ///
    /// The mapping intentionally does not cover every possible prefix —
    /// any prefix not listed here triggers a fall-through to the `system`
    /// catch-all, which is the locked Q1 decision.
    public static let prefixMap: [String: ModuleGroupID] = [
        "file":        .file,
        "notion":      .notion,
        "messages":    .messages,
        "notes":       .notes,
        "contacts":    .contacts,
        "reminders":   .reminders,
        "calendar":    .calendar,
        "memory":      .memory,
        "screen":      .screen,
        "chrome":      .chrome,
        "stripe":      .stripe,
        "applescript": .applescript,
        "ax":          .accessibility,
        "shell":       .shell,
        "credential":  .credential,
        "git":         .git,
        "gh":          .gh,
        "snippets":    .snippets,
        "job":         .jobs,
        "jobs":        .jobs,
        "skill":       .skills,
        "skills":      .skills,
        "lsp":         .lsp,
        "bg":          .bgProcess,
        "connections": .connections,
        "devserver":   .devserver,
        "clipboard":   .clipboard,
    ]

    /// Resolve a single tool name to its `ModuleGroupID`. Order:
    ///   1) Explicit override wins (handles legacy / singleton names).
    ///   2) Prefix lookup (first underscore-separated token).
    ///   3) `.system` catch-all (Q1: no tool left ungrouped).
    public static func resolve(toolName: String) -> ModuleGroupID {
        if let override = ModuleGroupOverride.map[toolName] {
            return override
        }
        let first = toolName.split(separator: "_", maxSplits: 1).first.map(String.init) ?? toolName
        if let g = prefixMap[first] { return g }
        return .system
    }

    /// Default dependency hints per group. The actual permission/credential
    /// availability is a UI concern (chip variant); this is only the
    /// declarative authoring of the chips themselves so the data side is
    /// testable without rendering.
    public static func defaultDependencies(for id: ModuleGroupID) -> [ModuleGroupDependency] {
        switch id {
        case .file:
            return [
                ModuleGroupDependency(label: "Full Disk Access", route: "permissions"),
                ModuleGroupDependency(label: "Sensitive Paths list", route: "permissions"),
            ]
        case .notion:
            return [
                ModuleGroupDependency(label: "Notion credential", route: "credentials"),
                ModuleGroupDependency(label: "Notion connection", route: "connections"),
            ]
        case .messages:
            return [ModuleGroupDependency(label: "Full Disk Access", route: "permissions") ]
        case .notes:
            // Notes is driven over Apple events; the per-app Notes Automation
            // grant is a macOS first-use operator prompt (no entitlement change).
            return [ModuleGroupDependency(label: "Automation", route: "permissions") ]
        case .contacts:
            return [ModuleGroupDependency(label: "Contacts permission", route: "permissions") ]
        case .reminders:
            return [ModuleGroupDependency(label: "Reminders permission", route: "permissions") ]
        case .calendar:
            return [ModuleGroupDependency(label: "Calendar permission", route: "permissions") ]
        case .screen:
            return [ModuleGroupDependency(label: "Screen Recording", route: "permissions") ]
        case .chrome:
            return [
                ModuleGroupDependency(label: "Accessibility", route: "permissions"),
                ModuleGroupDependency(label: "Screen Recording", route: "permissions"),
            ]
        case .stripe:
            return [ModuleGroupDependency(label: "Stripe credential", route: "credentials") ]
        case .applescript:
            return [ModuleGroupDependency(label: "Automation", route: "permissions") ]
        case .accessibility:
            return [ModuleGroupDependency(label: "Accessibility", route: "permissions") ]
        case .credential:
            return [ModuleGroupDependency(label: "Keychain credentials feature", route: "credentials") ]
        case .synthetic:
            return [ModuleGroupDependency(label: "Accessibility", route: "permissions") ]
        case .clipboard:
            return [] // no special permission on macOS 26+
        default:
            return []
        }
    }

    /// Resolve a deep-link ANCHOR (a Tools dep-link chip's `anchor`, which is a
    /// lowercased tool-MODULE name such as "chrome" / "notion" / "ax" / a single
    /// tool's module) to the `ModuleGroupID` whose card the chip should scroll to
    /// and expand. Resolution order:
    ///   1) If a live registered tool's `module` (lowercased) equals the anchor,
    ///      resolve THAT tool's group — this is authoritative because the Tools
    ///      list groups by `resolve(toolName:)`, and a module's tools all share a
    ///      group. (If the chip references a single tool, the group containing it
    ///      is returned — the instruction's "expand the group that contains it".)
    ///   2) Else, if the anchor matches a `ModuleGroupID.rawValue` directly, use
    ///      it (covers anchors that already are a group id but have no live tool
    ///      whose `module` string matches verbatim).
    ///   3) Else `nil` — no group to land on (e.g. an orphaned credential whose
    ///      module registers no live tools); callers no-op gracefully.
    ///
    /// `nil`/empty anchor → `nil`. Pure (no SwiftUI) so it is unit-testable.
    public static func groupID(
        forAnchor anchor: String?,
        registeredTools: [(name: String, module: String)]
    ) -> ModuleGroupID? {
        guard let raw = anchor?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        // 1) Live-tool module match → that tool's derived group.
        if let tool = registeredTools.first(where: { $0.module.lowercased() == raw }) {
            return resolve(toolName: tool.name)
        }
        // 2) Direct group-id match.
        if let direct = ModuleGroupID(rawValue: raw) { return direct }
        // 3) No mapping.
        return nil
    }

    /// Build the full group list from a set of registered tool names and
    /// the user's per-tool disabled set. Groups are returned in a stable,
    /// design-aligned order; empty groups are dropped (a group with zero
    /// member tools has nothing to show and should not render).
    public static func deriveGroups(
        registeredToolNames: [String],
        disabledNames: Set<String>
    ) -> [ModuleGroup] {
        // Bucket tool names by resolved group.
        var bucket: [ModuleGroupID: [String]] = [:]
        for name in registeredToolNames {
            let id = resolve(toolName: name)
            bucket[id, default: []].append(name)
        }
        // Preserve the declared `ModuleGroupID.allCases` order so the UI
        // gets a stable, design-aligned layout.
        return ModuleGroupID.allCases.compactMap { id in
            guard let tools = bucket[id], !tools.isEmpty else { return nil }
            return ModuleGroup(
                id: id,
                tools: tools,
                disabledNames: disabledNames,
                dependencies: defaultDependencies(for: id)
            )
        }
    }
}

// MARK: - Dispatch-time gate (THE SAFETY CONTRACT)

/// The pure, dispatch-side check the router uses to fail closed when an
/// entire group has been disabled. This intentionally consumes the same
/// derivation as the UI so the two views of "is group X disabled?" cannot
/// drift apart.
///
/// Semantics (Q2):
///   • A group is considered DISABLED when **every** tool registered to
///     that group is in `disabledNames`. This is the only safe definition
///     given derived state — a "partial" group still has at least one
///     enabled tool the router must serve.
///   • The router calls `isToolGated(name:registered:disabled:)`; a true
///     return means "throw `BridgeToolError.moduleGroupDisabled`".
public enum ModuleGroupGate {

    /// Pure check: would dispatching `toolName` be blocked because its
    /// entire group has been switched off?
    public static func isToolGated(
        toolName: String,
        registeredToolNames: [String],
        disabledNames: Set<String>
    ) -> (gated: Bool, groupID: ModuleGroupID) {
        let id = ModuleGroupDerivation.resolve(toolName: toolName)
        // Only fail closed if EVERY member of the group is currently off.
        // A partial group still has live tools the router must serve.
        let members = registeredToolNames.filter {
            ModuleGroupDerivation.resolve(toolName: $0) == id
        }
        guard !members.isEmpty else { return (false, id) }
        let allDisabled = members.allSatisfy { disabledNames.contains($0) }
        return (allDisabled, id)
    }
}
