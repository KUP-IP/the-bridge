// ConnectionSetupView.swift — Connection Setup & Tunnel Status
// Notion Bridge v1: Minimal tunnel status display with provider selection
// PKT-329: V1-14b Connection Setup UI

import AppKit
import Security
import SwiftUI

// MARK: - Tunnel Provider

/// Tunnel provider options for connecting Notion agents to the local MCP server.
public enum TunnelProvider: String, CaseIterable, Identifiable {
    case cloudflare = "Cloudflare"
    case tailscale = "Tailscale"
    case manual = "Manual URL"

    public var id: String { rawValue }

    var displayDescription: String {
        switch self {
        case .cloudflare: return "Easiest setup for a public HTTPS URL"
        case .tailscale: return "Private network URL for your own devices/team"
        case .manual: return "Paste a URL from another tunnel provider"
        }
    }

    var icon: String {
        switch self {
        case .cloudflare: return "cloud.fill"
        case .tailscale: return "network"
        case .manual: return "link"
        }
    }
}

// MARK: - Remote Access Status

/// Three-state status for the remote access indicator, mirroring
/// the server's `MCPHTTPValidation.streamableHTTPBearerPhase()` logic.
private enum RemoteAccessStatus {
    /// Tunnel URL + bearer token both configured — remote access is active.
    case active
    /// Tunnel URL is set but no bearer token — server will 401 all requests.
    case misconfigured
    /// No tunnel URL — remote access is off.
    case notConfigured

    var dotColor: Color {
        switch self {
        case .active: return BridgeTokens.ok
        case .misconfigured: return BridgeTokens.warn
        case .notConfigured: return BridgeTokens.fg4
        }
    }

    var label: String {
        switch self {
        case .active: return "" // caller uses provider name
        case .misconfigured: return "Token required"
        case .notConfigured: return "Not configured"
        }
    }

    static func resolve(tunnelURL: String, bearerToken: String) -> RemoteAccessStatus {
        let url = tunnelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return .notConfigured }
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? .misconfigured : .active
    }
}

// MARK: - Connection Setup View

/// Displays tunnel status and provider selection for connecting remote Notion agents.
/// Settings are persisted to UserDefaults via explicit Save action (tunnel URL)
/// or immediate persistence (bearer token Generate/Clear).
public struct ConnectionSetupView: View {
    @AppStorage("tunnelProvider") private var selectedProvider: String = TunnelProvider.cloudflare.rawValue
    @State private var isExpanded: Bool = false

    // Draft URL — decoupled from UserDefaults to prevent text field focus bugs.
    // Loaded from UserDefaults on appear; written on explicit Save.
    @State private var draftURL: String = ""
    @State private var savedURL: String = ""
    @State private var urlValidationError: String?
    @State private var showSaveConfirmation: Bool = false

    // Bearer token state
    @State private var mcpBearerToken: String = ""
    @State private var saveBearerTask: Task<Void, Never>?
    @State private var showBearerWarning: Bool = false

    /// SSE port resolution: config.json -> env var -> default.
    private var ssePort: Int {
        ConfigManager.shared.ssePort
    }

    public init() {}

    private var activeProvider: TunnelProvider {
        TunnelProvider(rawValue: selectedProvider) ?? .cloudflare
    }

    /// Whether the draft URL differs from the persisted URL.
    private var hasUnsavedURLChanges: Bool {
        draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
            != savedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Current remote access status based on persisted (saved) state.
    private var remoteStatus: RemoteAccessStatus {
        RemoteAccessStatus.resolve(tunnelURL: savedURL, bearerToken: mcpBearerToken)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusHeader
            if isExpanded { expandedContent }
        }
        .onAppear {
            loadFromStorage()
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(remoteStatus.dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: remoteStatus.dotColor.opacity(0.5), radius: 3)
            Text("Remote Access")
                .font(.system(size: 13.5))
                .foregroundStyle(BridgeTokens.fg1)
            Spacer()
            Text(remoteStatus == .active ? activeProvider.rawValue : remoteStatus.label)
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg4)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(BridgeTokens.fg4)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            "Remote Access, \(remoteStatus == .active ? activeProvider.rawValue : remoteStatus.label), \(isExpanded ? "expanded" : "collapsed")"
        )
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Provider selection
            ForEach(TunnelProvider.allCases) { provider in
                providerRow(provider)
            }

            Divider()

            // Tunnel URL + Save button
            tunnelURLSection

            // Bearer token (shown when a URL is saved)
            if !savedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                mcpBearerSection
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Tunnel URL Section

