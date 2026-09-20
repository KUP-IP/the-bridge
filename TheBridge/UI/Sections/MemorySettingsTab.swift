// MemorySettingsTab.swift — Settings → Memory → Settings tab (2026-07-03 redesign)
// TheBridge · UI · Sections
//
// Consolidates the old Processing tab (curator routing / transcription ladder / cloud
// provider — MemoryProcessingTab.swift) with the Handshake Memory Inject config that
// used to live inline at the top of the old Agent tab (MemorySurfacingSettingsCard.swift).
// Per the mockup (design/the-bridge-design-system/project/pages/page-memory.jsx,
// `function SettingsTab()`): this is configuration, not a memory itself, so it belongs
// here rather than on Recall. Card order: Curator routing → Transcription ladder →
// Cloud enhancement → Handshake memory inject.
//
// Real store bindings preserved from the ported files (no fake/stub data):
//   - @AppStorage(BridgeDefaults.voiceMemoCuratorMode) → VoiceMemoCuratorMode
//   - @AppStorage(BridgeDefaults.voiceMemoAppleTranscript /
//     .voiceMemoSpeechAnalyzerTranscription / .voiceMemoParakeetTranscription)
//   - MemoryHubProviderConfigStore.{load,upsert,saveKey,deleteKey,keyConfigured,
//     validateSyntax,canRunCloud}
//   - MCPClientPresence.shared.{hasConnectedClient,primaryClientName}
//   - @AppStorage(BridgeDefaults.memoryHandshakeAutoInject) + MemoryAutoInjectClientStore

import SwiftUI

public struct MemorySettingsTab: View {
    @AppStorage(BridgeDefaults.voiceMemoCuratorMode) private var curatorModeRaw: String = VoiceMemoCuratorMode.auto.rawValue
    @AppStorage(BridgeDefaults.voiceMemoAppleTranscript) private var appleTranscript = true
    @AppStorage(BridgeDefaults.voiceMemoSpeechAnalyzerTranscription) private var speechAnalyzerTranscription = false
    @AppStorage(BridgeDefaults.voiceMemoParakeetTranscription) private var parakeetTranscription = true
    @AppStorage(BridgeDefaults.memoryHandshakeAutoInject) private var globalInject = false

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

