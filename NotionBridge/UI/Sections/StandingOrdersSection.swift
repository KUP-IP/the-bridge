// StandingOrdersSection.swift — Settings → Commands (the command-palette manager).
// PKT-9 UI v3.5 · v3.7.6 redesign · Settings-Redesign PKT-orders · IA change 2026-06-12:
//
// This file hosts the `OrdersSection` page — the focused **Commands** manager.
// The v4 IA split the merged "Orders & Commands" page apart: the standing-orders
// doctrine moved OUT to Connection's "Agent handshake" (where it is store-backed
// and handed to clients at connect), and this page is now COMMANDS ONLY — the
// command library you fire from the Command Bridge (⌃⌘B). The old Orders|Commands
// tab strip, the doctrine sub-area body, and all of its draft/snapshot/routing
// state are gone.
//
// The enum case + rawValue keep the legacy `.orders` / "Standing Orders" id so
// existing MCP `bridge_settings_navigate` deep-links still resolve — only the UI
// label (sidebar + title bar) is "Commands". The on-disk standing-orders store,
// the standing_orders_* MCP tools, and the doctrine editor all still exist; the
// editable global doctrine now lives in ConnectionsSection.

import SwiftUI
import AppKit

// MARK: - Commands page (bespoke single-surface — the command-palette manager)

/// The **Commands** Settings page (v4 consolidated header): a single header
/// container (`commandsHeader`) holding the title, a LIVE status-indicator
/// subtitle (ok/warn dot + the real global-shortcut state — replaces the old
/// description), the relocated recordable shortcut editor trailing the title
/// row, and a compact controls row (Command Bridge master switch +
/// command/favorite counts) — then the command master–detail filling the
/// remaining height. The old `BridgeSettingsSectionHeader` + separate
/// `.cmdp-meta` shortcut row are folded into the one container per operator
/// direction (no doctrine — that moved to Connection).
public struct OrdersSection: View {
    /// Deep-link anchor (e.g. `commands`) — retained for back-compat with the old
    /// merged page's tab anchors; this page is commands-only so it has no effect
    /// on which sub-surface shows, but the parameter stays so existing nav calls
    /// (`SettingsNavigation.shared.go(.orders, anchor: "commands")`) compile.
    let anchor: String?

    // ── Commands page persistent state ──────────────────────────────────────
    @AppStorage(BridgeDefaults.commandsPaletteEnabled) private var paletteEnabled: Bool = true
    @State private var commands: [CommandStore.Command] = []
    @State private var selectedSlug: String? = nil

    /// cmd-ux W1: the single observable source of truth for the global hot-key —
    /// injected on the Settings root window. Reading its `@Observable` properties
    /// inside the body registers a dependency so the header's status-indicator
    /// subtitle + the shortcut editor's glyph re-render the instant a rebind /
    /// (un)registration moves the state. A nil controller degrades to the
    /// persisted value + a generic status.
    @Environment(CommandsController.self) private var commandsController: CommandsController?

    /// cmd-ux W2 — Change B: when true the meta-row recorder field is capturing.
    @State private var isRecordingHotkey = false

    public init(anchor: String?) {
        self.anchor = anchor
    }

