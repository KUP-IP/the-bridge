// NotionClient.swift – V1-05 → V1-12 → V1-FIX → PKT-367 Notion REST API Client
// NotionBridge · Notion
//
// Actor-based HTTP client with:
// - Rate limiting at 3 req/sec (token bucket)
// - Exponential backoff on 429 / transient errors
// - Max 3 retries per request
// - Token resolution: NOTION_API_TOKEN env var → config file fallback
// PKT-320: Updated env var to NOTION_API_TOKEN, added config file fallback,
//          added validate() method for startup health check
// PKT-332: Added verbose diagnostic logging to token resolver for cold-boot debugging
// PKT-367: API version upgrade 2022-06-28 → 2026-03-11, in_trash migration,
//          12 new API methods, multi-workspace registry support

import Foundation

// MARK: - Token Change Notification (PKT-350)

extension Notification.Name {
    /// Posted when the Notion API token is updated via Settings.
    static let notionTokenDidChange = Notification.Name("com.notionbridge.notionTokenDidChange")
}

// MARK: - Token Resolution

/// Resolves the Notion API token from environment or config file.
/// Priority: NOTION_API_TOKEN env var → NOTION_API_KEY env var (legacy) → config file
public enum NotionTokenResolver {

    /// Status of the Notion API token.
    public enum TokenStatus: Sendable {
        case available(source: String)
        case missing
    }

    /// Config file path: V3-QUALITY A2 — delegates to ConfigManager.
    public static var configFilePath: String {
        let path = ConfigManager.shared.configFileURL.path
        print("[TokenResolver] Config file path (via ConfigManager): \(path)")
        return path
    }

    /// Resolve the API token from all sources.
    /// Priority: NOTION_API_TOKEN env → NOTION_API_KEY env (legacy) → config file
    public static func resolve() -> (token: String, source: String)? {
        print("[TokenResolver] Starting token resolution...")

        // 0. Keychain (V3-QUALITY B2: primary secure storage)
        if let token = KeychainManager.shared.read(key: KeychainManager.Key.notionAPIToken),
           !token.isEmpty {
            print("[TokenResolver] ✅ Found token via Keychain")
            return (token, "keychain:notion_api_token")
        }
        print("[TokenResolver] Keychain — no token stored")

        // 1. NOTION_API_TOKEN environment variable (primary)
        if let token = ProcessInfo.processInfo.environment["NOTION_API_TOKEN"],
           !token.isEmpty {
            print("[TokenResolver] ✅ Found token via env:NOTION_API_TOKEN")
            return (token, "env:NOTION_API_TOKEN")
        }
        print("[TokenResolver] env:NOTION_API_TOKEN — not set or empty")

        // 2. NOTION_API_KEY environment variable (legacy/backward compat)
        if let token = ProcessInfo.processInfo.environment["NOTION_API_KEY"],
           !token.isEmpty {
            print("[TokenResolver] ✅ Found token via env:NOTION_API_KEY (legacy)")
            return (token, "env:NOTION_API_KEY")
        }
        print("[TokenResolver] env:NOTION_API_KEY — not set or empty")

        // 3. Config file fallback: ~/.config/notion-bridge/config.json
        print("[TokenResolver] Trying config file fallback...")
        if let token = readFromConfigFile() {
            print("[TokenResolver] ✅ Found token via config file")
            return (token, "config:\(configFilePath)")
        }
        print("[TokenResolver] ❌ All 3 sources exhausted — token not found")

        return nil
    }

    /// Check token availability without resolving the full token.
    public static func checkStatus() -> TokenStatus {
        if let result = resolve() {
            return .available(source: result.source)
        }
        return .missing
    }