    // PKT-MEM-115 — per-client handshake-inject overrides.
    @State private var overrides: [String: Bool] = [:]
    @State private var newClientName = ""

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                curatorRoutingCard
                transcriptionLadderCard
                cloudEnhancementCard
                handshakeInjectCard
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(BridgeTokens.Space.paneH)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.Settings.pane)
        .onAppear {
            loadProvider()
            reloadOverrides()
            Task { await refreshMCPStatus() }
        }
        .onChange(of: globalInject) { _, _ in reloadOverrides() }
    }

    // MARK: - Card 1: Curator routing

    private var curatorRoutingCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Curator routing")
                Text("When an MCP client is connected, Auto defers Execute to the agent (`voice_memo_get` → `voice_memo_commit`). When alone: cloud → heuristics, then Bridge auto-execute.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if mcpConnected {
                    Text("Connected\(mcpClientLabel.map { ": \($0)" } ?? "") — Execute deferred in Auto mode")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.accent)
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.curatorBanner)
                } else {
                    Text("No MCP client — autonomous processing when Auto is selected")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.curatorBanner)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Mode")
                        .font(BridgeTokens.Typeface.meta.weight(.semibold))
                        .foregroundStyle(BridgeTokens.fg2)
                    // NOTE: deliberately NOT `ForEach(VoiceMemoCuratorMode.allCases) { … }`
                    // inside the Picker — that pattern crashed reproducibly on macOS 27 beta
                    // (26A5368g) with a `dispatch_assert_queue_fail` / EXC_BREAKPOINT inside
                    // SwiftUI's ForEachChild/AttributeGraph update machinery, 100% repro on
                    // every open of this Picker (2 crash logs captured during Loop 3, see
                    // memory-swiftui-uiiter-log.md). Five fixed cases, so unrolled literal
                    // Text/.tag entries sidestep the ForEach-in-Picker AttributeGraph path
                    // entirely — functionally identical, same tags, same order.
                    Picker("Mode", selection: $curatorModeRaw) {
                        Text(VoiceMemoCuratorMode.auto.label).tag(VoiceMemoCuratorMode.auto.rawValue)
                        Text(VoiceMemoCuratorMode.heuristics.label).tag(VoiceMemoCuratorMode.heuristics.rawValue)
                        Text(VoiceMemoCuratorMode.agent.label).tag(VoiceMemoCuratorMode.agent.rawValue)
                        Text(VoiceMemoCuratorMode.cloud.label).tag(VoiceMemoCuratorMode.cloud.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(BridgeAXID.Memory.Settings.curatorMode)
                    if let mode = VoiceMemoCuratorMode(rawValue: curatorModeRaw) {
                        Text(Self.curatorModeHelp(mode))
                            .font(BridgeTokens.Typeface.sub)
                            .foregroundStyle(BridgeTokens.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 3)
                    }
                }
            }
        }
    }

    /// Mirrors the mockup's `MEM_MODE_HELP` copy (page-memory.jsx) keyed by mode.
    public nonisolated static func curatorModeHelp(_ mode: VoiceMemoCuratorMode) -> String {
        switch mode {
        case .auto:
            return "Tries cloud, then heuristics — whichever is available first. Configure and enable Cloud enhancement below to allow cloud routing. Defers Execute to a connected agent when one is present."
        case .cloud:
            return "Sends the transcript to the configured cloud provider for every Understand step. Configure and enable Cloud enhancement below."
        case .heuristics:
            return "Deterministic phrase-matching only — no model calls at all, fastest and fully offline."
        case .agent:
            return "No local model, no cloud calls — Understand and Execute both wait for an explicit call from the connected agent."
        }
    }

    // MARK: - Card 2: Transcription ladder

    private var transcriptionLadderCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Transcription ladder")
                ladderRow("Apple embedded transcript (tsrp)", isOn: $appleTranscript, axid: BridgeAXID.Memory.Settings.ladderApple)
                ladderRow("SpeechAnalyzer (opt-in)", isOn: $speechAnalyzerTranscription, axid: BridgeAXID.Memory.Settings.ladderSpeechAnalyzer)
                ladderRow("Parakeet fallback", isOn: $parakeetTranscription, axid: BridgeAXID.Memory.Settings.ladderParakeet)
            }
        }
    }

    private func ladderRow(_ label: String, isOn: Binding<Bool>, axid: String) -> some View {
        HStack(spacing: 9) {
            BridgeToggle(isOn: isOn)
                .accessibilityIdentifier(axid)
            Text(label)
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg2)
        }
    }

    // MARK: - Card 3: Cloud enhancement

    private var cloudEnhancementCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    BridgeCardLabel("Cloud enhancement")
                    // Mirrors the mockup's base `.mem-cloud` rule (not the
                    // `.btn:not(.primary) .mem-cloud` override, which only applies inside a
                    // button) — solid accent-tinted chip, onAccent text, mono micro face.
                    Text("uses cloud")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .tracking(0.2)
                        .foregroundStyle(BridgeTokens.onAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(BridgeTokens.accent.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text("Optional cloud provider for the manual “Improve title” action AND, when the curator Mode is Auto or Cloud, for the Understand step. In those modes, enabling this sends the FULL transcript to \(providerBaseURL) automatically during processing — including the scheduled morning curator job — not only when you trigger it by hand. Each cloud send is recorded in the Activity log. The API key is stored in the Keychain only; base URL, model, and enabled live in providers.json.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Base URL")
                        .font(BridgeTokens.Typeface.meta.weight(.semibold))
                        .foregroundStyle(BridgeTokens.fg2)
                    BridgeInput("Base URL", text: $providerBaseURL)
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.cloudBaseURL)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Model (required to run)")
                        .font(BridgeTokens.Typeface.meta.weight(.semibold))
                        .foregroundStyle(BridgeTokens.fg2)
                    BridgeInput("Model", text: $providerModel)
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.cloudModel)
                }
                HStack(spacing: 9) {
                    BridgeToggle(isOn: $providerEnabled)
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.cloudEnabled)
                    Text("Enabled")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg2)
                }
                HStack(spacing: 8) {
                    SecureField("API key (stored in Keychain)", text: $providerKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.cloudKeyInput)
                    BridgeButton("Save", systemImage: "key.fill", variant: .primary) { saveProvider() }
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.cloudKeySave)
                    BridgeButton("Delete key", systemImage: "trash") { deleteKey() }
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.cloudKeyDelete)
                }
                HStack(spacing: 6) {
                    BridgeBadge(providerKeyConfigured ? "Key configured" : "Key missing",
                                tone: providerKeyConfigured ? .ok : .neutral,
                                showsDot: true)
                    if let providerStatus {
                        Text("· \(providerStatus)")
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                }
                .accessibilityIdentifier(BridgeAXID.Memory.Settings.cloudKeyStatus)
            }
        }
    }

    // MARK: - Card 4: Handshake memory inject

    private var handshakeInjectCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Handshake memory inject")
                Text("Append salient agent memories to the MCP initialize instructions. Global default is off; Cursor is seeded on for new installs. Moved here from Recall — this is configuration, not a memory itself.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 9) {
                    BridgeToggle(isOn: $globalInject)
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.injectGlobal)
                    Text("Inject for all clients")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg2)
                }

                if !overrides.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(overrides.keys.sorted(), id: \.self) { client in
                            overrideRow(client: client)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Add per-client override")
                        .font(BridgeTokens.Typeface.meta.weight(.semibold))
                        .foregroundStyle(BridgeTokens.fg2)
                    HStack(spacing: 8) {
                        BridgeInput("Client name (e.g. cursor)", text: $newClientName)
                            .accessibilityIdentifier(BridgeAXID.Memory.Settings.injectClientName)
                        BridgeButton(
                            "Add override",
                            isEnabled: !newClientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            action: addOverride
                        )
                        .accessibilityIdentifier(BridgeAXID.Memory.Settings.injectAdd)
                    }
                }

                Text("MCP client names come from initialize clientInfo.name. Voice-memo agent_memory rows use type reference and may expire after 90 days without use.")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // NOTE: deliberately no card-level .accessibilityIdentifier here — SwiftUI/AX
            // propagates a container's accessibilityIdentifier down onto every descendant
            // AXUIElement that doesn't set its own, which was SHADOWING all the child
            // control ids below (injectGlobal/injectClientName/injectAdd/injectOverrideRow/
            // injectRemove all resolved to this one id in the raw AX tree — caught in
            // Loop 1 via ax_tree evidence, see memory-swiftui-uiiter-log.md). The pane-level
            // BridgeAXID.Memory.Settings.pane id + each control's own id are sufficient.
        }
    }

    private func overrideRow(client: String) -> some View {
        HStack(spacing: 10) {
            Text(client)
                .font(BridgeTokens.Typeface.sub.weight(.semibold))
                .foregroundStyle(BridgeTokens.fg1)
            Spacer(minLength: 8)
            BridgeBadge((overrides[client] ?? true) ? "Force on" : "Force off", tone: .neutral)
            BridgeButton("Remove", variant: .danger) { removeOverride(client) }
                .accessibilityIdentifier(BridgeAXID.Memory.Settings.injectRemove(client))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .bridgeBevel(BridgeTokens.bevelInset, radius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        // No row-level .accessibilityIdentifier — same propagation hazard as the card fix
        // above; it would shadow the Remove button's own injectRemove(client) id. The row
        // is still locatable by its Remove button's id or by client name text.
    }

    // MARK: - Actions

    private func refreshMCPStatus() async {
        mcpConnected = await MCPClientPresence.shared.hasConnectedClient
        mcpClientLabel = await MCPClientPresence.shared.primaryClientName
    }

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
