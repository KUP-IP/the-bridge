// RemoteAccessSection.swift — WS-E (Mac-side cloud access · Settings)
// NotionBridge · UI · Sections
//
// Settings → Remote Access pane. Surfaces Bridge Cloud Access: the
// cloudflared-backed Mac↔cloud tunnel (WS-C `BridgeCloudManager`) and the
// auth-passdown security posture from NL-3 (capability-gated + passkey-
// gated local execution; raw client credentials never leave the Mac).
//
// Static layout for this slice — it mirrors the glass-card structure of
// StandingOrdersSection / ConnectionsSection so it drops into the existing
// sidebar without new design primitives. The live wiring to a running
// `BridgeCloudManager` instance is a later slice; this compiles, renders,
// and states the security contract the user is opting into.

import SwiftUI
import AppKit

public struct RemoteAccessSection: View {
    /// Mirrors the WS-C `CloudConnectionState` machine for display. Static
    /// in this slice (defaults to `.disabled`); a later slice binds it to a
    /// live `BridgeCloudManager`.
    public enum DisplayState: String, Sendable, Equatable {
        case disabled   = "Disabled"
        case connecting = "Connecting\u{2026}"
        case online     = "Online"
        case degraded   = "Degraded"
        case offline    = "Offline"

        var dotColor: Color {
            switch self {
            case .online:     return .green
            case .degraded:   return .orange
            case .connecting: return .yellow
            case .offline:    return .red
            case .disabled:   return .secondary
            }
        }
    }

    @State private var displayState: DisplayState
    @State private var cloudAccessEnabled: Bool
    /// WS-F: the Enable-flow state machine. Lazily built on first toggle-ON
    /// so the static preview / non-interactive paths carry no live deps.
    @State private var flow: EnableCloudAccessFlow?

    // MARK: WS-G state

    /// Whether the one-time first-run guide sheet is presented.
    @State private var showFirstRun = false
    /// Whether the Disable-confirmation dialog is presented.
    @State private var showDisableConfirm = false
    /// Whether the Add-to-Claude.ai copy+hint has been shown (drives the
    /// inline confirmation line under the button).
    @State private var didCopyMCPURL = false
    /// Backing store for the `hasSeenCloudAccessFirstRun` one-time gate.
    private let defaults: UserDefaults

    /// WS-F: factory for the live Enable flow. Injectable so tests / previews
    /// can supply a mock-backed flow; defaults to `.live()` over the shared
    /// `BridgeCloudManager`-shaped provisioner.
    private let makeFlow: @MainActor () -> EnableCloudAccessFlow

    public init(
        displayState: DisplayState = .disabled,
        defaults: UserDefaults = .standard,
        makeFlow: @escaping @MainActor () -> EnableCloudAccessFlow = { RemoteAccessSection.defaultFlow() }
    ) {
        self._displayState = State(initialValue: displayState)
        self._cloudAccessEnabled = State(initialValue: displayState != .disabled)
        self.defaults = defaults
        self.makeFlow = makeFlow
    }

    /// Build the production Enable flow over a fresh `BridgeCloudManager`.
    /// The manager runs on `main` (the flow is `@MainActor`); the live
    /// Worker base URL is resolved by `.live()` (configurable; WS-A gates
    /// the real network path).
    ///
    /// NOTE: WS-C shipped `BridgeCloudManager` with injectable `TunnelProcess`
    /// / `PasskeyGate` seams but only the in-memory `Fake*` conformers; the
    /// real cloudflared process + Secure-Enclave passkey conformers land with
    /// the live Worker (WS-A) / operator tenant (PKT-810). Until then the
    /// manager is assembled over those seams so the toggle, state machine,
    /// and `BridgeDefaults` wiring are all live — only the underlying network
    /// + cloudflared remain gated. The passkey gate is unused on the
    /// provisioning path (it guards auth-passdown, not provision()).
    @MainActor
    public static func defaultFlow() -> EnableCloudAccessFlow {
        let manager = BridgeCloudManager(
            tunnel: FakeTunnelProcess(),
            passkeyGate: FakePasskeyGate(outcome: .approved),
            node: LocalNodeContext(ownerID: "local", deviceID: deviceIdentifier())
        )
        return EnableCloudAccessFlow.live(provisioner: manager)
    }

