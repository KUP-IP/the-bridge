// VoiceMemoTranscriber.swift — Parakeet TDT v3 via FluidAudio (Wave 2)
// TheBridge · Modules · VoiceMemo
//
// Uses the same Parakeet v3 family as Handy (CoreML via FluidAudio, not Handy's ONNX bundle).

import Foundation
import FluidAudio

public enum VoiceMemoTranscriber {

    public enum TranscriberError: Error, LocalizedError {
        case disabled
        case emptyResult
        case conversionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .disabled: return "Parakeet transcription is disabled in Settings"
            case .emptyResult: return "Transcription returned empty text"
            case .conversionFailed(let msg): return "Audio conversion failed: \(msg)"
            }
        }
    }

    /// Injectable hook for tests (defaults to live FluidAudio path).
    public nonisolated(unsafe) static var transcribeFile: @Sendable (URL) async throws -> String = { url in
        try await LiveEngine.shared.transcribe(audioURL: url)
    }

    public static func transcribeIfNeeded(for recording: VoiceMemoRecording) async throws -> String? {
        guard BridgeDefaults.voiceMemoParakeetTranscriptionEffective else { return nil }
        if recording.hasTranscript, let existing = recording.transcript { return existing }
        let url = URL(fileURLWithPath: recording.path, isDirectory: false)
        let text = try await transcribeFile(url)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriberError.emptyResult }
        try? VoiceMemoDiscovery.writeTranscriptSidecar(for: url, text: trimmed, source: .parakeet)
        return trimmed
    }

    // MARK: - Live FluidAudio engine (singleton, lazy model load)

    private actor LiveEngine {
        static let shared = LiveEngine()
        private var manager: AsrManager?
        private var decoderState: TdtDecoderState?
        private var loading: Task<Void, Error>?

        func transcribe(audioURL: URL) async throws -> String {
            try await ensureLoaded()
            guard let manager, var state = decoderState else { throw TranscriberError.disabled }
            let result = try await manager.transcribe(audioURL, decoderState: &state)
            decoderState = state
            return result.text
        }

        private func ensureLoaded() async throws {
            if manager != nil { return }
            if let loading {
                try await loading.value
                return
            }
            let task = Task {
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                let mgr = AsrManager(config: ASRConfig.default)
                try await mgr.loadModels(models)
                let layers = await mgr.decoderLayerCount
                self.manager = mgr
                self.decoderState = TdtDecoderState.make(decoderLayers: layers)
            }
            loading = task
            defer { loading = nil }
            try await task.value
        }
    }
}
