// CommandPalette.swift — cmd-w3 (Commands palette: search + gate + wiring)
// NotionBridge · Modules · Commands
//
// This consumes the GUI shell (CommandBox.swift — Carbon hot-key +
// non-activating NSPanel + a single clipboard write) and the W2 data
// layer (CommandsManager — /markdown fetch + mention resolve + TTL
// cache + offline-fallback). This file owns the GUI-FREE glue that
// joins them, all of it headlessly testable:
//
//   1. CommandDescriptor          — palette-row metadata (id/name/abbr/
//                                    group/tags). The BODY is NOT held
//                                    here; it is fetched on Enter via
//                                    CommandsManager (same metadata-vs-
//                                    body split a SKILL uses — see the
//                                    W2 data-source contract).
//   2. CommandDescriptorProviding — injectable source of the cached
//                                    descriptor list. Production wires an
//                                    operator-config provider (the real
//                                    Commands DS query is the SAME
//                                    deferred operator dependency W2
//                                    documented — out of scope here);
//                                    tests inject a synthetic list.
//   3. CommandPaletteSearch       — the pure fuzzy matcher + ranker over
//                                    the descriptor list. Deterministic
//                                    tie-break so ordering is testable.
//   4. CommandsPaletteGate        — the default-OFF opt-in gate, modelled
//                                    byte-for-byte on TransportRouter's
//                                    `== "1"` env pattern (BRIDGE_ENABLE_
//                                    COMMANDS). With it off the palette is
//                                    never constructed/registered.
//   5. CommandPaletteCoordinator  — the GUI-free decision core the GUI
//                                    controller delegates to: given a
//                                    typed query it returns ranked rows;
//                                    given a chosen descriptor it fetches
//                                    the resolved body via the injected
//                                    CommandsManager (NO duplicate fetch/
//                                    cache — it calls W2). Returns the
//                                    plain-text body the GUI shell writes
//                                    to the system clipboard.
//
// HONEST GUI CEILING (NOT papered over): the hot-key actually firing and
// the NSPanel receiving keystrokes require a live WindowServer/login
// session and cannot be asserted headlessly — an explicit operator
// manual-smoke. The clipboard WRITE itself is headlessly verified (write
// → read back via the ClipboardWriting seam). Everything in THIS file is
// pure and 100%-green-tested.

import Foundation

// ============================================================
// MARK: - 1. CommandDescriptor (palette-row metadata)
// ============================================================

/// One palette row. Metadata only — the command BODY is fetched lazily
/// from `CommandsManager` on selection (Enter), exactly like a SKILL
/// page body. Snippet/Command-shaped so it maps 1:1 onto a W2 `Command`.
public struct CommandDescriptor: Codable, Sendable, Equatable, Identifiable {
    /// Notion page id (dashed UUID) — the key `CommandsManager.body`/
    /// `.command` takes.
    public let id: String
    public var name: String
    /// Unique short trigger (e.g. "sig", "addr"). The strongest match key.
    public var abbreviation: String
    public var group: String
    public var tags: [String]

    public init(
        id: String,
        name: String,
        abbreviation: String,
        group: String = "General",
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
        self.group = group
        self.tags = tags
    }
}

/// Injectable source of the cached descriptor list. The default returns
/// an empty list (no operator DS wired = nothing to search — fail-safe,
/// never a crash); production injects an operator-config provider. The
/// REAL Commands-DS query is the same deferred operator dependency W2
/// documented (out of scope for this slice); the palette is verified
/// entirely against a synthetic injected provider with zero network.
public protocol CommandDescriptorProviding: Sendable {
    func descriptors() async -> [CommandDescriptor]
}

/// Static synthetic provider (test double + the safe production default).
public struct StaticCommandDescriptorProvider: CommandDescriptorProviding {
    private let list: [CommandDescriptor]
    public init(_ list: [CommandDescriptor] = []) { self.list = list }
    public func descriptors() async -> [CommandDescriptor] { list }
}

// ============================================================
// MARK: - 2. CommandPaletteSearch (pure fuzzy match + rank)
// ============================================================

/// One scored palette row.
public struct ScoredCommand: Equatable, Sendable {
    public let descriptor: CommandDescriptor
    /// Higher = better. Pure function of (query, descriptor); deterministic.
    public let score: Int
    public init(descriptor: CommandDescriptor, score: Int) {
        self.descriptor = descriptor
        self.score = score
    }
}