    /// A stable-ish device identifier for the local node (hostname-derived).
    @MainActor
    private static func deviceIdentifier() -> String {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: " ", with: "-")
        return host.isEmpty ? "this-mac" : host
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                statusCard
                securityCard
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        // WS-G: one-time first-run guide, shown on the first transition to
        // .online (gated by hasSeenCloudAccessFirstRun).
        .sheet(isPresented: $showFirstRun) {
            FirstRunCloudAccessModal {
                defaults.set(true, forKey: BridgeDefaults.hasSeenCloudAccessFirstRun)
                showFirstRun = false
            }
        }
        // WS-G: Disable-while-online confirmation. Confirm tears the tunnel
        // down + clears state; Cancel reverts the toggle to ON with no side
        // effects.
        .confirmationDialog(
            "Disable Cloud Access?",
            isPresented: $showDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Disable", role: .destructive) { confirmDisable() }
            Button("Cancel", role: .cancel) { cancelDisable() }
        } message: {
            Text("Your MCP URL will stop working until re-enabled.")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(NotionPalette.blue.opacity(0.20))
                        .frame(width: 44, height: 44)
                    Image(systemName: "cloud")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(NotionPalette.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote Access")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Reach this Mac from the cloud over a private tunnel. Every remote action is capability-scoped and passkey-gated — your credentials never leave this machine.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Bridge Cloud Access")
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Remote Access")
                            .font(.system(size: 13, weight: .medium))
                        Text("Starts a cloudflared tunnel so cloud agents can delegate work to this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $cloudAccessEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: cloudAccessEnabled) { _, on in
                            handleToggle(on)
                        }
                }
                Divider().background(Color.white.opacity(0.08))
                statusRow
                if let flow, ProvisioningPresentation.make(for: flow.state).indicator != .none {
                    ProvisioningProgressView(
                        state: flow.state,
                        mcpURL: connectedMCPURL,
                        onRetry: { flow.start() }
                    )
                }
                addToClaudeRow
            }
        }
        // Mirror the flow's terminal transitions back onto the toggle +
        // status dot (DoD: success → green/.connected; failure → revert).
        .onChange(of: flowStateKey) { _, _ in syncFromFlow() }
    }

    // MARK: - Toggle wiring (WS-F)

    /// Toggle ON → start the Enable flow. Toggle OFF: if cloud access is
    /// currently online (a live connection), intercept with the WS-G Disable
    /// confirmation (the toggle visually flips OFF but no teardown happens
    /// until the user confirms); otherwise (mid-flow / not yet online) just
    /// cancel the in-flight run.
    private func handleToggle(_ on: Bool) {
        if on {
            // Already online (e.g. the toggle was just reverted by a cancelled
            // Disable) → the connection is live; do NOT restart provisioning.
            guard displayState != .online else { return }
            didCopyMCPURL = false
            let f = flow ?? makeFlow()
            flow = f
            displayState = .connecting
            f.start()
        } else if displayState == .online {
            // Guard the teardown behind a confirmation (DoD).
            showDisableConfirm = true
        } else {
            flow?.cancel()
            displayState = .disabled
        }
    }

    // MARK: - Disable flow (WS-G)

    /// User confirmed Disable: tear the tunnel down, clear persisted state,
    /// and drop the UI to disabled. The toggle is already visually OFF.
    private func confirmDisable() {
        showDisableConfirm = false
        didCopyMCPURL = false
        let f = flow
        Task { @MainActor in
            await f?.disable()
            displayState = .disabled
        }
    }

    /// User cancelled Disable: revert the toggle back to ON. No teardown, no
    /// state change — the tunnel keeps running.
    private func cancelDisable() {
        showDisableConfirm = false
        if !cloudAccessEnabled { cloudAccessEnabled = true }
    }

    /// A hashable projection of the flow state so `.onChange` fires on every
    /// transition (the flow itself isn't Equatable as a whole).
    private var flowStateKey: String {
        guard let flow else { return "nil" }
        return String(describing: flow.state)
    }

    /// Reconcile the local display state + toggle from the flow's state.
    private func syncFromFlow() {
        guard let flow else { return }
        switch flow.state {
        case .idle:
            displayState = .disabled
        case .checkingAccount, .signingIn, .provisioning:
            displayState = .connecting
        case .connected:
            displayState = .online
            maybePresentFirstRun()
        case .failed:
            // Flow already reverted BridgeDefaults.cloudAccessEnabled = false;
            // snap the toggle + dot back so the UI matches.
            displayState = .offline
            if cloudAccessEnabled { cloudAccessEnabled = false }
        }
    }

    /// The connected MCP URL surfaced on success, from the persisted tunnel
    /// hostname (BridgeDefaults), if any.
    private var connectedMCPURL: String? {
        guard let host = defaults.string(forKey: BridgeDefaults.cloudTunnelHostname),
              !host.isEmpty else { return nil }
        return "https://\(host)/mcp"
    }

    /// The persisted tunnel hostname (drives the Add-to-Claude.ai enabled
    /// state — enabled only once a hostname exists).
    private var cloudTunnelHostname: String? {
        let host = defaults.string(forKey: BridgeDefaults.cloudTunnelHostname)
        return (host?.isEmpty == false) ? host : nil
    }

    // MARK: - First-run gate (WS-G)

    /// Present the one-time first-run guide if the gate allows (online + flag
    /// not yet set). Idempotent — the gate + the `hasSeen` flag prevent a
    /// second presentation.
    private func maybePresentFirstRun() {
        let hasSeen = defaults.bool(forKey: BridgeDefaults.hasSeenCloudAccessFirstRun)
        if FirstRunCloudAccessGate.shouldPresent(isOnline: true, hasSeenFirstRun: hasSeen) {
            showFirstRun = true
        }
    }

    // MARK: - Add to Claude.ai (WS-G)

    /// The "Add to Claude.ai" affordance — enabled only when a tunnel hostname
    /// is provisioned. Q3 (COA 2026-05-27) shipped as copy + inline hint
    /// (`ClaudeAIIntegration.shippedMode == .copyAndHint`): the deep-link
    /// format could not be confirmed at build time, so we copy the MCP URL and
    /// instruct the user to paste it in Claude.ai → Settings → Integrations.
    @ViewBuilder
    private var addToClaudeRow: some View {
        if displayState == .online {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    addToClaude()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Add to Claude.ai")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(cloudTunnelHostname == nil)
                if didCopyMCPURL {
                    Text(ClaudeAIIntegration.pasteHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Execute the Add-to-Claude.ai action per the shipped mode. In
    /// `.copyAndHint` (the Q3 fallback) it copies the MCP URL to the pasteboard
    /// and reveals the inline hint. In `.openBrowser` (reserved, gated on a
    /// confirmed Q3 format) it would open the encoded deep link.
    private func addToClaude() {
        guard let mcp = ClaudeAIIntegration.mcpURL(forHostname: cloudTunnelHostname) else { return }
        switch ClaudeAIIntegration.shippedMode {
        case .copyAndHint:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(mcp, forType: .string)
            didCopyMCPURL = true
        case .openBrowser:
            if let url = ClaudeAIIntegration.deepLink(forHostname: cloudTunnelHostname) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(displayState.dotColor)
                .frame(width: 8, height: 8)
            Text(displayState.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(displayState.dotColor)
            Spacer()
            Text("Tunnel: cloudflared")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Security posture

    private var securityCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("How remote actions stay safe")
                postureRow(
                    icon: "checkmark.shield",
                    title: "Capability-scoped",
                    detail: "The cloud can only ask this Mac to run one short-lived, pre-scoped operation at a time — never browse freely."
                )
                Divider().background(Color.white.opacity(0.08))
                postureRow(
                    icon: "touchid",
                    title: "Passkey-gated",
                    detail: "Before any stored credential is used, this Mac requires a fresh local passkey (Touch ID) approval."
                )
                Divider().background(Color.white.opacity(0.08))
                postureRow(
                    icon: "lock.fill",
                    title: "Credentials stay local",
                    detail: "Raw client credentials live only in this Mac's Keychain. They are never sent to, or stored by, the cloud."
                )
            }
        }
    }

    @ViewBuilder
    private func postureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NotionPalette.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
