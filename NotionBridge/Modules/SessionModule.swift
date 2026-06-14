// SessionModule.swift – V1-04 Session Tools (complete)
// NotionBridge · Modules

import Foundation
import MCP

// MARK: - SessionModule

/// Provides session tools: tools_list (V1-03), session_info (V1-04), session_clear (V1-04).
public enum SessionModule {

    public struct RuntimeDiagnostics: Sendable {
        public let connections: Int
        public let activeClients: Int

        public init(connections: Int, activeClients: Int) {
            self.connections = connections
            self.activeClients = activeClients
        }
    }

    public static let moduleName = "session"

    /// Session start timestamp for uptime tracking.
    private static let sessionStartTime = Date()

    /// Register all session module tools on the given router.
    /// V1-04: now accepts auditLog for session_info and session_clear.
    public static func register(
        on router: ToolRouter,
        auditLog: AuditLog,
        diagnosticsProvider: (@Sendable () async -> RuntimeDiagnostics)? = nil
    ) async {

        // tools_list – open (V1-03, preserved)
        await router.register(ToolRegistration(
            name: "tools_list",
            module: moduleName,
            tier: .open,
            description: "List MCP tools the bridge exposes. COMPACT by default (name, module, tier, one-line summary) to stay well under client output-token caps. Pass `module` to scope to one family, or `detail:true` for full descriptions + input schemas.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "module": .object([
                        "type": .string("string"),
                        "description": .string("Optional module name to filter by. If omitted, returns all tools. Scoping to a module implies detail:true.")
                    ]),
                    "detail": .object([
                        "type": .string("boolean"),
                        "description": .string("When true (or when `module` is set) each entry carries full description, input schema, tier, and output. Default false returns a compact summary so the full catalog stays under the ~25k MCP output cap.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let moduleFilter: String?
                var wantDetail = false
                if case .object(let args) = arguments {
                    if case .string(let m) = args["module"] { moduleFilter = m } else { moduleFilter = nil }
                    if case .bool(let d) = args["detail"] { wantDetail = d }
                } else {
                    moduleFilter = nil
                }
                // Scoping to a single module implies the caller wants full detail.
                let fullDetail = wantDetail || (moduleFilter != nil)

                let registrations: [ToolRegistration]
                if let filter = moduleFilter {
                    registrations = await router.registrations(forModule: filter)
                } else {
                    registrations = await router.allRegistrations()
                }

                func summarize(_ s: String) -> String {
                    let oneLine = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).joined(separator: " ")
                    return oneLine.count <= 100 ? oneLine : String(oneLine.prefix(99)) + "…"
                }

                let toolEntries: [Value] = registrations.map { reg in
                    guard fullDetail else {
                        return .object([
                            "name": .string(reg.name),
                            "module": .string(reg.module),
                            "tier": .string(reg.tier.rawValue),
                            "summary": .string(summarize(reg.description))
                        ])
                    }
                    let inputs: Value
                    if case .object(let schema) = reg.inputSchema,
                       case .object(let props) = schema["properties"] {
                        let required: [String]
                        if case .array(let reqArr) = schema["required"] {
                            required = reqArr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                        } else {
                            required = []
                        }
                        let inputItems: [Value] = props.map { key, val in
                            let propType: String
                            if case .object(let propDict) = val,
                               case .string(let t) = propDict["type"] {
                                propType = t
                            } else {
                                propType = "unknown"
                            }
                            return .object([
                                "name": .string(key),
                                "type": .string(propType),
                                "required": .bool(required.contains(key))
                            ])
                        }
                        inputs = .array(inputItems)
                    } else {
                        inputs = .array([])
                    }

                    return .object([
                        "name": .string(reg.name),
                        "module": .string(reg.module),
                        "tier": .string(reg.tier.rawValue),
                        "description": .string(reg.description),
                        "inputs": inputs,
                        "output": .string("Value")
                    ])
                }

                return .array(toolEntries)
            }
        ))

        // session_info – open (V1-04)
        await router.register(ToolRegistration(
            name: "session_info",
            module: moduleName,
            tier: .open,
            description: "Return the current bridge session's uptime, connected client count, and audit log size.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let uptime = max(0, Date().timeIntervalSince(sessionStartTime))
                let auditSize = await auditLog.count()
                let diagnostics = await diagnosticsProvider?() ?? RuntimeDiagnostics(connections: 1, activeClients: 1)
                let hours = Int(uptime) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                let seconds = Int(uptime) % 60
                let uptimeStr = String(format: "%dh %dm %ds", hours, minutes, seconds)

                return .object([
                    "uptime": .string(uptimeStr),
                    "uptimeSeconds": .double(uptime),
                    "connections": .int(diagnostics.connections),
                    "toolCalls": .int(auditSize),
                    "activeClients": .int(diagnostics.activeClients),
                    "auditLogSize": .int(auditSize)
                ])
            }
        ))

        // session_clear – notify (V1-04)
        await router.register(ToolRegistration(
            name: "session_clear",
            module: moduleName,
            tier: .notify,
            description: "Clear this session's audit log. Requires confirm: true. Irreversible for the current session only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "confirm": .object([
                        "type": .string("boolean"),
                        "description": .string("Must be true to confirm session clear")
                    ])
                ]),
                "required": .array([.string("confirm")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .bool(let confirm) = args["confirm"],
                      confirm else {
                    return .object([
                        "error": .string("session_clear requires confirm: true"),
                        "cleared": .bool(false)
                    ])
                }

                let previousUptime = max(0, Date().timeIntervalSince(sessionStartTime))
                let previousAuditSize = await auditLog.count()
                await auditLog.clear()

                return .object([
                    "cleared": .bool(true),
                    "previousUptimeSeconds": .double(previousUptime),
                    "previousAuditLogSize": .int(previousAuditSize)
                ])
            }
        ))
    }
}