/// Pure fuzzy matcher + ranker. No GUI, no state, fully deterministic.
///
/// Scoring (highest wins), evaluated against `abbreviation` and `name`
/// (case-insensitive). The abbreviation is the intended trigger so it
/// dominates the name on equal match strength:
///
///   • exact abbreviation match            → 1000
///   • abbreviation prefix match            →  800
///   • exact name match                     →  700
///   • name prefix match                    →  500
///   • subsequence (fuzzy) in abbreviation  →  300 − gapPenalty
///   • subsequence (fuzzy) in name          →  200 − gapPenalty
///   • subsequence in "group + tags" haystack → 100 − gapPenalty
///   • no subsequence anywhere              → not a result (filtered out)
///
/// An empty query returns ALL descriptors (score 0) so the palette can
/// show the full list before the user types. Ties break deterministically
/// by (score ↓, name ↑ case-insensitive, id ↑) so ordering is testable.
public enum CommandPaletteSearch {

    /// True iff every char of `needle` appears in `haystack` in order
    /// (the classic fuzzy/subsequence test). Both are pre-lowercased by
    /// the caller. Empty needle ⇒ trivially true. Public so the matching
    /// primitive itself is unit-assertable.
    public static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        if needle.isEmpty { return true }
        var i = 0
        for c in haystack {
            if c == needle[i] {
                i += 1
                if i == needle.count { return true }
            }
        }
        return false
    }

    /// Number of "gap" chars in `haystack` before the subsequence completes
    /// (a compactness proxy — fewer gaps = tighter match = better). Returns
    /// `nil` if `needle` is NOT a subsequence of `haystack`. Public so
    /// the compactness-ranking primitive is unit-assertable.
    public static func gapPenalty(_ needle: [Character], in haystack: [Character]) -> Int? {
        if needle.isEmpty { return 0 }
        var i = 0
        var firstMatchAt: Int? = nil
        var lastMatchAt = 0
        for (idx, c) in haystack.enumerated() {
            if i < needle.count, c == needle[i] {
                if firstMatchAt == nil { firstMatchAt = idx }
                lastMatchAt = idx
                i += 1
            }
        }
        guard i == needle.count, let first = firstMatchAt else { return nil }
        // Span minus matched chars = interleaved gap chars. Capped so a
        // huge haystack can't make a real match score negative.
        let span = lastMatchAt - first + 1
        let gaps = max(0, span - needle.count)
        return min(gaps, 90)
    }

    /// Score one descriptor for `rawQuery`. `nil` ⇒ filtered out (no match).
    /// Empty query ⇒ score 0 (everything shows).
    static func score(_ d: CommandDescriptor, query rawQuery: String) -> Int? {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return 0 }
        let needle = Array(q)
        let abbr = d.abbreviation.lowercased()
        let name = d.name.lowercased()
        let abbrChars = Array(abbr)
        let nameChars = Array(name)

        if abbr == q { return 1000 }
        if abbr.hasPrefix(q) { return 800 }
        if name == q { return 700 }
        if name.hasPrefix(q) { return 500 }
        if let p = gapPenalty(needle, in: abbrChars) { return 300 - p }
        if let p = gapPenalty(needle, in: nameChars) { return 200 - p }
        let haystack = Array(([d.group] + d.tags).joined(separator: " ").lowercased())
        if let p = gapPenalty(needle, in: haystack) { return 100 - p }
        return nil
    }

    /// Rank `descriptors` against `query`. Filters non-matches, sorts by
    /// the deterministic (score ↓, name ↑, id ↑) order. An empty query
    /// returns every descriptor in that same stable order.
    public static func rank(
        _ descriptors: [CommandDescriptor],
        query: String
    ) -> [ScoredCommand] {
        let scored: [ScoredCommand] = descriptors.compactMap { d in
            guard let s = score(d, query: query) else { return nil }
            return ScoredCommand(descriptor: d, score: s)
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let an = a.descriptor.name.lowercased()
            let bn = b.descriptor.name.lowercased()
            if an != bn { return an < bn }
            return a.descriptor.id < b.descriptor.id
        }
    }

    /// The single best match for `query`, or `nil` if nothing matches.
    /// Convenience for "type then Enter with no explicit selection".
    public static func best(
        _ descriptors: [CommandDescriptor],
        query: String
    ) -> CommandDescriptor? {
        rank(descriptors, query: query).first?.descriptor
    }
}

