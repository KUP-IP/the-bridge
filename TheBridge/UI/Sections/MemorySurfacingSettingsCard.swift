// MemorySurfacingSettingsCard.swift — handshake inject controls (PKT-MEM-115)
// TheBridge · UI · Sections

import SwiftUI

public struct MemorySurfacingSettingsCard: View {
    @AppStorage(BridgeDefaults.memoryHandshakeAutoInject) private var globalInject = false
    @State private var overrides: [String: Bool] = [:]
    @State private var newClientName = ""

    public init() {}

    public var body: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Handshake memory inject")
                Text("Append salient agent memories to the MCP initialize instructions. Global default is off; Cursor is seeded on for new installs.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Inject for all clients", isOn: $globalInject)
                    .accessibilityIdentifier(BridgeAXID.Memory.injectGlobalToggle)

                if !overrides.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Per-client overrides")
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg4)
                        ForEach(overrides.keys.sorted(), id: \.self) { client in
                            overrideRow(client: client)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Client name (e.g. cursor)", text: $newClientName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(BridgeAXID.Memory.injectClientNameField)
                    Button("Add override") { addOverride() }
                        .disabled(newClientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier(BridgeAXID.Memory.injectAddOverride)
                }

                Text("MCP client names come from initialize clientInfo.name. Voice-memo agent_memory rows use type reference and may expire after 90 days without use.")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(BridgeAXID.Memory.surfacingCard)
        .onAppear(perform: reloadOverrides)
        .onChange(of: globalInject) { _, _ in reloadOverrides() }
    }

    private func overrideRow(client: String) -> some View {
        HStack(spacing: 10) {
            Text(client)
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg2)
            Spacer(minLength: 8)
            Picker("Override", selection: binding(for: client)) {
                Text("Force ON").tag(OverrideChoice.on)
                Text("Force OFF").tag(OverrideChoice.off)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 140)
            Button("Remove") { removeOverride(client) }
                .accessibilityIdentifier(BridgeAXID.Memory.injectRemoveOverride)
        }
    }

    private enum OverrideChoice: String {
        case on, off
    }

    private func binding(for client: String) -> Binding<OverrideChoice> {
        Binding(
            get: {
                (overrides[client] ?? true) ? .on : .off
            },
            set: { choice in
                switch choice {
                case .on:
                    MemoryAutoInjectClientStore.shared.setOverride(true, forClient: client)
                case .off:
                    MemoryAutoInjectClientStore.shared.setOverride(false, forClient: client)
                }
                reloadOverrides()
            }
        )
    }

    private func reloadOverrides() {
        overrides = MemoryAutoInjectClientStore.shared.allOverrides()
    }

    private func addOverride() {
        let name = newClientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        MemoryAutoInjectClientStore.shared.setOverride(true, forClient: name)
        newClientName = ""
        reloadOverrides()
    }

    private func removeOverride(_ client: String) {
        MemoryAutoInjectClientStore.shared.setOverride(nil, forClient: client)
        reloadOverrides()
    }
}
