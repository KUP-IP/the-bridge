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
//
// v4 "Liquid Glass, evolved" reskin (PKT-connection): repainted onto the W1
// token ladder + W2 component kit (BridgeGlassCard, BridgeStatusStrip,
// BridgeBadge, BridgeListIconTile, BridgeBanner). Faithful to the "Remote
// access" card in design/the-bridge-design-system/project/pages/
// page-connection.jsx — the mcp.kup.solutions/mcp directory URL (muted, served
// over a Cloudflare tunnel, WorkOS sign-in), an honest coming-soon state, and
// the capability-scoped / passkey-gated / credentials-stay-local posture rows.
// When the cloud tenant is provisioned the live authenticated BridgeStatusStrip
// + login/re-auth flow re-appear. Both themes resolve through the adaptive
// tokens. Every controller branch (RemoteAccessToggleDecision, the flow state
// machine, the disable/first-run gates, Add-to-Claude.ai) is preserved verbatim.

import SwiftUI
import AppKit

/// Pure, headless-testable resolution of what a Remote Access toggle change
/// should DO — factored out of the SwiftUI view so every branch is unit-
/// asserted without a render (the same pattern as `ProvisioningPresentation`
/// / `FirstRunCloudAccessGate`).
///
/// Two behaviours this encodes that the live UI got wrong before:
///   • `.comingSoon` — when the cloud tenant isn't configured (placeholder
///     WorkOS client id; PKT-810 not yet live) toggling ON must NOT launch the
///     sign-in flow (which can only dead-end on WorkOS's "Invalid client ID"
///     page). It keeps the toggle OFF and surfaces a "coming soon" state.
///   • `.ignore` for an OFF request while already `.offline` — a `.failed` run
///     reverts the toggle programmatically (`cloudAccessEnabled = false`); that
///     reverting write re-enters the toggle's `onChange` and must NOT be
///     treated as a user cancel — doing so tore down the flow and wiped the
///     on-screen error (`.failed` → `.idle` → "Disabled") before the user
///     could read it. That was the "silent revert" observed live.
public enum RemoteAccessToggleDecision: Sendable, Equatable {
    /// Cloud sign-in isn't configured yet — keep OFF, show "coming soon".
    case comingSoon
    /// Begin (or retry) the Enable flow.
    case startFlow
    /// Online + user turned it OFF → confirm before tearing the tunnel down.
    case confirmDisable
    /// Mid-flow OFF (not yet online) → cancel the in-flight run.
    case cancelFlow
    /// No-op: already online and asked ON again, or a programmatic
    /// failure-revert OFF that must leave the error surface intact.
    case ignore

