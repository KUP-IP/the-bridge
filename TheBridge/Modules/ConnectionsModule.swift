import Foundation
import MCP

public enum ConnectionsModule {
    public static let moduleName = "connections"

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "connections_list",
            module: moduleName,
            tier: .open,
            description: "List all bridge connections across kinds (workspace, api, remote_access). Filterable by kind or provider.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "provider": .object([
                        "type": .string("string"),
                        "description": .string("Optional provider filter: notion, stripe, tunnel")
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "description": .string("Optional kind filter: workspace, api, remote_access")
                    ])
                ])
            ]),
            handler: { arguments in
                let (provider, kind) = parseConnectionFilters(arguments)
                let connections = try await ConnectionRegistry.shared.listConnections(
                    provider: provider,
                    kind: kind,
                    validateLive: true
                )
                return .object([
                    "count": .int(connections.count),
                    "connections": .array(connections.map(connectionValue))
                ])
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_get",
            module: moduleName,
            tier: .open,
            description: "Fetch one bridge connection's full record by ID (kind, provider, status, config).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "connectionId": .object([
                        "type": .string("string"),
                        "description": .string("Connection id, for example notion:primary or stripe:default")
                    ])
                ]),
                "required": .array([.string("connectionId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let connectionId) = args["connectionId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "connections_get", reason: "missing 'connectionId'")
                }
                let connection = try await ConnectionRegistry.shared.getConnection(id: connectionId, validateLive: true)
                return connectionValue(connection)
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_health",
            module: moduleName,
            tier: .open,
            description: "Cached health check for one or all bridge connections. Fast; doesn't hit the live service — use connections_validate for that.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "connectionId": .object([
                        "type": .string("string"),
                        "description": .string("Optional connection id")
                    ])
                ])
            ]),
            handler: { arguments in
                if case .object(let args) = arguments,
                   case .string(let connectionId) = args["connectionId"] {
                    let connection = try await ConnectionRegistry.shared.getConnection(id: connectionId, validateLive: true)
                    return .object([
                        "id": .string(connection.id),
                        "provider": .string(connection.provider.rawValue),
                        "status": .string(connection.status.rawValue),
                        "lastValidatedAt": stringOrNull(connection.lastValidatedAt)
                    ])
                }

                let connections = try await ConnectionRegistry.shared.listConnections(validateLive: true)
                let items = connections.map { connection in
                    Value.object([
                        "id": .string(connection.id),
                        "provider": .string(connection.provider.rawValue),
                        "status": .string(connection.status.rawValue),
                        "lastValidatedAt": stringOrNull(connection.lastValidatedAt)
                    ])
                }
                return .object([
                    "count": .int(items.count),
                    "connections": .array(items)
                ])
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_validate",
            module: moduleName,
            tier: .open,
            description: "Live round-trip validation against the remote service. Slower than connections_health; forces a fresh auth/token check.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "connectionId": .object([
                        "type": .string("string"),
                        "description": .string("Connection id")
                    ])
                ]),
                "required": .array([.string("connectionId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let connectionId) = args["connectionId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "connections_validate", reason: "missing 'connectionId'")
                }
                let connection = try await ConnectionRegistry.shared.validateConnection(id: connectionId)
                return connectionValue(connection)
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_capabilities",
            module: moduleName,
            tier: .open,
            description: "List the tools and modules a given connection exposes. Use to discover a provider's surface.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "connectionId": .object([
                        "type": .string("string"),
                        "description": .string("Connection id")
                    ])
                ]),
                "required": .array([.string("connectionId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let connectionId) = args["connectionId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "connections_capabilities", reason: "missing 'connectionId'")
                }
                let capabilities = try await ConnectionRegistry.shared.capabilities(forConnectionId: connectionId)
                return .object([
                    "connectionId": .string(connectionId),
                    "count": .int(capabilities.count),
                    "capabilities": .array(capabilities.map(Value.string))
                ])
            }
        ))
    }
}

private func parseConnectionFilters(_ arguments: Value) -> (BridgeConnectionProvider?, BridgeConnectionKind?) {
    guard case .object(let args) = arguments else {
        return (nil, nil)
    }

    let provider: BridgeConnectionProvider? = {
        guard case .string(let raw) = args["provider"] else {
            return nil
        }
        return BridgeConnectionProvider(rawValue: raw.lowercased())
    }()

    let kind: BridgeConnectionKind? = {
        guard case .string(let raw) = args["kind"] else {
            return nil
        }
        return BridgeConnectionKind(rawValue: raw.lowercased())
    }()

    return (provider, kind)
}

private func connectionValue(_ connection: BridgeConnection) -> Value {
    var object: [String: Value] = [
        "id": .string(connection.id),
        "provider": .string(connection.provider.rawValue),
        "kind": .string(connection.kind.rawValue),
        "name": .string(connection.name),
        "isPrimary": .bool(connection.isPrimary),
        "status": .string(connection.status.rawValue),
        "statusLabel": .string(connection.status.label),
        "authType": .string(connection.authType),
        "capabilities": .array(connection.capabilities.map(Value.string)),
        "metadata": .object(connection.metadata.reduce(into: [:]) { partialResult, item in
            partialResult[item.key] = .string(item.value)
        })
    ]

    object["maskedCredential"] = stringOrNull(connection.maskedCredential)
    object["lastValidatedAt"] = stringOrNull(connection.lastValidatedAt)
    object["summary"] = stringOrNull(connection.summary)
    return .object(object)
}

private func stringOrNull(_ value: String?) -> Value {
    guard let value else {
        return .null
    }
    return .string(value)
}