    public var body: some View {
        VStack(spacing: 0) {
            commandsHeader
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, BridgeTokens.Space.cardGap)
                .padding(.bottom, 12)

            Divider().background(BridgeTokens.hairlineFaint)

            CommandsSection(
                commands: $commands,
                selectedSlug: $selectedSlug
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
    }

    // MARK: Consolidated header (title + live-status subtitle + hotkey editor)
    //
    //   Operator direction (v4 IA): the global shortcut is folded INTO the title
    //   container, not a separate row/banner. The description subtitle is gone;
    //   in its place is a LIVE status-indicator subtitle (ok/warn dot + the real
    //   global-shortcut state). The recordable shortcut control (set / record /
    //   clear via HotkeyRecorderField) trails the title row inside the SAME
    //   BridgeGlassCard. A compact controls row (Command Bridge master switch +
    //   command/favorite counts) sits beneath, still inside the card. The old
    //   `BridgeSettingsSectionHeader` + separate `.cmdp-meta` shortcut row are
    //   replaced by this single container; all CommandStore/CommandsController
    //   wiring + the HotkeyRecorderField machinery are RELOCATED, not rewritten.

    private var commandsHeader: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .orders)
        return BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                // Title row: icon tile + (title + live status subtitle) + the
                // relocated hotkey editor trailing the row.
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(spec.tint.opacity(0.20))
                            .frame(width: 44, height: 44)
                        Image(systemName: spec.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(spec.tint.opacity(0.85))
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Commands")
                            .font(.system(size: 18, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        statusSubtitle
                    }

                    Spacer(minLength: 12)

                    shortcutEditor
                }

                Divider().background(BridgeTokens.hairlineFaint)

                // Compact controls row: master switch + live counts.
                HStack(spacing: 12) {
                    commandBridgeSwitch
                    Spacer(minLength: 8)
                    metaStat(value: "\(commands.count)", label: "commands", color: BridgeTokens.accentLink)
                    metaStat(value: "\(favoriteCount)", label: "favorites", color: BridgeTokens.gold)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Live status-indicator subtitle (replaces the description)

    /// The status line under the "Commands" title — driven by the REAL
    /// shortcut/registration state observed via `CommandsController` /
    /// `AppDelegate` (the same `settingsStatus` the warn dot used). Active ⇒
    /// an ok dot + "Global shortcut · ⌃⌘B"; inactive ⇒ a warn dot + a record
    /// prompt (a true collision names the combo). Disabled ⇒ a neutral dot.
    private var statusSubtitle: some View {
        let s = settingsStatus
        return HStack(spacing: 7) {
            BridgeStatusDot(s.indicatorSignal, size: 7)
            Text(s.indicatorText)
                .font(.system(size: 12))
                .foregroundStyle(s.isWarning ? BridgeTokens.warnText : BridgeTokens.fg3)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Global shortcut status: \(s.message)")
    }

    // MARK: Relocated hotkey editor (set / record / clear) — trails the title

    /// The recordable shortcut control folded INTO the title container (not a
    /// separate row/banner). The `HotkeyRecorderField` capture machinery is
    /// preserved verbatim — only its host moved. A Retry button surfaces on a
    /// transient collision; the recorder itself handles set / record, and a
    /// re-record replaces the bind.
    private var shortcutEditor: some View {
        HStack(spacing: 8) {
            HotkeyRecorderField(
                currentDisplay: hotkeyConfig.displayString,
                isRecording: $isRecordingHotkey,
                onCapture: handleCapture
            )
            .frame(width: 132, height: 28)
            .help("The system-wide chord that opens the Command Bridge. Click to record a new one.")
            .accessibilityLabel("Command Bridge global shortcut")
            .accessibilityValue(settingsStatus.message)
            if isCollision {
                Button("Retry") {
                    _ = (NSApp.delegate as? AppDelegate)?.retryHotkeyRegistration()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-attempt registering the current shortcut — a transient collision may have cleared.")
            }
        }
    }

    private func metaStat(value: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(BridgeTokens.Typeface.body.monospaced())
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(BridgeTokens.Typeface.cap)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    /// The Command Bridge master switch — a LABELED control (the hero toggle had
    /// only a tooltip). Destructive-global affordance deserves a visible label +
    /// a11y label.
    private var commandBridgeSwitch: some View {
        HStack(spacing: 8) {
            Text("Command Bridge")
                .font(BridgeTokens.Typeface.meta.weight(.medium))
                .foregroundStyle(BridgeTokens.fg2)
            Toggle("", isOn: $paletteEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: paletteEnabled) { _, newValue in
                    (NSApp.delegate as? AppDelegate)?.setCommandsPaletteEnabled(newValue)
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .help("Enable the global Command Bridge popup hot-key.")
        .accessibilityLabel("Command Bridge global hot-key")
        .accessibilityValue(paletteEnabled ? "on" : "off")
    }

    // MARK: - Observed hot-key state (mirrors the controller-or-fallback ladder)

    private var hotkeyConfig: HotkeyConfig {
        if let c = commandsController { return c.hotkeyConfig }
        return (NSApp.delegate as? AppDelegate)?.commandsHotkeyConfig ?? HotkeyConfig.loadPersisted()
    }

    private var lastRegisterStatus: HotkeyRegisterStatus {
        // STATUS-TRUTH FIX (v4): the displayed VALUE must come from the OBSERVED
        // `CommandsController` — the single source of truth that EVERY launch /
        // launch-retry / live-enable / rebind path pushes the real outcome into
        // via `publishRegistration`. The earlier ladder read the value from the
        // AppDelegate's `commandBridge` box, which is NOT @Observable: the launch
        // `publishRegistration(.registered)` fires before any SwiftUI observer
        // exists, so reading the non-observable box gave the header a value with
        // NO Observation dependency to ever refresh it — it latched whatever it
        // happened to read first and showed a false "⚠ Shortcut not active".
        //
        // Reading `commandsController.lastRegisterStatus` here registers a real
        // Observation dependency on the value we actually render, so the header
        // re-renders to Active the instant the controller publishes .registered.
        // The box (via the AppDelegate) is only a fallback for a host that never
        // injected the controller. The registrar-nil "transient reset" the old
        // comment feared cannot be observed: `setCommandsPaletteEnabled` always
        // re-publishes the real status synchronously in the SAME MainActor call.
        if let c = commandsController { return c.lastRegisterStatus }
        return (NSApp.delegate as? AppDelegate)?.commandsLastRegisterStatus ?? .unattempted
    }

    private var settingsStatus: CommandsSettingsStatus {
        CommandsSettingsStatus(
            enabled: paletteEnabled,
            lastRegisterStatus: lastRegisterStatus,
            hotkey: hotkeyConfig.displayString
        )
    }

    private var isCollision: Bool {
        if case .collision = lastRegisterStatus { return true }
        return false
    }

    /// Chord → validated config → live rebind. Preserved verbatim from the old
    /// `CommandsSection.shortcutRow` capture path.
    private func handleCapture(keyCode: UInt32, cocoaMods: NSEvent.ModifierFlags) -> Bool {
        guard let cfg = HotkeyConfig.from(keyCode: keyCode, cocoaModifiers: cocoaMods) else {
            return false
        }
        _ = (NSApp.delegate as? AppDelegate)?.setCommandsHotkey(cfg)
        return true
    }

    private var favoriteCount: Int { commands.filter { $0.keySlot != nil }.count }
}

// MARK: - Status → header indicator (UI mapping, kept out of the pure model)

/// Maps the pure `CommandsSettingsStatus` to the consolidated header's
/// status-indicator subtitle: a signal color for the dot + a compact line.
/// This lives in the UI layer (it returns a `BridgeSignal`) so the pure
/// `CommandsSettingsStatus` model in CommandPalette.swift stays free of any
/// UI-kit coupling.
private extension CommandsSettingsStatus {
    /// The dot color: ok when the shortcut is live, warn for any failure,
    /// neutral when the Command Bridge is disabled.
    var indicatorSignal: BridgeSignal {
        switch self {
        case .active:             return .ok
        case .disabled:           return .neutral
        case .shortcutUnavailable, .comboInUse, .registrationFailed:
            return .warn
        }
    }

    /// The compact subtitle text. Active reads "Global shortcut · ⌃⌘B";
    /// inactive prompts a record (a true collision names the conflicting
    /// combo); disabled states the Command Bridge is off.
    var indicatorText: String {
        switch self {
        case .active(let hotkey):
            return "Global shortcut · \(hotkey)"
        case .shortcutUnavailable, .registrationFailed:
            return "Shortcut not active — record one"
        case .comboInUse(let hotkey):
            return "\(hotkey) is in use — record a different shortcut"
        case .disabled:
            return "Command Bridge is off"
        }
    }
}
