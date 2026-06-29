// OllamaClient.swift — local Ollama HTTP client (Wave 2a)
// TheBridge · Modules · Ollama

import Foundation

public struct OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public struct GenerateOptions: Sendable {
        public var numPredict: Int
        public var temperature: Double
        public var numContext: Int
        public var think: Bool?
        public var keepAlive: String

        public init(numPredict: Int = 256, temperature: Double = 0.2, numContext: Int = 4096, think: Bool? = false, keepAlive: String = "0") {
            self.numPredict = numPredict
            self.temperature = temperature
            self.numContext = numContext
            self.think = think
            self.keepAlive = keepAlive
        }
    }

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public static func fromDefaults() -> OllamaClient {
        OllamaClient(baseURL: BridgeDefaults.ollamaBaseURLEffective)
    }

    public struct ModelInfo: Sendable, Equatable {
        public let name: String
        public let sizeBytes: Int64?
    }

    public func health() async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    public func listModels() async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OllamaError.unreachable
        }
        return try Self.parseTagsResponse(data)
    }

    public func generate(
        model: String,
        prompt: String,
        timeout: TimeInterval = 180,
        options: GenerateOptions = GenerateOptions()
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "keep_alive": options.keepAlive,
            "options": [
                "num_predict": options.numPredict,
                "temperature": options.temperature,
                "num_ctx": options.numContext,
            ],
        ]
        if let think = options.think {
            payload["think"] = think
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OllamaError.generateFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaError.invalidResponse
        }
        return try Self.extractGenerateText(from: json)
    }

    /// Pull usable text from Ollama generate JSON — handles Qwen models that
    /// spend `num_predict` tokens in `thinking` and leave `response` empty.
    public static func extractGenerateText(from json: [String: Any]) throws -> String {
        let response = (json["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !response.isEmpty { return response }

        if let thinking = json["thinking"] as? String {
            if let fromThinking = extractJSONBlock(from: thinking) { return fromThinking }
            let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw OllamaError.invalidResponse
    }

    static func extractJSONBlock(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }

    public static func parseTagsResponse(_ data: Data) throws -> [ModelInfo] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw OllamaError.invalidResponse
        }
        return models.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let size = row["size"] as? Int64
            return ModelInfo(name: name, sizeBytes: size)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public enum OllamaError: Error, LocalizedError {
    case unreachable
    case invalidResponse
    case generateFailed
    case modelNotConfigured

    public var errorDescription: String? {
        switch self {
        case .unreachable: return "Ollama is not reachable at the configured base URL"
        case .invalidResponse: return "Ollama returned an unexpected response"
        case .generateFailed: return "Ollama generate request failed"
        case .modelNotConfigured: return "No Ollama model selected for this role"
        }
    }
}