// ============================================================
// MARK: - 3. CommandsPaletteGate (default-OFF opt-in)
// ============================================================

/// The palette's gate. The Commands palette is now **ON by default**,
/// governed by a persisted Settings master toggle rather than env-only.
///
/// Effective-enabled precedence (first decisive rule wins):
///   1. env `BRIDGE_ENABLE_COMMANDS == "1"` → forced ON (any session).
///   2. env `BRIDGE_ENABLE_COMMANDS == "0"` → forced OFF (kill-switch).
///   3. otherwise → the persisted pref `commandsPaletteEnabled`, which
///      DEFAULTS TO TRUE when the key is absent (fresh install ⇒ ON).
///
/// Any other env value ("true", "yes", " 1", …) is NOT decisive — it
/// falls through to the persisted pref (the env var is a deliberate
/// force-on / force-off override, not a fuzzy flag).
///
/// Both the environment and the pref reader are injectable so the gate
/// stays a PURE value type, deterministically unit-testable headlessly
/// with no `ProcessInfo` / `UserDefaults` coupling.
public struct CommandsPaletteGate: Sendable, Equatable {

    /// Env var that force-overrides the palette. Named in the
    /// `BRIDGE_ENABLE_*` family alongside `BRIDGE_ENABLE_HTTP` /
    /// `BRIDGE_ENABLE_VOICE`. "1" forces ON, "0" forces OFF; absent /
    /// any other value defers to the persisted pref.
    public static let enableEnvKey = "BRIDGE_ENABLE_COMMANDS"

    /// The Settings master toggle's default when the key has never been
    /// written. The palette ships **ON**.
    public static let defaultEnabled = true

    public let isEnabled: Bool

    /// - Parameters:
    ///   - environment: process environment (injectable for tests).
    ///   - persistedPreference: the stored master-toggle value, or `nil`
    ///     if the key has never been written (⇒ use `defaultEnabled`).
    ///     A closure (not a captured `UserDefaults`) keeps the gate
    ///     `Sendable` under Swift 6 strict concurrency and lets tests
    ///     inject an exact value with zero process-global coupling.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistedPreference: () -> Bool? = {
            UserDefaults.standard.object(forKey: BridgeDefaults.commandsPaletteEnabled) as? Bool
        }
    ) {
        switch environment[Self.enableEnvKey] {
        case "1":
            self.isEnabled = true
        case "0":
            self.isEnabled = false
        default:
            self.isEnabled = persistedPreference() ?? Self.defaultEnabled
        }
    }
}

// ============================================================
// MARK: - 4. CommandPaletteCoordinator (GUI-free decision core)
// ============================================================

/// What happens when the user commits (Enter) on a query/selection.
public enum CommandPaletteCommitResult: Sendable, Equatable {
    /// Resolved body (plain text). The GUI shell writes this to the
    /// system clipboard (replace contents — no save/restore); the user
    /// pastes it themselves. The case name is retained for source/test
    /// stability — it now means "this is the body to put on the
    /// clipboard", NOT a synthetic paste into another app.
    case paste(String)
    /// The query matched no command — nothing to paste. The GUI shell
    /// keeps the panel open (no destructive paste of a wrong command).
    case notFound(query: String)
    /// A command matched but its body could not be fetched AND there was
    /// no offline-fallback cache (CommandsManager surfaced .unavailable).
    case unavailable(name: String, reason: String)
}