    private var tunnelURLSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Tunnel URL", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: draftURL) { _, _ in
                        // Clear validation error as user types
                        urlValidationError = nil
                        showSaveConfirmation = false
                    }

                Button("Save") {
                    saveTunnelURL()
                }
                .controlSize(.small)
                .disabled(!hasUnsavedURLChanges)
            }

            // Validation error
            if let error = urlValidationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(BridgeTokens.bad)
            }

            // Save confirmation
            if showSaveConfirmation {
                Text("Saved")
                    .font(.caption2)
                    .foregroundStyle(BridgeTokens.ok)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - MCP Remote Token

    private var mcpBearerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BEARER TOKEN")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(BridgeTokens.fg4)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SecureField("Bearer token", text: $mcpBearerToken)
                    .textContentType(.none)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: mcpBearerToken) { _, newValue in
                        schedulePersistMCPBearer(newValue)
                    }
                Button("Generate") {
                    let token = Self.makeRandomBearerToken()
                    mcpBearerToken = token
                    persistMCPBearerImmediate(token)
                    postRemoteAccessConfigChange()
                    showBearerWarningBriefly()
                }
                .controlSize(.small)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcpBearerToken, forType: .string)
                }
                .controlSize(.small)
                .disabled(mcpBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Clear") {
                    mcpBearerToken = ""
                    persistMCPBearerImmediate("")
                    postRemoteAccessConfigChange()
                    showBearerWarningBriefly()
                }
                .controlSize(.small)
            }

            // Warning after Generate/Clear
            if showBearerWarning {
                Text("Active clients disconnected — reconnect with the new token.")
                    .font(.caption2)
                    .foregroundStyle(BridgeTokens.warn)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Storage

    private func loadFromStorage() {
        let persisted = UserDefaults.standard.string(forKey: "tunnelURL") ?? ""
        draftURL = persisted
        savedURL = persisted
        refreshMCPBearerFromStorage()
    }

    private func saveTunnelURL() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate: empty is allowed (clears remote access), otherwise must parse
        if !trimmed.isEmpty {
            let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            guard let url = URL(string: withScheme), url.host != nil else {
                urlValidationError = "Invalid URL — must be a valid hostname or URL"
                return
            }
        }

        // Persist
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "tunnelURL")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "tunnelURL")
        }
        savedURL = trimmed
        urlValidationError = nil

        // Notify server to invalidate sessions and rebuild validation pipeline
        postRemoteAccessConfigChange()

        // Show confirmation
        showSaveConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showSaveConfirmation = false
        }
    }

    private func refreshMCPBearerFromStorage() {
        mcpBearerToken = MCPHTTPValidation.resolveMCPBearerToken()
    }

    private func schedulePersistMCPBearer(_ value: String) {
        saveBearerTask?.cancel()
        saveBearerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            persistMCPBearerImmediate(value)
        }
    }

    private func persistMCPBearerImmediate(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            _ = KeychainManager.shared.delete(key: KeychainManager.Key.mcpBearerToken)
            UserDefaults.standard.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        } else {
            _ = KeychainManager.shared.save(key: KeychainManager.Key.mcpBearerToken, value: trimmed)
            UserDefaults.standard.set(trimmed, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        }
    }

    private static func makeRandomBearerToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let st = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(st == errSecSuccess, "SecRandomCopyBytes failed: \(st)")
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Notifications

    private func postRemoteAccessConfigChange() {
        NotificationCenter.default.post(name: .remoteAccessConfigDidChange, object: nil)
    }

    private func showBearerWarningBriefly() {
        showBearerWarning = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            showBearerWarning = false
        }
    }

    // MARK: - Provider Row

    private func providerRow(_ provider: TunnelProvider) -> some View {
        let on = activeProvider == provider
        return Button {
            selectedProvider = provider.rawValue
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(on ? BridgeTokens.accentLink : BridgeTokens.hairlineStrong,
                                      lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if on {
                        Circle().fill(BridgeTokens.accentLink).frame(width: 7, height: 7)
                    }
                }
                Image(systemName: provider.icon)
                    .foregroundStyle(BridgeTokens.fg4)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text(provider.displayDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                on
                ? AnyShapeStyle(LinearGradient(
                    colors: [BridgeTokens.accent.opacity(0.18), BridgeTokens.accent.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(BridgeTokens.wellFill),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on ? BridgeTokens.accent.opacity(0.50) : BridgeTokens.hairline,
                                  lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
