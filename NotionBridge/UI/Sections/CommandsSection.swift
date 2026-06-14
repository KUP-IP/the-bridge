// CommandsSection.swift — Settings → Orders ▸ Commands tab body.
// PKT-6 UI v3.5 · Commands redesign (bundle-2) · Settings-Redesign PKT-orders:
//
// Was a standalone hero-led pane; now the Commands TAB body inside the merged
// Orders page. The hero + its master switch + stat tiles are gone (the composite
// header + meta row carry them). The outer ScrollView and the `minHeight: 560`
// floor are removed so ONLY the two master-detail columns scroll — the editor
// owns the full tab height. The global-shortcut card is slimmed to a single
// inline row above the editor.
//
// The `commands` array + `selectedSlug` are owned by the composite (OrdersSection)
// and passed in as bindings so the meta-row stat counts stay live with this
// pane's CRUD. Every other binding is preserved: CommandStore CRUD, the
// palette-enabled toggle (now in the composite meta row), the icon/color picker,
// favorite-slot assignment, clipboard-copy, and the live hot-key recorder.

import AppKit
import SwiftUI

public struct CommandsSection: View {
    @Binding private var commands: [CommandStore.Command]
    @Binding private var selectedSlug: String?

    /// cmd-ux W1: the single observable source of truth for the global
    /// hot-key — injected on the Settings root window. Reading its
    /// `@Observable` properties inside the body registers a dependency so the
    /// shortcut row's combo glyph + status re-render the instant a rebind /
    /// (un)registration moves the state. A nil controller degrades to the
    /// persisted value + a generic status.
    @Environment(CommandsController.self) private var commandsController: CommandsController?

    /// The palette master state — read here only to color the shortcut status
    /// row truthfully (the toggle itself lives in the composite meta row).
    @AppStorage(BridgeDefaults.commandsPaletteEnabled) private var paletteEnabled: Bool = true

    /// cmd-ux W2 — Change B: when true the recorder field is capturing.
    @State private var isRecordingHotkey = false

    public init(
        commands: Binding<[CommandStore.Command]>,
        selectedSlug: Binding<String?>
    ) {
        self._commands = commands
        self._selectedSlug = selectedSlug
    }

    public var body: some View {
        // No outer ScrollView and no minHeight floor: the master-detail owns the
        // full tab height; only its two columns scroll internally (fix U4).
        VStack(spacing: 10) {
            shortcutRow
            CommandsEditorView(
                commands: $commands,
                selectedSlug: $selectedSlug
            )
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    // MARK: - Global shortcut (slim inline row above the editor)

    /// The global-shortcut control, slimmed from a full glass card to one
    /// inline row: the trigger combo recorder + the live registration status.
    /// The recorder + status are driven by the OBSERVED `CommandsController`.
    private var shortcutRow: some View {
        BridgeGlassCard {
            HStack(alignment: .center, spacing: BridgeTokens.Space.s4) {
                ZStack {
                    Circle()
                        .fill(BridgeTokens.chipFill)
                        .overlay(Circle().strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
                    Image(systemName: "command")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BridgeTokens.accentLink)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Global shortcut")
                        .font(BridgeTokens.Typeface.base600)
                        .foregroundStyle(BridgeTokens.fg1)
                    statusLine
                }
                Spacer(minLength: 12)
                if isCollision {
                    Button("Retry") {
                        _ = (NSApp.delegate as? AppDelegate)?.retryHotkeyRegistration()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Re-attempt registering the current shortcut — a transient collision may have cleared.")
                }
                HotkeyRecorderField(
                    currentDisplay: hotkeyConfig.displayString,
                    isRecording: $isRecordingHotkey,
                    onCapture: handleCapture
                )
                .frame(width: 150, height: 30)
                .help("The system-wide chord that opens the Command Bridge. Click to record a new one.")
                .accessibilityLabel("Command Bridge global shortcut")
            }
        }
    }

    /// The live status line beneath the title. Reads the structured
    /// `lastRegisterStatus` from the observed controller and maps it via the
    /// pure `CommandsSettingsStatus` model.
    @ViewBuilder
    private var statusLine: some View {
        let status = settingsStatus
        HStack(spacing: 6) {
            BridgeStatusDot(status.isWarning ? .warn : .ok, size: 7)
            Text(status.message)
                .font(BridgeTokens.Typeface.meta.weight(.medium))
                .foregroundStyle(status.isWarning ? BridgeTokens.warnText : BridgeTokens.fg3)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(status.message)
        }
    }

    // MARK: - Observed state (mirrors SettingsView's controller-or-fallback ladder)

    private var hotkeyConfig: HotkeyConfig {
        if let c = commandsController { return c.hotkeyConfig }
        return (NSApp.delegate as? AppDelegate)?.commandsHotkeyConfig ?? HotkeyConfig.loadPersisted()
    }

    private var lastRegisterStatus: HotkeyRegisterStatus {
        // Observe the controller for reactivity, but trust the live box (via
        // the AppDelegate) for the VALUE — the mirror can be transiently reset
        // to .unattempted by a registrar-less setEnabled while the Carbon
        // hot-key is in fact registered. Mirrors the hotkeyConfig fallback above
        // (which previously had this fallback and lastRegisterStatus did not —
        // that asymmetry is the "Shortcut not active" lie).
        let observed = commandsController?.lastRegisterStatus
        return (NSApp.delegate as? AppDelegate)?.commandsLastRegisterStatus ?? observed ?? .unattempted
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

    // MARK: - Capture handler (chord → validated config → live rebind)

    private func handleCapture(keyCode: UInt32, cocoaMods: NSEvent.ModifierFlags) -> Bool {
        guard let cfg = HotkeyConfig.from(keyCode: keyCode, cocoaModifiers: cocoaMods) else {
            return false
        }
        _ = (NSApp.delegate as? AppDelegate)?.setCommandsHotkey(cfg)
        return true
    }
}