/// The headless core the GUI `CommandBoxController` delegates to. Holds
/// NO UI; joins the W2 `CommandsManager` (body fetch/cache — NOT
/// duplicated here) to the pure W3 search. Every method is pure-async
/// and unit-tested with a synthetic descriptor provider + an injected
/// `CommandsManager` fetcher (zero network).
public actor CommandPaletteCoordinator {

    private let provider: CommandDescriptorProviding
    private let manager: CommandsManager

    /// - Parameters:
    ///   - provider: cached descriptor list source (synthetic in tests).
    ///   - manager: the W2 data layer. The palette CONSUMES it for the
    ///     selected command's body — it never re-implements fetch/cache.
    public init(provider: CommandDescriptorProviding, manager: CommandsManager) {
        self.provider = provider
        self.manager = manager
    }

    /// Ranked rows for the current query (drives the live result list).
    public func search(_ query: String) async -> [ScoredCommand] {
        let list = await provider.descriptors()
        return CommandPaletteSearch.rank(list, query: query)
    }

    /// Commit on an explicit descriptor selection: fetch the resolved
    /// body via `CommandsManager` and return the plain text to paste.
    public func commit(_ descriptor: CommandDescriptor) async -> CommandPaletteCommitResult {
        do {
            let body = try await manager.body(forPageId: descriptor.id)
            return .paste(body)
        } catch let e as CommandsFetchError {
            switch e {
            case .unavailable(let why):
                return .unavailable(name: descriptor.name, reason: why)
            case .invalidPageId(let why):
                return .unavailable(name: descriptor.name, reason: "invalid page id: \(why)")
            }
        } catch {
            return .unavailable(name: descriptor.name, reason: "\(error)")
        }
    }

    /// Commit on a raw query with no explicit selection (type-then-Enter):
    /// pick the single best match, then fetch+resolve its body. Returns
    /// `.notFound` (NOT a paste) when the query matches nothing — the GUI
    /// must NOT paste a guessed command.
    public func commit(query: String) async -> CommandPaletteCommitResult {
        let list = await provider.descriptors()
        guard let best = CommandPaletteSearch.best(list, query: query) else {
            return .notFound(query: query)
        }
        return await commit(best)
    }
}

// ============================================================
// MARK: - 5. CommandPaletteSelection (pure ↑/↓ selection state)
//
//   The results-list selection state machine, extracted OUT of the
//   AppKit panel so it is exhaustively unit-testable headlessly. Given
//   a result count + an arrow input it yields the next selected index.
//   The AppKit table only RENDERS this — it owns no selection logic.
// ============================================================

/// A keyboard navigation input over the results list.
public enum CommandPaletteArrow: Sendable, Equatable {
    case up
    case down
}

/// Pure selection model for the live results list. Holds only an
/// integer index; all transitions are total functions (no GUI, no
/// state outside the index) so every edge — empty list, top/bottom
/// clamp, results shrinking under the cursor — is deterministically
/// assertable.
///
/// Policy (matches Spotlight/Raycast):
///   • Empty results        → `selectedIndex == nil` (nothing selected).
///   • Non-empty results     → top row (index 0) is PRESELECTED.
///   • ↓ at the bottom row   → stays on the bottom row (clamp, no wrap).
///   • ↑ at the top row      → stays on the top row (clamp, no wrap).
///   • Results change (user keeps typing) → selection is re-clamped
///     into `0..<count` (or cleared when the list becomes empty), so a
///     stale index can never point past the end.
public struct CommandPaletteSelection: Sendable, Equatable {

    public private(set) var count: Int
    private var index: Int?

    public init(count: Int = 0) {
        self.count = max(0, count)
        self.index = self.count > 0 ? 0 : nil
    }

    /// The currently selected row, or `nil` when there are no results.
    public var selectedIndex: Int? { index }

    /// Re-seat the model after the results list changed (the user typed
    /// another character). Preselects the top row; if a selection was
    /// already held it is clamped into the new range so it can never
    /// dangle past the end. An empty list clears the selection.
    public mutating func updateResultCount(_ newCount: Int) {
        let c = max(0, newCount)
        self.count = c
        guard c > 0 else { index = nil; return }
        if let i = index {
            index = min(max(0, i), c - 1)
        } else {
            index = 0
        }
    }

    /// Apply one arrow press. No-op on an empty list. Clamps at both
    /// ends (no wrap-around — matches the macOS palette convention).
    public mutating func move(_ arrow: CommandPaletteArrow) {
        guard count > 0, let i = index else { return }
        switch arrow {
        case .up:   index = max(0, i - 1)
        case .down: index = min(count - 1, i + 1)
        }
    }
}

// ============================================================
// MARK: - 6. CommandPalettePresentation (pure commit → UI message)
//
//   Maps a `CommandPaletteCommitResult` to the EXACT inline message
//   string the panel shows and whether the panel stays open. This is
//   the headlessly-verifiable core of the P2 "states + confirmation"
//   behaviour; the AppKit label/timer that renders it is the operator
//   manual-smoke ceiling (documented in CommandBox.swift's header).
// ============================================================

