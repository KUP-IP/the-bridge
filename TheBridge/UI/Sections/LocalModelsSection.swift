// LocalModelsSection.swift — Settings → Advanced → Local Models (Ollama + Parakeet)
// TheBridge · UI · Sections

import SwiftUI

public struct LocalModelsSection: View {
    @AppStorage(BridgeDefaults.ollamaBaseURL) private var baseURL = "http://127.0.0.1:11434"
    @AppStorage(BridgeDefaults.ollamaRoutingModel) private var routingModel = ""
    @AppStorage(BridgeDefaults.ollamaSummarizationModel) private var summarizationModel = ""
    @AppStorage(BridgeDefaults.voiceMemoOllamaRouting) private var voiceMemoOllamaRouting = false
    @AppStorage(BridgeDefaults.voiceMemoParakeetTranscription) private var parakeetTranscription = true

    @State private var models: [String] = []
    @State private var reachable = false
    @State private var status = "Not checked yet"
    @State private var busy = false

    public init() {}

    public var body: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.s3) {
                BridgeCardLabel("Local Models")
                Text("Ollama routing + FluidAudio Parakeet v3 transcription (same family as Handy)")
                    .font(.caption)
                    .foregroundStyle(BridgeTokens.fg4)

                HStack(alignment: .firstTextBaseline) {
                    Text("Base URL")
                        .frame(width: 118, alignment: .leading)
                        .foregroundStyle(BridgeTokens.fg3)
                    BridgeInput("http://127.0.0.1:11434", text: $baseURL, mono: true)
                }

                HStack {
                    BridgeButton(busy ? "Checking…" : "Test connection", systemImage: "network") {
                        Task { await refreshModels() }
                    }
                    .disabled(busy)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(reachable ? BridgeTokens.ok : BridgeTokens.fg4)
                }

                modelPicker(
                    label: "Routing model",
                    selection: $routingModel,
                    help: "Voice memo intent classification — default gemma4:12b on M1 16 GB"
                )

                modelPicker(
                    label: "Summary model",
                    selection: $summarizationModel,
                    help: "One-sentence Memory summary (Relevant:) — empty uses routing model"
                )

                Toggle(isOn: $voiceMemoOllamaRouting) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Ollama for voice memo routing")
                        Text("When off, the curator uses deterministic phrase matching.")
                            .font(.caption)
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $parakeetTranscription) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcribe memos with Parakeet v3 (FluidAudio)")
                        Text("When on, memos without a .txt sidecar are transcribed on-device before routing.")
                            .font(.caption)
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                }
                .toggleStyle(.switch)

                let pending = VoiceMemoReviewStore.pendingEntries().count
                if pending > 0 {
                    HStack {
                        BridgeBadge("\(pending) review", tone: .warn, showsDot: true)
                        Text("Pending voice memos in review.json")
                            .font(.caption)
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                }
            }
        }
        .id("local-models")
        .onAppear { BridgeDefaults.seedOllamaDefaultsIfNeeded() }
        .task { await refreshModels() }
    }

    @ViewBuilder
    private func modelPicker(label: String, selection: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .frame(width: 118, alignment: .leading)
                    .foregroundStyle(BridgeTokens.fg3)
                Picker("", selection: selection) {
                    Text("— none —").tag("")
                    ForEach(models, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(BridgeTokens.fg4)
                .padding(.leading, 118)
        }
    }

    @MainActor
    private func refreshModels() async {
        busy = true
        defer { busy = false }
        BridgeDefaults.seedOllamaDefaultsIfNeeded()
        let client = OllamaClient(baseURL: BridgeDefaults.ollamaBaseURLEffective)
        do {
            reachable = try await client.health()
            if reachable {
                let listed = try await client.listModels()
                models = listed.map(\.name)
                status = "\(models.count) model(s) available"
            } else {
                models = []
                status = "Ollama not reachable"
            }
        } catch {
            reachable = false
            models = []
            status = error.localizedDescription
        }
    }
}