    /// Read token from config file.
    /// Supports both new connections format and legacy flat format.
    /// New format: { "connections": [{ "name": "...", "token": "ntn_...", "primary": true }] }
    /// Legacy format: { "notion_api_token": "ntn_..." }
    /// V3-QUALITY A2: Reads config via ConfigManager (single source of truth).
    private static func readFromConfigFile() -> String? {
        let json = ConfigManager.shared.configJSON
        guard !json.isEmpty else {
            print("[TokenResolver] ConfigManager returned empty config")
            return nil
        }
        print("[TokenResolver] Config loaded via ConfigManager — keys: \(json.keys.sorted())")

        // New connections format — find primary connection
        if let connections = json["connections"] as? [[String: Any]] {
            if let primary = connections.first(where: { $0["primary"] as? Bool == true }),
               let token = primary["token"] as? String, !token.isEmpty {
                let name = primary["name"] as? String ?? "default"
                print("[TokenResolver] Key 'connections' found — primary connection '\(name)', token length: \(token.count)")
                return token
            }
            if let first = connections.first,
               let token = first["token"] as? String, !token.isEmpty {
                let name = first["name"] as? String ?? "default"
                print("[TokenResolver] Key 'connections' found — no primary, using first connection '\(name)', token length: \(token.count)")
                return token
            }
        }

        // Legacy flat format
        if let token = json["notion_api_token"] as? String, !token.isEmpty {
            print("[TokenResolver] Key 'notion_api_token' found — token length: \(token.count)")
            return token
        }
        if let token = json["notion_api_key"] as? String, !token.isEmpty {
            print("[TokenResolver] Key 'notion_api_key' found (legacy) — token length: \(token.count)")
            return token
        }

        print("[TokenResolver] No token keys found. Available keys: \(json.keys.sorted())")
        return nil
    }

    // MARK: - Token Management (PKT-350: F1)

    /// Read the current raw token value.
    public static func readCurrentToken() -> String? {
        return resolve()?.token
    }

    /// Masked token for UI display: ntn_•••••••1234
    public static func maskedToken() -> String {
        guard let token = readCurrentToken(), token.count >= 8 else {
            return "Not configured"
        }
        let prefix = String(token.prefix(4))
        let suffix = String(token.suffix(4))
        return "\(prefix)•••••••\(suffix)"
    }

    /// Validate token format before saving.
    public static func validateTokenFormat(_ token: String) -> (valid: Bool, error: String?) {
        guard token.count >= 20 else {
            return (false, "Token must be at least 20 characters")
        }
        guard token.hasPrefix("ntn_") || token.hasPrefix("secret_") else {
            return (false, "Token must start with 'ntn_' or 'secret_'")
        }
        return (true, nil)
    }

    /// V3-QUALITY A2+B3: Write token to both ConfigManager and Keychain.
    public static func writeToken(_ newToken: String) throws {
        ConfigManager.shared.notionAPIToken = newToken
        KeychainManager.shared.save(key: KeychainManager.Key.notionAPIToken, value: newToken)
        print("[TokenResolver] Token written via ConfigManager + Keychain")
    }
}

// MARK: - Append block children (API 2026-03-11)

/// Insert position for `PATCH /v1/blocks/{id}/children` (Notion API `2026-03-11`).
/// - `.end`: omit `position` entirely — default server behavior appends at end of parent.
/// - `.afterBlock(id:)`: send `position.type == "after_block"` with the target block id.
/// - `.start`: send `position.type == "start"` — prepend at the beginning of the parent (new in API `2026-03-11`).
public enum AppendBlocksPosition: Sendable {
    case end
    case afterBlock(id: String)
    case start
}

// MARK: - Block collection result

/// Result of depth-first block collection (`@unchecked` — JSON dictionaries from Notion API).
public struct CollectedBlocks: @unchecked Sendable {
    public let blocks: [[String: Any]]
    public let truncated: Bool
    public let truncationReason: String?

    public init(blocks: [[String: Any]], truncated: Bool, truncationReason: String?) {
        self.blocks = blocks
        self.truncated = truncated
        self.truncationReason = truncationReason
    }
}

// MARK: - NotionClient Actor

