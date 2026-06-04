// ProvisioningProgressView.swift — WS-F (Bridge Cloud Access · Enable flow)
// NotionBridge · UI · Sections
//
// Renders `EnableCloudAccessFlow.state` while the Enable Cloud Access toggle
// is provisioning. Inline in `RemoteAccessSection` (under the toggle row).
//
// The state→presentation mapping is factored into the pure, Sendable
// `ProvisioningPresentation` value so it is unit-asserted headlessly (no
// SwiftUI render, no WindowServer) — the same headless-decision shape the
// rest of the app uses (CommandsController, the streamableHTTP gate, …).
// The SwiftUI view is a thin renderer over that mapping.

import SwiftUI

/// Pure, deterministic description of what the progress UI shows for a given
/// flow state. Unit-tested directly (DoD: "ProvisioningProgressView shows
/// correct state for all flow states").
public struct ProvisioningPresentation: Sendable, Equatable {
    /// Which visual the row leads with.
    public enum Indicator: Sendable, Equatable {
        case none           // .idle — nothing shown
        case spinner        // .checkingAccount / .provisioning — indeterminate
        case browser        // .signingIn — "opening browser" affordance
        case success        // .connected — checkmark
        case failure        // .failed — error glyph + Retry
    }

    public let indicator: Indicator
    public let title: String
    /// Whether a Retry affordance is offered (only on `.failed`).
    public let showsRetry: Bool
    /// Whether the connected MCP URL row is shown (only on `.connected`).
    public let showsURL: Bool

    public init(indicator: Indicator, title: String, showsRetry: Bool, showsURL: Bool) {
        self.indicator = indicator
        self.title = title
        self.showsRetry = showsRetry
        self.showsURL = showsURL
    }

    /// Map a flow state to its presentation. Total over the state enum.
    public static func make(for state: EnableCloudAccessState) -> ProvisioningPresentation {
        switch state {
        case .idle:
            return .init(indicator: .none, title: "", showsRetry: false, showsURL: false)
        case .checkingAccount:
            return .init(indicator: .spinner, title: "Checking your account…",
                         showsRetry: false, showsURL: false)
        case .signingIn:
            return .init(indicator: .browser, title: "Opening browser for sign in…",
                         showsRetry: false, showsURL: false)
        case .provisioning:
            return .init(indicator: .spinner, title: "Setting up your Bridge…",
                         showsRetry: false, showsURL: false)
        case .connected:
            return .init(indicator: .success, title: "Connected",
                         showsRetry: false, showsURL: true)
        case .failed(let error):
            return .init(indicator: .failure, title: error.userMessage,
                         showsRetry: true, showsURL: false)
        }
    }
}

/// Inline progress UI for the Enable Cloud Access flow. Renders the pure
/// `ProvisioningPresentation` for the flow's current state and exposes a
/// `Retry` button (on `.failed`) that calls back into the flow.
public struct ProvisioningProgressView: View {
    private let state: EnableCloudAccessState
    /// The connected MCP URL (shown on `.connected`).
    private let mcpURL: String?
    /// Retry handler — wired to `flow.start()` by the parent.
    private let onRetry: () -> Void

    public init(
        state: EnableCloudAccessState,
        mcpURL: String? = nil,
        onRetry: @escaping () -> Void = {}
    ) {
        self.state = state
        self.mcpURL = mcpURL
        self.onRetry = onRetry
    }

    private var presentation: ProvisioningPresentation {
        ProvisioningPresentation.make(for: state)
    }

    public var body: some View {
        let p = presentation
        if p.indicator == .none {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    indicatorView(p.indicator)
                    Text(p.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.indicator == .failure ? BridgeTokens.bad : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if p.showsRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                if p.showsURL, let url = mcpURL, !url.isEmpty {
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func indicatorView(_ indicator: ProvisioningPresentation.Indicator) -> some View {
        switch indicator {
        case .none:
            EmptyView()
        case .spinner:
            ProgressView()
                .controlSize(.small)
        case .browser:
            Image(systemName: "safari")
                .foregroundStyle(NotionPalette.blue)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BridgeTokens.ok)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(BridgeTokens.bad)
        }
    }
}
