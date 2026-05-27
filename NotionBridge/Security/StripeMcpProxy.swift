// StripeMcpProxy.swift — MCP Client for Stripe's hosted MCP server
// NotionBridge · Security
// v1.6.0: Dynamic tool discovery via StreamableHTTP transport (JSON-RPC over HTTP POST)

import Foundation
import MCP

// MARK: - StripeMcpProxy

/// Lightweight MCP client actor that proxies tool calls to Stripe's hosted MCP server.
/// Implements StreamableHTTP transport: JSON-RPC over HTTP POST to mcp.stripe.com.
/// Bearer-token auth via Keychain-stored Stripe API key.
public actor StripeMcpProxy {
    public static let shared = StripeMcpProxy()

    private static let endpoint = URL(string: "https://mcp.stripe.com")!
    private let urlSession: URLSession
    private let apiKeyProvider: @Sendable () -> String?

    private var mcpSessionId: String?
    private var isInitialized = false
    private var cachedTools: [DiscoveredTool] = []
    private var nextRequestId: Int = 0

    /// A tool definition discovered from the Stripe MCP server.
    public struct DiscoveredTool: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: Value
    }

    public init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = {
            KeychainManager.shared.read(key: KeychainManager.Key.stripeAPIKey)
        }
    ) {
        self.urlSession = session
        self.apiKeyProvider = apiKeyProvider
    }

    // MARK: - Public API

    /// Discover available tools from the Stripe MCP server.
    /// Returns cached tools unless `force` is true.
    public func discoverTools(force: Bool = false) async throws -> [DiscoveredTool] {
        if !force && isInitialized && !cachedTools.isEmpty { return cachedTools }
        try await ensureInitialized()
        let response = try await jsonRpcRequest(method: "tools/list", params: [String: Any]())
        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw StripeMcpError.invalidResponse("tools/list: missing tools array")
        }
        cachedTools = tools.compactMap { parseToolDefinition($0) }
        return cachedTools
    }

    /// Call a tool by name with Value arguments. Returns structured result as Value.
    public func callTool(name: String, arguments: Value) async throws -> Value {
        try await ensureInitialized()
        let argsAny = Self.valueToFoundation(arguments)
        let params: [String: Any] = ["name": name, "arguments": argsAny]
        let response = try await jsonRpcRequest(method: "tools/call", params: params)

        // Check for JSON-RPC error
        if let error = response["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown MCP error"
            let code = error["code"] as? Int ?? -1
            throw StripeMcpError.serverError(code: code, message: msg)
        }

        guard let result = response["result"] as? [String: Any] else {
            throw StripeMcpError.invalidResponse("tools/call: no result object")
        }

        // Check if MCP result indicates tool-level error
        if result["isError"] as? Bool == true {
            let errorText = extractTextContent(result) ?? "Tool execution failed"
            return .object(["error": .string(errorText)])
        }

        // Extract text content and try to parse as structured JSON
        if let text = extractTextContent(result) {
            if let jsonData = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) {
                return Self.foundationToValue(json)
            }
            return .object(["result": .string(text)])
        }

        // Fallback: return full result as Value
        return Self.foundationToValue(result)
    }

    /// Reset session state (e.g., after API key rotation or reconnect).
    public func reset() {
        isInitialized = false
        mcpSessionId = nil
        cachedTools = []
        nextRequestId = 0
    }

    // MARK: - Session Lifecycle

    private func ensureInitialized() async throws {
        guard !isInitialized else { return }
        let params: [String: Any] = [
            "protocolVersion": BridgeConstants.mcpProtocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "The Bridge",  // PKT-1 v3.5: brand rename
                "version": AppVersion.marketing
            ]
        ]
        _ = try await jsonRpcRequest(method: "initialize", params: params)
        isInitialized = true
        // Send initialized notification (fire-and-forget per MCP spec)
        try? await jsonRpcNotification(method: "notifications/initialized")
    }

    // MARK: - JSON-RPC Transport

    private func jsonRpcRequest(method: String, params: Any) async throws -> [String: Any] {
        nextRequestId += 1
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": nextRequestId,
            "method": method,
            "params": params
        ]
        return try await httpPost(body: body)
    }

    private func jsonRpcNotification(method: String) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        _ = try? await httpPost(body: body)
    }

    private func httpPost(body: [String: Any]) async throws -> [String: Any] {
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw StripeMcpError.authenticationFailed
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let sid = mcpSessionId {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = jsonData
        request.timeoutInterval = 30

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            throw StripeMcpError.networkError(error)
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw StripeMcpError.invalidResponse("Non-HTTP response")
        }

        // Capture MCP session ID from response headers
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            mcpSessionId = sid
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw StripeMcpError.authenticationFailed
            }
            throw StripeMcpError.httpError(statusCode: http.statusCode, body: bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StripeMcpError.invalidResponse("Failed to parse JSON-RPC response")
        }

        return json
    }

    // MARK: - Parsing Helpers

    private func parseToolDefinition(_ json: [String: Any]) -> DiscoveredTool? {
        guard let name = json["name"] as? String else { return nil }
        let desc = json["description"] as? String ?? ""
        let schema = json["inputSchema"] as Any
        return DiscoveredTool(
            name: name,
            description: desc,
            inputSchema: Self.foundationToValue(schema)
        )
    }

    private func extractTextContent(_ result: [String: Any]) -> String? {
        guard let content = result["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    // MARK: - Value <-> Foundation Conversion

    /// Convert MCP Value to Foundation types for JSON serialization.
    static func valueToFoundation(_ value: Value) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .data(let mimeType, let data):
            var dict: [String: Any] = ["base64": data.base64EncodedString()]
            if let mimeType { dict["mimeType"] = mimeType }
            return dict
        case .array(let arr): return arr.map { valueToFoundation($0) }
        case .object(let obj): return obj.mapValues { valueToFoundation($0) }
        @unknown default: return NSNull()
        }
    }

    /// Convert Foundation types (from JSONSerialization) to MCP Value.
    static func foundationToValue(_ any: Any) -> Value {
        if let s = any as? String { return .string(s) }
        if let n = any as? NSNumber {
            // Distinguish Bool from Number (NSNumber wraps both in ObjC)
            if CFBooleanGetTypeID() == CFGetTypeID(n) { return .bool(n.boolValue) }
            if n.doubleValue == Double(n.intValue) { return .int(n.intValue) }
            return .double(n.doubleValue)
        }
        if let arr = any as? [Any] { return .array(arr.map { foundationToValue($0) }) }
        if let dict = any as? [String: Any] {
            return .object(dict.mapValues { foundationToValue($0) })
        }
        if any is NSNull { return .null }
        return .string(String(describing: any))
    }
}

// MARK: - Errors

public enum StripeMcpError: LocalizedError {
    case authenticationFailed
    case networkError(Error)
    case httpError(statusCode: Int, body: String)
    case serverError(code: Int, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Stripe API key missing or invalid. Configure via credential_save."
        case .networkError(let e):
            return "Network error connecting to Stripe MCP: \(e.localizedDescription)"
        case .httpError(let code, let body):
            return "Stripe MCP HTTP \(code): \(String(body.prefix(200)))"
        case .serverError(_, let msg):
            return "Stripe MCP server error: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid Stripe MCP response: \(msg)"
        }
    }
}
