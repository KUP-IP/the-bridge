// OllamaModule.swift — local model discovery + health (Wave 2a)
// TheBridge · Modules · Ollama

import Foundation
import MCP

public enum OllamaModule {
    public static let moduleName = "ollama"

    public static func register(on router: ToolRouter) async {
        await router.register(makeHealth())
        await router.register(makeListModels())
    }

    private static func makeHealth() -> ToolRegistration {
        ToolRegistration(
            name: "ollama_health",
            module: moduleName,
            tier: .open,
            description: "Check whether a local Ollama server is reachable at the configured base URL (default http://127.0.0.1:11434). Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            metadata: ToolMetadata(
                title: "Ollama Health",
                whenToUse: ["verify local Ollama before enabling voice memo LLM routing"],
                whenNotToUse: ["remote LLM calls — Ollama is localhost-only"],
                relatedTools: ["ollama_list_models"]
            ),
            handler: { _ in
                let client = OllamaClient.fromDefaults()
                let ok = (try? await client.health()) ?? false
                return .object([
                    "reachable": .bool(ok),
                    "baseURL": .string(BridgeDefaults.ollamaBaseURLEffective.absoluteString),
                ])
            }
        )
    }

    private static func makeListModels() -> ToolRegistration {
        ToolRegistration(
            name: "ollama_list_models",
            module: moduleName,
            tier: .open,
            description: "List models installed in the local Ollama instance. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            metadata: ToolMetadata(
                title: "Ollama List Models",
                whenToUse: ["populate the Local Models settings picker", "choose a routing model for voice memos"],
                whenNotToUse: ["inference — use voice_memo_process with Ollama routing enabled"],
                relatedTools: ["ollama_health"]
            ),
            handler: { _ in
                let client = OllamaClient.fromDefaults()
                let models = try await client.listModels()
                return .object([
                    "count": .int(models.count),
                    "models": .array(models.map {
                        .object([
                            "name": .string($0.name),
                            "sizeBytes": $0.sizeBytes.map { .int(Int($0)) } ?? .null,
                        ])
                    }),
                    "routingModel": BridgeDefaults.ollamaRoutingModelEffective.map { .string($0) } ?? .null,
                    "transcriptionModel": BridgeDefaults.ollamaTranscriptionModelEffective.map { .string($0) } ?? .null,
                ])
            }
        )
    }
}
