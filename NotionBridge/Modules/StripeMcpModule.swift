// StripeMcpModule.swift — Dynamic Stripe MCP Tool Registration
// NotionBridge · Modules
// v1.7.0: Adds 3-attempt exponential backoff + stripe_reconnect sentinel tool.
// Tools are discovered dynamically via mcp.stripe.com — no hardcoded tool definitions.

import Foundation
import MCP

// MARK: - StripeMcpModule

public enum StripeMcpModule {
    public static let moduleName = "stripe"

    /// Maximum retry attempts for tool discovery at startup.
    private static let maxRetries = 3
    /// Base delay in seconds for exponential backoff (2s → 4s → 8s).
    private static let baseDelay: UInt64 = 2

    /// Register all discovered Stripe MCP tools on the given router.
    /// Retries up to 3 times with exponential backoff (2s → 4s → 8s) on transient failures.
    /// If all retries fail, registers a `stripe_reconnect` sentinel tool for manual recovery.
    /// Authentication failures (missing API key) fail immediately — no retries.
    public static func register(on router: ToolRouter) async {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                // Clear stale session state before retries
                if attempt > 1 {
                    await StripeMcpProxy.shared.reset()
                }

                let tools = try await StripeMcpProxy.shared.discoverTools()
                await registerDiscoveredTools(tools, on: router)
                if !tools.isEmpty {
                    print("[StripeMcpModule] Registered \(tools.count) tools from Stripe MCP server")
                }
                return // Success — exit retry loop
            } catch StripeMcpError.authenticationFailed {
                // API key missing or invalid — no point retrying
                let keyStatus = apiKeyPresent() ? "present but invalid" : "absent"
                print("[StripeMcpModule] ⚠️ Startup discovery failed (attempt \(attempt)/\(maxRetries)): authenticationFailed. API key: \(keyStatus). Stripe tools unavailable — call stripe_reconnect to retry.")
                lastError = StripeMcpError.authenticationFailed
                break
            } catch {
                lastError = error
                let keyStatus = apiKeyPresent() ? "present" : "absent"
                print("[StripeMcpModule] ⚠️ Startup discovery failed (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription). API key: \(keyStatus).")

                if attempt < maxRetries {
                    let delay = baseDelay * UInt64(1 << (attempt - 1)) // 2s, 4s, 8s
                    print("[StripeMcpModule] Retrying in \(delay)s...")
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                }
            }
        }

        // All retries exhausted or auth failure — register sentinel tool
        let keyStatus = apiKeyPresent() ? "present" : "absent"
        let reason = lastError?.localizedDescription ?? "unknown"
        print("[StripeMcpModule] ⚠️ All discovery attempts exhausted. Last error: \(reason). API key: \(keyStatus). Registering stripe_reconnect for manual recovery.")
        await registerReconnectSentinel(on: router)
    }

    /// Register discovered Stripe tools on the router.
    private static func registerDiscoveredTools(
        _ tools: [StripeMcpProxy.DiscoveredTool],
        on router: ToolRouter
    ) async {
        for tool in tools {
            let tier = securityTier(for: tool.name)
            let isDestructive = isDestructiveOperation(tool.name)
            let isDeprecated = StripeDeprecationShim.deprecatedToolNames.contains(tool.name)

            let baseDescription = Self.customerFacingDescription(tool.description)
            let description = isDeprecated
                ? StripeDeprecationShim.decoratedDescription(
                    originalDescription: baseDescription,
                    toolName: tool.name)
                : baseDescription

            // PKT-754: For 25 long-tail Stripe tools, replace the pass-through
            // handler with a deprecation shim that emits a warning, increments a
            // telemetry counter, translates args, and forwards to stripe_api_execute
            // (or stripe_api_search for the two aggregator tools). Two-release ramp:
            // warn now (v2.2), hard-remove in v2.3.
            let handler: @Sendable (Value) async throws -> Value
            if isDeprecated {
                handler = StripeDeprecationShim.wrapHandler(toolName: tool.name)
            } else {
                handler = { [name = tool.name] arguments in
                    do {
                        return try await StripeMcpProxy.shared.callTool(
                            name: name,
                            arguments: arguments
                        )
                    } catch {
                        return .object(["error": .string(error.localizedDescription)])
                    }
                }
            }

            await router.register(ToolRegistration(
                name: tool.name,
                module: moduleName,
                tier: tier,
                neverAutoApprove: isDestructive,
                description: description,
                inputSchema: tool.inputSchema,
                handler: handler
            ))
        }
    }

    /// Register the stripe_reconnect sentinel tool for manual session recovery.
    /// On successful reconnection, registers all discovered tools and deregisters itself.
    private static func registerReconnectSentinel(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "stripe_reconnect",
            module: moduleName,
            tier: .open,
            neverAutoApprove: false,
            description: "Retry connecting to the Stripe MCP server. Call this if Stripe tools are unavailable after startup.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { _ in
                do {
                    await StripeMcpProxy.shared.reset()
                    let tools = try await StripeMcpProxy.shared.discoverTools(force: true)

                    // Register all discovered tools on the live router
                    await Self.registerDiscoveredTools(tools, on: router)

                    // Deregister the sentinel tool — no longer needed
                    await router.deregister(name: "stripe_reconnect")

                    print("[StripeMcpModule] Reconnected — registered \(tools.count) tools from Stripe MCP server")
                    return .object([
                        "status": .string("reconnected"),
                        "tools_registered": .int(tools.count)
                    ])
                } catch {
                    return .object([
                        "status": .string("failed"),
                        "error": .string(error.localizedDescription)
                    ])
                }
            }
        ))
    }

    /// Check whether a Stripe API key is present in the Keychain.
    private static func apiKeyPresent() -> Bool {
        if let key = KeychainManager.shared.read(key: KeychainManager.Key.stripeAPIKey),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    /// Short, customer-readable line for Settings and MCP listings (Stripe's API may return long copy).
    private static func customerFacingDescription(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Stripe account or payment tool." }
        if let range = trimmed.range(of: ". ") {
            return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) + "."
        }
        if trimmed.count > 180 {
            return String(trimmed.prefix(177)) + "..."
        }
        return trimmed
    }

    /// Returns the list of currently discovered tool names (for ConnectionRegistry capabilities).
    public static func discoveredToolNames() async -> [String] {
        do {
            let tools = try await StripeMcpProxy.shared.discoverTools()
            return tools.map { $0.name }
        } catch {
            return []
        }
    }

    // MARK: - Security Tier Mapping

    /// Map tool names to SecurityGate tiers based on operation semantics.
    /// Read → .notify (user sees notification, no approval needed)
    /// Write → .request (user must approve)
    /// Delete → .request + neverAutoApprove (always confirm, never auto-approve)
    private static func securityTier(for toolName: String) -> SecurityTier {
        let lower = toolName.lowercased()

        // Read-only operations
        if lower.hasPrefix("list") || lower.hasPrefix("get") || lower.hasPrefix("retrieve")
            || lower.hasPrefix("search") || lower.hasPrefix("read")
            || lower.contains("_list") || lower.contains("_read") || lower.contains("_get") {
            return .notify
        }

        // Destructive operations
        if lower.hasPrefix("delete") || lower.hasPrefix("remove")
            || lower.hasPrefix("cancel") || lower.hasPrefix("void") {
            return .request
        }

        // Write operations (create, update, set, etc.)
        if lower.hasPrefix("create") || lower.hasPrefix("update")
            || lower.hasPrefix("set") || lower.hasPrefix("add")
            || lower.hasPrefix("modify") || lower.hasPrefix("edit") {
            return .request
        }

        // Default to .request for safety on unknown operations
        return .request
    }

    /// Check if a tool name represents a destructive (irreversible) operation.
    private static func isDestructiveOperation(_ toolName: String) -> Bool {
        let lower = toolName.lowercased()
        return lower.hasPrefix("delete") || lower.hasPrefix("remove")
            || lower.hasPrefix("cancel") || lower.hasPrefix("void")
            || lower.hasPrefix("archive")
    }
}
