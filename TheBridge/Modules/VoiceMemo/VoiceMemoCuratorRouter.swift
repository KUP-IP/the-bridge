// VoiceMemoCuratorRouter.swift — hybrid Understand routing (PKT-MEM-110 foundation)
// TheBridge · Modules · VoiceMemo

import Foundation

/// How voice-memo Understand + Plan stages are routed before Execute (Bridge-owned).
public enum VoiceMemoCuratorMode: String, CaseIterable, Sendable, Codable {
    case auto
    case heuristics
    case local
    case agent
    case cloud

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .heuristics: return "Heuristics only"
        case .local: return "Local Ollama"
        case .agent: return "Connected MCP agent"
        case .cloud: return "Cloud API"
        }
    }
}

public enum VoiceMemoCuratorRouter {

    public static func effectiveMode() -> VoiceMemoCuratorMode {
        let raw = UserDefaults.standard.string(forKey: BridgeDefaults.voiceMemoCuratorMode)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let raw, !raw.isEmpty, let mode = VoiceMemoCuratorMode(rawValue: raw) else {
            return .auto
        }
        return mode
    }

    /// Whether Ollama routing/summarization may run (local or auto with Ollama enabled).
    public static func shouldUseLocalOllama() -> Bool {
        switch effectiveMode() {
        case .heuristics, .agent, .cloud: return false
        case .local: return true
        case .auto: return BridgeDefaults.voiceMemoOllamaRoutingEffective
        }
    }

    /// Whether Gemma/LLM summarization should run for memory_keep lanes.
    public static func shouldSummarizeForMemoryKeep() -> Bool {
        switch effectiveMode() {
        case .heuristics: return false
        case .local, .cloud, .agent, .auto: return true
        }
    }

    /// Agent-deferred processing: transcribe + notify, no auto Execute.
    public static func deferExecuteToAgent() -> Bool {
        effectiveMode() == .agent
    }
}
