import Foundation

public enum BridgeConnectionProvider: String, Codable, Sendable, CaseIterable {
    case notion
    case stripe
    case tunnel
    case generic

    public var displayName: String {
        switch self {
        case .notion:
            return "Notion"
        case .stripe:
            return "Stripe"
        case .tunnel:
            return "Tunnel"
        case .generic:
            return "Service"
        }
    }
}

public enum BridgeConnectionKind: String, Codable, Sendable, CaseIterable {
    case workspace
    case api
    case remoteAccess = "remote_access"
}

public enum BridgeConnectionStatus: String, Codable, Sendable, CaseIterable {
    case connected
    case warning
    case disconnected
    case notConfigured = "not_configured"
    case checking
    case invalid

    public var label: String {
        switch self {
        case .connected:
            return "Connected"
        case .warning:
            return "Attention"
        case .disconnected:
            return "Disconnected"
        case .notConfigured:
            return "Not Configured"
        case .checking:
            return "Checking\u{2026}"
        case .invalid:
            return "Invalid"
        }
    }

    public var systemImage: String {
        switch self {
        case .connected:
            return "circle.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .disconnected:
            return "xmark.circle.fill"
        case .notConfigured:
            return "circle.dashed"
        case .checking:
            return "circle.dotted"
        case .invalid:
            return "xmark.octagon.fill"
        }
    }
}

public struct BridgeConnection: Sendable, Codable, Identifiable {
    public let id: String
    public let provider: BridgeConnectionProvider
    public let kind: BridgeConnectionKind
    public var name: String
    public var isPrimary: Bool
    public var status: BridgeConnectionStatus
    public var authType: String
    public var maskedCredential: String?
    public var capabilities: [String]
    public var lastValidatedAt: String?
    public var summary: String?
    public var metadata: [String: String]

    public init(
        id: String,
        provider: BridgeConnectionProvider,
        kind: BridgeConnectionKind,
        name: String,
        isPrimary: Bool = false,
        status: BridgeConnectionStatus,
        authType: String,
        maskedCredential: String? = nil,
        capabilities: [String] = [],
        lastValidatedAt: String? = nil,
        summary: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.name = name
        self.isPrimary = isPrimary
        self.status = status
        self.authType = authType
        self.maskedCredential = maskedCredential
        self.capabilities = capabilities
        self.lastValidatedAt = lastValidatedAt
        self.summary = summary
        self.metadata = metadata
    }

    public static func maskSecret(_ secret: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}" }
        return "\(trimmed.prefix(4))\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(trimmed.suffix(4))"
    }
}