    /// Resolve the action for a toggle change.
    /// - Parameters:
    ///   - requestedOn: the new toggle value the user (or a programmatic write)
    ///     set.
    ///   - configured: whether the cloud tenant is provisioned
    ///     (`WorkOSConfig.isConfigured`).
    ///   - state: the current display state.
    public static func resolve(
        requestedOn: Bool,
        configured: Bool,
        state: RemoteAccessSection.DisplayState
    ) -> RemoteAccessToggleDecision {
        if requestedOn {
            if !configured { return .comingSoon }
            return state == .online ? .ignore : .startFlow
        } else {
            switch state {
            case .online:  return .confirmDisable
            case .offline: return .ignore   // failure already reverted us
            default:       return .cancelFlow
            }
        }
    }
}

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
            case .online:     return BridgeTokens.ok
            case .degraded:   return BridgeTokens.warn
            case .connecting: return BridgeTokens.warn
            case .offline:    return BridgeTokens.bad
            case .disabled:   return BridgeTokens.fg3
            }
        }

        /// The W2 `BridgeSignal` for this state — drives the `BridgeStatusStrip`
        /// dot + (warn/bad) border tint. Mirrors `dotColor`.
        var signal: BridgeSignal {
            switch self {
            case .online:     return .ok
            case .degraded:   return .warn
            case .connecting: return .warn
            case .offline:    return .bad
            case .disabled:   return .neutral
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

    /// PKT-810: Model A (the bespoke kup-worker "Enable Cloud Access" flow) is
    /// DISABLED pending multi-tenant reconciliation. Toggling it provisioned a
    /// tenant and advertised a non-resolving `*.bridge.kup.solutions` URL that
    /// conflicted with — and broke setup of — the directory OAuth connector
    /// (Model B: `mcp.kup.solutions/mcp`, the single blessed cloud path that
    /// works on web + mobile + desktop). Flip to `true` to re-enable once WS-B
    /// multi-tenant routing actually ships. Until then the toggle is disabled +
    /// shows the "coming soon" state.
    public static let modelAEnabled = false

    /// Whether the cloud tenant is provisioned (`WorkOSConfig.isConfigured`)
    /// AND Model A is enabled (`modelAEnabled`). When false the Enable toggle
    /// is disabled + shows "Coming soon" rather than launching a flow that can
    /// only error or hand out a dead tenant URL.
    private let cloudConfigured: Bool

    /// WS-F: factory for the live Enable flow. Injectable so tests / previews
    /// can supply a mock-backed flow; defaults to `.live()` over the shared
    /// `BridgeCloudManager`-shaped provisioner.
    private let makeFlow: @MainActor () -> EnableCloudAccessFlow

    public init(
        displayState: DisplayState = .disabled,
        defaults: UserDefaults = .standard,
        cloudConfigured: Bool = RemoteAccessSection.modelAEnabled && WorkOSConfig.resolved().isConfigured,
        makeFlow: @escaping @MainActor () -> EnableCloudAccessFlow = { RemoteAccessSection.defaultFlow() }
    ) {
        self._displayState = State(initialValue: displayState)
        self._cloudAccessEnabled = State(initialValue: displayState != .disabled)
        self.defaults = defaults
        self.cloudConfigured = cloudConfigured
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

    /// The blessed directory-connector URL — the cloud path users will paste once
    /// remote access goes live. Surfaced as STATIC copyable reference text today
    /// (PKT-810 not yet enabled on this build), NOT gated behind an unreachable
    /// `.online` state. This fixes the dead-URL problem: the page previously only
    /// built a URL from a tunnel hostname that is never set while
    /// `cloudConfigured == false`, so the cloud half showed all chrome, no payload.
    static let directoryConnectorURL = "https://mcp.kup.solutions/mcp"

    @State private var copiedDirectoryURL = false

    public var body: some View {
        // Hosted inside the ConnectionSection composite's outer scroll (it racks
        // ConnectionsSection above this and supplies the scroll + bottom inset),
        // so NO inner ScrollView here — it would nest scrolls. We mirror the
        // ConnectionsSection sibling: just the card stack + horizontal pane pad.
        VStack(spacing: BridgeTokens.Space.cardGap) {
            statusCard
            securityCard
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
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

    // MARK: - Status

    private var statusCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    BridgeCardLabel("Remote access")
                    Spacer()
                    // Coming-soon badge in the head act-slot (design: `.badge.warn`)
                    // only while the cloud tenant isn't provisioned.
                    if !cloudConfigured {
                        BridgeBadge("Coming soon", tone: .warn, showsDot: true)
                    }
                }

                // Blessed directory-connector URL as static copyable reference.
                directoryURLRow

                // Model A: an honest "Coming soon" BANNER + posture-context line
                // when cloud isn't configured (today's default) — never a dead
                // switch. When the cloud tenant IS provisioned, the live
                // authenticated status strip + Enable toggle + flow re-appear
                // (preserving RemoteAccessToggleDecision).
                if cloudConfigured {
                    Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
                    authenticatedStrip
                    enableToggleRow
                    if let flow, ProvisioningPresentation.make(for: flow.state).indicator != .none {
                        ProvisioningProgressView(
                            state: flow.state,
                            mcpURL: connectedMCPURL,
                            onRetry: { flow.start() }
                        )
                    }
                    addToClaudeRow
                } else {
                    comingSoonRow
                }
            }
        }
        // Mirror the flow's terminal transitions back onto the toggle +
        // status dot (DoD: success → green/.connected; failure → revert).
        .onChange(of: flowStateKey) { _, _ in syncFromFlow() }
    }

    /// The blessed cloud path, copyable today even though sign-in is gated. An
    /// inset well (`.cnp-endpoint`) with a cloud glyph tile, the mono URL in a
    /// MUTED ink (the design renders the not-yet-live URL `code.muted`), and a
    /// check-confirm copy button — sibling to the loopback endpoint well.
    private var directoryURLRow: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 10) {
            BridgeListIconTile(systemImage: "cloud")
                .accessibilityHidden(true)
            Text(Self.directoryConnectorURL)
                .font(BridgeTokens.Typeface.mono)
                .foregroundStyle(cloudConfigured ? BridgeTokens.accentLink : BridgeTokens.fg3)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button { copyDirectoryURL() } label: {
                Image(systemName: copiedDirectoryURL ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(copiedDirectoryURL ? BridgeTokens.okText : BridgeTokens.fg3)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy directory-connector URL")
            .accessibilityLabel(copiedDirectoryURL ? "Copied directory connector URL" : "Copy directory connector URL")
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(shape.fill(BridgeTokens.wellFill))
        .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
    }

    /// Honest "coming soon" state — a `.warn` banner + one explanatory line,
    /// no switch. The directory URL above is the path users will add once cloud
    /// sign-in (Cloudflare tunnel + WorkOS) ships.
    private var comingSoonRow: some View {
        BridgeBanner(
            signal: .warn,
            message: "Cloud sign-in isn't enabled on this build yet. The hosted connector will front this Mac over a Cloudflare tunnel — no port opened, sign-in through WorkOS. The URL above is the directory address it will live at.",
            systemImage: "clock"
        )
    }

    /// The live authenticated status strip (`BridgeStatusStrip`) shown once the
    /// cloud tenant is provisioned: the state dot + label, the org + tunnel meta
    /// (mono), and a trailing tunnel badge. Replaces the old bespoke status row
    /// with the W2 component so it matches every other status surface.
    private var authenticatedStrip: some View {
        BridgeStatusStrip(
            signal: displayState.signal,
            title: displayState.rawValue,
            meta: ["mcp.kup.solutions", "cloudflared"]
        ) {
            BridgeBadge("WorkOS", tone: displayState == .online ? .ok : .neutral)
        }
    }

    /// Live Enable toggle — only shown when the cloud tenant is provisioned.
    /// The login/logout/re-auth switch: ON starts the cloudflared tunnel + sign-in
    /// flow, OFF tears it down (confirmed). Uses the native switch tinted to the
    /// one accent so it reads as the page's single primary control.
    private var enableToggleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayState == .online ? "Remote access is on" : "Enable remote access")
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg1)
                Text("Starts a cloudflared tunnel and signs in through WorkOS so cloud agents can delegate work to this Mac.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Enable remote access", isOn: $cloudAccessEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(BridgeTokens.accent)
                .onChange(of: cloudAccessEnabled) { _, on in
                    handleToggle(on)
                }
                .accessibilityIdentifier(BridgeAXID.Connection.toggleRemote)   // PKT-1005 remainder (b)
        }
    }

    // MARK: - Toggle wiring (WS-F)

    /// Toggle changed → resolve the intent through the pure
    /// `RemoteAccessToggleDecision` and act on it:
    ///   • `.comingSoon`     — cloud sign-in isn't configured; snap the toggle
    ///       back OFF and leave the "Coming soon" state. Never opens a browser.
    ///   • `.startFlow`      — begin (or, via the toggle, retry) the Enable flow.
    ///   • `.confirmDisable` — online + OFF → WS-G teardown confirmation (the
    ///       toggle visually flips OFF but nothing tears down until confirmed).
    ///   • `.cancelFlow`     — mid-flow OFF → cancel the in-flight run.
    ///   • `.ignore`         — no-op. Covers two cases: already online + asked
    ///       ON again, and the programmatic failure-revert OFF (which must
    ///       leave the `.offline` error + Retry surface intact — re-entering a
    ///       cancel here is exactly what silently wiped the error before).
    private func handleToggle(_ on: Bool) {
        switch RemoteAccessToggleDecision.resolve(
            requestedOn: on, configured: cloudConfigured, state: displayState
        ) {
        case .comingSoon:
            if cloudAccessEnabled { cloudAccessEnabled = false }
        case .startFlow:
            didCopyMCPURL = false
            let f = flow ?? makeFlow()
            flow = f
            displayState = .connecting
            f.start()
        case .confirmDisable:
            showDisableConfirm = true
        case .cancelFlow:
            flow?.cancel()
            displayState = .disabled
        case .ignore:
            break
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
                BridgeButton(
                    "Add to Claude.ai",
                    systemImage: "plus.circle",
                    variant: .primary,
                    isEnabled: cloudTunnelHostname != nil
                ) {
                    addToClaude()
                }
                .accessibilityIdentifier(BridgeAXID.Connection.addToClaude)   // PKT-1005 remainder (b)
                if didCopyMCPURL {
                    Text(ClaudeAIIntegration.pasteHint)
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg3)
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

    /// Copy the blessed directory-connector URL to the pasteboard with a brief
    /// check-confirm (mirrors the loopback Copy affordance).
    private func copyDirectoryURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.directoryConnectorURL, forType: .string)
        copiedDirectoryURL = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copiedDirectoryURL = false
        }
    }

    // MARK: - Security posture

    private var securityCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 9) {
                BridgeCardLabel("How remote actions stay safe")
                postureRow(
                    icon: "checkmark.shield",
                    title: "Capability-scoped",
                    detail: "The cloud can only ask this Mac to run one short-lived, pre-scoped operation at a time — never browse freely."
                )
                Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
                postureRow(
                    icon: "touchid",
                    title: "Passkey-gated",
                    detail: "Before any stored credential is used, this Mac requires a fresh local passkey (Touch ID) approval."
                )
                Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
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
        HStack(alignment: .top, spacing: 11) {
            // Leading tile with the posture glyph tinted to the ok signal — the
            // design's `.cnp-posture` "this is a guarantee" green check read.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BridgeTokens.wellFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5)
                )
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(BridgeTokens.okText)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BridgeTokens.Typeface.body.weight(.semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(detail)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }
}
