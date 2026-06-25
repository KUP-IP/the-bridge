// MemoryProcessingTab.swift — Processing settings (PKT-MEM-111 U6)
// TheBridge · UI · Sections

import SwiftUI

struct MemoryProcessingTab: View {
    @AppStorage(BridgeDefaults.voiceMemoCuratorMode) private var curatorModeRaw: String = VoiceMemoCuratorMode.auto.rawValue
    @AppStorage(BridgeDefaults.voiceMemoOllamaRouting) private var ollamaRouting = true
    @AppStorage(BridgeDefaults.voiceMemoAppleTranscript) private var appleTranscript = true
    @AppStorage(BridgeDefaults.voiceMemoParakeetTranscription) private var parakeetTranscription = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                BridgeGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        BridgeCardLabel("Curator routing")
                        Text("Understand + Plan routing before Bridge-owned Execute. Auto prefers local Ollama when enabled.")
                            .font(BridgeTokens.Typeface.sub)
                            .foregroundStyle(BridgeTokens.fg3)
                            .fixedSize(horizontal: false, vertical: true)
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
            }
            .padding(BridgeTokens.Space.paneH)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.processingPane)
    }
}
