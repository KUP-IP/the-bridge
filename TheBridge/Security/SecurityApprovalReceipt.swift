// SecurityApprovalReceipt.swift — exact-action approval evidence

import CryptoKit
import Foundation
import MCP

/// Server-issued evidence that a request-tier approval covered one exact tool call.
/// The receipt is task-scoped: callers cannot supply or persist it as an argument.
public struct SecurityApprovalReceipt: Sendable, Equatable {
    @TaskLocal public static var current: SecurityApprovalReceipt?

    public let receiptId: String
    public let toolName: String
    public let argumentsDigest: String
    public let approvedAt: Date
    public let transportSessionId: String?
    public let governancePrincipal: String?

    public init(
        receiptId: String = UUID().uuidString,
        toolName: String,
        argumentsDigest: String,
        approvedAt: Date = Date(),
        transportSessionId: String?,
        governancePrincipal: String?
    ) {
        self.receiptId = receiptId
        self.toolName = toolName
        self.argumentsDigest = argumentsDigest
        self.approvedAt = approvedAt
        self.transportSessionId = transportSessionId
        self.governancePrincipal = governancePrincipal
    }

    public static func issue(
        toolName: String,
        arguments: Value,
        context: ToolDispatchContext,
        approvedAt: Date = Date()
    ) -> SecurityApprovalReceipt {
        .init(
            toolName: toolName,
            argumentsDigest: digest(arguments),
            approvedAt: approvedAt,
            transportSessionId: context.transportSessionId,
            governancePrincipal: context.governancePrincipal
        )
    }

    public func validates(toolName: String, arguments: Value) -> Bool {
        self.toolName == toolName && argumentsDigest == Self.digest(arguments)
    }

    public static func digest(_ value: Value) -> String {
        SHA256.hash(data: Data(canonical(value).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonical(_ value: Value) -> String {
        switch value {
        case .string(let string):
            return "s:" + jsonString(string)
        case .object(let object):
            return "o:{" + object.keys.sorted().map { key in
                jsonString(key) + ":" + canonical(object[key] ?? .null)
            }.joined(separator: ",") + "}"
        case .array(let array):
            return "a:[" + array.map(canonical).joined(separator: ",") + "]"
        case .int(let int):
            return "i:\(int)"
        case .double(let double):
            return "d:\(double.bitPattern)"
        case .bool(let bool):
            return bool ? "b:1" : "b:0"
        case .null:
            return "n:"
        case .data(let payload):
            return "x:" + (payload.mimeType ?? "") + ":" + payload.1.base64EncodedString()
        }
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}
