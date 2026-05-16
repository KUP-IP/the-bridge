// CredentialModule.swift — Credential MCP Tools
// NotionBridge · Modules
// PKT-372: 4 MCP tools for polymorphic credential vault.
//
// Security tiers:
// - credential_save:   .request (outer) + LAContext biometric (inner)
// - credential_read:   .request (no biometric — approval is sufficient)
// - credential_list:   .notify  (fire-and-forget notification)
// - credential_delete: .request (outer) + LAContext biometric (inner)

import Foundation
import MCP

// MARK: - CredentialModule

/// Provides 4 MCP tools for polymorphic credential CRUD.
/// Biometric enforcement (LAContext) is handled inside CredentialManager
/// on the write path (save/delete). SecurityGate tier enforcement is
/// handled by ToolRouter at the dispatch level.
public enum CredentialModule {

    public static let moduleName = "credential"

    /// Register all CredentialModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: credential_save — request tier + biometric
        await router.register(ToolRegistration(
            name: "credential_save",
            module: moduleName,
            tier: .request,
            description: "Save a password, API key, or payment card to the macOS Keychain. Cards are tokenized; optional iCloud Keychain sync. Requires user approval.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "service": .object([
                        "type": .string("string"),
                        "description": .string("Service name (e.g., 'github.com', 'aws-prod')")
                    ]),
                    "account": .object([
                        "type": .string("string"),
                        "description": .string("Account identifier (e.g., username or email)")
                    ]),
                    "password": .object([
                        "type": .string("string"),
                        "description": .string("Password or card number to store")
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "description": .string("Credential type: 'password' (default), 'card', or 'api_key'")
                    ]),
                    "metadata": .object([
                        "type": .string("object"),
                        "description": .string("Optional metadata JSON. For cards: {brand, last4, exp_month, exp_year, cardholder_name, zip_code}")
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Cardholder name (card type only, optional).")
                    ]),
                    "zipCode": .object([
                        "type": .string("string"),
                        "description": .string("Billing ZIP / postal code (card type only, optional). (legacy alias: zip_code)")
                    ]),
                    "syncToiCloud": .object([
                        "type": .string("boolean"),
                        "description": .string("Sync to iCloud Keychain (default: false)")
                    ])
                ]),
                "required": .array([.string("service"), .string("account"), .string("password")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let service) = args["service"],
                      case .string(let account) = args["account"],
                      case .string(let password) = args["password"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "credential_save",
                        reason: "missing required 'service', 'account', or 'password' parameter"
                    )
                }

                let typeStr: String = {
                    if case .string(let t) = args["type"] { return t }
                    return "password"
                }()
                guard let credType = CredentialType(rawValue: typeStr) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "credential_save",
                        reason: "invalid type '\(typeStr)'. Must be 'password', 'card', or 'api_key'"
                    )
                }

                var metadata = CredentialMetadata.empty
                if case .object(let metaDict) = args["metadata"] {
                    if case .string(let b) = metaDict["brand"] { metadata.brand = b }
                    if case .string(let l) = metaDict["last4"] { metadata.last4 = l }
                    if case .int(let m) = metaDict["exp_month"] { metadata.expMonth = m }
                    if case .int(let y) = metaDict["exp_year"] { metadata.expYear = y }
                    if case .string(let n) = metaDict["cardholder_name"] { metadata.cardholderName = n }
                    if case .string(let z) = metaDict["zip_code"] { metadata.zipCode = z }
                }
                // PKT-573: top-level name / zipCode (card type). Override metadata if provided.
                // v3.0·0.5: zipCode is canonical; zip_code accepted as legacy alias (Q2).
                if case .string(let n) = args["name"] { metadata.cardholderName = n }
                if case .string(let z) = args["zipCode"] { metadata.zipCode = z }
                else if case .string(let z) = args["zip_code"] { metadata.zipCode = z }

                let sync: Bool = {
                    if case .bool(let s) = args["syncToiCloud"] { return s }
                    return false
                }()

                do {
                    let entry = try await CredentialManager.shared.save(
                        service: service,
                        account: account,
                        password: password,
                        type: credType,
                        metadata: metadata,
                        syncToiCloud: sync
                    )

                    var result: [String: Value] = [
                        "service": .string(entry.service),
                        "account": .string(entry.account),
                        "type": .string(entry.type.rawValue),
                        "created": .string(ISO8601DateFormatter().string(from: entry.createdAt ?? Date()))
                    ]

                    if credType == .card {
                        result["last4"] = .string(entry.metadata.last4 ?? "")
                        result["brand"] = .string(entry.metadata.brand ?? "unknown")
                        if let pm = entry.metadata.stripePm {
                            result["stripe_pm"] = .string(pm)
                        }
                    }

                    return .object(result)
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))

        // MARK: credential_read — request tier (no biometric)
        await router.register(ToolRegistration(
            name: "credential_read",
            module: moduleName,
            tier: .request,
            description: "Read one credential from the Keychain by service + account. Requires user approval.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "service": .object([
                        "type": .string("string"),
                        "description": .string("Service name to look up")
                    ]),
                    "account": .object([
                        "type": .string("string"),
                        "description": .string("Account identifier to look up")
                    ])
                ]),
                "required": .array([.string("service"), .string("account")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let service) = args["service"],
                      case .string(let account) = args["account"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "credential_read",
                        reason: "missing required 'service' or 'account' parameter"
                    )
                }

                do {
                    let entry = try CredentialManager.shared.read(
                        service: service, account: account
                    )

                    var result: [String: Value] = [
                        "service": .string(entry.service),
                        "account": .string(entry.account),
                        "type": .string(entry.type.rawValue),
                        "password_or_token": .string(entry.password ?? "")
                    ]

                    var meta: [String: Value] = [:]
                    if let b = entry.metadata.brand { meta["brand"] = .string(b) }
                    if let l = entry.metadata.last4 { meta["last4"] = .string(l) }
                    if let m = entry.metadata.expMonth { meta["exp_month"] = .int(m) }
                    if let y = entry.metadata.expYear { meta["exp_year"] = .int(y) }
                    if let pm = entry.metadata.stripePm { meta["stripe_pm"] = .string(pm) }
                    result["metadata"] = .object(meta)

                    return .object(result)
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))

        // MARK: credential_list — notify tier
        await router.register(ToolRegistration(
            name: "credential_list",
            module: moduleName,
            tier: .notify,
            description: "List Keychain credentials — service + account names only, never secret values.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filter": .object([
                        "type": .string("string"),
                        "description": .string("Optional service name filter (substring match)")
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "description": .string("Optional type filter: 'password' or 'card'")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                let typeFilter: CredentialType? = {
                    if case .string(let t) = args["type"] {
                        return CredentialType(rawValue: t)
                    }
                    return nil
                }()

                let serviceFilter: String? = {
                    if case .string(let f) = args["filter"] { return f }
                    return nil
                }()

                do {
                    var entries = try CredentialManager.shared.list(type: typeFilter)

                    if let filter = serviceFilter {
                        let lowered = filter.lowercased()
                        entries = entries.filter {
                            $0.service.lowercased().contains(lowered)
                        }
                    }

                    let items: [Value] = entries.map { entry in
                        var item: [String: Value] = [
                            "service": .string(entry.service),
                            "account": .string(entry.account),
                            "type": .string(entry.type.rawValue)
                        ]

                        if entry.type == .card {
                            if let l = entry.metadata.last4 { item["last4"] = .string(l) }
                            if let b = entry.metadata.brand { item["brand"] = .string(b) }
                            if let m = entry.metadata.expMonth { item["exp_month"] = .int(m) }
                            if let y = entry.metadata.expYear { item["exp_year"] = .int(y) }
                        }

                        if let created = entry.createdAt {
                            item["created"] = .string(ISO8601DateFormatter().string(from: created))
                        }
                        if let modified = entry.modifiedAt {
                            item["modified"] = .string(ISO8601DateFormatter().string(from: modified))
                        }

                        return .object(item)
                    }

                    return .object([
                        "credentials": .array(items),
                        "count": .int(items.count)
                    ])
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))

        // MARK: credential_delete — request tier + biometric
        await router.register(ToolRegistration(
            name: "credential_delete",
            module: moduleName,
            tier: .request,
            description: "Delete one Keychain credential by service + account. Irreversible. Requires user approval.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "service": .object([
                        "type": .string("string"),
                        "description": .string("Service name of the credential to delete")
                    ]),
                    "account": .object([
                        "type": .string("string"),
                        "description": .string("Account identifier of the credential to delete")
                    ])
                ]),
                "required": .array([.string("service"), .string("account")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let service) = args["service"],
                      case .string(let account) = args["account"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "credential_delete",
                        reason: "missing required 'service' or 'account' parameter"
                    )
                }

                do {
                    _ = try await CredentialManager.shared.deleteCredential(
                        service: service,
                        account: account
                    )
                    return .object([
                        "service": .string(service),
                        "account": .string(account),
                        "deleted": .bool(true)
                    ])
                } catch {
                    return .object(["error": .string(error.localizedDescription)])
                }
            }
        ))
    }
}
