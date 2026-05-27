// CommandsSection.swift — Settings → Commands pane.
// PKT-6 UI v3.5. Hosts the new TextExpander-analog editor and a small
// hotkey/enable summary card so the popup's master switch remains
// reachable here.

import SwiftUI

public struct CommandsSection: View {
    @AppStorage(BridgeDefaults.commandsPaletteEnabled)
    private var paletteEnabled: Bool = true

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Hotkey / enable summary strip
            BridgeGlassCard(cornerRadius: 0, padding: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.08)).frame(width: 36, height: 36)
                        Text("⌘").font(.system(size: 16, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Commands").font(.system(size: 17, weight: .semibold))
                        Text("Markdown-per-command store at ~/Library/Application Support/The Bridge/commands/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Popup enabled", isOn: $paletteEnabled)
                        .onChange(of: paletteEnabled) { _, newValue in
                            (NSApp.delegate as? AppDelegate)?.setCommandsPaletteEnabled(newValue)
                        }
                        .toggleStyle(.switch)
                }
            }
            .background(Color.clear)
            Divider().background(Color.white.opacity(0.10))

            // The editor pane
            CommandsEditorView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