/// Thread-safe Notion REST API client with rate limiting and retry logic.
/// PKT-367: Upgraded to API v2026-03-11 with 16 total API methods.
public actor NotionClient {

    private let apiKey: String
    private let tokenSource: String
    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = BridgeConstants.notionAPIVersion
    private let maxRequestsPerSecond: Double = 3.0
    private let maxRetries = 3
    private var lastRequestTime: ContinuousClock.Instant?
    private let session: URLSession

    /// Initialize with a Notion integration API key.
    /// Resolution order: explicit parameter → NOTION_API_TOKEN env → NOTION_API_KEY env → config file
    public init(apiKey: String? = nil) throws {
        if let key = apiKey, !key.isEmpty {
            self.apiKey = key
            self.tokenSource = "explicit"
        } else if let resolved = NotionTokenResolver.resolve() {
            self.apiKey = resolved.token
            self.tokenSource = resolved.source
        } else {
            throw NotionClientError.missingAPIKey
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        print("[NotionClient] Initialized — token source: \(tokenSource)")
    }

    /// Returns the source of the resolved token (for diagnostics).
    public func getTokenSource() -> String {
        return tokenSource
    }

    /// Returns the Notion API version string (for testing).
    public func getAPIVersion() -> String {
        return notionVersion
    }

    private static func validateSingleRichTextRun(_ text: String, context: String) throws {
        let actualChars = text.count
        let maxChars = 2000
        guard actualChars <= maxChars else {
            throw NotionClientError.decodingError("\(context): rich_text.text.content exceeds Notion's 2000-character per-run limit (actualChars=\(actualChars), maxChars=\(maxChars)). Split into shorter comments, flatten list-like text into smaller runs, or use notion_code_block_append for code content.")
        }
    }

    // MARK: - Validation

    /// Validate the token by making a lightweight API call (search with empty query, 1 result).
    /// Returns true if the API responds with 200, false otherwise.
    public func validate() async -> (success: Bool, message: String) {
        do {
            let body: [String: Any] = ["query": "", "page_size": 1]
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await request(method: "POST", path: "/search", body: bodyData)
            if (200...299).contains(response.statusCode) {
                return (true, "Connected")
            } else {
                return (false, "HTTP \(response.statusCode)")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Rate Limiting

    /// Enforce rate limit: sleep if needed to stay under 3 req/sec.
    private func rateLimit() async {
        if let last = lastRequestTime {
            let minInterval = Duration.milliseconds(Int(1000.0 / maxRequestsPerSecond))
            let elapsed = ContinuousClock.now - last
            if elapsed < minInterval {
                try? await Task.sleep(for: minInterval - elapsed)
            }
        }
        lastRequestTime = .now
    }

    // MARK: - Core Request

    /// Execute an HTTP request with rate limiting and exponential backoff.
    private func request(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            await rateLimit()

            guard let url = URL(string: baseURL + path) else {
                throw NotionClientError.invalidResponse
            }

            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            if let body = body { req.httpBody = body }

            do {
                let (data, response) = try await session.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NotionClientError.invalidResponse
                }

                // Rate limited — exponential backoff
                if httpResponse.statusCode == 429 {
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    let delay: Double
                    if let retrySeconds = retryAfter.flatMap({ Double($0) }) {
                        delay = retrySeconds
                    } else {
                        delay = Double(1 << attempt) * 0.5
                    }
                    try await Task.sleep(for: .seconds(delay))
                    lastError = NotionClientError.httpError(429, "Rate limited")
                    continue
                }

                // Server errors — retry with backoff
                if httpResponse.statusCode >= 500 {
                    let delay = Double(1 << attempt) * 0.5
                    try await Task.sleep(for: .seconds(delay))
                    let body = String(data: data, encoding: .utf8) ?? ""
                    lastError = NotionClientError.httpError(httpResponse.statusCode, body)
                    continue
                }

                return (data, httpResponse)
            } catch let error as NotionClientError {
                throw error
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    let delay = Double(1 << attempt) * 0.5
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw lastError ?? NotionClientError.maxRetriesExceeded
    }

    // MARK: - Existing API Methods

    /// Search Notion workspace.
    public func search(query: String, pageSize: Int = 10) async throws -> Data {
        let body: [String: Any] = ["query": query, "page_size": pageSize]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "POST", path: "/search", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// Retrieve a page by ID.
    public func getPage(pageId: String) async throws -> Data {
        let cleanId = pageId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(method: "GET", path: "/pages/\(cleanId)")
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// Retrieve child blocks of a page or block (single API page — up to `page_size` results).
    public func getBlocks(blockId: String, pageSize: Int = 100) async throws -> Data {
        try await fetchChildBlocksRaw(blockId: blockId, startCursor: nil, pageSize: pageSize)
    }

    /// One page of `GET /blocks/{id}/children` with optional cursor (Notion pagination).
    public func fetchChildBlocksRaw(blockId: String, startCursor: String?, pageSize: Int = 100) async throws -> Data {
        let cleanId = blockId.replacingOccurrences(of: "-", with: "")
        var path = "/blocks/\(cleanId)/children?page_size=\(pageSize)"
        if let cursor = startCursor, !cursor.isEmpty {
            let encoded =
                cursor.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? cursor
            path += "&start_cursor=\(encoded)"
        }
        let (data, response) = try await request(method: "GET", path: path)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// All direct children of a block or page, following `has_more` / `next_cursor` until exhausted.
    public func fetchAllSiblingBlocks(blockId: String, pageSize: Int = 100) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var cursor: String? = nil
        while true {
            let data = try await fetchChildBlocksRaw(blockId: blockId, startCursor: cursor, pageSize: pageSize)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                throw NotionClientError.invalidResponse
            }
            all.append(contentsOf: results)
            let hasMore = json["has_more"] as? Bool ?? false
            guard hasMore, let next = json["next_cursor"] as? String, !next.isEmpty else {
                break
            }
            cursor = next
        }
        return all
    }

    /// Depth-first collection: root is typically a **page** id. `depth` starts at 1 for page-level children.
    /// Stops when `maxBlocks` or `maxDepth` would be exceeded (`truncated` true).
    public func collectBlocksDepthFirst(
        rootBlockId: String,
        includeNested: Bool,
        maxBlocks: Int,
        maxDepth: Int
    ) async throws -> CollectedBlocks {
        final class State: @unchecked Sendable {
            var collected: [[String: Any]] = []
            var truncated = false
            var truncationReason: String? = nil
            var count = 0
        }
        let state = State()

        func visit(_ parentId: String, depth: Int, state: State) async throws {
            let siblings = try await fetchAllSiblingBlocks(blockId: parentId, pageSize: 100)
            for block in siblings {
                if state.count >= maxBlocks {
                    state.truncated = true
                    state.truncationReason = "maxBlocks"
                    return
                }
                state.collected.append(block)
                state.count += 1

                let hasChildren = block["has_children"] as? Bool ?? false
                let bid = block["id"] as? String
                if includeNested, hasChildren, let bid, depth < maxDepth {
                    try await visit(bid, depth: depth + 1, state: state)
                    if state.truncated { return }
                }
            }
        }

        try await visit(rootBlockId, depth: 1, state: state)
        return CollectedBlocks(
            blocks: state.collected,
            truncated: state.truncated,
            truncationReason: state.truncationReason
        )
    }


    /// v1.9.0 B3/E5: Normalize a pageId that may be a raw UUID, a dashed UUID,
    /// a full Notion URL (".../Title-<32hex>"), or a compressed placeholder.
    /// Returns the last 32-hex-char run if found; otherwise the dash-stripped input.
    internal static func normalizePageId(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "-", with: "")
        // Find the last run of >=32 hex chars
        let chars = Array(stripped)
        var endIdx = chars.count
        while endIdx > 0 {
            var startIdx = endIdx
            while startIdx > 0, chars[startIdx - 1].isHexDigit {
                startIdx -= 1
            }
            let runLen = endIdx - startIdx
            if runLen >= 32 {
                return String(chars[(endIdx - 32)..<endIdx])
            }
            // Skip the non-hex char (or stop if we hit the beginning)
            if startIdx == 0 { break }
            endIdx = startIdx - 1
        }
        return stripped
    }

    /// Update page properties.
    public func updatePage(pageId: String, properties: Data) async throws -> Data {
        let cleanId = Self.normalizePageId(pageId)
        let (data, response) = try await request(
            method: "PATCH",
            path: "/pages/\(cleanId)",
            body: properties
        )
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    // MARK: - PKT-367: New API Methods (A3–A13)

    /// A3: Create a page under a parent (page or database).
    /// POST /v1/pages
    public func createPage(parentId: String, parentType: String = "page_id", properties: Data, children: Data? = nil) async throws -> Data {
        let cleanId = parentId.replacingOccurrences(of: "-", with: "")
        var body: [String: Any] = ["parent": [parentType: cleanId]]

        // Parse properties Data into dictionary
        if let propsObj = try? JSONSerialization.jsonObject(with: properties) {
            body["properties"] = propsObj
        }

        // Optional children blocks
        if let childrenData = children,
           let childrenObj = try? JSONSerialization.jsonObject(with: childrenData) {
            body["children"] = childrenObj
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "POST", path: "/pages", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A4: Query a data source.
    /// POST /v1/data_sources/{id}/query
    public func queryDataSource(dataSourceId: String, filter: Data? = nil, sorts: Data? = nil, pageSize: Int = 100, startCursor: String? = nil) async throws -> Data {
        let cleanId = dataSourceId.replacingOccurrences(of: "-", with: "")
        var body: [String: Any] = ["page_size": pageSize]

        if let filterData = filter,
           let filterObj = try? JSONSerialization.jsonObject(with: filterData) {
            body["filter"] = filterObj
        }
        if let sortsData = sorts,
           let sortsObj = try? JSONSerialization.jsonObject(with: sortsData) {
            body["sorts"] = sortsObj
        }
        if let cursor = startCursor {
            body["start_cursor"] = cursor
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "POST", path: "/data_sources/\(cleanId)/query", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// Builds the JSON body for append-block-children. Public for unit tests; matches Notion API `2026-03-11` (`position`, not deprecated `after`).
    nonisolated public static func buildAppendBlocksRequestBody(children: Data, position: AppendBlocksPosition) throws -> [String: Any] {
        var body: [String: Any] = [:]
        let childrenObj = try JSONSerialization.jsonObject(with: children)
        body["children"] = childrenObj

        switch position {
        case .end:
            // Omit `position` entirely; Notion appends at end of parent.
            break
        case .afterBlock(let rawId):
            // API 2026-03-11: position.type == "after_block" with after_block.id.
            let id = Self.normalizeNotionIdForJSONBody(rawId)
            body["position"] = [
                "type": "after_block",
                "after_block": [
                    "id": id
                ]
            ]
        case .start:
            // API 2026-03-11: position.type == "start" prepends at beginning of parent.
            body["position"] = [
                "type": "start"
            ]
        }
        return body
    }

    /// Normalizes a block/page UUID for JSON bodies (8-4-4-4-12). Accepts dashed or 32-char hex.
    nonisolated private static func normalizeNotionIdForJSONBody(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else {
            return trimmed
        }
        let s = String(hex)
        let i8 = s.index(s.startIndex, offsetBy: 8)
        let i12 = s.index(s.startIndex, offsetBy: 12)
        let i16 = s.index(s.startIndex, offsetBy: 16)
        let i20 = s.index(s.startIndex, offsetBy: 20)
        return "\(s[..<i8])-\(s[i8..<i12])-\(s[i12..<i16])-\(s[i16..<i20])-\(s[i20...])"
    }

    /// A5: Append child blocks to a parent block/page with optional position.
    /// PATCH /v1/blocks/{id}/children — uses `position` per API 2026-03-11 (deprecated `after` is not sent).
    public func appendBlocks(blockId: String, children: Data, position: AppendBlocksPosition = .end) async throws -> Data {
        let cleanId = blockId.replacingOccurrences(of: "-", with: "")
        let body = try Self.buildAppendBlocksRequestBody(children: children, position: position)
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "PATCH", path: "/blocks/\(cleanId)/children", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A6: Delete (trash) a block.
    /// DELETE /v1/blocks/{id}
    public func deleteBlock(blockId: String) async throws -> Data {
        let cleanId = blockId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(method: "DELETE", path: "/blocks/\(cleanId)")
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A7: Get page content as markdown.
    /// GET /v1/pages/{id}/markdown
    public func getPageMarkdown(pageId: String) async throws -> Data {
        let cleanId = pageId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(method: "GET", path: "/pages/\(cleanId)/markdown")
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }



    /// A9a: List comments on a block or page.
    /// GET /v1/comments?block_id={id}
    public func listComments(blockId: String, pageSize: Int = 100) async throws -> Data {
        let cleanId = blockId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(
            method: "GET",
            path: "/comments?block_id=\(cleanId)&page_size=\(pageSize)"
        )
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A9b: Create a comment on a page.
    /// POST /v1/comments
    public func createComment(pageId: String, text: String) async throws -> Data {
        try Self.validateSingleRichTextRun(text, context: "notion_comment_create")
        // v1.9.0 B3: accept raw UUID, dashed UUID, Notion URL, or compressed placeholder
        let cleanId = Self.normalizePageId(pageId)
        let body: [String: Any] = [
            "parent": ["page_id": cleanId],
            "rich_text": [["type": "text", "text": ["content": text]]]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "POST", path: "/comments", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A10a: List all users in the workspace.
    /// GET /v1/users
    public func listUsers(pageSize: Int = 100) async throws -> Data {
        let (data, response) = try await request(
            method: "GET",
            path: "/users?page_size=\(pageSize)"
        )
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A10b: Get a single user by ID.
    /// GET /v1/users/{id}
    public func getUser(userId: String) async throws -> Data {
        let cleanId = userId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(method: "GET", path: "/users/\(cleanId)")
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A11: Move a page to a new parent.
    /// PATCH /v1/pages/{id} with new parent
    public func movePage(pageId: String, newParentId: String, parentType: String = "page_id") async throws -> Data {
        let cleanPageId = pageId.replacingOccurrences(of: "-", with: "")
        let cleanParentId = newParentId.replacingOccurrences(of: "-", with: "")
        let body: [String: Any] = ["parent": [parentType: cleanParentId]]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "PATCH", path: "/pages/\(cleanPageId)", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A12: Upload a file (single-part ≤ 20MB).
    /// POST /v1/file_uploads (two-phase: create upload → send content)
    public func uploadFile(fileName: String, fileData: Data, contentType: String = "application/octet-stream") async throws -> Data {
        return try await uploadFileWithTrace(fileName: fileName, fileData: fileData, contentType: contentType).data
    }

    /// Upload a file and return safe phase diagnostics. Trace entries intentionally avoid tokens and file contents.
    public func uploadFileWithTrace(fileName: String, fileData: Data, contentType: String = "application/octet-stream") async throws -> (data: Data, trace: [String]) {
        var trace: [String] = ["phase=create_upload status=starting fileName=\(fileName) contentType=\(contentType) bytes=\(fileData.count)"]
        let createBody: [String: Any] = [
            "file_name": fileName,
            "content_type": contentType,
            "mode": "single_part"
        ]
        let createData = try JSONSerialization.data(withJSONObject: createBody)
        let (createResponseData, createHttp) = try await request(method: "POST", path: "/file_uploads", body: createData)
        trace.append("phase=create_upload httpStatus=\(createHttp.statusCode)")
        guard (200...299).contains(createHttp.statusCode) else {
            let msg = String(data: createResponseData, encoding: .utf8) ?? ""
            throw NotionClientError.decodingError("notion_file_upload failed during phase=create_upload httpStatus=\(createHttp.statusCode) body=\(String(msg.prefix(500)))")
        }

        guard let createJSON = try? JSONSerialization.jsonObject(with: createResponseData) as? [String: Any],
              let uploadId = createJSON["id"] as? String else {
            throw NotionClientError.decodingError("notion_file_upload failed during phase=parse_create_response: missing file_upload id")
        }

        trace.append("phase=send status=starting uploadId=\(uploadId)")
        let boundary = "NotionBridge-\(UUID().uuidString)"
        var bodyData = Data()
        bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
        bodyData.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        bodyData.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        bodyData.append(fileData)
        bodyData.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await request(
            method: "POST",
            path: "/file_uploads/\(uploadId)/send",
            body: bodyData,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        trace.append("phase=send httpStatus=\(response.statusCode)")
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.decodingError("notion_file_upload failed during phase=send httpStatus=\(response.statusCode) body=\(String(msg.prefix(500)))")
        }
        trace.append("phase=complete status=success")
        return (data, trace)
    }

    /// A13: Get bot user identity (token introspection).
    /// GET /v1/users/me
    public func introspectToken() async throws -> Data {
        let (data, response) = try await request(method: "GET", path: "/users/me")
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    // MARK: - Block Operations (v1.7.0)

    /// A14: Retrieve a single block by ID.
    /// GET /v1/blocks/{block_id}
    public func getBlock(blockId: String) async throws -> Data {
        let cleanId = blockId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(method: "GET", path: "/blocks/" + cleanId)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// A15: Update a block by ID.
    /// PATCH /v1/blocks/{block_id}
    public func updateBlock(blockId: String, data body: [String: Any]) async throws -> Data {
        let cleanId = blockId.replacingOccurrences(of: "-", with: "")
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "PATCH", path: "/blocks/" + cleanId, body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    // MARK: - Database Schema (v1.7.0)

    /// A16: Retrieve a database schema by ID.
    /// GET /v1/databases/{database_id}
    public func getDatabase(databaseId: String) async throws -> Data {
        let cleanId = databaseId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(method: "GET", path: "/databases/" + cleanId)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// B2 (v1.8.0): Retrieve a data source schema by ID.
    /// GET /v1/data_sources/{data_source_id}
    public func getDataSource(dataSourceId: String) async throws -> Data {
        let cleanId = dataSourceId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(method: "GET", path: "/data_sources/" + cleanId)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    // MARK: - Data Source Schema Write (v1.8.5)

    /// B3 (v1.8.5): Update a data source schema by ID.
    /// PATCH /v1/data_sources/{data_source_id}
    public func updateDataSource(dataSourceId: String, properties: Data) async throws -> Data {
        let cleanId = dataSourceId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(
            method: "PATCH",
            path: "/data_sources/" + cleanId,
            body: properties
        )
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// B4 (v1.8.5): Create a new data source under a database.
    /// POST /v1/data_sources
    public func createDataSource(databaseId: String, properties: Data, title: String? = nil, parentType: String = "database_id") async throws -> Data {
        // v1.9.1 B2+E1: accept page_id parent for "create new database with page parent" path.
        // Notion API supports parent: { type: "page_id", page_id: "..." } natively; previous
        // hard-wired database_id caused 404 object_not_found when a page ID was passed.
        let cleanId = Self.normalizePageId(databaseId)
        let parentKey = parentType == "page_id" ? "page_id" : "database_id"
        var body: [String: Any] = ["parent": [parentKey: cleanId]]

        if let propsObj = try? JSONSerialization.jsonObject(with: properties) {
            body["properties"] = propsObj
        }

        if let title = title {
            body["title"] = [["type": "text", "text": ["content": title]]]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "POST", path: "/data_sources", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// E5 (v1.9.1): Create a new discussion thread on a page.
    /// POST /v1/comments with parent.page_id (no discussion_id → starts a new thread).
    /// Accepts raw UUID, dashed UUID, Notion URL, or compressed placeholder (via normalizePageId).
    public func createDiscussion(pageId: String, text: String) async throws -> Data {
        try Self.validateSingleRichTextRun(text, context: "notion_discussion_create")
        let cleanId = Self.normalizePageId(pageId)
        let body: [String: Any] = [
            "parent": ["page_id": cleanId],
            "rich_text": [["type": "text", "text": ["content": text]]]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "POST", path: "/comments", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// E3 (v1.9.1): Update a code block by chunking a long string into
    /// sequential rich_text runs (each ≤2000 chars to respect Notion's
    /// per-run cap). Block must already be a code block.
    public func updateCodeBlockChunked(blockId: String, content: String, language: String? = nil) async throws -> Data {
        let cleanId = Self.normalizePageId(blockId)
        // Chunk content into ≤2000-char pieces. Notion caps rich_text.text.content at 2000.
        let maxChunk = 2000
        var chunks: [String] = []
        var idx = content.startIndex
        while idx < content.endIndex {
            let end = content.index(idx, offsetBy: maxChunk, limitedBy: content.endIndex) ?? content.endIndex
            chunks.append(String(content[idx..<end]))
            idx = end
        }
        if chunks.isEmpty { chunks = [""] }
        let richText: [[String: Any]] = chunks.map { chunk in
            ["type": "text", "text": ["content": chunk]]
        }
        var codePayload: [String: Any] = ["rich_text": richText]
        if let language = language { codePayload["language"] = language }
        let body: [String: Any] = ["code": codePayload]
        return try await updateBlock(blockId: cleanId, data: body)
    }
}
