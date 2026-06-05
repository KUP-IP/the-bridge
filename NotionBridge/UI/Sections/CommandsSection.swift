// CommandsSection.swift — Settings → Commands pane.
// PKT-6 UI v3.5 · Commands redesign (bundle-2): hero with ⌘ orb + stat tiles +
// the palette master switch, over a carbon canvas, hosting the alphabetical
// master-detail editor. Mirrors StandingOrdersSection's quality + approach and
// the locked design mockup (design/.../ui_kits/the-bridge/Commands.jsx).
//
// Source of truth for the command list + selection lives HERE so the hero stat
// tiles (commands / favorites) stay live with the editor's CRUD. All mutation
// logic remains in CommandsEditorView, which receives the array + selection as
// bindings. Every binding is preserved: CommandStore CRUD, the palette-enabled
// toggle, icon/color picker, favorite-slot assignment, clipboard-copy.

import AppKit
import SwiftUI

public struct CommandsSection: View {
    @AppStorage(BridgeDefaults.commandsPaletteEnabled)
    private var paletteEnabled: Bool = true

    @State private var commands: [CommandStore.Command] = []
    @State private var selectedSlug: String? = nil

    /// cmd-ux W1: the single observable source of truth for the global
    /// hot-key — injected on the Settings root window (see SettingsWindow
    /// `.environment(commandsController)`). Reading its `@Observable`
    /// properties inside the body registers a dependency so the shortcut
    /// card's combo glyph + status row re-render the instant a rebind /
    /// (un)registration moves the state. A nil controller (non-injected
    /// host, e.g. a preview) degrades to the persisted value + a generic
    /// status, mirroring SettingsView's fallback ladder.
    @Environment(CommandsController.self) private var commandsController: CommandsController?

    /// cmd-ux W2 — Change B: when true the recorder field is capturing;
    /// the next valid modifier+key chord becomes the new global combo.
    @State private var isRecordingHotkey = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                shortcutCard
                CommandsEditorView(
                    commands: $commands,
                    selectedSlug: $selectedSlug
                )
                .frame(minHeight: 560)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    // MARK: - Hero

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BridgeTokens.gold.opacity(0.22))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.gold.opacity(0.45), lineWidth: 1))
                    Text("⌘")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(BridgeTokens.gold)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Commands")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("Reusable prompts you fire from the Command Bridge. Assign a number to make one a one-keystroke favorite.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    statTile(value: "\(commands.count)", label: "commands", color: BridgeTokens.accentLink)
                    statTile(value: "\(favoriteCount)", label: "favorites", color: BridgeTokens.gold)
                }
                Toggle("", isOn: $paletteEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: paletteEnabled) { _, newValue in
                        (NSApp.delegate as? AppDelegate)?.setCommandsPaletteEnabled(newValue)
                    }
                    .help("Enable the global Command Bridge popup hot-key.")
            }
        }
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
    }

    private var favoriteCount: Int { commands.filter { $0.keySlot != nil }.count }

    // MARK: - Global shortcut card (cmd-ux W1/W2 — mounts the recorder)

    /// The "Global shortcut" card: shows the current combo, mounts the
    /// recorder field (`HotkeyRecorderField`), and renders the live
    /// registration status row below it. The recorder + status are driven
    /// by the OBSERVED `CommandsController` so they stay truthful the
    /// instant a rebind succeeds, collides, or fails.
    private var shortcutCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Global shortcut")

                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Trigger combo")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(BridgeTokens.fg1)
                        Text("The system-wide chord that opens the Command Bridge. Click to record a new one — hold modifiers and press a key.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    HotkeyRecorderField(
                        currentDisplay: hotkeyConfig.displayString,
                        isRecording: $isRecordingHotkey,
                        onCapture: handleCapture
                    )
                    .frame(width: 150, height: 30)
                }

                Divider().overlay(BridgeTokens.hairlineFaint)

                statusRow
            }
        }
    }

    /// The live status row beneath the recorder. Reads the structured
    /// `lastRegisterStatus` from the observed controller and maps it via
    /// the pure `CommandsSettingsStatus` model (so a true Carbon collision
    /// reads differently from a plumbing failure). A collision surfaces a
    /// "Retry" button calling `AppDelegate.retryHotkeyRegistration()`.
    @ViewBuilder
    private var statusRow: some View {
        let status = settingsStatus
        HStack(spacing: 8) {
            Image(systemName: status.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.isWarning ? BridgeTokens.warnText : BridgeTokens.okText)
            Text(status.message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(status.isWarning ? BridgeTokens.warnText : BridgeTokens.fg3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
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

    // MARK: - Observed state (mirrors SettingsView's controller-or-fallback ladder)

    /// The combo the recorder should DISPLAY — from the observed
    /// controller when injected (so a just-recorded rebind shows
    /// immediately), else the persisted value (falls back to the shipping
    /// default). Mirrors `SettingsView.commandsHotkeyConfig`.
    private var hotkeyConfig: HotkeyConfig {
        if let c = commandsController { return c.hotkeyConfig }
        return (NSApp.delegate as? AppDelegate)?.commandsHotkeyConfig ?? HotkeyConfig.loadPersisted()
    }

    /// The structured outcome of the last registration attempt, observed
    /// live. Drives the precise status message. Mirrors
    /// `SettingsView.commandsLastRegisterStatus`.
    private var lastRegisterStatus: HotkeyRegisterStatus {
        commandsController?.lastRegisterStatus ?? .unattempted
    }

    /// The pure status-row model, derived over the observed master-toggle
    /// + the structured register outcome + the combo glyph. The exact
    /// strings + severity live in (and are unit-tested via)
    /// `CommandsSettingsStatus` — this view only renders them.
    private var settingsStatus: CommandsSettingsStatus {
        CommandsSettingsStatus(
            enabled: paletteEnabled,
            lastRegisterStatus: lastRegisterStatus,
            hotkey: hotkeyConfig.displayString
        )
    }

    /// True ⟺ the last attempt was a TRUE Carbon combo collision — only
    /// then does the row offer the "Retry" affordance (a plumbing failure
    /// or a generic-unavailable is not retryable on the same combo).
    private var isCollision: Bool {
        if case .collision = lastRegisterStatus { return true }
        return false
    }

    // MARK: - Capture handler (chord → validated config → live rebind)

    /// `(carbonKeyCode, Cocoa modifiers) -> accepted`. Validates the chord
    /// via the pure `HotkeyConfig.from` (rejects modifier-less /
    /// pure-modifier presses → nil → keeps the field recording so the user
    /// can immediately try again). On a valid chord, hands it to the
    /// AppDelegate for the persist + live-rebind, returning its accept/
    /// reject Bool so the recorder ends (accept) or stays open (reject).
    private func handleCapture(keyCode: UInt32, cocoaMods: NSEvent.ModifierFlags) -> Bool {
        guard let cfg = HotkeyConfig.from(keyCode: keyCode, cocoaModifiers: cocoaMods) else {
            return false
        }
        // A non-nil config is a valid combo — accept it for the recorder
        // (end capture) regardless of whether the live Carbon register
        // then succeeds: the status row surfaces a collision/failure, and
        // the recorder must not re-arm on a perfectly valid chord that
        // merely lost a registration race. The AppDelegate persists +
        // live-rebinds; a nil delegate (preview) still accepts the combo.
        _ = (NSApp.delegate as? AppDelegate)?.setCommandsHotkey(cfg)
        return true
    }
}
