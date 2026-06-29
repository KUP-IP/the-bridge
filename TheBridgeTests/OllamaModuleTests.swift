// OllamaModuleTests.swift — local Ollama client + module (Wave 2a)
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runOllamaModuleTests() async {
    print("\n🦙 Ollama — client parse + module registration")

    await test("OllamaClient.parseTagsResponse decodes model names") {
        let json = """
        {"models":[{"name":"llama3.2:latest","size":2019393189},{"name":"mistral","size":1000}]}
        """.data(using: .utf8)!
        let models = try OllamaClient.parseTagsResponse(json)
        try expect(models.count == 2, "expected 2 models")
        try expect(models[0].name == "llama3.2:latest", "sorted order")
        try expect(models[1].name == "mistral", "second model")
    }

    await test("OllamaModule registers 2 open tools") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await OllamaModule.register(on: router)
        let tools = await router.registrations(forModule: "ollama")
        try expect(tools.count == 2, "expected 2 ollama tools")
        let names = Set(tools.map(\.name))
        try expect(names.contains("ollama_health"), "health tool")
        try expect(names.contains("ollama_list_models"), "list models tool")
        try expect(tools.allSatisfy { $0.tier == .open }, "ollama tools are open")
    }

    await test("BridgeDefaults ollama base URL defaults to localhost") {
        let url = BridgeDefaults.ollamaBaseURLEffective
        try expect(url.host == "127.0.0.1" || url.host == "localhost", "localhost default")
        try expect(url.port == 11434, "default port 11434")
    }

    await test("OllamaClient.extractGenerateText prefers response field") {
        let json: [String: Any] = ["response": "hello", "thinking": "{\"lanes\":[\"review\"]}"]
        let text = try OllamaClient.extractGenerateText(from: json)
        try expect(text == "hello", "response wins")
    }

    await test("OllamaClient.extractGenerateText falls back to JSON in thinking") {
        let json: [String: Any] = [
            "response": "",
            "thinking": "Let me classify.\n{\"lanes\":[\"memory_keep\"],\"title\":\"Ship it\",\"confidence\":0.9}",
        ]
        let text = try OllamaClient.extractGenerateText(from: json)
        try expect(text.contains("memory_keep"), "JSON extracted from thinking")
    }

    await test("BridgeDefaults.seedOllamaDefaultsIfNeeded sets split routing and summary models") {
        let d = UserDefaults.standard
        let savedRouting = d.string(forKey: BridgeDefaults.ollamaRoutingModel)
        let savedSummary = d.string(forKey: BridgeDefaults.ollamaSummarizationModel)
        d.removeObject(forKey: BridgeDefaults.ollamaRoutingModel)
        d.removeObject(forKey: BridgeDefaults.ollamaSummarizationModel)
        BridgeDefaults.seedOllamaDefaultsIfNeeded()
        let seeded = d.string(forKey: BridgeDefaults.ollamaRoutingModel)
        let seededSummary = d.string(forKey: BridgeDefaults.ollamaSummarizationModel)
        try expect(seeded == BridgeDefaults.ollamaRoutingModelDefault, "default qwen3.5:9b")
        try expect(seededSummary == BridgeDefaults.ollamaSummarizationModelDefault, "default gemma4:12b-mlx")
        if let savedRouting { d.set(savedRouting, forKey: BridgeDefaults.ollamaRoutingModel) }
        else { d.removeObject(forKey: BridgeDefaults.ollamaRoutingModel) }
        if let savedSummary { d.set(savedSummary, forKey: BridgeDefaults.ollamaSummarizationModel) }
        else { d.removeObject(forKey: BridgeDefaults.ollamaSummarizationModel) }
    }
}
