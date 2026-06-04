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

import SwiftUI

public struct CommandsSection: View {
    @AppStorage(BridgeDefaults.commandsPaletteEnabled)
    private var paletteEnabled: Bool = true

    @State private var commands: [CommandStore.Command] = []
    @State private var selectedSlug: String? = nil

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
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
                        .fill(BridgeTokens.accent.opacity(0.22))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 1))
                    Text("⌘")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(BridgeTokens.accentLink)
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
}