/// The pure result of presenting a commit outcome: the message text,
/// whether the panel should remain open, and (for `.paste`) whether an
/// auto-dismiss confirmation timer should run.
public struct CommandPalettePresentation: Sendable, Equatable {
    /// Inline status text to show in the panel.
    public let message: String
    /// True ⇒ keep the panel open (let the user retry / re-type).
    /// False ⇒ the body was copied; dismiss after the confirmation.
    public let staysOpen: Bool
    /// True ⇒ the body was written to the clipboard; the panel should
    /// flash this confirmation briefly then auto-dismiss.
    public let isConfirmation: Bool

    public init(message: String, staysOpen: Bool, isConfirmation: Bool) {
        self.message = message
        self.staysOpen = staysOpen
        self.isConfirmation = isConfirmation
    }
}

/// Pure mapping from commit outcomes / input edge-cases to the panel's
/// observable presentation. No GUI; total + deterministic so every
/// state is unit-asserted exhaustively.
public enum CommandPalettePresenter {

    /// The auto-dismiss delay (ms) for the "Copied ‹name›" confirmation.
    public static let confirmationDismissMillis = 900

    /// Empty-registry guidance shown when the palette opens with zero
    /// commands available.
    public static let emptyRegistryMessage =
        "No commands yet — add skills in Settings → Commands"

    /// Map a commit result to its presentation. `name` is the label to
    /// echo in the success confirmation (the selected/best descriptor's
    /// display name); ignored for the non-paste cases.
    public static func present(
        _ result: CommandPaletteCommitResult,
        name: String
    ) -> CommandPalettePresentation {
        switch result {
        case .paste:
            return CommandPalettePresentation(
                message: "Copied \(name)",
                staysOpen: false,
                isConfirmation: true
            )
        case .notFound(let query):
            return CommandPalettePresentation(
                message: "No match for \(query)",
                staysOpen: true,
                isConfirmation: false
            )
        case .unavailable(let unName, _):
            return CommandPalettePresentation(
                message: "\(unName) unavailable — offline?",
                staysOpen: true,
                isConfirmation: false
            )
        }
    }

    /// Presentation for an Enter on an empty query: a pure no-op —
    /// nothing copied, panel stays, no message.
    public static var emptyQueryNoOp: CommandPalettePresentation {
        CommandPalettePresentation(message: "", staysOpen: true, isConfirmation: false)
    }
}

// ============================================================
// MARK: - 7. CommandsSettingsStatus (pure Settings status-row model)
//
//   The Settings → Commands status row text/severity, factored out of
//   the SwiftUI view so the exact strings and the
//   enabled×registered→state mapping are unit-asserted headlessly.
// ============================================================

/// The status the Settings "Commands" section shows under the master
/// toggle. Pure value type so the four states and their exact copy are
/// deterministically testable without SwiftUI / a WindowServer.
public enum CommandsSettingsStatus: Sendable, Equatable {
    /// Toggle on, hot-key successfully registered. Carries the combo
    /// glyph (e.g. "⌃B") so the row reads "Active — ⌃B".
    case active(hotkey: String)
    /// Toggle on, but the global hot-key could NOT be registered
    /// (another app already owns the combo). Shown as a red warning.
    case shortcutUnavailable
    /// Toggle off — the palette is disabled by the user.
    case disabled

    /// - Parameters:
    ///   - enabled: the persisted master-toggle value.
    ///   - isRegistered: `CommandBoxController.isRegistered` (false when
    ///     the controller is absent OR registration failed).
    ///   - hotkey: the combo glyph to show in the active state.
    public init(enabled: Bool, isRegistered: Bool, hotkey: String) {
        if !enabled {
            self = .disabled
        } else if isRegistered {
            self = .active(hotkey: hotkey)
        } else {
            self = .shortcutUnavailable
        }
    }

    /// The exact row text.
    public var message: String {
        switch self {
        case .active(let hotkey): return "Active — \(hotkey)"
        case .shortcutUnavailable: return "⚠ Shortcut unavailable (in use by another app)"
        case .disabled: return "Disabled"
        }
    }

    /// True ⇒ render the row in the warning (red) treatment.
    public var isWarning: Bool {
        if case .shortcutUnavailable = self { return true }
        return false
    }
}
