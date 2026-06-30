// MemoryProcessingTab.swift — Processing settings (PKT-MEM-111 U6 + PKT-MEM-106 0c provider keys)
// TheBridge · UI · Sections

import SwiftUI

struct MemoryProcessingTab: View {
    @AppStorage(BridgeDefaults.voiceMemoCuratorMode) private var curatorModeRaw: String = VoiceMemoCuratorMode.auto.rawValue
    @AppStorage(BridgeDefaults.voiceMemoOllamaRouting) private var ollamaRouting = true
    @AppStorage(BridgeDefaults.voiceMemoAppleTranscript) private var appleTranscript = true
    @AppStorage(BridgeDefaults.voiceMemoParakeetTranscription) private var parakeetTranscription = true

    // PKT-MEM-106 0c — OpenAI-compatible cloud provider (non-secret config in providers.json;
    // API key in Keychain only).
    @State private var providerBaseURL = MemoryHubProviderConfigStore.defaultBaseURL
    @State private var providerModel = ""
    @State private var providerEnabled = false
    @State private var providerKeyInput = ""
    @State private var providerKeyConfigured = false
    @State private var providerStatus: String?
    @State private var mcpConnected = false
    @State private var mcpClientLabel: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                BridgeGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        BridgeCardLabel("Curator routing")
                        Text("When an MCP client is connected, Auto defers Execute to the agent (`voice_memo_get` → `voice_memo_commit`). When alone: cloud → local Ollama → heuristics, then Bridge auto-execute.")
                            .font(BridgeTokens.Typeface.sub)
                            .foregroundStyle(BridgeTokens.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                        if mcpConnected {
                            Text("Connected\(mcpClientLabel.map { ": \($0)" } ?? "") — Execute deferred in Auto mode")
                                .font(BridgeTokens.Typeface.meta)
                                .foregroundStyle(BridgeTokens.accent)
                        } else {
                            Text("No MCP client — autonomous processing when Auto is selected")
                                .font(BridgeTokens.Typeface.meta)
                                .foregroundStyle(BridgeTokens.fg4)
                        }
                        Picker("Mode", selection: $curatorModeRaw) {
                            ForEach(VoiceMemoCuratorMode.allCases, id: \.rawValue) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier(BridgeAXID.Memory.processingMode)
                    }
                }
                BridgeGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        BridgeCardLabel("Transcription ladder")
                        Toggle("Apple embedded transcript (tsrp)", isOn: $appleTranscript)
                            .accessibilityIdentifier(BridgeAXID.Memory.processingApple)
                        Toggle("Parakeet fallback", isOn: $parakeetTranscription)
                            .accessibilityIdentifier(BridgeAXID.Memory.processingParakeet)
                        Toggle("Ollama routing + summarization", isOn: $ollamaRouting)
                            .accessibilityIdentifier(BridgeAXID.Memory.processingOllama)
                        Text("Local model picks live under Advanced → Local Models.")
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                }
                providerCard
            }
            .padding(BridgeTokens.Space.paneH)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.processingPane)
        .onAppear {
            loadProvider()
            Task { await refreshMCPStatus() }
        }
    }

    private func refreshMCPStatus() async {
        mcpConnected = await MCPClientPresence.shared.hasConnectedClient
        mcpClientLabel = await MCPClientPresence.shared.primaryClientName
    }

    private var providerCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Cloud enhancement (OpenAI-compatible)")
                Text("Optional cloud provider for the manual “Improve title” action AND, when the curator Mode is Auto or Cloud, for the Understand step. In those modes, enabling this sends the FULL transcript to \(providerBaseURL) automatically during processing — including the scheduled morning curator job — not only when you trigger it by hand. Each cloud send is recorded in the Activity log. The API key is stored in the Keychain only; base URL, model, and enabled live in providers.json.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Base URL", text: $providerBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(BridgeAXID.control(.memory, "processing.provider.baseURL"))
                TextField("Model (required to run)", text: $providerModel)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(BridgeAXID.control(.memory, "processing.provider.model"))
                Toggle("Enabled", isOn: $providerEnabled)
                    .accessibilityIdentifier(BridgeAXID.control(.memory, "processing.provider.enabled"))
                HStack(spacing: 8) {
                    SecureField("API key (stored in Keychain)", text: $providerKeyInput)
                        .textFieldStyle(.roundedBorder)
                    BridgeButton("Save", systemImage: "key.fill", variant: .primary) { saveProvider() }
                        .accessibilityIdentifier(BridgeAXID.Memory.processingProviderSave)
                    BridgeButton("Delete key", systemImage: "trash") { deleteKey() }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(providerKeyConfigured ? BridgeTokens.accent : BridgeTokens.fg4)
                        .frame(width: 8, height: 8)
                    Text(providerKeyConfigured ? "Key configured" : "Key missing")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                    if let providerStatus {
                        Text("· \(providerStatus)")
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                }
                .accessibilityIdentifier(BridgeAXID.Memory.processingProviderStatus)
            }
        }
    }

    // MARK: - Provider actions

    private func loadProvider() {
        let provider = MemoryHubProviderConfigStore.load().first { $0.id == MemoryHubProviderConfigStore.openAICompatibleId }
            ?? MemoryHubProviderConfigStore.defaultProvider()
        providerBaseURL = provider.baseURL
        providerModel = provider.model
        providerEnabled = provider.enabled
        providerKeyConfigured = MemoryHubProviderConfigStore.keyConfigured(providerId: provider.id)
    }

    private func saveProvider() {
        let provider = MemoryHubProvider(
            id: MemoryHubProviderConfigStore.openAICompatibleId,
            baseURL: providerBaseURL, model: providerModel, enabled: providerEnabled
        )
        if case .rejected(let why) = MemoryHubProviderConfigStore.validateSyntax(provider) {
            providerStatus = "✗ \(why)"
            return
        }
        try? MemoryHubProviderConfigStore.upsert(provider)
        if !providerKeyInput.isEmpty {
            _ = MemoryHubProviderConfigStore.saveKey(providerId: provider.id, apiKey: providerKeyInput)
            providerKeyInput = ""
        }
        providerKeyConfigured = MemoryHubProviderConfigStore.keyConfigured(providerId: provider.id)
        providerStatus = MemoryHubProviderConfigStore.canRunCloud(provider)
            ? "ready for manual cloud enhance"
            : "saved — set a model + enable to run"
    }

    private func deleteKey() {
        _ = MemoryHubProviderConfigStore.deleteKey(providerId: MemoryHubProviderConfigStore.openAICompatibleId)
        providerKeyConfigured = false
        providerStatus = "key deleted"
    }
}
